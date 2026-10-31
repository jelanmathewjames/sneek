import Foundation

public actor Daemon {
    public let configStore: ConfigStore
    public let sessionManager: SessionManager
    public let tunnelManager: SSHTunnelManager
    private let ipcServer: IPCServer
    private let restrictSocket: Bool
    private var previousCommands: [String: CommandConfig] = [:]

    public init(configStore: ConfigStore, socketPath: String? = nil, restrictSocket: Bool? = nil) {
        self.configStore = configStore
        self.sessionManager = SessionManager()
        self.tunnelManager = SSHTunnelManager()
        let global = configStore.globalConfig
        self.restrictSocket = restrictSocket ?? global.restrictSocket ?? false
        let path = Self.resolveSocketPath(explicit: socketPath, config: global, baseDir: configStore.baseDir)
        self.ipcServer = IPCServer(socketPath: path, mode: global.socketMode.flatMap(Self.parseMode))
    }

    /// Explicit flag beats `socket_path` in config.json beats `<config dir>/sneekd.sock`.
    static func resolveSocketPath(explicit: String?, config: SneekConfig, baseDir: URL) -> String {
        explicit ?? config.socketPath ?? baseDir.appendingPathComponent("sneekd.sock").path
    }

    /// Client-side socket path resolution. Reads `<baseDir>/config.json` directly
    /// (never via `ConfigStore`, which creates `<baseDir>/commands/` as a side
    /// effect) so resolving a path has no filesystem side effect of its own.
    public static func resolveClientSocketPath(baseDir: URL, explicit: String?) -> String {
        if let explicit { return explicit }
        let configPath = baseDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configPath),
           let config = try? JSONDecoder().decode(SneekConfig.self, from: data),
           let socketPath = config.socketPath {
            return socketPath
        }
        return baseDir.appendingPathComponent("sneekd.sock").path
    }

    /// `"0660"` / `"660"` → `0o660`; anything that is not an octal mode → nil.
    static func parseMode(_ s: String) -> mode_t? {
        guard let v = UInt16(s, radix: 8), v <= 0o777 else { return nil }
        return mode_t(v)
    }

    private static let actionsAllowedWhenRestricted: Set<IPCAction> = [.run, .tools, .status]

    static func restrictionRefusal(for request: IPCRequest, restricted: Bool) -> IPCResponse? {
        guard restricted, !actionsAllowedWhenRestricted.contains(request.action) else { return nil }
        return .refused(code: "action_restricted", "action '\(request.action.rawValue)' is not allowed on this socket")
    }

    public func start() async throws {
        let memoryHidden = Sys.hideProcessMemory()

        // Initialize logger
        let logsDir = configStore.baseDir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        SneekLogger.logFile = logsDir.appendingPathComponent("sneekd.log")

        SneekLogger.info("daemon: starting")
        if memoryHidden {
            SneekLogger.info("daemon: process memory hidden from same-user processes (PR_SET_DUMPABLE=0)")
        }

        // A typo in socket_mode must not silently fall back to a world-accessible
        // socket — refuse to bind at all.
        if let raw = configStore.globalConfig.socketMode, Self.parseMode(raw) == nil {
            throw IPCError.bindFailed("invalid socket_mode '\(raw)': it is not an octal mode like 0660")
        }

        // A server that cannot audit must not serve: an unopenable path is a start-up
        // error, not a warning. Absent `audit_log` leaves this nil and records nothing.
        let auditPath = configStore.globalConfig.auditLog
        let audit: AuditLog? = try auditPath.map { try AuditLog(path: $0) }
        if let auditPath { SneekLogger.info("daemon: auditing every IPC request to \(auditPath)") }

        try ipcServer.start()

        previousCommands = configStore.commands

        // Watch for config changes — start tunnels for newly enabled commands,
        // reap sessions when their runtime-affecting config changed.
        configStore.onChange = { [weak self] in
            Task { await self?.handleConfigChange() }
        }
        configStore.startWatching()

        let sessionMgr = sessionManager
        let tunnelMgr = tunnelManager
        let store = configStore
        let restricted = restrictSocket

        ipcServer.handler = { [weak self] request, peer in
            let started = Date()
            SneekLogger.debug("daemon: IPC request received: \(request.action)")

            // Every branch below produces (response, secret values to redact from the
            // audit line). The audit record is written before the response is returned —
            // including for the shutdown branch, which exits asynchronously.
            let outcome: (response: IPCResponse, redact: [String])
            if let refusal = Self.restrictionRefusal(for: request, restricted: restricted) {
                SneekLogger.warn("daemon: refused '\(request.action.rawValue)' on a restricted socket")
                outcome = (refusal, [])
            } else if request.action == .shutdown {
                SneekLogger.info("daemon: shutdown requested via IPC")
                outcome = (.ok("shutting down"), [])
            } else {
                outcome = await Self.handleRequest(request, configStore: store, sessionManager: sessionMgr,
                                                   tunnelManager: tunnelMgr, auditPath: auditPath)
            }

            if let audit {
                await audit.record(AuditLog.entry(for: request, peer: peer, response: outcome.response,
                                                  started: started, redact: outcome.redact))
            }
            if request.action == .shutdown, outcome.response.success {
                Task { await self?.stop(); Foundation.exit(0) }
            }
            return outcome.response
        }

        // Start auto-connect tunnels (skip disabled commands and disabled tunnels)
        for (name, cmd) in configStore.commands {
            if cmd.enabled == false { continue }
            if let tunnel = cmd.tunnel, tunnel.enabled != false, tunnel.autoConnect == true {
                try? await tunnelManager.ensureUp(name, tunnel: tunnel)
            }
        }

        // When a tunnel is respawned by the monitor, any session bound to the old
        // forward is now talking to a dead socket — reap it so the next call re-establishes.
        await tunnelManager.setOnReconnect { [sessionMgr] name in
            await sessionMgr.reap(name)
            SneekLogger.info("session/\(name): reaped after tunnel reconnect")
        }

        // Start-up check: warm every prod command so an account that can write is reported at boot.
        // A failure only logs — the daemon still starts and the command stays refused until a
        // session can start and pass.
        if configStore.globalConfig.requireReadonlyProd == true {
            for (name, cmd) in configStore.commands where cmd.enabled != false && ReadonlyCheck.isProd(cmd) {
                Task {
                    let r = await Self.runCommand(name: name, input: "", configStore: store,
                                                  sessionManager: sessionMgr, tunnelManager: tunnelMgr)
                    if r.success { SneekLogger.info("startup: '\(name)' read-only check passed") }
                    else { SneekLogger.error("startup: '\(name)' will be refused: \(r.error ?? "unknown")") }
                }
            }
        }

        await tunnelManager.startMonitoring()
        await ipcServer.acceptLoop()
    }

    public func stop() async {
        SneekLogger.info("daemon: stopping")
        configStore.stopWatching()
        ipcServer.stop()
        await tunnelManager.stopMonitoring()
        await sessionManager.reapAll()
        await tunnelManager.tearDownAll()
    }

    // MARK: - Config Change Handling

    private func handleConfigChange() async {
        let current = configStore.commands
        let previous = previousCommands
        previousCommands = current

        for (name, cmd) in current {
            if cmd.enabled == false {
                try? await tunnelManager.tearDown(name)
                await sessionManager.reap(name)
                continue
            }

            // If a live session was started under a previous config whose runtime
            // fields differ (e.g. setup_commands cleared, password rotated), reap
            // it so the next call re-establishes against the new config.
            if let prev = previous[name], Self.sessionConfigChanged(prev, cmd) {
                await sessionManager.reap(name)
                SneekLogger.info("session/\(name): reaped after config change")
            }

            if let tunnel = cmd.tunnel, tunnel.enabled != false {
                if tunnel.autoConnect == true {
                    try? await tunnelManager.ensureUp(name, tunnel: tunnel)
                }
            } else {
                try? await tunnelManager.tearDown(name)
            }
        }

        // Commands removed from disk — drop their tunnel and session.
        for name in previous.keys where current[name] == nil {
            try? await tunnelManager.tearDown(name)
            await sessionManager.reap(name)
        }
    }

    /// True when `b` changes any field that affects an already-running session,
    /// such that the session should be reaped and re-established.
    static func sessionConfigChanged(_ a: CommandConfig, _ b: CommandConfig) -> Bool {
        a.command != b.command
            || a.setupCommands != b.setupCommands
            || a.sentinel != b.sentinel
            || a.secrets != b.secrets
            || a.variables != b.variables
            || a.mode != b.mode
            || a.tunnel != b.tunnel
            || a.secretEnv != b.secretEnv || a.secretFiles != b.secretFiles || a.statementTimeout != b.statementTimeout
            || a.queryLimit != b.queryLimit || a.rowCap != b.rowCap
    }

    // MARK: - Request Handling

    /// Returns the wire response plus the resolved secret values that must be redacted
    /// from the audit line. Only `run` ever resolves secrets; every other action returns
    /// an empty redaction list.
    private static func handleRequest(
        _ request: IPCRequest,
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager,
        auditPath: String? = nil
    ) async -> (response: IPCResponse, redact: [String]) {
        switch request.action {
        case .status:
            return (await statusResponse(configStore: configStore, sessionManager: sessionManager,
                                         tunnelManager: tunnelManager, auditPath: auditPath), [])

        case .run:
            guard let cmdName = request.command else {
                return (.fail("missing command name"), [])
            }
            return await runCommandAudited(name: cmdName, input: request.input, configStore: configStore, sessionManager: sessionManager, tunnelManager: tunnelManager)

        case .tunnel:
            guard let cmdName = request.command, let op = request.operation else {
                return (.fail("missing command name or operation"), [])
            }
            return (await tunnelOp(name: cmdName, operation: op, configStore: configStore, sessionManager: sessionManager, tunnelManager: tunnelManager), [])

        case .list:
            let names = configStore.commands.keys.sorted()
            return (.ok(names.joined(separator: "\n")), [])

        case .tools:
            return (IPCResponse(success: true, tools: ToolCatalog.enabledTools(in: configStore.commands)), [])

        case .shutdown:
            return (.ok("shutting down"), [])
        }
    }

    private static func statusResponse(
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager,
        auditPath: String? = nil
    ) async -> IPCResponse {
        var lines: [String] = ["daemon: running"]

        // One hop, one snapshot: reading the names and then each name's count was N+1 hops,
        // with a session free to start or end in between, so the two numbers printed on this
        // line could describe two different moments.
        let sessions = await sessionManager.sessionSnapshot()
        lines.append("sessions: \(sessions.count) commands, \(sessions.values.reduce(0, +)) processes")

        for (name, cmd) in configStore.commands {
            if cmd.tunnel != nil {
                let ts = await tunnelManager.status(name)
                lines.append("tunnel/\(name): \(ts)")
            }
        }

        if let auditPath { lines.append("audit: \(auditPath)") }

        return .ok(lines.joined(separator: "\n"))
    }

    /// Internal rather than private so a test can pin the wire response it produces.
    /// Its signature is the stable one; `runCommandAudited` carries the extra redaction
    /// list the audit log needs and this wrapper drops it.
    static func runCommand(
        name: String,
        input: String?,
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager
    ) async -> IPCResponse {
        await runCommandAudited(name: name, input: input, configStore: configStore,
                                sessionManager: sessionManager, tunnelManager: tunnelManager).response
    }

    /// The real implementation. Returns the resolved `secrets` values alongside the
    /// response so the caller can redact them from the audited input and error text —
    /// they are never logged, stored, or returned to the client.
    static func runCommandAudited(
        name: String,
        input: String?,
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager
    ) async -> (response: IPCResponse, redact: [String]) {
        guard let cmd = configStore.commands[name] else {
            return (.fail("unknown command: \(name)"), [])
        }
        if cmd.enabled == false {
            return (.fail("command '\(name)' is disabled"), [])
        }

        if let refusal = InputGuard.check(input: input, config: cmd, global: configStore.globalConfig) {
            SneekLogger.warn("daemon: refused input for '\(name)': \(refusal.code)")
            return (.refused(code: refusal.code, refusal.message), [])
        }

        SneekLogger.info("daemon: executing command '\(name)' (mode: \(cmd.mode))")

        // Resolve → render → plan, with the redaction set for everything after this point.
        let prepared: RunPipeline.Prepared
        do {
            prepared = try await RunPipeline.prepare(config: cmd, store: configStore)
        } catch let f as RunPipeline.Failure {
            if let refusal = f.underlying as? Refusal {
                SneekLogger.warn("daemon: refused '\(name)': \(refusal.code)")
                return (.refused(code: refusal.code, refusal.message), f.redact)
            }
            return (.fail("\(f.stage.rawValue): \(f.underlying)"), f.redact)
        } catch {
            return (.fail("\(error)"), [])      // prepare throws only Failure; the compiler cannot know
        }
        let secretValues = prepared.redact, resolvedCommand = prepared.command, launch = prepared.launch

        // Ensure tunnel is up (if configured and enabled)
        if let tunnel = cmd.tunnel, tunnel.enabled != false {
            do {
                try await tunnelManager.ensureUp(name, tunnel: tunnel)
            } catch {
                return (.fail("tunnel failed: \(error)"), secretValues)
            }
        }

        // Execute
        do {
            let result: String
            switch cmd.mode {
            case .session:
                guard let raw = input else {
                    return (.fail("session mode requires input"), secretValues)
                }
                result = try await sessionManager.send(input: RunPipeline.sessionInput(raw, config: cmd), to: name,
                                                       config: cmd, resolvedCommand: resolvedCommand, launch: launch)
            case .oneshot:
                result = try await sessionManager.runOneshot(command: resolvedCommand, input: input, launch: launch, rowCap: cmd.rowCap)
            }
            return (.ok(Redaction.apply(result, secrets: secretValues)), secretValues)
        } catch SessionError.readonlyCheckFailed(let refusal) {
            return (.refused(code: refusal.code, refusal.message), secretValues)
        } catch SessionError.timedOut(let seconds) {
            return (IPCResponse(success: false, error: "timed out after \(seconds)s waiting for '\(name)'; session restarted", code: "timeout"), secretValues)
        } catch let refusal as Refusal {
            return (.refused(code: refusal.code, refusal.message), secretValues)
        } catch {
            return (.fail(Redaction.apply("execution failed: \(error)", secrets: secretValues)), secretValues)
        }
    }

    static func tunnelOp(
        name: String,
        operation: String,
        configStore: ConfigStore,
        sessionManager: SessionManager,
        tunnelManager: SSHTunnelManager
    ) async -> IPCResponse {
        guard let cmd = configStore.commands[name], let tunnel = cmd.tunnel else {
            return .fail("no tunnel config for: \(name)")
        }

        switch operation {
        case "up":
            do {
                try await tunnelManager.ensureUp(name, tunnel: tunnel)
                return .ok("tunnel up")
            } catch {
                return .fail("tunnel up failed: \(error)")
            }
        case "down":
            do {
                try await tunnelManager.tearDown(name)
                // A live session holds a socket through the dead forward — reap it
                // so the next run re-establishes instead of failing once with EOF.
                await sessionManager.reap(name)
                return .ok("tunnel down")
            } catch {
                return .fail("tunnel down failed: \(error)")
            }
        case "status":
            let s = await tunnelManager.status(name)
            return .ok("\(s)")
        default:
            return .fail("unknown tunnel operation: \(operation)")
        }
    }
}

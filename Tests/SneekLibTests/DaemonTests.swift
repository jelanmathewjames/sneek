import Foundation
@testable import SneekLib

private func baseCommand() -> CommandConfig {
    CommandConfig(
        name: "pg-test",
        description: "test",
        mode: .session,
        readonly: true,
        command: "psql {{host}}",
        secrets: ["password": .keychain(key: "pg-test")],
        variables: ["host": "localhost"],
        setupCommands: ["SET default_transaction_read_only = on;"],
        blockedPatterns: ["DROP", "DELETE"],
        sentinel: #"\echo __SNEEK_DONE__"#
    )
}

private func runBlockingWithTimeout<T: Sendable>(seconds: Int = 15, _ body: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task { do { result = .success(try await body()) } catch { result = .failure(error) }; sem.signal() }
    if sem.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
        throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "timed out after \(seconds)s"])
    }
    return try result!.get()
}

func runDaemonTests() {
    print("\nDaemon:")

    test("run: a reply that never arrives comes back as the 'timeout' refusal, not a generic failure") {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-tmo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ConfigStore(baseDir: tempDir)
        var cmd = CommandConfig(name: "hangd", description: "t", mode: .session,
                                command: "exec bash --norc --noprofile", sentinel: "echo __SNEEK_DONE__")
        cmd.replyTimeout = 1
        try store.save(cmd)

        let response: IPCResponse = try runBlockingWithTimeout(seconds: 20) {
            let m = SessionManager()
            let r = await Daemon.runCommand(name: "hangd", input: "sleep 30", configStore: store,
                                            sessionManager: m, tunnelManager: SSHTunnelManager())
            await m.reapAll(); return r
        }
        check(!response.success && response.code == "timeout", "success=\(response.success) code=\(response.code ?? "nil")")
        check(response.error == "timed out after 1s waiting for 'hangd'; session restarted", response.error ?? "nil")
    }

    test("run: an input over 64 KiB is refused with input_too_large before anything runs") {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-big-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ConfigStore(baseDir: tempDir)
        try store.save(CommandConfig(name: "big", description: "t", mode: .session,
                                     command: "exec bash --norc --noprofile", sentinel: "echo __SNEEK_DONE__"))
        let input = "echo hi " + String(repeating: "#", count: 65536)
        let (response, sessions): (IPCResponse, [String]) = try runBlockingWithTimeout {
            let m = SessionManager()
            let r = await Daemon.runCommand(name: "big", input: input, configStore: store,
                                            sessionManager: m, tunnelManager: SSHTunnelManager())
            let s = await m.activeSessions()
            await m.reapAll(); return (r, s)
        }
        check(response.code == "input_too_large", response.code ?? "nil")
        check(response.error == "refused: input too large (\(input.utf8.count) bytes, limit 65536)", response.error ?? "nil")
        check(sessions.isEmpty, "no session may be started for a refused input")
        check(InputGuard.check(input: String(repeating: "x", count: 65536), config: store.commands["big"]!, global: SneekConfig()) == nil,
              "exactly 64 KiB is allowed")
    }

    // A client under command B can be talked into printing command A's credential (both run
    // as one uid; /run/secrets is readable to every child), so the redaction set is the union
    // of every enabled command's secrets resolved since boot, not the current command's alone.
    test("run: a reply from command B is redacted for a secret command A resolved earlier") {
        setenv("SNEEK_TEST_CMD_A_SECRET", "canary-a-secret-value", 1)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-red-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try ConfigStore(baseDir: tempDir)
        let bash = "exec bash --norc --noprofile"
        try store.save(CommandConfig(name: "cmd-a", description: "t", mode: .session, command: bash,
                                     secrets: ["pw": .env(variable: "SNEEK_TEST_CMD_A_SECRET")], sentinel: "echo __SNEEK_DONE__"))
        try store.save(CommandConfig(name: "cmd-b", description: "t", mode: .session, command: bash, sentinel: "echo __SNEEK_DONE__"))
        let (a, b): (IPCResponse, IPCResponse) = try runBlockingWithTimeout {
            let m = SessionManager()
            let a = await Daemon.runCommand(name: "cmd-a", input: "echo hi", configStore: store,
                                            sessionManager: m, tunnelManager: SSHTunnelManager())
            let b = await Daemon.runCommand(name: "cmd-b", input: "echo leaked=canary-a-secret-value", configStore: store,
                                            sessionManager: m, tunnelManager: SSHTunnelManager())
            await m.reapAll(); return (a, b)
        }
        check(a.output == "hi", a.output ?? "nil")
        check(b.output == "leaked=[sneek: redacted secret]", b.output ?? "nil")
    }

    test("sessionConfigChanged: identical configs do not trigger reap") {
        let a = baseCommand()
        let b = baseCommand()
        check(!Daemon.sessionConfigChanged(a, b), "identical configs should be equal")
    }

    test("sessionConfigChanged: cosmetic-only changes do not trigger reap") {
        var a = baseCommand()
        var b = baseCommand()
        b.description = "different description"
        b.tags = ["new", "tags"]
        b.mcp = MCPConfig(enabled: true, toolName: "x", toolDescription: "y")
        b.readonly = false  // readonly alone — blocked patterns gate is per-call
        a.readonly = true
        check(!Daemon.sessionConfigChanged(a, b),
              "description/tags/mcp/readonly alone should not reap a live session")
    }

    test("sessionConfigChanged: setup_commands change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.setupCommands = nil
        check(Daemon.sessionConfigChanged(a, b),
              "clearing setup_commands must reap (this is the pg-dev bug)")
    }

    test("sessionConfigChanged: command template change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.command = "psql --csv {{host}}"
        check(Daemon.sessionConfigChanged(a, b), "command template change must reap")
    }

    test("sessionConfigChanged: secret change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.secrets = ["password": .keychain(key: "rotated-key")]
        check(Daemon.sessionConfigChanged(a, b), "rotated password must reap")
    }

    test("sessionConfigChanged: variable change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.variables = ["host": "different-host"]
        check(Daemon.sessionConfigChanged(a, b), "variable change must reap")
    }

    test("sessionConfigChanged: sentinel change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.sentinel = "echo __SNEEK_DONE__"
        check(Daemon.sessionConfigChanged(a, b), "sentinel change must reap")
    }

    test("sessionConfigChanged: tunnel change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.tunnel = TunnelConfig(host: "bastion.example.com", user: "deploy",
                                localPort: 15432, remoteHost: "db.internal", remotePort: 5432)
        check(Daemon.sessionConfigChanged(a, b), "adding tunnel must reap")
    }

    test("sessionConfigChanged: mode change triggers reap") {
        let a = baseCommand()
        var b = baseCommand()
        b.mode = .oneshot
        check(Daemon.sessionConfigChanged(a, b), "mode change must reap")
    }

    test("sessionConfigChanged: secret delivery and statement timeout changes trigger reap") {
        let a = baseCommand()
        var b = baseCommand(); b.secretEnv = ["PGUSER": "x"]
        var c = baseCommand(); c.secretFiles = ["PGPASSFILE": SecretFileSpec(content: "x", escape: nil)]
        var d = baseCommand(); d.statementTimeout = 30
        var f = baseCommand(); f.queryLimit = true; f.rowCap = 100   // mongosh gets it as a setup command
        check(Daemon.sessionConfigChanged(a, b) && Daemon.sessionConfigChanged(a, c) && Daemon.sessionConfigChanged(a, d)
              && Daemon.sessionConfigChanged(a, f))
        var e = baseCommand(); e.replyTimeout = 5; e.rejectBackslash = true; e.maxSessions = 3
        check(!Daemon.sessionConfigChanged(a, e), "per-call settings do not need a new session")
    }
}

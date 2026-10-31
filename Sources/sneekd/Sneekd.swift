import ArgumentParser
import Foundation
import SneekLib

@main
struct Sneekd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sneekd",
        abstract: "Sneek daemon — manage tunnels, secrets, and commands",
        subcommands: platformSubcommands
    )

    private static var platformSubcommands: [ParsableCommand.Type] {
        var cmds: [ParsableCommand.Type] = [
            Start.self, Stop.self, Status.self, Run.self, Tunnel.self,
            List.self, MCPServe.self, GenerateScripts.self, InstallMCP.self,
        ]
        #if os(macOS)
        cmds += [Install.self, Uninstall.self]   // launchd; servers run `sneekd start` from an entrypoint or unit
        #endif
        return cmds
    }
}

// MARK: - Helpers

func defaultConfigDir() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".config/sneek")
}

/// Config-directory selection, shared by every subcommand that touches one.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Config directory (default: ~/.config/sneek, or $SNEEK_CONFIG_DIR)")
    var configDir: String?

    @Option(name: .customLong("socket-path"), help: "Unix socket path (default: <config dir>/sneekd.sock, or socket_path in config.json)")
    var socketPathOption: String?

    var baseDir: URL {
        if let configDir { return URL(fileURLWithPath: NSString(string: configDir).expandingTildeInPath) }
        if let env = ProcessInfo.processInfo.environment["SNEEK_CONFIG_DIR"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return defaultConfigDir()
    }

    /// Where the daemon for this config directory listens. Reads config.json
    /// directly (never via `ConfigStore`, which would create `<baseDir>/commands/`
    /// as a side effect) so resolving a client socket path never touches disk.
    func socketPath(explicit: String? = nil) -> String {
        Daemon.resolveClientSocketPath(baseDir: baseDir, explicit: explicit ?? socketPathOption)
    }
}

/// Glibc's `stderr` is a mutable global Swift 6 refuses to read from a concurrent
/// context; `FileHandle.standardError` is the same unbuffered fd 2 on both platforms.
func printError(_ message: String) {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
}

// MARK: - Start

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the daemon")

    @OptionGroup var global: GlobalOptions

    @Flag(name: .long, help: "Serve only run, tools and status on the socket")
    var restrictSocket = false

    func run() async throws {
        // Before anything is logged: in a container every level goes to stderr.
        SneekLogger.stderrAllLevels = SneekLogger.stderrAllLevelsFromEnvironment(ProcessInfo.processInfo.environment)

        // Write PID file
        let pidPath = global.baseDir.appendingPathComponent("sneekd.pid")
        try String(ProcessInfo.processInfo.processIdentifier).write(to: pidPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: pidPath) }

        let configStore = try ConfigStore(baseDir: global.baseDir)
        let daemon = Daemon(configStore: configStore, socketPath: global.socketPathOption, restrictSocket: restrictSocket ? true : nil)

        // Ignore SIGPIPE: writes to a broken pipe (e.g. a dead session's stdin
        // after its ssh tunnel reconnected) should return EPIPE, not kill the daemon.
        signal(SIGPIPE, SIG_IGN)

        // Trap SIGINT (Ctrl+C) and SIGTERM for clean shutdown
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let shutdownOnce: @Sendable () -> Void = {
            Task {
                print("\nsneekd: shutting down...")
                await daemon.stop()
                Foundation.exit(0)
            }
        }
        sigintSource.setEventHandler(handler: shutdownOnce)
        sigtermSource.setEventHandler(handler: shutdownOnce)
        sigintSource.resume()
        sigtermSource.resume()

        print("sneekd: starting daemon...")
        try await daemon.start()
    }
}

// MARK: - Stop

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the daemon")

    @OptionGroup var global: GlobalOptions

    func run() throws {
        let client = IPCClient(socketPath: global.socketPath())
        let response = try client.send(IPCRequest(action: .shutdown))
        print(response.output ?? response.error ?? "stopped")
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show daemon status")

    @OptionGroup var global: GlobalOptions

    func run() throws {
        let client = IPCClient(socketPath: global.socketPath())
        let response = try client.send(IPCRequest(action: .status))
        if response.success {
            print(response.output ?? "ok")
        } else {
            print("error: \(response.error ?? "unknown")")
        }
    }
}

// MARK: - Run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a command")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Command name") var name: String
    @Argument(help: "Input to send") var input: String?

    func run() throws {
        let client = IPCClient(socketPath: global.socketPath())
        let response = try client.send(IPCRequest(action: .run, command: name, input: input))
        if response.success {
            if let output = response.output {
                print(output)
            }
        } else {
            printError(response.error ?? "unknown")
            throw ExitCode.failure
        }
    }
}

// MARK: - Tunnel

struct Tunnel: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage tunnels")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Command name") var name: String
    @Argument(help: "Operation: up, down, status") var operation: String

    func run() throws {
        let client = IPCClient(socketPath: global.socketPath())
        let response = try client.send(IPCRequest(action: .tunnel, command: name, operation: operation))
        if response.success {
            print(response.output ?? "ok")
        } else {
            printError(response.error ?? "unknown")
            throw ExitCode.failure
        }
    }
}

// MARK: - List

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List all commands")

    @OptionGroup var global: GlobalOptions

    func run() throws {
        let configStore = try ConfigStore(baseDir: global.baseDir)
        for (name, cmd) in configStore.commands.sorted(by: { $0.key < $1.key }) {
            var flags: [String] = []
            if cmd.enabled == false { flags.append("disabled") }
            if cmd.tunnel != nil { flags.append("tunnel") }
            if cmd.mcp?.enabled == true { flags.append("mcp") }
            if cmd.readonly == true { flags.append("read-only") }
            let flagStr = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
            print("  \(name) — \(cmd.description)\(flagStr)")
        }
    }
}

// MARK: - MCP Serve

struct MCPServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-serve",
        abstract: "Run as MCP server (stdio)"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "Filter by tags (comma-separated)") var tags: String?
    @Option(help: "Filter by command names (comma-separated)") var commands: String?

    func run() async throws {
        let configStore = try ConfigStore(baseDir: global.baseDir)
        let sessionManager = SessionManager()
        let tunnelManager = SSHTunnelManager()

        let tagList = tags?.split(separator: ",").map(String.init)
        let cmdList = commands?.split(separator: ",").map(String.init)

        let server = MCPServer(
            configStore: configStore,
            sessionManager: sessionManager,
            tunnelManager: tunnelManager,
            tags: tagList,
            commands: cmdList,
            ipcSocketPath: global.socketPath()
        )
        try await server.run()
    }
}

// MARK: - Generate Scripts

struct GenerateScripts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-scripts",
        abstract: "Generate shell scripts for all commands"
    )
    @OptionGroup var global: GlobalOptions
    @Option(help: "Output directory") var outputDir: String?

    func run() throws {
        let configStore = try ConfigStore(baseDir: global.baseDir)
        let dir = outputDir ?? configStore.globalConfig.scriptOutputDir ?? "~/bin"
        let expanded = NSString(string: dir).expandingTildeInPath
        let paths = try ScriptGenerator.generateAll(configStore: configStore, outputDir: expanded)
        for path in paths {
            print("  generated: \(path)")
        }
    }
}

// MARK: - Install MCP

struct InstallMCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-mcp",
        abstract: "Add sneek to Claude Code MCP config"
    )

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsPath = home.appendingPathComponent(".claude/settings.json").path
        let sneekdPath = ProcessInfo.processInfo.arguments[0]
        try ScriptGenerator.installMCP(sneekdPath: sneekdPath, settingsPath: settingsPath)
        print("sneek MCP server added to \(settingsPath)")
    }
}

#if os(macOS)

// MARK: - Install (launchd)

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install daemon as launchd service (auto-start on login)")

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sneekdPath = ProcessInfo.processInfo.arguments[0]
        let plistPath = home.appendingPathComponent("Library/LaunchAgents/com.sneek.daemon.plist")
        let logsDir = defaultConfigDir().appendingPathComponent("logs")

        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/LaunchAgents"),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": "com.sneek.daemon",
            "ProgramArguments": [sneekdPath, "start"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logsDir.appendingPathComponent("sneekd.log").path,
            "StandardErrorPath": logsDir.appendingPathComponent("sneekd.err").path,
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["load", plistPath.path]
        try process.run()
        process.waitUntilExit()

        print("Installed and started. Daemon will auto-start on login.")
        print("  Plist: \(plistPath.path)")
        print("  Logs:  \(logsDir.path)/sneekd.{log,err}")
    }
}

// MARK: - Uninstall

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Uninstall daemon launchd service")

    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plistPath = home.appendingPathComponent("Library/LaunchAgents/com.sneek.daemon.plist")

        if FileManager.default.fileExists(atPath: plistPath.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["unload", plistPath.path]
            try process.run()
            process.waitUntilExit()

            try FileManager.default.removeItem(at: plistPath)
            print("Uninstalled. Daemon will no longer auto-start.")
        } else {
            print("Not installed (no plist found).")
        }
    }
}

#endif

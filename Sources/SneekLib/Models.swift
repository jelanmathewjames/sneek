import Foundation

// MARK: - Command Configuration

public struct CommandConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }

    public var name: String
    public var description: String
    public var enabled: Bool?
    public var tags: [String]?
    public var mode: ExecutionMode
    public var idleTimeout: Int?
    public var readonly: Bool?

    public var command: String

    public var secrets: [String: SecretRef]?
    public var variables: [String: String]?

    public var tunnel: TunnelConfig?

    public var setupCommands: [String]?
    public var blockedPatterns: [String]?
    public var sentinel: String?

    public var mcp: MCPConfig?

    /// Reject input containing a literal backslash (guard against psql/mysql meta-commands). Per-call.
    public var rejectBackslash: Bool?
    /// Extra environment variables resolved from secrets and passed to the child process.
    public var secretEnv: [String: String]?
    /// Files materialized from secrets (e.g. a `.pgpass` file) before the session starts.
    public var secretFiles: [String: SecretFileSpec]?
    /// Statement timeout (seconds) applied at session setup.
    public var statementTimeout: Int?
    /// Per-call reply timeout (seconds).
    public var replyTimeout: Int?
    /// Caps rows returned per call; delivered via a setup command for mode == .session tools like mongosh.
    public var rowCap: Int?
    /// A probe run at session start to confirm the connection is actually read-only.
    public var readonlyProbe: ReadonlyProbe?
    /// Per-call cap on concurrent sessions for this command.
    public var maxSessions: Int?
    /// Whether a row cap should be enforced via query rewriting/setup rather than left to the client.
    public var queryLimit: Bool?

    enum CodingKeys: String, CodingKey {
        case name, description, enabled, tags, mode
        case idleTimeout = "idle_timeout"
        case readonly, command, secrets, variables, tunnel
        case setupCommands = "setup_commands"
        case blockedPatterns = "blocked_patterns"
        case sentinel, mcp
        case rejectBackslash = "reject_backslash"
        case secretEnv = "secret_env"
        case secretFiles = "secret_files"
        case statementTimeout = "statement_timeout"
        case replyTimeout = "reply_timeout"
        case rowCap = "row_cap"
        case readonlyProbe = "readonly_probe"
        case maxSessions = "max_sessions"
        case queryLimit = "query_limit"
    }

    public init(
        name: String,
        description: String,
        enabled: Bool? = nil,
        tags: [String]? = nil,
        mode: ExecutionMode,
        idleTimeout: Int? = nil,
        readonly: Bool? = nil,
        command: String,
        secrets: [String: SecretRef]? = nil,
        variables: [String: String]? = nil,
        tunnel: TunnelConfig? = nil,
        setupCommands: [String]? = nil,
        blockedPatterns: [String]? = nil,
        sentinel: String? = nil,
        mcp: MCPConfig? = nil,
        rejectBackslash: Bool? = nil,
        secretEnv: [String: String]? = nil,
        secretFiles: [String: SecretFileSpec]? = nil,
        statementTimeout: Int? = nil,
        replyTimeout: Int? = nil,
        rowCap: Int? = nil,
        readonlyProbe: ReadonlyProbe? = nil,
        maxSessions: Int? = nil,
        queryLimit: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.enabled = enabled
        self.tags = tags
        self.mode = mode
        self.idleTimeout = idleTimeout
        self.readonly = readonly
        self.command = command
        self.secrets = secrets
        self.variables = variables
        self.tunnel = tunnel
        self.setupCommands = setupCommands
        self.blockedPatterns = blockedPatterns
        self.sentinel = sentinel
        self.mcp = mcp
        self.rejectBackslash = rejectBackslash
        self.secretEnv = secretEnv
        self.secretFiles = secretFiles
        self.statementTimeout = statementTimeout
        self.replyTimeout = replyTimeout
        self.rowCap = rowCap
        self.readonlyProbe = readonlyProbe
        self.maxSessions = maxSessions
        self.queryLimit = queryLimit
    }
}

extension CommandConfig {
    /// The GUI editor rebuilds a config from its form. This carries over every key the form has
    /// no field for, so a save in the editor cannot drop a hand-edited setting.
    public func keepingUneditedKeys(from original: CommandConfig) -> CommandConfig {
        var merged = self
        merged.idleTimeout = original.idleTimeout
        merged.sentinel = original.sentinel
        merged.rejectBackslash = original.rejectBackslash
        merged.secretEnv = original.secretEnv
        merged.secretFiles = original.secretFiles
        merged.statementTimeout = original.statementTimeout
        merged.replyTimeout = original.replyTimeout
        merged.rowCap = original.rowCap
        merged.readonlyProbe = original.readonlyProbe
        merged.maxSessions = original.maxSessions
        merged.queryLimit = original.queryLimit
        return merged
    }
}

// MARK: - Secret File Spec

public struct SecretFileSpec: Codable, Equatable, Sendable {
    public var content: String
    public var escape: String?

    public init(content: String, escape: String? = nil) {
        self.content = content
        self.escape = escape
    }
}

// MARK: - Readonly Probe

public struct ReadonlyProbe: Codable, Equatable, Sendable {
    public var input: String
    public var expect: String
    /// Any of these strings appearing in the probe output refuses the command; checked before `expect`.
    public var reject: [String]?

    public init(input: String, expect: String, reject: [String]? = nil) {
        self.input = input
        self.expect = expect
        self.reject = reject
    }
}

// MARK: - Execution Mode

public enum ExecutionMode: String, Codable, Equatable, Sendable {
    case session
    case oneshot
}

// MARK: - Secret Reference

public enum SecretRef: Codable, Equatable, Sendable {
    case keychain(key: String)
    case onePassword(ref: String)
    case bitwarden(item: String)
    case env(variable: String)

    enum CodingKeys: String, CodingKey {
        case provider, key, ref, item, variable = "var"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(String.self, forKey: .provider)
        switch provider {
        case "keychain":
            self = .keychain(key: try container.decode(String.self, forKey: .key))
        case "1password":
            self = .onePassword(ref: try container.decode(String.self, forKey: .ref))
        case "bitwarden":
            self = .bitwarden(item: try container.decode(String.self, forKey: .item))
        case "env":
            self = .env(variable: try container.decode(String.self, forKey: .variable))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .provider, in: container,
                debugDescription: "Unknown secret provider: \(provider)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keychain(let key):
            try container.encode("keychain", forKey: .provider)
            try container.encode(key, forKey: .key)
        case .onePassword(let ref):
            try container.encode("1password", forKey: .provider)
            try container.encode(ref, forKey: .ref)
        case .bitwarden(let item):
            try container.encode("bitwarden", forKey: .provider)
            try container.encode(item, forKey: .item)
        case .env(let variable):
            try container.encode("env", forKey: .provider)
            try container.encode(variable, forKey: .variable)
        }
    }
}

// MARK: - Tunnel Configuration

public enum TunnelType: String, Codable, Sendable {
    case ssh
    case kubectl
}

public struct TunnelConfig: Codable, Equatable, Sendable {
    public var enabled: Bool?
    /// Absent in configs written before kubectl support — treated as ssh.
    public var type: TunnelType?
    public var host: String?
    public var user: String?
    public var identityKey: String?
    public var localPort: Int
    public var remoteHost: String?
    public var remotePort: Int
    public var autoConnect: Bool?
    public var context: String?
    public var namespace: String?
    public var resource: String?

    public var tunnelType: TunnelType { type ?? .ssh }

    enum CodingKeys: String, CodingKey {
        case enabled, type, host, user, context, namespace, resource
        case identityKey = "identity_key"
        case localPort = "local_port"
        case remoteHost = "remote_host"
        case remotePort = "remote_port"
        case autoConnect = "auto_connect"
    }

    public init(
        enabled: Bool? = nil,
        type: TunnelType? = nil,
        host: String? = nil,
        user: String? = nil,
        identityKey: String? = nil,
        localPort: Int,
        remoteHost: String? = nil,
        remotePort: Int,
        autoConnect: Bool? = nil,
        context: String? = nil,
        namespace: String? = nil,
        resource: String? = nil
    ) {
        self.enabled = enabled
        self.type = type
        self.host = host
        self.user = user
        self.identityKey = identityKey
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.autoConnect = autoConnect
        self.context = context
        self.namespace = namespace
        self.resource = resource
    }
}

// MARK: - MCP Configuration

public struct MCPConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var toolName: String
    public var toolDescription: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case toolName = "tool_name"
        case toolDescription = "tool_description"
    }

    public init(enabled: Bool, toolName: String, toolDescription: String) {
        self.enabled = enabled
        self.toolName = toolName
        self.toolDescription = toolDescription
    }
}

// MARK: - Global Configuration

public struct SneekConfig: Codable, Equatable, Sendable {
    public var scriptOutputDir: String?
    public var logLevel: String?
    /// Where the daemon listens. Absent = `<config dir>/sneekd.sock`, as before.
    public var socketPath: String?
    /// Octal permissions for the socket file, e.g. `"0660"`. Absent = left to the umask, as before.
    public var socketMode: String?
    /// Serve only the safe subset of actions on the socket.
    public var restrictSocket: Bool?
    /// Scrub the child process environment before launching commands.
    public var scrubChildEnv: Bool?
    /// Reject input containing a literal backslash, daemon-wide default.
    public var rejectBackslash: Bool?
    /// Require the readonly probe to pass before allowing a command tagged prod to run.
    public var requireReadonlyProd: Bool?
    /// Path to an audit log file; absent = no audit logging.
    public var auditLog: String?

    enum CodingKeys: String, CodingKey {
        case scriptOutputDir = "script_output_dir"
        case logLevel = "log_level"
        case socketPath = "socket_path"
        case socketMode = "socket_mode"
        case restrictSocket = "restrict_socket"
        case scrubChildEnv = "scrub_child_env"
        case rejectBackslash = "reject_backslash"
        case requireReadonlyProd = "require_readonly_prod"
        case auditLog = "audit_log"
    }

    public init(
        scriptOutputDir: String? = nil,
        logLevel: String? = nil,
        socketPath: String? = nil,
        socketMode: String? = nil,
        restrictSocket: Bool? = nil,
        scrubChildEnv: Bool? = nil,
        rejectBackslash: Bool? = nil,
        requireReadonlyProd: Bool? = nil,
        auditLog: String? = nil
    ) {
        self.scriptOutputDir = scriptOutputDir
        self.logLevel = logLevel
        self.socketPath = socketPath
        self.socketMode = socketMode
        self.restrictSocket = restrictSocket
        self.scrubChildEnv = scrubChildEnv
        self.rejectBackslash = rejectBackslash
        self.requireReadonlyProd = requireReadonlyProd
        self.auditLog = auditLog
    }
}

// MARK: - Tunnel Status

public enum TunnelStatus: Equatable, Sendable {
    case up
    case down
    case reconnecting
}

import Foundation

/// How a child process is started: which environment it sees and which secret files it gets.
/// `.inherit` reproduces the historical behaviour (no environment set, no files).
public struct LaunchContext: Sendable, Equatable {
    public var baseEnvironment: [String: String]?    // nil = inherit the daemon's environment
    public var extraEnvironment: [String: String]    // rendered `secret_env`
    public var secretFiles: [String: String]         // env var name → file content
    public var probe: ReadonlyProbe?

    public init(baseEnvironment: [String: String]? = nil, extraEnvironment: [String: String] = [:],
                secretFiles: [String: String] = [:], probe: ReadonlyProbe? = nil) {
        self.baseEnvironment = baseEnvironment; self.extraEnvironment = extraEnvironment
        self.secretFiles = secretFiles; self.probe = probe
    }

    public static let inherit = LaunchContext()
    public var isInherit: Bool { baseEnvironment == nil && extraEnvironment.isEmpty && secretFiles.isEmpty }
}

public enum LaunchPlanError: Error, Equatable {
    case unknownEscape(String)
}

public enum LaunchPlanner {
    /// What a scrubbed child still needs to find its binaries, its home and its locale.
    static let envAllowlist = ["PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR"]

    /// libpq password-file escaping: backslash first, then colon.
    static func pgpassEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
    }

    public static func plan(config: CommandConfig, global: SneekConfig, resolved: [String: String],
                            daemonEnvironment: [String: String]) throws -> LaunchContext {
        var ctx = LaunchContext()
        // The probe needs a live session to run in; a prod command that cannot be checked is refused
        // rather than launched. Nothing is cached, so a grant change is caught at the next start.
        if ReadonlyCheck.required(config, global: global) {
            let prefix = "command '\(config.name)' is tagged prod and its read-only check could not run: "
            guard config.mode == .session else {
                throw Refusal(code: "prod_readonly_unverified", message: prefix + "it needs session mode")
            }
            guard let probe = config.readonlyProbe ?? ReadonlyCheck.builtinProbe(for: config) else {
                throw Refusal(code: "prod_readonly_unverified", message: prefix + "no readonly_probe defined")
            }
            ctx.probe = probe
        }
        if global.scrubChildEnv == true {
            ctx.baseEnvironment = daemonEnvironment.filter { envAllowlist.contains($0.key) }
        }
        for (name, template) in config.secretEnv ?? [:] {
            ctx.extraEnvironment[name] = try TemplateEngine.render(template, variables: resolved)
        }
        for (name, spec) in config.secretFiles ?? [:] {
            let transform: ((String) -> String)?
            switch spec.escape {
            case nil: transform = nil
            case "pgpass": transform = pgpassEscape
            case let other?: throw LaunchPlanError.unknownEscape(other)
            }
            ctx.secretFiles[name] = try TemplateEngine.render(spec.content, variables: resolved, transform: transform)
        }
        return ctx
    }
}

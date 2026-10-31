import Foundation

/// The preflight both `Daemon.runCommandAudited` and `MCPServer.handleToolCallDirect` run before a
/// command executes: resolve secrets, expose the tunnel port and the timeout to the template,
/// render the command, plan the launch, derive the redaction set. The input guard and the tunnel
/// stay with the callers, which log and report them differently.
public enum RunPipeline {
    public struct Prepared: Sendable {
        public let command: String          // the rendered command line
        public let launch: LaunchContext
        public let redact: [String]         // every enabled command's secrets resolved so far
    }

    /// A stage that failed, with the values to redact from its message. `underlying` is a
    /// `Refusal` when the launch planner refused (a policy refusal, not an error).
    public struct Failure: Error {
        public enum Stage: String, Sendable {
            case resolve = "secret resolution failed", render = "template error", plan = "launch planning failed"
        }
        public let stage: Stage
        public let underlying: Error
        public let redact: [String]
    }

    public static func prepare(config cmd: CommandConfig, store: ConfigStore,
                               daemonEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws -> Prepared {
        let resolver = SecretResolver(secrets: cmd.secrets ?? [:], variables: cmd.variables ?? [:])
        var vars: [String: String]
        do { vars = try await resolver.resolveAll() }
        catch { throw Failure(stage: .resolve, underlying: error, redact: []) }

        // Only the values that came from a `secrets` entry are redacted; plain `variables` are
        // configuration, not credentials. The reply is scrubbed for every enabled command's
        // secrets resolved so far, not just this one's (see `SecretCache`).
        SecretCache.shared.record((cmd.secrets ?? [:]).keys.compactMap { vars[$0] }, for: cmd.name)
        let redact = SecretCache.shared.values(for: SecretCache.enabledCommands(in: store.commands))

        if let tunnel = cmd.tunnel { vars["local_port"] = String(tunnel.localPort) }
        // Clients that take the timeout on their command line (cqlsh, a mongo URI) read it from
        // here. A variable the config defines itself wins.
        if let t = cmd.statementTimeout {
            if vars["statement_timeout"] == nil { vars["statement_timeout"] = String(t) }
            if vars["statement_timeout_ms"] == nil { vars["statement_timeout_ms"] = String(t * 1000) }
        }

        let command: String
        do { command = try TemplateEngine.render(cmd.command, variables: vars) }
        catch { throw Failure(stage: .render, underlying: error, redact: redact) }
        let launch: LaunchContext
        do { launch = try LaunchPlanner.plan(config: cmd, global: store.globalConfig, resolved: vars, daemonEnvironment: daemonEnvironment) }
        catch { throw Failure(stage: .plan, underlying: error, redact: redact) }
        return Prepared(command: command, launch: launch, redact: redact)
    }

    /// The text handed to a session. The database-side cap is applied after the backslash guard
    /// (which must see the raw input) and the terminator last, so the blocked-pattern check in
    /// `send` sees the final text.
    public static func sessionInput(_ raw: String, config: CommandConfig) -> String {
        Terminator.psqlTerminated(QueryLimit.apply(raw, config: config), config: config)
    }
}

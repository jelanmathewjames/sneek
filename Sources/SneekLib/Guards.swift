import Foundation

/// A policy refusal. Maps to `IPCResponse.refused(code:_:)` on the socket.
public struct Refusal: Error, Equatable, Sendable {
    public let code: String
    public let message: String
}

/// A client that can be talked into printing its own credential (`print(process.env.X)`,
/// an error that quotes a connection string) must not get it past the daemon.
public enum Redaction {
    public static let placeholder = "[sneek: redacted secret]"
    /// Replaces each secret value (8+ characters, longest first so a secret that contains another is
    /// removed whole) with the placeholder. Shorter values are left: redacting "1234" would mangle data.
    public static func apply(_ text: String, secrets: [String]) -> String {
        var out = text
        for s in Set(secrets).filter({ $0.count >= 8 }).sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: s, with: placeholder)
        }
        return out
    }
}

/// Every secret value resolved since boot, by command. The commands inside one daemon share a
/// uid, so a client under command B can be made to print command A's credential; replies are
/// therefore redacted for the union of every enabled command's secrets, not the caller's alone.
/// Values live only in memory, for the daemon's lifetime; a rotated secret adds its new value
/// at the next resolution and the old one stays until restart (redacting it does no harm).
public final class SecretCache: @unchecked Sendable {
    public static let shared = SecretCache()
    private let lock = NSLock()
    private var byCommand: [String: Set<String>] = [:]

    public func record(_ values: [String], for command: String) {
        lock.lock(); defer { lock.unlock() }
        byCommand[command, default: []].formUnion(values)
    }

    /// The redaction list for a reply: the secrets of `commands` (the enabled ones), resolved so far.
    public func values(for commands: some Sequence<String>) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(commands.reduce(into: Set<String>()) { $0.formUnion(byCommand[$1] ?? []) })
    }

    /// The names of the enabled commands in `store` — the set a reply must be redacted against.
    public static func enabledCommands(in commands: [String: CommandConfig]) -> [String] {
        commands.values.filter { $0.enabled != false }.map(\.name)
    }
}

public enum RowCap {
    /// Counts lines, not database rows: sneek does not know the client's output format.
    public static func apply(_ output: String, cap: Int?) -> String {
        guard let cap, cap > 0, !output.isEmpty else { return output }
        let lines = output.components(separatedBy: "\n")
        guard lines.count > cap else { return output }
        return lines[..<cap].joined(separator: "\n")
            + "\n[sneek] output truncated: showing first \(cap) of \(lines.count) lines (row_cap)"
    }
}

/// Caps a result in the database at row_cap + 1 rows. Postgres: a single read statement is wrapped
/// in a subquery — anything the wrap cannot parse (two statements, a write) fails in the database
/// instead of running. CQL: `LIMIT n` is appended. mongosh: see `effectiveSetupCommands`.
public enum QueryLimit {
    public static func limit(_ config: CommandConfig) -> Int? {
        guard config.queryLimit == true, let cap = config.rowCap, cap > 0 else { return nil }
        return cap + 1
    }

    public static func apply(_ input: String, config: CommandConfig) -> String {
        guard let n = limit(config) else { return input }
        let cmd = config.command.lowercased()
        if cmd.contains("psql") { return wrapPostgres(input, limit: n) }
        if cmd.contains("cqlsh") { return appendCQL(input, limit: n) }
        return input
    }

    private static let readPrefixes = ["SELECT", "WITH", "VALUES", "TABLE"]

    /// Trailing whitespace and semicolons removed, then surrounding whitespace.
    private static func bareStatement(_ input: String) -> String {
        var s = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        while s.last == ";" { s = s.dropLast(); s = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return String(s)
    }

    /// The statement with leading `--` and `/* */` comments removed, for the keyword check only.
    private static func withoutLeadingComments(_ s: String) -> Substring {
        var t = Substring(s)
        while true {
            t = t.drop(while: { $0.isWhitespace })
            if t.hasPrefix("--") {
                guard let nl = t.firstIndex(of: "\n") else { return "" }
                t = t[t.index(after: nl)...]
            } else if t.hasPrefix("/*") {
                guard let end = t.range(of: "*/") else { return t }
                t = t[end.upperBound...]
            } else {
                return t
            }
        }
    }

    private static func startsWithReadKeyword(_ s: String) -> Bool {
        let head = withoutLeadingComments(s).uppercased()
        for k in readPrefixes where head.hasPrefix(k) {
            let rest = head.dropFirst(k.count)
            if let c = rest.first, c.isLetter || c.isNumber || c == "_" { continue }   // SELECTION, TABLES
            return true
        }
        return false
    }

    /// The wrap emits no trailing `;`; `Terminator.psqlTerminated` adds it on the way to the session.
    static func wrapPostgres(_ input: String, limit: Int) -> String {
        let body = bareStatement(input)
        guard startsWithReadKeyword(body) else { return input }
        return "SELECT * FROM (\n\(body)\n) AS sneek_q LIMIT \(limit)"
    }

    static func appendCQL(_ input: String, limit: Int) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadSemicolon = trimmed.hasSuffix(";")
        let body = bareStatement(trimmed)
        let upper = body.uppercased()
        guard upper.count == body.count else { return input }          // indices below assume same length
        guard upper.hasPrefix("SELECT"),
              upper.range(of: #"\bLIMIT\s+\d+"#, options: .regularExpression) == nil else { return input }
        let suffix = hadSemicolon ? ";" : ""
        if let af = upper.range(of: #"\s+ALLOW\s+FILTERING\s*$"#, options: .regularExpression) {
            let cut = body.index(body.startIndex, offsetBy: upper.distance(from: upper.startIndex, to: af.lowerBound))
            return body[..<cut] + " LIMIT \(limit)" + body[cut...] + suffix
        }
        return body + " LIMIT \(limit)" + suffix
    }
}

public enum Terminator {
    /// psql keeps an unterminated statement in its buffer while the sentinel `\echo` runs anyway:
    /// the reply comes back empty with `success: true` and the *next* query fails with a syntax
    /// error at the leftover text. A missing `;` is never valid input for a psql session, so this
    /// is not gated by a setting — every psql-type input gets one unless it is a backslash command
    /// (which takes no semicolon) or empty.
    ///
    /// The semicolon goes on a line of its own: appended to the last line it would land inside a
    /// trailing `--` comment (`select 1 -- note;`) and never reach the parser, which is the very
    /// bug this exists to prevent. It is added unconditionally — there is no "already terminated"
    /// heuristic, because telling a real `;` from one inside a comment, a string or a dollar-quoted
    /// body needs a parser. A surplus `;` is an empty statement, for which psql under
    /// `--csv --quiet -X` prints nothing (verified in the E2E suite).
    public static func psqlTerminated(_ input: String, config: CommandConfig) -> String {
        guard InputGuard.isPsqlType(config) else { return input }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("\\") else { return input }
        return input + "\n;"
    }
}

public enum InputGuard {
    /// Same detection `SessionManager.defaultSentinel` uses.
    static func isPsqlType(_ config: CommandConfig) -> Bool {
        config.command.lowercased().contains("psql")
    }

    static func rejectsBackslash(_ config: CommandConfig, global: SneekConfig) -> Bool {
        config.rejectBackslash ?? (global.rejectBackslash == true && isPsqlType(config))
    }

    /// The largest `run` input accepted, in bytes: the size of a pipe buffer. A query is never
    /// this long; a payload that is would sit in `write(2)` until the client drained it.
    public static let maxInputBytes = 65536

    /// psql runs shell commands through `\!`, `\o |cmd` and `\copy … program`; every one needs a backslash.
    public static func check(input: String?, config: CommandConfig, global: SneekConfig) -> Refusal? {
        guard let input else { return nil }
        if input.utf8.count > maxInputBytes {
            return Refusal(code: "input_too_large",
                           message: "input too large (\(input.utf8.count) bytes, limit \(maxInputBytes))")
        }
        guard rejectsBackslash(config, global: global), input.contains("\\") else { return nil }
        return Refusal(code: "backslash_rejected",
                       message: "input contains a backslash, which is not allowed for command '\(config.name)'")
    }
}

import Foundation

public enum SneekLogger {
    public enum Level: Int, Comparable, Sendable {
        case debug, info, warn, error

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .debug: return "DEBUG"
            case .info: return "INFO"
            case .warn: return "WARN"
            case .error: return "ERROR"
            }
        }
    }

    public nonisolated(unsafe) static var level: Level = .info
    public nonisolated(unsafe) static var logFile: URL?

    /// Send every level to stderr, not just warn-and-up. In a container the log file
    /// sits on a disposable tmpfs and `docker logs` is the record, so INFO has to
    /// reach stderr. Off by default: on the Mac the launchd daemon's stderr stays
    /// warn-and-up as before.
    public nonisolated(unsafe) static var stderrAllLevels = false

    /// `SNEEK_LOG_STDERR=1` in the process environment turns `stderrAllLevels` on.
    public static func stderrAllLevelsFromEnvironment(_ env: [String: String]) -> Bool {
        env["SNEEK_LOG_STDERR"] == "1"
    }

    private static let queue = DispatchQueue(label: "com.sneek.logger")
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func log(_ level: Level, _ message: String) {
        guard level >= self.level else { return }
        let timestamp = iso8601.string(from: Date())
        let line = "[\(timestamp)] [\(level.label)] \(message)\n"

        if level >= .warn || stderrAllLevels {
            FileHandle.standardError.write(Data(line.utf8))
        }

        guard let logFile = logFile else { return }
        queue.async {
            if let fh = try? FileHandle(forWritingTo: logFile) {
                // The throwing forms, never the legacy `seekToEndOfFile()`/`write(_:)`: those trap
                // on an error, and a full filesystem under the log file must not stop the daemon.
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: Data(line.utf8))
                try? fh.close()
            } else {
                FileManager.default.createFile(atPath: logFile.path, contents: Data(line.utf8))
            }
        }
    }

    /// Waits for every line queued so far to reach the file. Tests only.
    static func flush() { queue.sync {} }

    public static func debug(_ message: String) { log(.debug, message) }
    public static func info(_ message: String) { log(.info, message) }
    public static func warn(_ message: String) { log(.warn, message) }
    public static func error(_ message: String) { log(.error, message) }
}

import Foundation
@testable import SneekLib

func runLoggerTests() {
    print("\nLogger:")

    test("SNEEK_LOG_STDERR=1 sends info lines to stderr; unset keeps today's warn-and-up") {
        // Capture stderr through a pipe for the duration of the test.
        let pipe = Pipe()
        let saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        SneekLogger.stderrAllLevels = false
        SneekLogger.info("info-hidden-by-default")
        SneekLogger.warn("warn-always-visible")
        SneekLogger.stderrAllLevels = true
        SneekLogger.info("info-visible-when-enabled")
        SneekLogger.stderrAllLevels = false

        // Restore stderr *before* reading: while fd 2 still points at the pipe's write
        // end, the pipe never reaches EOF and readDataToEndOfFile() blocks forever.
        dup2(saved, STDERR_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        check(!out.contains("info-hidden-by-default"), out)
        check(out.contains("warn-always-visible") && out.contains("info-visible-when-enabled"), out)
    }

    // The legacy `FileHandle.write(_:)` traps on a write error: a full filesystem under the log
    // file would take the daemon down. /dev/full answers every write with ENOSPC (Linux only).
    test("a log file that cannot be written (full filesystem) does not crash the process (Linux)") {
        #if os(Linux)
        let saved = SneekLogger.logFile
        SneekLogger.logFile = URL(fileURLWithPath: "/dev/full")
        SneekLogger.info("line that cannot be written")
        SneekLogger.flush()
        SneekLogger.logFile = saved
        check(true, "still alive after a failed write")
        #else
        check(true, "no /dev/full on macOS")
        #endif
    }

    test("stderrAllLevels is read from the SNEEK_LOG_STDERR environment variable at start") {
        check(SneekLogger.stderrAllLevelsFromEnvironment(["SNEEK_LOG_STDERR": "1"]) == true)
        check(SneekLogger.stderrAllLevelsFromEnvironment([:]) == false && SneekLogger.stderrAllLevelsFromEnvironment(["SNEEK_LOG_STDERR": "0"]) == false)
    }
}

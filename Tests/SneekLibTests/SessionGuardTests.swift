import Foundation
@testable import SneekLib

private func runBlockingWithTimeout<T: Sendable>(seconds: Int = 15, _ body: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task { do { result = .success(try await body()) } catch { result = .failure(error) }; sem.signal() }
    if sem.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
        throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "timed out after \(seconds)s"])
    }
    return try result!.get()
}

private let bashCmd = "exec bash --norc --noprofile"
private func bash(_ name: String) -> CommandConfig {
    CommandConfig(name: name, description: "t", mode: .session, command: bashCmd, sentinel: "echo __SNEEK_DONE__")
}

/// The same manager must serve both calls in the wall-clock test, so the restart is what is tested.
extension SessionManager { static let shared_forTest = SessionManager() }

/// True once `pid` has exited — reaped (`kill` fails) or still a zombie waiting for Foundation's
/// reaper (Linux: `State: Z` in /proc). On Linux the reaper can lag a killed child by seconds.
private func exitedOrZombie(_ pid: pid_t) -> Bool {
    if kill(pid, 0) != 0 { return true }
    #if os(Linux)
    if let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8),
       status.contains("State:\tZ") { return true }
    #endif
    return false
}

func runSessionGuardTests() {
    print("\nSession guards:")
    setenv("SNEEK_TEST_OTHER_DB_PASSWORD", "canary-other-db-secret", 1)   // stands in for another database's password

    test("default: the child inherits the daemon environment (unchanged behaviour)") {
        let out: String = try runBlockingWithTimeout {
            let m = SessionManager()
            let o = try await m.send(input: "echo $SNEEK_TEST_OTHER_DB_PASSWORD", to: "inh", config: bash("inh"), resolvedCommand: bashCmd)
            await m.reapAll(); return o
        }
        check(out == "canary-other-db-secret", out)
    }

    test("scrubbed: another command's secret is absent, its own is present") {
        let out: String = try runBlockingWithTimeout {
            let m = SessionManager()
            let ctx = LaunchContext(baseEnvironment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
                                    extraEnvironment: ["OWN_SECRET": "own-value"], secretFiles: [:], probe: nil)
            let o = try await m.send(input: "echo other=[$SNEEK_TEST_OTHER_DB_PASSWORD] own=[$OWN_SECRET]; env | wc -l",
                                     to: "scr", config: bash("scr"), resolvedCommand: bashCmd, launch: ctx)
            await m.reapAll(); return o
        }
        check(out.contains("other=[] own=[own-value]"), out)
    }

    test("secret file: 0600 in a 0700 dir, readable by the child, removed on reap") {
        let (content, perms, path): (String, String, String) = try runBlockingWithTimeout {
            let m = SessionManager()
            let ctx = LaunchContext(baseEnvironment: nil, extraEnvironment: [:], secretFiles: ["PGPASSFILE": "db:5432:*:ro:pw"], probe: nil)
            let c = try await m.send(input: "cat $PGPASSFILE", to: "sf", config: bash("sf"), resolvedCommand: bashCmd, launch: ctx)
            let p = try await m.send(input: "ls -ld $(dirname $PGPASSFILE) $PGPASSFILE | cut -c1-10 | tr '\\n' ' '; echo", to: "sf", config: bash("sf"), resolvedCommand: bashCmd, launch: ctx)
            let path = try await m.send(input: "echo $PGPASSFILE", to: "sf", config: bash("sf"), resolvedCommand: bashCmd, launch: ctx)
            await m.reapAll()
            return (c, p, path)
        }
        check(content == "db:5432:*:ro:pw", content)
        check(perms.hasPrefix("drwx------ -rw-------"), perms)
        check(!FileManager.default.fileExists(atPath: path), "secret file must be deleted on reap")
    }

    // Guards against a revert to FileManager.createDirectory(attributes:), which on corelibs
    // mkdir's with the umask'd mode and chmods afterwards — a window on a shared /tmp where
    // the directory is world-searchable. Under umask 0 that lazy path yields 0777, not 0700.
    test("the secrets directory is created 0700 even under a permissive umask") {
        let previousMask = umask(0o000)
        defer { _ = umask(previousMask) }
        let (dirMode, fileMode): (Int, Int) = try runBlockingWithTimeout {
            let m = SessionManager()
            let ctx = LaunchContext(baseEnvironment: nil, extraEnvironment: [:], secretFiles: ["PGPASSFILE": "db:5432:*:ro:pw"], probe: nil)
            let path = try await m.send(input: "echo $PGPASSFILE", to: "um", config: bash("um"), resolvedCommand: bashCmd, launch: ctx)
            let fm = FileManager.default
            let dirPath = (path as NSString).deletingLastPathComponent
            let d = (try fm.attributesOfItem(atPath: dirPath)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let f = (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            await m.reapAll()
            return (d, f)
        }
        check(dirMode == 0o700, "dir mode \(String(dirMode, radix: 8))")
        check(fileMode == 0o600, "file mode \(String(fileMode, radix: 8))")
    }

    test("wall clock: a hung reply is cut off, and the next call gets a fresh session") {
        signal(SIGPIPE, SIG_IGN)
        let cfg: CommandConfig = { var c = bash("hang"); c.replyTimeout = 2; return c }()
        let started = Date()
        var timedOut = false
        do {
            let _: String = try runBlockingWithTimeout(seconds: 20) {
                try await SessionManager.shared_forTest.send(input: "sleep 30", to: "hang", config: cfg, resolvedCommand: bashCmd)
            }
        } catch let e as SessionError { if case .timedOut(let s) = e { timedOut = (s == 2) } }
        check(timedOut, "expected SessionError.timedOut(2)")
        check(Date().timeIntervalSince(started) < 6, "took \(Date().timeIntervalSince(started))s")
        let again: String = try runBlockingWithTimeout {
            let o = try await SessionManager.shared_forTest.send(input: "echo recovered", to: "hang", config: cfg, resolvedCommand: bashCmd)
            await SessionManager.shared_forTest.reapAll(); return o
        }
        check(again == "recovered", again)
    }

    // The stdin write used to run on the actor before the timeout was armed: an input larger than
    // the pipe buffer, behind a statement the client is still busy with, blocked the actor for
    // every caller with no wall clock at all.
    test("wall clock: covers the stdin write — a large input behind a busy client times out and does not block other commands") {
        signal(SIGPIPE, SIG_IGN)
        let cfg: CommandConfig = { var c = bash("bigin"); c.replyTimeout = 1; return c }()
        let padding = String(repeating: "# " + String(repeating: "x", count: 98) + "\n", count: 2000)   // ~200 KB
        let started = Date()
        let (timedOut, other, elapsed): (Bool, String, TimeInterval) = try runBlockingWithTimeout(seconds: 20) {
            let m = SessionManager()
            async let a: Bool = {
                do { _ = try await m.send(input: "sleep 3\n" + padding, to: "bigin", config: cfg, resolvedCommand: bashCmd); return false }
                catch let e as SessionError { if case .timedOut = e { return true }; return false }
            }()
            async let b: String = {
                try await Task.sleep(nanoseconds: 200_000_000)
                return try await m.send(input: "echo other", to: "other", config: bash("other"), resolvedCommand: bashCmd)
            }()
            let r = (try await a, try await b, Date().timeIntervalSince(started))
            await m.reapAll(); return r
        }
        check(timedOut, "expected SessionError.timedOut")
        check(elapsed < 2.5, "the wall clock must cover the write: took \(elapsed)s")
        check(other == "other", "a concurrent send on another command must still answer: \(other)")
    }

    // A wall-clock kill sends SIGINT before SIGTERM: psql answers it with a server-side cancel,
    // mongosh and cqlsh cancel the in-flight operation. A child that ignores TERM but honours INT
    // is therefore gone right after the timeout, not 3 s later at the SIGKILL.
    test("wall clock: the kill starts with SIGINT, so a client that cancels on INT exits at once") {
        signal(SIGPIPE, SIG_IGN)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("signal").path
        let cfg: CommandConfig = { var c = bash("int"); c.replyTimeout = 1; return c }()
        // `wait` (not a foreground sleep) is what lets bash run the trap as soon as INT arrives.
        let script = "trap '' TERM; trap 'echo INT > \(file); kill $!; exit 0' INT; sleep 30 & wait"
        let (pid, timedOut, gone): (pid_t, Bool, Bool) = try runBlockingWithTimeout(seconds: 20) {
            let m = SessionManager()
            let pidText = try await m.send(input: "echo $$", to: "int", config: cfg, resolvedCommand: bashCmd)
            var timedOut = false
            do { _ = try await m.send(input: script, to: "int", config: cfg, resolvedCommand: bashCmd) }
            catch let e as SessionError { if case .timedOut = e { timedOut = true } }
            // 2.5 s: the SIGTERM at +1 s is ignored by the trap, so only the INT (now) or the
            // SIGKILL at +3 s can end the child — the window still tells the two apart. A child
            // that has exited but is not yet reaped is a zombie, which counts as gone.
            let deadline = Date().addingTimeInterval(2.5)
            var gone = false
            while Date() < deadline {
                if exitedOrZombie(pid_t(pidText) ?? -1) { gone = true; break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            await m.reapAll()
            return (pid_t(pidText) ?? -1, timedOut, gone)
        }
        check(pid > 0 && timedOut, "expected a pid and SessionError.timedOut: \(pid)")
        check(gone, "the child must exit on the SIGINT, within 2.5 s of the timeout")
        check((try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "INT",
              "the INT trap must have run")
    }

    test("wall clock: no reply_timeout → no limit (unchanged behaviour)") {
        let out: String = try runBlockingWithTimeout {
            let m = SessionManager()
            let o = try await m.send(input: "sleep 3; echo slow", to: "slow", config: bash("slow"), resolvedCommand: bashCmd)
            await m.reapAll(); return o
        }
        check(out == "slow", out)
    }

    test("row cap is applied to session output") {
        let cfg: CommandConfig = { var c = bash("cap"); c.rowCap = 5; return c }()
        let out: String = try runBlockingWithTimeout {
            let m = SessionManager()
            let o = try await m.send(input: "seq 1 100", to: "cap", config: cfg, resolvedCommand: bashCmd)
            await m.reapAll(); return o
        }
        check(out.hasSuffix("[sneek] output truncated: showing first 5 of 100 lines (row_cap)") && out.hasPrefix("1\n2\n3\n4\n5\n"), out)
    }

    test("oneshot honours the launch context too") {
        let out: String = try runBlockingWithTimeout {
            let ctx = LaunchContext(baseEnvironment: ["PATH": "/usr/bin:/bin"], extraEnvironment: [:], secretFiles: [:], probe: nil)
            return try await SessionManager().runOneshot(command: "echo [$SNEEK_TEST_OTHER_DB_PASSWORD]", input: nil, launch: ctx)
        }
        check(out == "[]", out)
    }

    test("PR_SET_DUMPABLE: a child cannot read the daemon's /proc/<ppid>/environ (Linux)") {
        setenv("SNEEK_TEST_PARENT_CANARY", "canary-parent-environ", 1)
        let applied = Sys.hideProcessMemory()
        #if os(Linux)
        check(applied, "prctl must succeed on Linux")
        let out: String = try runBlockingWithTimeout {
            let m = SessionManager()
            let ctx = LaunchContext(baseEnvironment: ["PATH": "/usr/bin:/bin"], extraEnvironment: [:], secretFiles: [:], probe: nil)
            let o = try await m.send(input: "cat /proc/$PPID/environ 2>&1 | tr '\\0' '\\n' | grep -c canary-parent-environ || echo DENIED",
                                     to: "ppid", config: bash("ppid"), resolvedCommand: bashCmd, launch: ctx)
            await m.reapAll(); return o
        }
        check(out.hasSuffix("DENIED") || out == "0", "child read the parent's environment: \(out)")
        #else
        check(!applied, "no-op on macOS")
        #endif
    }
}

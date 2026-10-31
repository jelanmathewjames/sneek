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
private func bash(_ name: String, max: Int? = nil) -> CommandConfig {
    CommandConfig(name: name, description: "t", mode: .session, command: bashCmd, sentinel: "echo __SNEEK_DONE__", maxSessions: max)
}

/// Runs `inputs` concurrently against one manager; each output is "R<i> <pid>" if nothing interleaved.
private func fanOut(_ m: SessionManager, _ name: String, _ cfg: CommandConfig, _ inputs: [String]) async throws -> [String] {
    try await withThrowingTaskGroup(of: String.self) { g in
        for input in inputs { g.addTask { try await m.send(input: input, to: name, config: cfg, resolvedCommand: bashCmd) } }
        var out: [String] = []
        for try await o in g { out.append(o) }
        return out
    }
}
private func tags(_ outs: [String]) -> [String] { outs.map { $0.components(separatedBy: " ").first ?? "" }.sorted() }
private func pids(_ outs: [String]) -> Set<String> { Set(outs.map { $0.components(separatedBy: " ").last ?? "" }) }

private actor OrderLog { var items: [String] = []; func add(_ s: String) { items.append(s) } }

/// True when `pid` is still a process we can signal. A child killed a moment ago is briefly a
/// zombie (`kill(pid, 0)` still succeeds) until Foundation waits on it, so poll for a few seconds.
private func waitUntilGone(_ pid: pid_t, seconds: Double = 5) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return true }
        usleep(50_000)
    }
    return false
}

func runSessionPoolTests() {
    print("\nSession pool:")
    signal(SIGPIPE, SIG_IGN)

    test("marker: a fresh marker per call, embedded in the configured sentinel command") {
        let a = Marker.make(from: #"\echo __SNEEK_DONE__"#), b = Marker.make(from: #"\echo __SNEEK_DONE__"#)
        check(a.command.hasPrefix(#"\echo __SNEEK_DONE_"#) && a.command.hasSuffix("__") && a.command.contains(a.output), a.command)
        check(a.output != b.output && a.output.count == "__SNEEK_DONE_".count + 8 + 2, "\(a.output) \(b.output)")
        let m = Marker.make(from: #"print("__SNEEK_DONE__")"#)
        check(m.command == #"print("\#(m.output)")"#, m.command)
        let odd = Marker.make(from: "echo DONE")
        check(odd.command == "echo DONE" && odd.output == "__SNEEK_DONE__", "unchanged for a sentinel without the token")
    }

    test("default max_sessions (1): five concurrent sends are served one at a time on one process, never interleaved") {
        let outs: [String] = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            let o = try await fanOut(m, "one", bash("one"), (1...5).map { "sleep 0.2; echo R\($0) $$" })
            await m.reapAll(); return o
        }
        check(tags(outs) == ["R1", "R2", "R3", "R4", "R5"], "\(outs)")
        check(pids(outs).count == 1, "expected one process: \(outs)")
        check(outs.allSatisfy { !$0.contains("\n") }, "an output with two lines means two replies were glued together: \(outs)")
    }

    test("max_sessions 2: a fast query is not queued behind a slow one, and each gets its own output") {
        let cfg = bash("two", max: 2)
        let (slow, fast, order): (String, String, [String]) = try runBlockingWithTimeout {
            let m = SessionManager(); let log = OrderLog()
            async let a: String = {
                let o = try await m.send(input: "sleep 2; echo SLOW", to: "two", config: cfg, resolvedCommand: bashCmd)
                await log.add("slow"); return o
            }()
            async let b: String = {
                try await Task.sleep(nanoseconds: 300_000_000)
                let o = try await m.send(input: "echo FAST", to: "two", config: cfg, resolvedCommand: bashCmd)
                await log.add("fast"); return o
            }()
            let r = (try await a, try await b, await log.items)
            await m.reapAll(); return r
        }
        check(slow == "SLOW" && fast == "FAST", "\(slow) / \(fast)")
        check(order == ["fast", "slow"], "\(order)")
    }

    test("max_sessions 2: six concurrent sends use at most two processes; the third waits for a free one") {
        let cfg = bash("cap", max: 2)
        let (outs, count): ([String], Int) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            let o = try await fanOut(m, "cap", cfg, (1...6).map { "sleep 0.3; echo R\($0) $$" })
            let c = await m.sessionCount("cap")
            await m.reapAll(); return (o, c)
        }
        check(tags(outs) == ["R1", "R2", "R3", "R4", "R5", "R6"], "\(outs)")
        check(pids(outs).count == 2 && count == 2, "expected exactly two processes, got \(pids(outs).count) / \(count)")
    }

    test("a send that fails releases its slot: a waiter behind it is served, not stuck") {
        let cfg = bash("rel")
        let (failed, next): (Bool, String) = try runBlockingWithTimeout {
            let m = SessionManager()
            async let a: String? = { try? await m.send(input: "exit 3", to: "rel", config: cfg, resolvedCommand: bashCmd) }()
            async let b: String = {
                try await Task.sleep(nanoseconds: 100_000_000)
                return try await m.send(input: "echo next", to: "rel", config: cfg, resolvedCommand: bashCmd)
            }()
            let r = (await a == nil, try await b)
            await m.reapAll(); return r
        }
        check(failed, "exit 3 must make the first send throw")
        check(next == "next", next)
    }

    test("output containing the literal __SNEEK_DONE__ is returned intact and the session stays in step") {
        let cfg = bash("lit")
        let (first, second): (String, String) = try runBlockingWithTimeout {
            let m = SessionManager()
            let a = try await m.send(input: "echo '__SNEEK_DONE__ inside data'; echo tail", to: "lit", config: cfg, resolvedCommand: bashCmd)
            let b = try await m.send(input: "echo second", to: "lit", config: cfg, resolvedCommand: bashCmd)
            await m.reapAll(); return (a, b)
        }
        check(first == "__SNEEK_DONE__ inside data\ntail", first)
        check(second == "second", "the next reply must not be shifted: \(second)")
    }

    test("output without a trailing newline keeps its last line, which shares a line with the marker") {
        let cfg = bash("nonl")
        let (out, next): (String, String) = try runBlockingWithTimeout {
            let m = SessionManager()
            let a = try await m.send(input: "printf 'no-newline'", to: "nonl", config: cfg, resolvedCommand: bashCmd)
            let b = try await m.send(input: "printf 'first\\nsecond'", to: "nonl", config: cfg, resolvedCommand: bashCmd)
            await m.reapAll(); return (a, b)
        }
        check(out == "no-newline", out)
        check(next == "first\nsecond", next)
    }

    test("reap(name) ends every pooled process; a later send starts fresh") {
        let cfg = bash("all", max: 3)
        let (before, after, again): (Int, Int, String) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            _ = try await fanOut(m, "all", cfg, (1...3).map { "sleep 0.3; echo R\($0) $$" })
            let before = await m.sessionCount("all")
            await m.reap("all")
            let after = await m.sessionCount("all")
            let again = try await m.send(input: "echo again", to: "all", config: cfg, resolvedCommand: bashCmd)
            await m.reapAll(); return (before, after, again)
        }
        check(before == 3 && after == 0 && again == "again", "\(before) \(after) \(again)")
    }

    test("idle timeout: a session idle past the timeout is reaped; one used since is kept") {
        // A 2 s timeout with 1.5 s / 1 s margins: wide enough that a busy CI box cannot turn
        // "kept" into "reaped" by scheduling the checks late.
        let cfg: CommandConfig = { var c = bash("idle"); c.idleTimeout = 2; return c }()
        let (kept, reaped): (Int, Int) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            _ = try await m.send(input: "echo a", to: "idle", config: cfg, resolvedCommand: bashCmd)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try await m.send(input: "echo b", to: "idle", config: cfg, resolvedCommand: bashCmd)   // t = 1.5
            try await Task.sleep(nanoseconds: 1_000_000_000)      // t = 2.5: past the first timer, not the second (3.5)
            let kept = await m.sessionCount("idle")
            try await Task.sleep(nanoseconds: 2_000_000_000)      // t = 4.5
            let reaped = await m.sessionCount("idle")
            await m.reapAll(); return (kept, reaped)
        }
        check(kept == 1, "a session used 1s ago must survive a 2s idle timeout: \(kept)")
        check(reaped == 0, "an idle session must be reaped after the timeout: \(reaped)")
    }

    // The error path of `send` discards the failed process; if other processes are idle the
    // idle timer is re-armed from that moment, so their reap clock restarts like after a release.
    test("idle timeout: a failed send re-arms the idle timer for the processes still idle") {
        let cfg: CommandConfig = { var c = bash("rearm", max: 2); c.idleTimeout = 2; return c }()
        let (afterFailure, later): (Int, Int) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            async let a: String? = { try? await m.send(input: "sleep 1; exit 3", to: "rearm", config: cfg, resolvedCommand: bashCmd) }()
            try await Task.sleep(nanoseconds: 100_000_000)
            _ = try await m.send(input: "echo b", to: "rearm", config: cfg, resolvedCommand: bashCmd)   // released at t ≈ 0.1, timer → 2.1
            _ = await a                                                                                // fails at t ≈ 1.0: re-armed → 3.0
            try await Task.sleep(nanoseconds: 1_400_000_000)                                           // t ≈ 2.5
            let afterFailure = await m.sessionCount("rearm")
            try await Task.sleep(nanoseconds: 1_500_000_000)                                           // t ≈ 4.0
            let later = await m.sessionCount("rearm")
            await m.reapAll(); return (afterFailure, later)
        }
        check(afterFailure == 1, "the idle process's clock restarts at the failure, so it is still there at 2.5 s: \(afterFailure)")
        check(later == 0, "and it is reaped once the re-armed timer fires: \(later)")
    }

    // `acquire` re-checks that its pool is still the registered one after `startSession`: a process
    // registered in a reaped pool would be tracked nowhere and never killed.
    test("a reap while a session is starting does not orphan the process being started") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-orphan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pids").path
        // The setup command stalls the start long enough for the reap to land mid-flight.
        let cfg: CommandConfig = {
            var c = bash("orph"); c.setupCommands = ["echo $$ >> \(pidFile); sleep 1"]; return c
        }()
        let (out, count): (String, Int) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            async let a: String = m.send(input: "echo ok", to: "orph", config: cfg, resolvedCommand: bashCmd)
            try await Task.sleep(nanoseconds: 300_000_000)
            await m.reap("orph")
            let o = try await a
            let c = await m.sessionCount("orph")
            await m.reapAll(); return (o, c)
        }
        check(out == "ok" && count == 1, "\(out) / \(count)")
        let pids = (try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) } ?? []
        check(pids.count == 2, "expected a first process abandoned by the reap and a second one: \(pids)")
        check(pids.allSatisfy { waitUntilGone($0) }, "a process survived the reap: \(pids)")
    }

    test("wall clock: a timed-out query kills only its own pooled process; a concurrent query finishes") {
        let cfg: CommandConfig = { var c = bash("tmo", max: 2); c.replyTimeout = 2; return c }()
        let (timedOut, other, left): (Bool, String, Int) = try runBlockingWithTimeout(seconds: 20) {
            let m = SessionManager()
            async let a: Bool = {
                do { _ = try await m.send(input: "sleep 30", to: "tmo", config: cfg, resolvedCommand: bashCmd); return false }
                catch let e as SessionError { if case .timedOut = e { return true }; return false }
            }()
            async let b: String = {
                try await Task.sleep(nanoseconds: 300_000_000)
                return try await m.send(input: "sleep 1; echo other", to: "tmo", config: cfg, resolvedCommand: bashCmd)
            }()
            let r = (try await a, try await b, await m.sessionCount("tmo"))
            await m.reapAll(); return r
        }
        check(timedOut, "expected SessionError.timedOut")
        check(other == "other", other)
        check(left == 1, "the surviving process stays in the pool: \(left)")
    }
}

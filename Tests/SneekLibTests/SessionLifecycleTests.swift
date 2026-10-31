import Foundation
@testable import SneekLib

// Consolidation of the session lifecycle (Tasks 11-16 layered the pool, timeouts, probe and
// secrets onto single-session code). Each test here pins one of the rough edges that survived
// that layering. They are behavioural where the behaviour is observable and structural where
// the defect is a leak -- a leaked timer or a leaked thread changes nothing a caller can see
// until the daemon has been up for a week.

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

private func waitUntilGone(_ pid: pid_t, seconds: Double = 8) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return true }
        usleep(50_000)
    }
    return false
}

func runSessionLifecycleTests() {
    print("\nSession lifecycle:")
    signal(SIGPIPE, SIG_IGN)

    // 1. A reply timeout used to be a DispatchQueue.asyncAfter block that could not be
    //    cancelled: it stayed queued for the full timeout after the reply had arrived, holding
    //    its closure. With reply_timeout 600 and a query a second, that is 600 live blocks.
    test("reply timeout: the wall clock is cancelled when the reply arrives, not left queued") {
        let cfg: CommandConfig = { var c = bash("clock"); c.replyTimeout = 600; return c }()
        let live: Int = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            for i in 1...5 {
                _ = try await m.send(input: "echo r\(i)", to: "clock", config: cfg, resolvedCommand: bashCmd)
            }
            let n = SessionManager.liveReplyTimers.value
            await m.reapAll(); return n
        }
        check(live == 0, "\(live) reply timers still armed after 5 replies")
    }

    test("reply timeout: the wall clock still fires when no reply comes") {
        let cfg: CommandConfig = { var c = bash("clockfire"); c.replyTimeout = 1; return c }()
        let (timedOut, live): (Bool, Int) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            var timedOut = false
            do { _ = try await m.send(input: "sleep 30", to: "clockfire", config: cfg, resolvedCommand: bashCmd) }
            catch let e as SessionError { if case .timedOut = e { timedOut = true } }
            let n = SessionManager.liveReplyTimers.value
            await m.reapAll(); return (timedOut, n)
        }
        check(timedOut, "expected SessionError.timedOut")
        check(live == 0, "the fired timer must not stay registered: \(live)")
    }

    // 2. reapIdle re-armed a *full* idle_timeout for sessions that were still fresh, so a
    //    session released just before a firing could live for nearly twice the timeout.
    test("idle timeout: a re-arm runs for the time remaining, so a session cannot live twice the timeout") {
        // timeout 2 s, used again at t ≈ 1.0. The first timer fires at 2.0 and finds it fresh:
        // the re-arm must be for the 1 s remaining (expiry 3.0), not another full 2 s (4.0).
        let cfg: CommandConfig = { var c = bash("rearm2"); c.idleTimeout = 2; return c }()
        let (atThreeFive, ): (Int, ) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            _ = try await m.send(input: "echo a", to: "rearm2", config: cfg, resolvedCommand: bashCmd)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            _ = try await m.send(input: "echo b", to: "rearm2", config: cfg, resolvedCommand: bashCmd)   // t ≈ 1.0
            try await Task.sleep(nanoseconds: 2_500_000_000)                                             // t ≈ 3.5
            let n = await m.sessionCount("rearm2")
            await m.reapAll(); return (n, )
        }
        check(atThreeFive == 0, "idle 2 s, last used at 1.0 s: must be gone by 3.5 s, not alive until 4.0 (\(atThreeFive))")
    }

    // 3. Only reap(name) removed a pool, so a command that failed once kept an empty pool (and
    //    its idle-timeout entry) for the life of the daemon. activeSessions() compensated with
    //    a filter; the table itself still grew, once per command name ever used.
    test("an emptied pool is removed, not left behind as an empty entry") {
        let cfg = bash("gone")
        let (active, tracked, timeouts): ([String], Int, Int) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            _ = try? await m.send(input: "exit 3", to: "gone", config: cfg, resolvedCommand: bashCmd)
            let r = (await m.activeSessions(), await m.trackedPoolCount, await m.trackedIdleTimeoutCount)
            await m.reapAll(); return r
        }
        check(active.isEmpty, "\(active)")
        check(tracked == 0, "the pool table still holds \(tracked) empty pool(s)")
        check(timeouts == 0, "the idle-timeout table still holds \(timeouts) entry/entries")
    }

    test("reap clears the idle-timeout entry it armed") {
        let cfg: CommandConfig = { var c = bash("clear"); c.idleTimeout = 60; return c }()
        let timeouts: Int = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            _ = try await m.send(input: "echo a", to: "clear", config: cfg, resolvedCommand: bashCmd)
            await m.reapAll()
            return await m.trackedIdleTimeoutCount
        }
        check(timeouts == 0, "\(timeouts) idle-timeout entries survived reapAll")
    }

    // 5. After a wall-clock kill the reader thread stayed blocked until the child's pipe closed.
    //    With a configured command that does not exec -- a pipeline rather than a simple command
    //    -- the grandchild holds that pipe open, so the kill freed neither the grandchild nor the
    //    thread. Foundation already gives each child its own process group, so the kill can be
    //    addressed to the group.
    test("wall clock: the kill reaches a grandchild that is holding the pipe open") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-pgid-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("pid").path
        // `bash -c 'sleep … | cat'` does not exec: bash stays as the direct child and the
        // pipeline members are grandchildren, each holding the stdout pipe open.
        let cfg: CommandConfig = { var c = bash("pgid"); c.replyTimeout = 2; return c }()
        let (timedOut, grandchild): (Bool, pid_t) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            var timedOut = false
            do {
                _ = try await m.send(input: "sleep 120 & echo $! > \(pidFile); wait",
                                     to: "pgid", config: cfg, resolvedCommand: bashCmd)
            } catch let e as SessionError { if case .timedOut = e { timedOut = true } }
            await m.reapAll()
            let raw = (try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? ""
            return (timedOut, pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        }
        check(timedOut, "expected SessionError.timedOut")
        check(grandchild > 0, "the test did not record a grandchild pid")
        check(waitUntilGone(grandchild), "grandchild \(grandchild) survived the wall-clock kill")
    }

    // 6. Daemon.statusResponse read activeSessions() and then sessionCount() per name: N+1 actor
    //    hops, so a session could start or end between them and the two numbers disagree.
    test("status: one snapshot, so the command count and the process count cannot disagree") {
        let cfg = bash("snap", max: 2)
        let (snapshot, active): ([String: Int], [String]) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            _ = try await m.send(input: "echo a", to: "snap", config: cfg, resolvedCommand: bashCmd)
            let r = (await m.sessionSnapshot(), await m.activeSessions())
            await m.reapAll(); return r
        }
        check(snapshot == ["snap": 1], "\(snapshot)")
        check(Set(snapshot.keys) == Set(active), "snapshot \(snapshot.keys) vs activeSessions \(active)")
        check(snapshot.values.allSatisfy { $0 > 0 }, "a snapshot must never carry a zero count: \(snapshot)")
    }

    // 7. A session could be terminated twice (reap, then the discard of the call that held it).
    //    It was harmless only because removeItem is `try?` and the pid had not been recycled yet.
    test("a session is terminated once, even when a reap and a failing call both let it go") {
        let cfg = bash("twice")
        let (out, terminations): (Bool, Int) = try runBlockingWithTimeout(seconds: 30) {
            let m = SessionManager()
            SessionManager.terminationCount.reset()
            async let call: String? = { try? await m.send(input: "sleep 2; echo late", to: "twice", config: cfg, resolvedCommand: bashCmd) }()
            try await Task.sleep(nanoseconds: 300_000_000)
            await m.reap("twice")                       // ends the leased process under the call
            let o = await call
            await m.reapAll()
            return (o == nil, SessionManager.terminationCount.value)
        }
        check(out, "the reaped call must fail, not return")
        check(terminations == 1, "the process was terminated \(terminations) times")
    }

    // 8. `terminate` clears the pool back-reference, so `discard` has to resolve the pool
    //    *before* it kills. Resolving after left the dead session in `busy`: the slot was never
    //    returned and no waiter was woken, so with max_sessions 1 the next caller waited for
    //    ever on a process that had already been killed. Those two lines look freely
    //    swappable and the only symptom is a hang, so pin the consequence where it gets a name.
    test("a discarded lease frees the slot, so a caller queued behind it is woken") {
        let cfg = bash("slot", max: 1)
        let (queued, pools, count): (String?, Int, Int) = try runBlockingWithTimeout(seconds: 20) {
            let m = SessionManager()
            async let dies: String? = { try? await m.send(input: "sleep 1; exit 7", to: "slot", config: cfg, resolvedCommand: bashCmd) }()
            try await Task.sleep(nanoseconds: 300_000_000)      // long enough to be parked in waiters
            async let waiting: String? = { try? await m.send(input: "echo second", to: "slot", config: cfg, resolvedCommand: bashCmd) }()
            _ = await dies
            let out = await waiting
            let r = (out, await m.trackedPoolCount, await m.sessionCount("slot"))
            await m.reapAll(); return r
        }
        check(queued?.contains("second") == true, "the queued caller never got the slot back: \(queued ?? "nil")")
        check(pools == 1, "the pool table holds \(pools) pool(s), expected the one live pool")
        check(count == 1, "expected exactly one live session in the pool, got \(count)")
    }
}

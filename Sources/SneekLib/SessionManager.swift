import Foundation

// MARK: - Weak Reference Helper

private final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// A counter two threads may touch. These measure leaks a caller cannot see -- a timer left
/// armed, a process signalled twice -- which is exactly the class of defect that survived the
/// session work, so the counters live in the type they measure rather than in a test double.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func decrement() { lock.lock(); count -= 1; lock.unlock() }
    func reset() { lock.lock(); count = 0; lock.unlock() }
}

/// Resumes a continuation at most once; the reader thread and the timeout race for it.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(with result: Result<T, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
}

/// One reply's wall clock. It fires at most once and is disarmed exactly once: the reader
/// disarms it on every exit path, and it disarms itself when it fires. The predecessor was a
/// `DispatchQueue.asyncAfter` block, which cannot be cancelled -- with `reply_timeout: 600` and
/// a query a second, ten minutes of answered calls each left a live closure on a global queue.
private final class ReplyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(seconds: Int, onFire: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        self.timer = timer
        SessionManager.liveReplyTimers.increment()
        timer.schedule(deadline: .now() + .seconds(seconds))
        // A strong `self` on purpose: the handler must be able to disarm, and the reference
        // cycle it forms is broken by `cancel()`, which every path reaches.
        timer.setEventHandler { self.disarm(); onFire() }
        timer.resume()
    }

    func disarm() {
        lock.lock(); let timer = self.timer; self.timer = nil; lock.unlock()
        guard let timer else { return }
        timer.cancel()
        SessionManager.liveReplyTimers.decrement()
    }
}

// MARK: - End-of-reply marker

/// One end-of-reply marker per call, so data that happens to contain `__SNEEK_DONE__`
/// cannot end a read early, and a stale marker from an earlier call can never match.
public enum Marker {
    /// The placeholder a configured sentinel carries; `make` replaces it with a per-call nonce.
    /// Private on purpose: nothing outside may compare against it, because the token a session
    /// actually emits is never this string.
    private static let token = "__SNEEK_DONE__"

    public static func make(from sentinelCommand: String) -> (command: String, output: String) {
        guard let range = sentinelCommand.range(of: token) else { return (sentinelCommand, token) }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        let output = "__SNEEK_DONE_\(nonce)__"
        return (sentinelCommand.replacingCharacters(in: range, with: output), output)
    }
}

// MARK: - Session Manager

public actor SessionManager {

    /// Test instrumentation, deliberately unconditional: a `#if DEBUG` counter would be absent
    /// from exactly the build a leak is found in. Two atomics cost nothing per call.
    static let liveReplyTimers = AtomicCounter()
    static let terminationCount = AtomicCounter()

    /// Where one client process is in its life. `gone` is terminal and is what makes
    /// `terminate` idempotent: a reap and the failing call that held the lease both let the
    /// same process go, and before this the second one signalled a pid it no longer owned.
    enum SessionState { case starting, idle, leased, gone }

    /// One client process. A reference type: its identity is the lease a call holds on it.
    final class LiveSession {
        let id = UUID()
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let sentinel: String       // the configured sentinel *command*; Marker.make derives the per-call form
        let secretsDir: URL?
        var lastUsed: Date
        var state: SessionState = .starting
        /// The pool that tracks this process, or nil once nothing does. Release and discard
        /// follow this rather than looking the name up again: a `reap` may have replaced the
        /// pool underneath, and the old session must not reach into the new one.
        weak var owner: SessionPool?

        init(process: Process, stdin: FileHandle, stdout: FileHandle, sentinel: String, secretsDir: URL?, lastUsed: Date) {
            self.process = process; self.stdin = stdin; self.stdout = stdout
            self.sentinel = sentinel; self.secretsDir = secretsDir; self.lastUsed = lastUsed
        }
    }

    /// Per command: processes that are free, processes leased to a call, calls waiting for one,
    /// and the pool's own idle timer. The timer used to live in two side tables keyed by name,
    /// which outlived the pools they described; owning it here means it is removed with the pool.
    final class SessionPool {
        let name: String
        var idle: [LiveSession] = []
        var busy: [LiveSession] = []
        var starting = 0                                            // reserved slots (startSession in flight)
        var waiters: [CheckedContinuation<UUID?, Never>] = []      // a leased session's id; nil = "a slot freed, try again"
        var idleTimer: DispatchSourceTimer?
        var idleTimeout = 300
        /// Bumped by every arm. A firing whose generation is stale was already replaced by a
        /// release and must not touch the timer that replaced it.
        var idleGeneration = 0

        init(name: String) { self.name = name }

        /// No processes, none starting and nobody waiting: nothing would ever reference it again.
        var isEmpty: Bool { idle.isEmpty && busy.isEmpty && starting == 0 && waiters.isEmpty }
        var count: Int { idle.count + busy.count }
    }

    private var pools: [String: SessionPool] = [:]

    public init() {}

    // Structural test hooks: the two side tables this consolidation removed used to grow once
    // per command name ever used, for the life of the daemon.
    var trackedPoolCount: Int { pools.count }
    var trackedIdleTimeoutCount: Int { pools.values.filter { $0.idleTimer != nil }.count }

    // MARK: - Session mode

    public func send(input: String, to name: String, config: CommandConfig, resolvedCommand: String,
                     launch: LaunchContext = .inherit) async throws -> String {
        if config.readonly == true, let patterns = config.blockedPatterns {
            let upper = input.uppercased()
            for pattern in patterns {
                if upper.contains(pattern.uppercased()) {
                    SneekLogger.warn("session/\(name): blocked input matching pattern '\(pattern)'")
                    throw SessionError.blockedByReadonly(pattern: pattern, input: input)
                }
            }
        }

        let session = try await acquire(name, config: config, command: resolvedCommand, launch: launch)
        let marker = Marker.make(from: session.sentinel)
        do {
            let output = try await exchange(input + "\n" + marker.command + "\n", on: session, marker: marker.output,
                                            timeout: Self.effectiveReplyTimeout(config))
            release(session, idleTimeout: config.idleTimeout ?? 300)
            return RowCap.apply(output, cap: config.rowCap)
        } catch {
            // This process is in an unknown state — drop only it; other leased sessions keep running.
            // After a timeout the client is still working on the query, so it also gets a SIGKILL
            // follow-up if it ignores the SIGTERM.
            let pool = session.owner
            discard(session, force: { if case SessionError.timedOut = error { return true }; return false }())
            // The pool's other processes may be idle; give them the same fresh clock a release would.
            if let pool, pools[pool.name] === pool, !pool.idle.isEmpty {
                armIdleTimer(pool, timeout: config.idleTimeout ?? 300, after: Double(config.idleTimeout ?? 300))
            }
            throw error
        }
    }

    // MARK: - Effective per-command limits

    /// The daemon's wall clock: a session can undo a database-side statement timeout, so this is the
    /// limit that holds. `reply_timeout` wins; otherwise `statement_timeout` plus 5 s of slack so the
    /// database's own error is the one the caller normally sees.
    public static func effectiveReplyTimeout(_ config: CommandConfig) -> Int? {
        config.replyTimeout ?? config.statementTimeout.map { $0 + 5 }
    }

    /// The configured setup commands, prefixed with whatever this command's limits need at session
    /// start. Returns nil (unchanged) when nothing is configured.
    public static func effectiveSetupCommands(_ config: CommandConfig) -> [String]? {
        var prelude: [String] = []
        if let t = config.statementTimeout, InputGuard.isPsqlType(config) {
            prelude.append("SET statement_timeout = \(t * 1000);")
        }
        if let n = QueryLimit.limit(config), config.command.lowercased().contains("mongosh") {
            prelude.append(#"config.set("displayBatchSize", \#(n))"#)   // docs displayed per cursor iteration
        }
        guard !prelude.isEmpty else { return config.setupCommands }
        return prelude + (config.setupCommands ?? [])
    }

    // MARK: - Pool

    // All bookkeeping here is synchronous actor code. The only suspension points are the
    // `startSession` await (after its slot is reserved) and the waiter continuation, so no
    // pool state is read before an `await` and mutated after it.

    /// Exclusive lease on one client process for `name`. Reuses an idle one, starts one while under
    /// `max_sessions`, otherwise waits for a release. The slot is reserved before the first await.
    private func acquire(_ name: String, config: CommandConfig, command: String, launch: LaunchContext) async throws -> LiveSession {
        let max = Swift.max(1, config.maxSessions ?? 1)
        while true {
            // Re-resolved each pass: `reap(name)` may have replaced the pool while we were suspended.
            let pool = pools[name] ?? { let p = SessionPool(name: name); pools[name] = p; return p }()
            // Evict idle processes that died (e.g. after a tunnel reconnect) so we start fresh.
            for dead in pool.idle.filter({ !$0.process.isRunning }) {
                SneekLogger.info("session/\(name): previous process is dead, restarting")
                discard(dead)
            }
            if let s = pool.idle.popLast() { pool.busy.append(s); s.state = .leased; return s }
            if pool.busy.count + pool.starting < max {
                pool.starting += 1
                defer { pool.starting -= 1 }
                let s: LiveSession
                do { s = try await startSession(name: name, command: command, config: config, launch: launch) }
                catch { wakeOneWaiter(pool); throw error }          // the slot is free again
                guard pools[name] === pool else {
                    // `reap(name)` ran while we were starting: this pool is gone and nothing would
                    // ever reap a process we register in it. Drop it and start under the new pool.
                    terminate(s, force: false)
                    continue
                }
                pool.busy.append(s)
                s.owner = pool
                s.state = .leased
                return s
            }
            // The continuation carries the id, not the session: `LiveSession` is not Sendable.
            let handed: UUID? = await withCheckedContinuation { c in pool.waiters.append(c) }
            if let handed, let s = pool.busy.first(where: { $0.id == handed }) { return s }   // release() moved it to busy
            // nil: a slot freed without a session to hand over — loop and start one
        }
    }

    private func release(_ session: LiveSession, idleTimeout: Int) {
        guard let pool = currentPool(of: session), pool.busy.contains(where: { $0 === session }) else {
            // The pool was reaped while this call held the lease; the process is not tracked
            // anywhere any more, so end it here rather than leak it.
            terminate(session, force: false)
            return
        }
        pool.busy.removeAll { $0 === session }
        session.lastUsed = Date()
        if !pool.waiters.isEmpty {
            let next = pool.waiters.removeFirst()
            pool.busy.append(session)
            session.state = .leased
            next.resume(returning: session.id)
        } else {
            pool.idle.append(session)
            session.state = .idle
        }
        armIdleTimer(pool, timeout: idleTimeout, after: Double(idleTimeout))
    }

    /// Kills one process and forgets it. `force` adds the SIGKILL follow-up.
    private func discard(_ session: LiveSession, force: Bool = false) {
        // Resolved before the kill: `terminate` clears the back-reference, and a session left
        // in `busy` because its pool could no longer be found holds a slot for ever -- with
        // max_sessions 1, the next caller waits on a process that is already dead.
        let owner = currentPool(of: session)
        terminate(session, force: force)
        guard let pool = owner else { return }
        pool.idle.removeAll { $0 === session }
        pool.busy.removeAll { $0 === session }
        session.owner = nil
        wakeOneWaiter(pool)
        dropIfEmpty(pool)
    }

    /// The pool that still tracks `session`, or nil when a `reap` has replaced or removed it.
    /// Going through the session's own back-reference is what keeps a late release or discard
    /// from waking a waiter of the pool that replaced its own.
    private func currentPool(of session: LiveSession) -> SessionPool? {
        guard let pool = session.owner, pools[pool.name] === pool else { return nil }
        return pool
    }

    /// A pool nothing can reference again is removed, so the table does not keep one empty
    /// entry per command name the daemon has ever served.
    private func dropIfEmpty(_ pool: SessionPool) {
        guard pool.isEmpty, pools[pool.name] === pool else { return }
        pool.idleTimer?.cancel()
        pool.idleTimer = nil
        pools.removeValue(forKey: pool.name)
    }

    private func wakeOneWaiter(_ pool: SessionPool) {
        if !pool.waiters.isEmpty { pool.waiters.removeFirst().resume(returning: nil) }
    }

    /// The one place a client process is ended and its secrets directory removed.
    ///
    /// `force` is the wall-clock path, where the client is still working on a query: SIGINT
    /// first — psql answers it with a server-side cancel request, mongosh and cqlsh cancel the
    /// in-flight operation — then SIGTERM after 1 s and SIGKILL 2 s after that, each only if the
    /// process is still running. The `Process` object is captured, not the pid, so a recycled pid
    /// is never signalled.
    private func terminate(_ session: LiveSession, force: Bool) {
        // Idempotent: a reap and the failing call that held the lease both let the same process
        // go. Signalling twice was harmless only because the pid had not been recycled yet.
        guard session.state != .gone else { return }
        session.state = .gone
        session.owner = nil
        Self.terminationCount.increment()

        if let d = session.secretsDir { try? FileManager.default.removeItem(at: d) }
        let target = SignalTarget(session.process)
        guard force else { target.deliver(SIGTERM); return }
        target.deliver(SIGINT)
        // Escalation follows the TARGET, not the direct child. A non-interactive bash sets
        // SIGINT to ignore for a background job, so `sleep 120 & wait` survives the SIGINT that
        // kills bash itself -- and the old check, `process.isRunning`, was then false, so the
        // SIGTERM and SIGKILL never went out at all and the grandchild ran to completion
        // holding the stdout pipe open.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            guard target.isAlive else { return }
            target.deliver(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if target.isAlive { target.deliver(SIGKILL) }   // ignores SIGTERM too
            }
        }
    }

    /// What a kill is addressed to: the child's whole process group where it leads one, or the
    /// child alone where it does not.
    ///
    /// A configured command that does not `exec` — a pipeline, or anything that backgrounds a
    /// job — leaves bash as the direct child with the real work in grandchildren, and it is a
    /// grandchild that holds the stdout pipe open. Signalling the child alone freed neither the
    /// grandchild nor the reader thread blocked on that pipe, which leaked one GCD thread per
    /// wall-clock timeout. Foundation already starts each child in its own process group
    /// (`pgid == pid`), so nothing needs to call `setpgid`; where that does not hold — or where
    /// the group is somehow the daemon's own — this falls back to the child, which is the
    /// behaviour that shipped.
    struct SignalTarget {
        private let process: Process
        private let group: pid_t?

        init(_ process: Process) {
            self.process = process
            let pid = process.processIdentifier
            let pgid = pid > 0 ? getpgid(pid) : -1
            // Never the daemon's own group, whatever the kernel reports.
            self.group = (pgid > 0 && pgid == pid && pgid != getpgid(0)) ? pgid : nil
        }

        func deliver(_ sig: Int32) {
            if let group { _ = killpg(group, sig) } else if process.processIdentifier > 0 {
                _ = kill(process.processIdentifier, sig)
            }
        }

        /// Whether anything is left to escalate against. For a group this outlives the leader:
        /// the group exists while any member does, which is the whole point — the leader is
        /// often the first to die. A group id can in principle be recycled once its last member
        /// is gone, which would make this true for a stranger; the window is the 3 s of the
        /// escalation, and the alternative is leaving real grandchildren running.
        var isAlive: Bool {
            if let group { return killpg(group, 0) == 0 }
            return process.isRunning
        }
    }

    // MARK: - Oneshot mode

    /// No wall clock here: a oneshot has no session to restart, and one is not in the spec.
    public func runOneshot(command: String, input: String?, launch: LaunchContext = .inherit,
                           rowCap: Int? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", input.map { "\(command) \(shellEscape($0))" } ?? command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let secretsDir = try apply(launch, to: process)
        defer { if let d = secretsDir { try? FileManager.default.removeItem(at: d) } }

        try Sys.launch(process)
        Sys.waitForExit(process)

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw SessionError.processExited(code: process.terminationStatus, stderr: stderr)
        }

        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RowCap.apply(output, cap: rowCap)
    }

    // MARK: - Lifecycle

    /// Ends every pooled process for `name`, busy ones included (config change, tunnel reconnect).
    /// A call holding a lease sees its reader hit EOF and throws `processExited`, as for a dead child.
    public func reap(_ name: String) {
        guard let pool = pools.removeValue(forKey: name) else { return }
        for s in pool.idle + pool.busy { terminate(s, force: false) }
        pool.idle.removeAll(); pool.busy.removeAll()
        pool.idleTimer?.cancel(); pool.idleTimer = nil
        let waiters = pool.waiters; pool.waiters.removeAll()
        waiters.forEach { $0.resume(returning: nil) }                 // they start fresh with their own config
        SneekLogger.info("session/\(name): reaped")
    }

    public func reapAll() { for name in pools.keys { reap(name) } }

    /// Every command with at least one live process, and how many each has, read in one actor
    /// hop. `Daemon.statusResponse` used to call `activeSessions()` and then `sessionCount()`
    /// per name — N+1 hops, with a session free to start or end between them, so the two
    /// numbers it printed could describe different moments.
    public func sessionSnapshot() -> [String: Int] {
        pools.compactMapValues { $0.count > 0 ? $0.count : nil }
    }

    public func activeSessions() -> [String] { Array(sessionSnapshot().keys) }
    public func sessionCount(_ name: String) -> Int { pools[name]?.count ?? 0 }

    /// Idle-timer target: ends the free processes only. A leased one is never killed here; the
    /// timer is re-armed by its release, so a long query outlives the timeout as it does today.
    private func reapIdle(_ name: String, generation: Int) {
        // A stale firing: a release has already armed a newer timer, which is the one that
        // decides when this pool is next looked at.
        guard let pool = pools[name], pool.idleGeneration == generation else { return }
        pool.idleTimer = nil
        guard !pool.idle.isEmpty else { dropIfEmpty(pool); return }

        // A session released microseconds before this fired has not been idle for the timeout:
        // keep it and re-arm, so a busy pool is never reaped out from under the next call.
        let timeout = TimeInterval(pool.idleTimeout)
        let cutoff = Date().addingTimeInterval(-timeout)
        let (fresh, stale) = (pool.idle.filter { $0.lastUsed > cutoff }, pool.idle.filter { $0.lastUsed <= cutoff })
        for s in stale { terminate(s, force: false) }
        let n = stale.count
        pool.idle = fresh

        // Re-arm for the time the oldest survivor has LEFT, not for another full timeout: with a
        // full one, a session released just before a firing lived for nearly twice idle_timeout.
        if let oldest = fresh.map({ $0.lastUsed }).min() {
            armIdleTimer(pool, timeout: Int(timeout),
                         after: Swift.max(0.05, oldest.addingTimeInterval(timeout).timeIntervalSinceNow))
        } else {
            dropIfEmpty(pool)
        }
        guard n > 0 else { return }
        SneekLogger.info("session/\(name): reaped \(n) idle process\(n == 1 ? "" : "es")")
    }

    // MARK: - Private

    /// The refusal text for a failed read-only check. The conjunction follows the code, so every
    /// message of a given code reads the same wherever it is raised: a command that *can* write is
    /// "tagged prod **but** …", one that could not be checked is "tagged prod **and** …" (the form
    /// `LaunchPlanner` uses for the same code).
    static func refusal(code: String, name: String, detail: String) -> Refusal {
        let conjunction = code == "prod_not_readonly" ? "but" : "and"
        return Refusal(code: code, message: "command '\(name)' is tagged prod \(conjunction) \(detail)")
    }

    /// Launches one client process and runs its setup commands. It is registered in a pool by
    /// `acquire` alone, once this returns.
    private func startSession(name: String, command: String, config: CommandConfig,
                              launch: LaunchContext = .inherit) async throws -> LiveSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe  // merge stderr into stdout so errors are visible

        let secretsDir = try apply(launch, to: process)
        do {
            try Sys.launch(process)
        } catch {
            if let dir = secretsDir { try? FileManager.default.removeItem(at: dir) }
            throw error
        }

        let sentinel = config.sentinel ?? defaultSentinel(for: command)

        let session = LiveSession(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            sentinel: sentinel,
            secretsDir: secretsDir,
            lastUsed: Date()
        )

        // Run setup commands — fail session if any produces error output. The same wall clock
        // applies: a database that never answers the connect must not hang the daemon.
        if let setupCmds = Self.effectiveSetupCommands(config) {
            let timeout = Self.effectiveReplyTimeout(config)
            do {
                for cmd in setupCmds {
                    let m = Marker.make(from: sentinel)
                    let output = try await exchange(cmd + "\n" + m.command + "\n", on: session, marker: m.output, timeout: timeout)
                    if !output.isEmpty {
                        let lower = output.lowercased()
                        if lower.contains("error") || lower.contains("fatal") || lower.contains("denied") {
                            throw SessionError.setupCommandFailed(command: cmd, output: output)
                        }
                    }
                }
            } catch {
                // The session never becomes live, so nothing else will terminate the child
                // or clean this up — and that holds for a read/EOF failure just as much as
                // for a setup command that reported an error.
                if case SessionError.timedOut = error { terminate(session, force: true) }
                else { terminate(session, force: false) }
                throw error
            }
        }

        // Read-only start-up check. Written straight to the child so it bypasses the blocked-pattern
        // guard (it names INSERT/UPDATE/DELETE as privileges). Every pooled process runs it, so a
        // re-granted or rotated account is caught at the next session start; nothing is cached.
        if let probe = launch.probe {
            let m = Marker.make(from: sentinel)
            let output: String
            do {
                // A broken pipe here (the client died on connect) is a probe that proved nothing,
                // so the write joins the fail-closed path rather than being silently dropped.
                output = try await exchange(probe.input + "\n" + m.command + "\n", on: session, marker: m.output,
                                            timeout: Self.effectiveReplyTimeout(config) ?? 30)
            } catch {
                // Fail closed: a probe that times out or hits EOF has proved nothing. The session
                // never becomes live, so nothing else would terminate the child.
                if case SessionError.timedOut = error { terminate(session, force: true) }
                else { terminate(session, force: false) }
                SneekLogger.error("session/\(name): read-only check could not run")
                throw SessionError.readonlyCheckFailed(Self.refusal(
                    code: "prod_readonly_unverified", name: name,
                    detail: "its read-only check could not run: no answer from the client"))
            }
            if let refusal = ReadonlyCheck.evaluate(output: output, probe: probe) {
                terminate(session, force: false)
                SneekLogger.error("session/\(name): read-only check failed (\(refusal.code))")
                throw SessionError.readonlyCheckFailed(
                    Self.refusal(code: refusal.code, name: name, detail: refusal.message))
            }
            SneekLogger.info("session/\(name): read-only check passed")
        }

        SneekLogger.info("session/\(name): started")
        return session
    }

    /// Applies a launch context to a process. Returns the private directory holding its secret files, if any.
    private func apply(_ launch: LaunchContext, to process: Process) throws -> URL? {
        if launch.isInherit { return nil }                       // identical to the historical path
        var env = launch.baseEnvironment ?? ProcessInfo.processInfo.environment
        env.merge(launch.extraEnvironment) { _, new in new }

        var dir: URL?
        if !launch.secretFiles.isEmpty {
            let d = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-secrets-\(UUID().uuidString)")
            // POSIX mkdir, not FileManager.createDirectory: corelibs creates the directory
            // with the umask'd default mode and only then chmods it, leaving a window on a
            // shared /tmp where the directory is world-searchable. mkdir(2) applies the mode
            // at creation, and it fails with EEXIST rather than adopting an existing directory
            // (the `withIntermediateDirectories: false` semantics this replaces).
            guard mkdir(d.path, 0o700) == 0 else {
                throw SessionError.secretsDirFailed(errno: errno)
            }
            // mkdir's mode is still masked by the umask, so a restrictive umask could leave
            // the daemon unable to write into its own directory. Widening to exactly 0700
            // afterwards is safe — the directory is never wider than 0700 at any instant.
            guard chmod(d.path, 0o700) == 0 else {
                let e = errno
                try? FileManager.default.removeItem(at: d)
                throw SessionError.secretsDirFailed(errno: e)
            }
            for (name, content) in launch.secretFiles {
                let file = d.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: file.path, contents: Data((content + "\n").utf8),
                                                     attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
                    try? FileManager.default.removeItem(at: d)
                    throw SessionError.secretFileFailed(name)
                }
                env[name] = file.path
            }
            dir = d
        }
        process.environment = env
        return dir
    }

    /// Writes `payload` to the session's stdin and reads its stdout until a line containing
    /// `marker` (the per-call output of the sentinel command, see `Marker`), returning everything
    /// before it, trimmed.
    ///
    /// The write happens on the same background thread as the read, *after* the wall clock is
    /// armed: a payload larger than the pipe buffer, sent to a client still busy with an earlier
    /// statement, blocks in `write(2)` until the client drains it — on the actor that would have
    /// stalled every command with no timeout at all. A write error (the client died: EPIPE) fails
    /// the call like an EOF.
    ///
    /// Output that does not end in a newline shares its last line with the marker (bash:
    /// `printf 'x'` → `x__SNEEK_DONE_ab12cd34__`), so any text on the marker line before the
    /// marker is kept as the last line of the output. It is trimmed with the rest, so a
    /// client that prints its marker on a line of its own is unaffected.
    ///
    /// With `timeout` set, the wall clock resumes the caller with `SessionError.timedOut` while the
    /// worker thread stays blocked on the pipe; it is released when the killed child closes its end
    /// (the kill goes to the child's process group, so a grandchild holding that pipe open goes
    /// with it), and its late resume is a no-op (`ResumeOnce`). When the reply wins the race the
    /// clock is disarmed, so nothing stays queued for the remainder of the timeout.
    private func exchange(_ payload: String, on session: LiveSession, marker: String, timeout: Int?) async throws -> String {
        let stdin = session.stdin, handle = session.stdout, data = Data(payload.utf8)
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            // Cancellable, and cancelled on every exit path below: an answered call must not
            // leave its wall clock armed for the rest of the timeout.
            let clock = timeout.map { seconds in
                ReplyClock(seconds: seconds) { once.resume(with: .failure(SessionError.timedOut(seconds: seconds))) }
            }
            DispatchQueue.global().async {
                // Sys.write, not FileHandle.write: this thread may hit EPIPE while another is
                // inside Sys.launch's SIG_DFL window, and that must be an error, not a signal.
                do { try Sys.write(data, to: stdin) }
                catch { clock?.disarm(); once.resume(with: .failure(error)); return }
                var accumulated = Data()

                while true {
                    let data = handle.availableData
                    if data.isEmpty {
                        clock?.disarm()
                        once.resume(with: .failure(SessionError.processExited(code: -1, stderr: "EOF")))
                        return
                    }
                    accumulated.append(data)

                    // Pipe reads split multi-byte characters at arbitrary byte
                    // offsets, so decode the whole buffer lossily every pass —
                    // strict per-chunk decoding would drop the chunk (and hang
                    // forever if the dropped chunk contained the sentinel).
                    let text = String(decoding: accumulated, as: UTF8.self)

                    // Check if the marker appeared
                    let lines = text.components(separatedBy: "\n")
                    if let idx = lines.lastIndex(where: { $0.contains(marker) }),
                       let markerRange = lines[idx].range(of: marker) {
                        let partial = String(lines[idx][..<markerRange.lowerBound])
                        let output = (lines[..<idx] + [partial]).joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        clock?.disarm()
                        once.resume(with: .success(output))
                        return
                    }
                }
            }
        }
    }

    /// Arms the pool's one idle timer to fire `after` seconds from now. `timeout` is the
    /// configured idle_timeout, which `reapIdle` needs to tell a stale session from a fresh one;
    /// `after` is what remains of it, which is the same thing only on a release.
    private func armIdleTimer(_ pool: SessionPool, timeout: Int, after: Double) {
        pool.idleTimer?.cancel()
        pool.idleTimeout = timeout
        pool.idleGeneration += 1
        let generation = pool.idleGeneration
        let name = pool.name
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .milliseconds(Int(after * 1000)))
        let weakSelf = WeakRef(self)
        timer.setEventHandler {
            Task { await weakSelf.value?.reapIdle(name, generation: generation) }
        }
        timer.resume()
        pool.idleTimer = timer
    }

    private func defaultSentinel(for command: String) -> String {
        let lower = command.lowercased()
        if lower.contains("psql") {
            return #"\echo __SNEEK_DONE__"#
        } else if lower.contains("mysql") {
            return "SELECT '__SNEEK_DONE__';"
        } else if lower.contains("redis") {
            return "ECHO __SNEEK_DONE__"
        } else if lower.contains("cqlsh") {
            return "SELECT (text)'__SNEEK_DONE__' FROM system.local;"
        } else if lower.contains("mongosh") {
            return #"print("__SNEEK_DONE__")"#
        }
        return "echo __SNEEK_DONE__"
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Errors

public enum SessionError: Error, Equatable {
    case timedOut(seconds: Int)
    case blockedByReadonly(pattern: String, input: String)
    case processExited(code: Int32, stderr: String)
    case setupCommandFailed(command: String, output: String)
    case secretFileFailed(String)
    case secretsDirFailed(errno: Int32)
    case readonlyCheckFailed(Refusal)
}

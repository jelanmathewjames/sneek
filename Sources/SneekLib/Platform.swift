import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
import CPrctl
#endif

/// Serialises the disposition-modify -> `run()` -> restore section of `Sys.launch`'s
/// Linux branch. That section reads/writes process-wide `sigaction` state; without a
/// lock, two threads launching concurrently can interleave so a child inherits `SIG_IGN`
/// or a restore clobbers another launch's in-flight `SIG_DFL` window.
private let launchLock = NSLock()

/// Thin wrappers over the libc socket calls. Call sites inside types that declare
/// their own `send`/`connect` need a module-qualified name, and the module differs
/// per platform (`Darwin` vs `Glibc`).
enum Sys {
    static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, addr, len)
        #else
        return Glibc.connect(fd, addr, len)
        #endif
    }

    static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(fd, addr, len)
        #else
        return Glibc.bind(fd, addr, len)
        #endif
    }

    static func send(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.send(fd, buf, n, 0)
        #else
        // MSG_NOSIGNAL: a client that hung up must not raise SIGPIPE in the daemon.
        return Glibc.send(fd, buf, n, Int32(MSG_NOSIGNAL))
        #endif
    }

    static func recv(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.recv(fd, buf, n, 0)
        #else
        return Glibc.recv(fd, buf, n, 0)
        #endif
    }

    /// `SOCK_STREAM` is an `Int32` on Darwin and an enum on Glibc.
    static var sockStream: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    /// Glibc's `stdout` is a mutable global Swift 6 won't let us read across isolation;
    /// `fflush(nil)` flushes every open stream and is portable.
    static func flushStdout() {
        #if canImport(Darwin)
        fflush(stdout)
        #else
        fflush(nil)
        #endif
    }

    /// `Process.run()`; every spawn goes through here. On Linux corelibs spawns with
    /// neither `POSIX_SPAWN_SETSIGMASK` nor `SETSIGDEF`, so the child inherits two things
    /// that make `terminate()` a no-op: the mask of the calling thread (libdispatch workers,
    /// i.e. every actor, block all signals) and any `SIG_IGN` disposition (sneekd ignores
    /// TERM/INT/PIPE, and a non-interactive shell cannot trap an ignored signal back).
    /// Both are reset for the duration of `run()` — a synchronous call with no suspension
    /// point — and restored afterwards, throw path included. A SIGTERM landing inside that
    /// window ends the daemon without the graceful path; acceptable, it was asked to stop.
    static func launch(_ process: Process) throws {
        #if canImport(Darwin)
        try process.run()
        #else
        launchLock.lock()
        defer { launchLock.unlock() }

        var none = sigset_t(), saved = sigset_t()
        sigemptyset(&none)
        pthread_sigmask(SIG_SETMASK, &none, &saved)
        defer { pthread_sigmask(SIG_SETMASK, &saved, nil) }

        var ignored: [(Int32, sigaction)] = []
        let sigIgn = unsafeBitCast(SIG_IGN, to: Int.self)
        for sig in [SIGTERM, SIGINT, SIGPIPE, SIGHUP] {
            var current = sigaction()
            sigaction(sig, nil, &current)
            guard unsafeBitCast(current.__sigaction_handler.sa_handler, to: Int.self) == sigIgn else { continue }
            var dfl = sigaction()
            dfl.__sigaction_handler.sa_handler = SIG_DFL
            sigaction(sig, &dfl, nil)
            ignored.append((sig, current))
        }
        // An index loop, deliberately. With the restore written as a destructuring pattern
        // (`for (sig, var previous) in ignored`), 2 of 40 launches in one Linux test run left
        // SIGPIPE at SIG_DFL for the rest of the process, and the next EPIPE killed it. The
        // index form has not failed since, but the mechanism was never established: this is an
        // unexplained correlation, not a diagnosis, so do not "simplify" it back without
        // re-running "launch leaves SIGPIPE ignored" in PlatformTests, which pins the invariant
        // that actually matters — SIGPIPE ignored after every launch.
        defer {
            for i in ignored.indices {
                var previous = ignored[i].1
                sigaction(ignored[i].0, &previous, nil)
            }
        }

        try process.run()
        #endif
    }

    /// Writes `data` to `handle` so that a broken pipe is an error, never a fatal signal.
    /// The process ignores SIGPIPE, but `launch` opens a short window on Linux in which it is
    /// at its default, and a write from another thread that hits EPIPE inside that window would
    /// end the daemon. Linux raises a pipe's SIGPIPE thread-directed, so it is blocked on the
    /// calling thread for the write and a pending one is consumed before the mask is restored;
    /// Darwin raises it process-wide, so the per-descriptor `F_SETNOSIGPIPE` is used instead.
    static func write(_ data: Data, to handle: FileHandle) throws {
        #if canImport(Darwin)
        // XNU raises a pipe's SIGPIPE process-wide, so a per-thread mask cannot contain it;
        // the per-descriptor flag is the Darwin way (idempotent, so set on every write).
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        try handle.write(contentsOf: data)
        #else
        var pipeOnly = sigset_t(), saved = sigset_t()
        sigemptyset(&pipeOnly)
        sigaddset(&pipeOnly, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &pipeOnly, &saved)
        defer {
            // A SIGPIPE the write raised is pending on this thread. Take it out with sigwait
            // (which returns at once for a pending signal) before unblocking; otherwise it would
            // be delivered on unblock — fatally, if the disposition is default at that moment.
            var pending = sigset_t()
            sigemptyset(&pending)
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) == 1 { var taken: Int32 = 0; sigwait(&pipeOnly, &taken) }
            pthread_sigmask(SIG_SETMASK, &saved, nil)
        }
        try handle.write(contentsOf: data)
        #endif
    }

    /// `Process.waitUntilExit()`. On Linux it spins the calling thread's run loop, and
    /// that loop never wakes while another child launched from the same thread is still
    /// alive (corelibs Process.swift, `waitUntilExit`). The reaper thread clears
    /// `isRunning` without any run loop, so poll that instead: 1 ms at first, doubling to
    /// a 50 ms cap, so a quick child costs little and a long one costs almost nothing.
    /// Unbounded on purpose — per-reply timeouts are a separate concern.
    static func waitForExit(_ process: Process) {
        #if canImport(Darwin)
        process.waitUntilExit()
        #else
        var delay: UInt32 = 1_000
        while process.isRunning {
            usleep(delay)
            delay = min(delay * 2, 50_000)
        }
        #endif
    }
}

extension Sys {
    /// Makes /proc/<pid>/environ, /proc/<pid>/mem and core dumps of this process unreadable to
    /// other processes of the same user. Children spawned by sneekd run as the same user.
    @discardableResult
    static func hideProcessMemory() -> Bool {
        #if os(Linux)
        // prctl(2) is variadic, so it isn't callable from Swift at all via Glibc's
        // overlay (not just missing the PR_SET_DUMPABLE constant); CPrctl wraps
        // prctl(PR_SET_DUMPABLE, value, ...) behind a fixed-arity C function. 0 turns
        // dumpability off.
        return sneek_prctl_set_dumpable(0) == 0
        #else
        return false
        #endif
    }
}

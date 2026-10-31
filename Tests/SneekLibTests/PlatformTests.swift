import Foundation
@testable import SneekLib

func runPlatformTests() {
    print("\nPlatform:")

    test("IPC round-trip over a real unix socket") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.sock").path

        let server = IPCServer(socketPath: path)
        server.handler = { req, _ in .ok("echo:\(req.command ?? "")") }
        try server.start()
        Task { await server.acceptLoop() }
        defer { server.stop() }

        let resp = try IPCClient(socketPath: path).send(IPCRequest(action: .run, command: "ping"))
        check(resp.success && resp.output == "echo:ping", "got \(resp)")
    }

    test("TCP health check is false on a closed port") {
        check(TCPHealthCheck.check(port: 1, timeout: 0.5) == false)
    }

    // Sys.launch resets an ignored SIGPIPE to SIG_DFL around run() and must restore it every
    // time. With the restore loop written as `for (sig, var previous) in ignored`, 2 of 40
    // launches on Linux left SIGPIPE at default and the next EPIPE killed the process; the cause
    // was never identified. Hence 40 launches here: the failure was intermittent, so one launch
    // proves nothing.
    test("launch leaves SIGPIPE ignored afterwards, every time") {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        var leftDefault = 0
        let children = (0..<40).map { _ in bash("exit 0") }
        for child in children {
            try Sys.launch(child)
            // signal() returns the disposition in force and re-ignores for the next round.
            let was = signal(SIGPIPE, SIG_IGN)
            if unsafeBitCast(was, to: Int.self) != unsafeBitCast(SIG_IGN, to: Int.self) { leftDefault += 1 }
        }
        for child in children { Sys.waitForExit(child) }
        check(leftDefault == 0, "\(leftDefault) of 40 launches left SIGPIPE at SIG_DFL")
    }

    // The background writer in SessionManager can hit EPIPE while another thread is inside
    // launch's SIG_DFL window. Sys.write must turn that into an error, not a dead process:
    // here SIGPIPE is at its default the whole time and the pipe has no reader.
    test("Sys.write to a pipe with no reader is an error, not a fatal SIGPIPE, even at SIG_DFL") {
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        let pipe = Pipe()
        pipe.fileHandleForReading.closeFile()
        var threw = false
        do { try Sys.write(Data("hello".utf8), to: pipe.fileHandleForWriting) } catch { threw = true }
        check(threw, "the write must fail with EPIPE")
        // And nothing is left pending on this thread that a later unblock could deliver.
        var pending = sigset_t(); sigemptyset(&pending); sigpending(&pending)
        check(sigismember(&pending, SIGPIPE) == 0, "SIGPIPE still pending after Sys.write")
    }

    // The daemon's shape: a long-lived session/tunnel child, then a oneshot on the same
    // actor thread. On Linux, Foundation's waitUntilExit() never returns while another
    // child launched from the same thread is still alive.
    test("Process wait returns while a sibling child from the same thread is still running") {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int32 = -1
        nonisolated(unsafe) var launchError: Error?
        let sibling = bash("sleep 30", stdin: true)
        DispatchQueue.global().async {
            do {
                try Sys.launch(sibling)
                let short = bash("true")
                try Sys.launch(short)
                Sys.waitForExit(short)
                status = short.terminationStatus
            } catch { launchError = error }
            done.signal()
        }
        if done.wait(timeout: .now() + .seconds(3)) == .success {
            check(launchError == nil, "launch failed: \(String(describing: launchError))")
            check(sibling.isRunning, "sibling is still alive while we wait")
            check(status == 0, "short child exit status \(status)")
        } else {
            check(false, "wait for the short child never returned")
        }
        if sibling.isRunning { sibling.terminate() }
    }

    // Actors run on dispatch workers; on Linux those threads block every signal and the
    // child inherits that mask, so reap()'s SIGTERM would stay pending forever.
    test("terminate() kills a session child launched from a dispatch worker") {
        let done = DispatchSemaphore(value: 0)
        let child = bash("exec bash --norc --noprofile", stdin: true)
        nonisolated(unsafe) var launchError: Error?
        DispatchQueue.global().async {
            do { try Sys.launch(child) } catch { launchError = error }
            done.signal()
        }
        done.wait()
        check(launchError == nil, "launch failed: \(String(describing: launchError))")
        check(child.isRunning, "child is running before terminate()")
        if child.isRunning { child.terminate() }
        for _ in 0..<200 where child.isRunning { usleep(10_000) }
        check(!child.isRunning, "child still running after SIGTERM")
    }

    // sneekd ignores SIGTERM/SIGINT/SIGPIPE in its own process. An ignored disposition
    // survives exec, and a non-interactive child cannot trap it back, so reap()'s SIGTERM
    // would be a no-op unless the spawn resets it.
    test("terminate() kills a child launched while the parent ignores SIGTERM") {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let child = bash("sleep 30")
        try Sys.launch(child)
        check(child.isRunning, "child launched")
        if child.isRunning { child.terminate() }
        let done = DispatchSemaphore(value: 0)
        Thread { Sys.waitForExit(child); done.signal() }.start()
        check(done.wait(timeout: .now() + .seconds(2)) == .success, "child exited after SIGTERM")
    }

    // Sys.launch's Linux branch mutates process-wide sigaction state (save -> SIG_DFL ->
    // run() -> restore). Two threads launching concurrently could interleave so one child
    // inherits SIG_IGN, or a restore clobbers another launch's in-flight window. Guards
    // against that race with a file-scope lock; on Darwin this just exercises the plain
    // process.run() branch.
    test("Concurrent launches from multiple threads all terminate cleanly") {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }

        let count = 8
        let children = (0..<count).map { _ in bash("sleep 30") }
        let launchErrors = NSLock()
        nonisolated(unsafe) var errors: [Error] = []
        let group = DispatchGroup()
        for child in children {
            group.enter()
            Thread {
                do { try Sys.launch(child) } catch {
                    launchErrors.lock()
                    errors.append(error)
                    launchErrors.unlock()
                }
                group.leave()
            }.start()
        }
        group.wait()
        check(errors.isEmpty, "launch errors: \(errors)")
        for child in children where child.isRunning {
            child.terminate()
        }

        let done = DispatchSemaphore(value: 0)
        let exitGroup = DispatchGroup()
        for child in children {
            exitGroup.enter()
            Thread {
                Sys.waitForExit(child)
                exitGroup.leave()
            }.start()
        }
        exitGroup.notify(queue: .global()) { done.signal() }
        if done.wait(timeout: .now() + .seconds(3)) == .success {
            for child in children {
                check(!child.isRunning, "child still running after terminate()")
            }
        } else {
            check(false, "not all children exited in time")
        }
    }
}

private func bash(_ cmd: String, stdin: Bool = false) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    if stdin { p.standardInput = Pipe() }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    return p
}

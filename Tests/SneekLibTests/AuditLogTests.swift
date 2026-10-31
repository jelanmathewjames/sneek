import Foundation
@testable import SneekLib

private func runBlocking<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>?
    Task {
        do { result = .success(try await body()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result!.get()
}

func runAuditLogTests() {
    print("\nAudit log:")

    test("entry: run request → action, command, redacted input, outcome, size, hash; no output text") {
        check(sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256Hex("abc"))
        // 56 bytes: the 8-byte length field no longer fits in the first block, so the
        // padding spills into a second one. Pins the block loop, not just the rounds.
        let twoBlocks = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        check(sha256Hex(twoBlocks) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", sha256Hex(twoBlocks))
        let req = IPCRequest(action: .run, command: "pg-prod", input: "select 'canary-secret-value' as x")
        let resp = IPCResponse(success: true, output: "x\ncanary-secret-value\n")
        let e = AuditLog.entry(for: req, peer: PeerInfo(uid: 1001, gid: 2100, pid: 42), response: resp,
                               started: Date(timeIntervalSinceNow: -0.25), redact: ["canary-secret-value"])
        check(e.action == "run" && e.command == "pg-prod" && e.outcome == "ok" && e.code == nil && e.error == nil)
        check(e.input == "select '[sneek: redacted secret]' as x", e.input ?? "nil")
        check(e.output_lines == 2 && e.output_sha256?.count == 64 && e.duration_ms >= 200 && e.duration_ms < 5000, "\(e)")
        check(e.peer == PeerInfo(uid: 1001, gid: 2100, pid: 42) && e.ts.hasSuffix("Z"))
        let json = String(data: try JSONEncoder().encode(e), encoding: .utf8)!
        check(!json.contains("canary-secret-value") && !json.contains("\"output\""), json)
    }

    test("entry: refusal and error outcomes") {
        let refused = AuditLog.entry(for: IPCRequest(action: .shutdown), peer: .unknown,
                                     response: .refused(code: "action_restricted", "action 'shutdown' is not allowed on this socket"),
                                     started: Date(), redact: [])
        check(refused.outcome == "refused" && refused.code == "action_restricted" && refused.input == nil && refused.output_lines == nil)
        let failed = AuditLog.entry(for: IPCRequest(action: .run, command: "pg", input: "select 1"), peer: .unknown,
                                    response: IPCResponse(success: false, error: "execution failed: pw=canary-secret-value " + String(repeating: "x", count: 300)),
                                    started: Date(), redact: ["canary-secret-value"])
        check(failed.outcome == "error" && failed.code == nil && failed.error?.count == 200 && !(failed.error!.contains("canary")), failed.error ?? "nil")
        let tools = AuditLog.entry(for: IPCRequest(action: .tools), peer: .unknown, response: IPCResponse(success: true, tools: []), started: Date(), redact: [])
        check(tools.action == "tools" && tools.input == nil && tools.output_lines == nil, "tools has no input or output summary")
    }

    test("file: one JSON line per record, appended, 0600") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("audit.jsonl").path
        let lines: [String] = try runBlocking {
            let log = try AuditLog(path: path)
            for i in 1...3 {
                await log.record(AuditLog.entry(for: IPCRequest(action: .run, command: "c\(i)", input: "q\(i)"), peer: .unknown,
                                                response: .ok("r"), started: Date(), redact: []))
            }
            let again = try AuditLog(path: path)                       // reopen appends, never truncates
            await again.record(AuditLog.entry(for: IPCRequest(action: .status), peer: .unknown, response: .ok("s"), started: Date(), redact: []))
            return try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        check(lines.count == 4, "\(lines.count) lines")
        let decoded = try lines.map { try JSONDecoder().decode(AuditEntry.self, from: Data($0.utf8)) }
        check(decoded.map(\.command) == ["c1", "c2", "c3", nil] && decoded.last?.action == "status")
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        check(perms?.intValue == 0o600, "perms \(String(describing: perms))")
    }

    test("file: an existing log that is too readable is narrowed to 0600 on open") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("wide.jsonl").path
        check(FileManager.default.createFile(atPath: path, contents: Data("pre-existing\n".utf8),
                                             attributes: [.posixPermissions: NSNumber(value: 0o644)]))
        _ = try runBlocking {
            let log = try AuditLog(path: path)
            await log.record(AuditLog.entry(for: IPCRequest(action: .status), peer: .unknown,
                                            response: .ok("s"), started: Date(), redact: []))
            return true
        }
        let perms = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        check(perms == 0o600, "perms \(String(describing: perms.map { String($0, radix: 8) }))")
        // O_APPEND, so the line that was already there is still the first one.
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        check(lines.count == 2 && lines[0] == "pre-existing", "\(lines)")
    }

    // A full audit volume must be visible in the daemon log, once — not silently, and not
    // once per request.
    test("file: the first failed write is logged as a warning, later ones are silent") {
        let pipe = Pipe()
        let saved = dup(STDERR_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        _ = try runBlocking {
            let log = AuditLog(handle: FileHandle(forReadingAtPath: "/dev/null")!, isStderr: false)   // read-only fd: every write fails
            for i in 1...3 {
                await log.record(AuditLog.entry(for: IPCRequest(action: .run, command: "c\(i)", input: "q"), peer: .unknown,
                                                response: .ok("r"), started: Date(), redact: []))
            }
            return true
        }
        dup2(saved, STDERR_FILENO)
        close(saved)
        pipe.fileHandleForWriting.closeFile()
        let err = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let warnings = err.components(separatedBy: "\n").filter { $0.contains("[WARN]") && $0.contains("audit") }
        check(warnings.count == 1, "expected exactly one warning, got \(warnings.count): \(err)")
    }

    test("ts: ISO-8601 with milliseconds, UTC, computed without a shared formatter") {
        check(AuditLog.iso8601(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z",
              AuditLog.iso8601(Date(timeIntervalSince1970: 0)))
        check(AuditLog.iso8601(Date(timeIntervalSince1970: 1758449702.125)) == "2025-09-21T10:15:02.125Z",
              AuditLog.iso8601(Date(timeIntervalSince1970: 1758449702.125)))
        check(AuditLog.iso8601(Date(timeIntervalSince1970: 1709164800)) == "2024-02-29T00:00:00.000Z",
              AuditLog.iso8601(Date(timeIntervalSince1970: 1709164800)))   // leap day
        // Agrees with Foundation's own formatter for "now", whatever the machine's zone.
        // Only to the second: Foundation rounds the fraction, this truncates it, so the
        // millisecond digits may legitimately differ by one.
        let now = Date()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let mine = AuditLog.iso8601(now), theirs = f.string(from: now)
        check(mine.prefix(20) == theirs.prefix(20), "\(mine) vs \(theirs)")
        check(mine.count == 24 && mine.hasSuffix("Z") && mine.dropFirst(20).dropLast().allSatisfy(\.isNumber), mine)
    }

    test("audit: a path that cannot be opened is a start-up error") {
        checkThrows({ try AuditLog(path: "/no-such-dir-\(UUID().uuidString)/audit.jsonl") }, "unopenable path must throw")
    }

    test("peer: the daemon sees the connecting process's uid") {
        signal(SIGPIPE, SIG_IGN)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sneek-peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path
        let server = IPCServer(socketPath: path)
        let seen = PeerBox()
        server.handler = { req, peer in _ = req; await seen.set(peer); return .ok("hi") }
        try server.start()
        Task { await server.acceptLoop() }
        _ = try IPCClient(socketPath: path).send(IPCRequest(action: .status))
        server.stop()
        let peer: PeerInfo = try runBlocking { await seen.get() }
        check(peer.uid == getuid() && peer.gid == getgid(), "\(peer)")
        #if os(Linux)
        check(peer.pid == getpid(), "SO_PEERCRED pid: \(String(describing: peer.pid))")
        #else
        check(peer.pid == nil, "no pid on macOS")
        #endif
    }
}

private actor PeerBox { var p = PeerInfo.unknown; func set(_ v: PeerInfo) { p = v }; func get() -> PeerInfo { p } }

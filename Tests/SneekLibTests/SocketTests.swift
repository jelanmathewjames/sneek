import Foundation
@testable import SneekLib

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("snk-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func mode(of path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
}

func runSocketTests() {
    print("\nSocket:")

    test("socket path: explicit beats config beats default") {
        let base = URL(fileURLWithPath: "/tmp/base")
        check(Daemon.resolveSocketPath(explicit: nil, config: SneekConfig(), baseDir: base) == "/tmp/base/sneekd.sock")
        check(Daemon.resolveSocketPath(explicit: nil, config: SneekConfig(socketPath: "/run/sneek/s.sock"), baseDir: base) == "/run/sneek/s.sock")
        check(Daemon.resolveSocketPath(explicit: "/x.sock", config: SneekConfig(socketPath: "/run/sneek/s.sock"), baseDir: base) == "/x.sock")
    }

    test("parseMode accepts octal strings only") {
        check(Daemon.parseMode("0660") == 0o660 && Daemon.parseMode("660") == 0o660)
        check(Daemon.parseMode("rw") == nil && Daemon.parseMode("0999") == nil && Daemon.parseMode("7777") == nil)
    }

    test("socket_mode 0660 is applied to the socket file") {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("m.sock").path
        let server = IPCServer(socketPath: path, mode: 0o660)
        try server.start(); defer { server.stop() }
        check(mode(of: path) == 0o660, "mode \(String(mode(of: path), radix: 8))")
    }

    test("without a mode the socket is left to the umask, as before") {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("d.sock").path
        let old = umask(0o022); defer { umask(old) }
        let server = IPCServer(socketPath: path)
        try server.start(); defer { server.stop() }
        check(mode(of: path) == 0o755, "mode \(String(mode(of: path), radix: 8))")
    }

    test("an over-long socket path is an error, not a silent truncation") {
        let server = IPCServer(socketPath: "/tmp/" + String(repeating: "x", count: 120) + ".sock")
        checkThrows({ try server.start() }, "must throw")
    }

    test("restricted socket serves only run, tools, status") {
        for a in [IPCAction.run, .tools, .status] {
            check(Daemon.restrictionRefusal(for: IPCRequest(action: a), restricted: true) == nil, "\(a) must pass")
        }
        for (req, name) in [(IPCRequest(action: .shutdown), "shutdown"),
                            (IPCRequest(action: .tunnel, command: "x", operation: "down"), "tunnel"),
                            (IPCRequest(action: .tunnel, command: "x", operation: "status"), "tunnel"),
                            (IPCRequest(action: .list), "list")] {
            let r = Daemon.restrictionRefusal(for: req, restricted: true)
            check(r?.success == false && r?.code == "action_restricted", "\(name): \(String(describing: r))")
            check(r?.error == "refused: action '\(name)' is not allowed on this socket")
        }
    }

    test("unrestricted socket refuses nothing") {
        for a in [IPCAction.run, .tools, .status, .shutdown, .tunnel, .list] {
            check(Daemon.restrictionRefusal(for: IPCRequest(action: a), restricted: false) == nil)
        }
    }

    // A client that never sends its newline must not grow the daemon's memory without bound:
    // past 1 MiB the connection gets the "invalid request" failure and is closed, so the
    // sender's remaining bytes are refused (EPIPE) rather than buffered.
    test("a request over 1 MiB without a newline is refused and the connection closed") {
        signal(SIGPIPE, SIG_IGN)
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("big.sock").path
        let server = IPCServer(socketPath: path)
        server.handler = { _, _ in .ok("should never be reached") }
        try server.start(); defer { server.stop() }
        Task { await server.acceptLoop() }

        let fd = socket(AF_UNIX, Sys.sockStream, 0); defer { close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { d in for (i, b) in path.utf8CString.enumerated() where i < 104 { d[i] = b } }
        }
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sys.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        check(connected == 0, "connect")
        let chunk = [UInt8](repeating: 0x78, count: 65536)      // 'x', never a newline
        var sent = 0
        for _ in 0..<32 {                                        // 2 MiB offered
            let n = chunk.withUnsafeBytes { Sys.send(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            sent += n
        }
        var buf = [UInt8](repeating: 0, count: 4096), reply = Data()
        while true { let n = Sys.recv(fd, &buf, buf.count); if n <= 0 { break }; reply.append(contentsOf: buf[..<n]) }
        let resp = try? JSONDecoder().decode(IPCResponse.self, from: reply)
        check(resp?.success == false && resp?.error == "invalid request", String(decoding: reply, as: UTF8.self))
        check(sent < 2 * 1024 * 1024, "the server must stop reading past the cap; it accepted \(sent) bytes")
    }

    test("resolving a client socket path for a nonexistent config dir creates nothing on disk") {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("no-such-config-dir")
        let path = Daemon.resolveClientSocketPath(baseDir: sub, explicit: nil)
        check(path == sub.appendingPathComponent("sneekd.sock").path)
        check(!FileManager.default.fileExists(atPath: sub.appendingPathComponent("commands").path))
        check(!FileManager.default.fileExists(atPath: sub.path))
    }

    test("resolveClientSocketPath: explicit beats config beats default") {
        let base = URL(fileURLWithPath: "/tmp/base-client")
        check(Daemon.resolveClientSocketPath(baseDir: base, explicit: "/x.sock") == "/x.sock")
        check(Daemon.resolveClientSocketPath(baseDir: base, explicit: nil) == "/tmp/base-client/sneekd.sock")
    }

    test("SneekConfig without the new keys round-trips unchanged") {
        let json = #"{"log_level":"debug","script_output_dir":"~\/bin"}"#
        let cfg = try JSONDecoder().decode(SneekConfig.self, from: Data(json.utf8))
        check(cfg.socketPath == nil && cfg.socketMode == nil && cfg.restrictSocket == nil)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        check(String(data: try enc.encode(cfg), encoding: .utf8) == json, String(data: try enc.encode(cfg), encoding: .utf8) ?? "")
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if os(Linux)
import CPrctl
#endif

// MARK: - IPC Message Types

public enum IPCAction: String, Codable, Sendable {
    case status
    case run
    case tunnel
    case list
    case shutdown
    case tools
}

public struct ToolInfo: Codable, Equatable, Sendable {
    public var name: String
    public var command: String
    public var description: String
    public var readonly: Bool

    public init(name: String, command: String, description: String, readonly: Bool) {
        self.name = name; self.command = command; self.description = description; self.readonly = readonly
    }
}

public struct IPCRequest: Codable, Sendable {
    public var action: IPCAction
    public var command: String?
    public var input: String?
    public var operation: String?  // for tunnel: "up", "down", "status"

    public init(action: IPCAction, command: String? = nil, input: String? = nil, operation: String? = nil) {
        self.action = action
        self.command = command
        self.input = input
        self.operation = operation
    }
}

public struct IPCResponse: Codable, Sendable {
    public var success: Bool
    public var output: String?
    public var error: String?
    public var tools: [ToolInfo]?
    public var code: String?

    public init(success: Bool, output: String? = nil, error: String? = nil, tools: [ToolInfo]? = nil, code: String? = nil) {
        self.success = success
        self.output = output
        self.error = error
        self.tools = tools
        self.code = code
    }

    public static func ok(_ output: String? = nil) -> IPCResponse {
        IPCResponse(success: true, output: output)
    }

    public static func fail(_ error: String) -> IPCResponse {
        IPCResponse(success: false, error: error)
    }

    /// A policy refusal: machine-readable `code`, human-readable message.
    public static func refused(code: String, _ message: String) -> IPCResponse {
        IPCResponse(success: false, error: "refused: \(message)", code: code)
    }
}

// MARK: - Peer Credentials

/// Credentials of the process on the other end of an accepted unix socket.
/// Recorded in the audit log so a reviewer can tell who asked, not just what was asked.
public struct PeerInfo: Sendable, Codable, Equatable {
    public var uid: UInt32?
    public var gid: UInt32?
    public var pid: Int32?
    public static let unknown = PeerInfo()

    public init(uid: UInt32? = nil, gid: UInt32? = nil, pid: Int32? = nil) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
    }

    /// Credentials of the process at the other end of an accepted unix-socket fd.
    /// Darwin exposes `getpeereid`, which gives uid and gid but no pid. Glibc's Swift
    /// overlay exposes neither `getpeereid` nor `struct ucred`, so Linux goes through
    /// the `SO_PEERCRED` C shim — which does give a pid.
    static func of(fd: Int32) -> PeerInfo {
        var info = PeerInfo()
        #if os(Linux)
        var uid = UInt32(0), gid = UInt32(0), pid = Int32(0)
        if sneek_peer_cred(fd, &uid, &gid, &pid) == 0 {
            info.uid = uid; info.gid = gid; info.pid = pid
        }
        #else
        var uid = uid_t(0), gid = gid_t(0)
        if getpeereid(fd, &uid, &gid) == 0 { info.uid = UInt32(uid); info.gid = UInt32(gid) }
        #endif
        return info
    }
}

// MARK: - IPC Client

public final class IPCClient: Sendable {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let fd = socket(AF_UNIX, Sys.sockStream, 0)
        guard fd >= 0 else {
            throw IPCError.connectionFailed("socket() failed")
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Sys.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCError.connectionFailed("connect() failed: \(String(cString: strerror(errno)))")
        }

        // Send request
        let data = try JSONEncoder().encode(request)
        let message = data + Data([0x0a]) // newline delimiter
        message.withUnsafeBytes { ptr in
            _ = Sys.send(fd, ptr.baseAddress!, ptr.count)
        }

        // Read response — accumulate until newline delimiter found
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Sys.recv(fd, &buf, buf.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[..<n])
            if responseData.contains(0x0a) { break }
        }

        return try JSONDecoder().decode(IPCResponse.self, from: responseData)
    }
}

// MARK: - IPC Server

public final class IPCServer: @unchecked Sendable {
    private let socketPath: String
    private let mode: mode_t?
    private var serverFd: Int32 = -1
    private var running = false

    public var handler: (@Sendable (IPCRequest, PeerInfo) async -> IPCResponse)?

    public init(socketPath: String, mode: mode_t? = nil) {
        self.socketPath = socketPath
        self.mode = mode
    }

    public func start() throws {
        // sun_path is a fixed 104-byte buffer: a longer path would be silently
        // truncated, and we would then bind — and unlink — the wrong file.
        guard socketPath.utf8.count < 104 else {
            throw IPCError.bindFailed("socket path is \(socketPath.utf8.count) bytes; the limit is 103")
        }

        // Remove stale socket
        unlink(socketPath)

        serverFd = socket(AF_UNIX, Sys.sockStream, 0)
        guard serverFd >= 0 else {
            throw IPCError.bindFailed("socket() failed")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    dest[i] = byte
                }
            }
        }

        // Narrow the umask across the bind so the socket is never, even briefly,
        // wider than the mode that was asked for; chmod afterwards pins the exact bits.
        let previousUmask = mode.map { umask(~$0 & 0o777) }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Sys.bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if let previousUmask { umask(previousUmask) }
        guard bindResult == 0 else {
            close(serverFd)
            throw IPCError.bindFailed("bind() failed: \(String(cString: strerror(errno)))")
        }

        if let mode, chmod(socketPath, mode) != 0 {
            close(serverFd)
            throw IPCError.bindFailed("chmod(\(String(mode, radix: 8))) failed: \(String(cString: strerror(errno)))")
        }

        guard listen(serverFd, 5) == 0 else {
            close(serverFd)
            throw IPCError.bindFailed("listen() failed")
        }

        running = true
    }

    public func acceptLoop() async {
        while running {
            let clientFd = accept(serverFd, nil, nil)
            if clientFd < 0 {
                if !running { break }
                continue
            }

            let handler = self.handler
            Task {
                await Self.handleClient(fd: clientFd, handler: handler)
            }
        }
    }

    /// The most a client may send per connection. A `run` input is capped at 64 KiB by
    /// `InputGuard`; this bound keeps a client that never sends its newline from growing the
    /// daemon's memory without limit before that check can run.
    static let maxRequestBytes = 1 << 20

    private static func handleClient(fd: Int32, handler: (@Sendable (IPCRequest, PeerInfo) async -> IPCResponse)?) async {
        defer { close(fd) }

        // Read the peer's credentials from the live fd, before anything can close it.
        let peer = PeerInfo.of(fd: fd)

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var oversized = false
        while true {
            let n = Sys.recv(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[..<n])
            if data.count > maxRequestBytes { oversized = true; break }
            if data.contains(0x0a) { break }
        }

        guard !oversized,
              let request = try? JSONDecoder().decode(IPCRequest.self, from: data),
              let handler = handler else {
            let errorResp = IPCResponse.fail("invalid request")
            if let respData = try? JSONEncoder().encode(errorResp) {
                respData.withUnsafeBytes { ptr in
                    _ = Sys.send(fd, ptr.baseAddress!, ptr.count)
                }
            }
            return
        }

        let response = await handler(request, peer)
        if let respData = try? JSONEncoder().encode(response) {
            let message = respData + Data([0x0a])
            message.withUnsafeBytes { ptr in
                _ = Sys.send(fd, ptr.baseAddress!, ptr.count)
            }
        }
    }

    public func stop() {
        running = false
        if serverFd >= 0 {
            shutdown(serverFd, Int32(SHUT_RDWR))   // wakes accept() on Linux; a harmless ENOTCONN on Darwin
            close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)
    }
}

// MARK: - Errors

public enum IPCError: Error {
    case connectionFailed(String)
    case bindFailed(String)
}

import Foundation

/// One line of the audit log: what was asked, by whom, how it ended.
/// Deliberately never carries the output text or a secret value — the output is
/// summarised as a line count and a SHA-256 so two replies can be compared
/// without the log itself becoming a copy of the database.
public struct AuditEntry: Codable, Sendable, Equatable {
    public var ts: String
    public var action: String
    public var command: String?
    public var peer: PeerInfo
    public var input: String?
    public var outcome: String
    public var code: String?
    public var error: String?
    public var duration_ms: Int
    public var output_lines: Int?
    public var output_sha256: String?

    public init(ts: String, action: String, command: String?, peer: PeerInfo, input: String?,
                outcome: String, code: String?, error: String?, duration_ms: Int,
                output_lines: Int?, output_sha256: String?) {
        self.ts = ts
        self.action = action
        self.command = command
        self.peer = peer
        self.input = input
        self.outcome = outcome
        self.code = code
        self.error = error
        self.duration_ms = duration_ms
        self.output_lines = output_lines
        self.output_sha256 = output_sha256
    }
}

/// Append-only JSON-lines audit log. One `write(2)` per entry, and the actor
/// serialises writers, so concurrent requests never interleave within a line.
public actor AuditLog {
    private let handle: FileHandle
    private let isStderr: Bool
    private var writeFailureLogged = false

    private static func error(_ message: String) -> NSError {
        NSError(domain: "sneek.audit", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// For tests: an audit log over any handle, e.g. one whose writes fail.
    init(handle: FileHandle, isStderr: Bool) {
        self.handle = handle
        self.isStderr = isStderr
    }

    public init(path: String) throws {
        if path == "-" {
            handle = .standardError
            isStderr = true
            return
        }
        isStderr = false

        // O_APPEND, not a seek to the end: the kernel then places every write at the
        // current end of file. A private offset would write into the middle of a file
        // `logrotate copytruncate` had shortened (leaving a NUL hole), and two AuditLogs
        // on one path would overwrite each other. O_CREAT with 0600 also makes creation
        // atomic — the file is never briefly world-readable.
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else {
            throw Self.error("cannot open audit log at \(path): \(String(cString: strerror(errno)))")
        }

        // 0600 must hold for a file that already existed, too — O_CREAT's mode applies
        // only to a file this call creates.
        guard fchmod(fd, 0o600) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Self.error("cannot set mode 0600 on audit log at \(path): \(reason)")
        }

        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public func record(_ e: AuditEntry) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? enc.encode(e) else { return }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)     // one write per line; the actor serialises callers
        } catch {
            // A full audit volume must be visible in the daemon log — once. Repeating it per
            // request would only fill whatever space the daemon log has left.
            if !writeFailureLogged {
                writeFailureLogged = true
                SneekLogger.warn("audit: cannot write to the audit log (\(error)); further failures are not repeated")
            }
        }
        if !isStderr { try? handle.synchronize() }
    }

    /// `2026-09-21T10:15:02.123Z`, computed per call from the epoch with no shared
    /// state. A single `ISO8601DateFormatter` cannot be used here: `entry` is called
    /// from one task per connection, and corelibs-foundation does not promise a
    /// formatter is safe to use from several threads at once.
    static func iso8601(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        let whole = t.rounded(.down)
        let ms = min(999, Int((t - whole) * 1000))
        let secs = Int(whole)
        let days = Int((Double(secs) / 86400).rounded(.down))
        let sod = secs - days * 86400
        let (y, m, d) = civilFromDays(days)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      y, m, d, sod / 3600, (sod % 3600) / 60, sod % 60, ms)
    }

    /// Howard Hinnant's `civil_from_days`: days since 1970-01-01 → (year, month, day)
    /// in the proleptic Gregorian calendar.
    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097                                      // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365  // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)               // [0, 365]
        let mp = (5 * doy + 2) / 153                                    // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                            // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9                               // [1, 12]
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Counts output lines without treating the customary single trailing
    /// newline as a line of its own.
    static func lineCount(_ out: String) -> Int {
        if out.isEmpty { return 0 }
        var lines = out.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.count
    }

    public static func entry(for request: IPCRequest, peer: PeerInfo, response: IPCResponse,
                             started: Date, redact: [String]) -> AuditEntry {
        var e = AuditEntry(ts: iso8601(Date()), action: request.action.rawValue, command: request.command,
                           peer: peer, input: nil, outcome: "ok", code: response.code, error: nil,
                           duration_ms: Int(Date().timeIntervalSince(started) * 1000), output_lines: nil, output_sha256: nil)
        if request.action == .run, let input = request.input {
            e.input = Redaction.apply(input, secrets: redact)
        }
        if !response.success {
            e.outcome = response.code != nil ? "refused" : "error"
            if let err = response.error { e.error = String(Redaction.apply(err, secrets: redact).prefix(200)) }
        } else if request.action == .run, let out = response.output {
            e.output_lines = lineCount(out)
            e.output_sha256 = sha256Hex(out)
        }
        return e
    }
}

// MARK: - SHA-256

/// Pure-Swift SHA-256. CryptoKit is macOS-only and swift-crypto would be a new
/// package dependency; the audit log needs only a digest of a string, so the
/// 64-round compression function is implemented here and pinned by a
/// known-answer test (`sha256Hex("abc")`).
func sha256Hex(_ s: String) -> String {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                       0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

    var msg = Array(s.utf8)
    let bitLength = UInt64(msg.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0x00) }
    for i in (0..<8).reversed() { msg.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }

    var w = [UInt32](repeating: 0, count: 64)
    var block = msg.startIndex
    while block < msg.count {
        for i in 0..<16 {
            let o = block + i * 4
            w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16) | (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        block += 64
    }

    return h.map { String(format: "%08x", $0) }.joined()
}

private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

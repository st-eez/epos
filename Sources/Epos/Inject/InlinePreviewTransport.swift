import Foundation

enum InlinePreviewTransportError: Error {
    /// The probe input method is not running, or its socket is gone.
    case unavailable
    /// The connection is gone: never opened, already closed, or the peer hung up
    /// mid-send. No complete command line reached the probe.
    case closed
    /// The command could not be fully written inside the send budget. Its
    /// terminating newline never reached the probe, so it was never executed.
    case timedOut
    /// The command was fully written but no reply line arrived in time. The
    /// probe may have executed it — callers must treat delivery as unknown.
    case replyTimedOut
    /// The command was fully written and the probe closed the connection without
    /// replying. Delivery is exactly as unknown as `replyTimedOut`; the two are
    /// distinct only so the log names a dead peer instead of blaming a timeout.
    case replyPeerClosed
}

/// Line-oriented command channel to the palette-IME preview probe. The seam that
/// keeps `InlinePreviewSession` unit-testable without a real socket.
protocol InlinePreviewTransport: Sendable {
    func open() async throws
    func send(_ line: String) async throws -> String
    /// Same as `send`, with a wider bounded reply window. Used for the final
    /// commit, whose acknowledgment decides between done and ambiguous.
    func send(_ line: String, replyTimeout: TimeInterval) async throws -> String
    func close() async
}

extension InlinePreviewTransport {
    func send(_ line: String, replyTimeout: TimeInterval) async throws -> String {
        try await send(line)
    }
}

enum InlinePreviewSocket {
    /// The probe derives its socket path from `confstr(_CS_DARWIN_USER_TEMP_DIR)`
    /// rather than `$TMPDIR`; Epos is unsandboxed, so the same call resolves to the
    /// same per-user directory in both processes.
    static let defaultPath: String = {
        var buffer = [CChar](repeating: 0, count: 1024)
        // confstr reports the byte count including the terminating NUL.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let directory = length > 1
            ? String(decoding: buffer[0..<(length - 1)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : NSTemporaryDirectory()
        return (directory as NSString).appendingPathComponent("epos-probe-im.sock")
    }()
}

/// AF_UNIX client for the preview probe.
///
/// Every syscall runs on one private serial queue, so no socket blocking ever
/// reaches the main actor or the Swift concurrency pool, and each operation is
/// bounded by `SO_SNDTIMEO`/`SO_RCVTIMEO`: a wedged probe costs one timeout, not
/// a stalled dictation.
///
/// A timed-out read leaves the reply stream possibly one line behind. That is
/// accepted deliberately: replies only feed the diagnostic acknowledgement flag,
/// while *delivering* the discard command matters, so a late reply never closes
/// the connection out from under a pending `cancel`.
final class UnixSocketInlinePreviewTransport: InlinePreviewTransport, @unchecked Sendable {
    private let path: String
    private let timeout: TimeInterval
    private let maximumReadChunks = 8
    private let queue = DispatchQueue(label: "com.steez.Epos.inline-preview", qos: .utility)
    /// Touched only on `queue`.
    private var descriptor: Int32 = -1

    init(path: String = InlinePreviewSocket.defaultPath, timeout: TimeInterval = 0.075) {
        self.path = path
        self.timeout = timeout
    }

    func open() async throws {
        try await onQueue { try self.openSocket() }
    }

    func send(_ line: String) async throws -> String {
        try await onQueue { try self.write(line) }
    }

    func send(_ line: String, replyTimeout: TimeInterval) async throws -> String {
        try await onQueue { try self.write(line, replyTimeout: replyTimeout) }
    }

    func close() async {
        try? await onQueue { self.closeSocket() }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func openSocket() throws {
        guard descriptor < 0 else { return }
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw InlinePreviewTransportError.unavailable }

        // The probe is killed and restarted routinely (install scripts, crashes),
        // and writing to a socket whose peer is gone raises SIGPIPE, whose default
        // disposition would kill Epos mid-recording. Scoped to this descriptor
        // rather than a process-wide SIG_IGN, which would silently change failure
        // behavior for every other file descriptor in the app. Without it a dead
        // probe is unsurvivable, so a socket that refuses the option is unusable.
        var suppressSignal: Int32 = 1
        let suppressed = setsockopt(
            socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &suppressSignal, socklen_t(MemoryLayout<Int32>.size)
        )
        guard suppressed == 0 else {
            Darwin.close(socketDescriptor)
            throw InlinePreviewTransportError.unavailable
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(socketDescriptor)
            throw InlinePreviewTransportError.unavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(socketDescriptor)
            throw InlinePreviewTransportError.unavailable
        }

        var budget = Self.budget(timeout)
        let budgetSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &budget, budgetSize)
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &budget, budgetSize)
        descriptor = socketDescriptor
    }

    private static func budget(_ interval: TimeInterval) -> timeval {
        timeval(
            tv_sec: Int(interval),
            tv_usec: Int32((interval - TimeInterval(Int(interval))) * 1_000_000)
        )
    }

    private func setReceiveTimeout(_ interval: TimeInterval) {
        var budget = Self.budget(interval)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))
    }

    private func write(_ line: String, replyTimeout: TimeInterval? = nil) throws -> String {
        guard descriptor >= 0 else { throw InlinePreviewTransportError.closed }
        try sendCommand(Array((line + "\n").utf8))
        if let replyTimeout {
            setReceiveTimeout(replyTimeout)
            defer { setReceiveTimeout(timeout) }
            return try readLine()
        }
        return try readLine()
    }

    /// Writes the whole command line or throws. A failure mid-payload leaves a
    /// truncated line the next command would concatenate onto — `commit <half>`
    /// plus the next line could execute a bogus second insertion — so the socket
    /// is closed before throwing and the poisoned connection is never written
    /// again. Every throw here means the terminating newline never arrived, so
    /// the probe never parsed, let alone executed, the command.
    private func sendCommand(_ payload: [UInt8]) throws {
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), payload.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            // Read before `closeSocket`, which can overwrite errno.
            let failure = errno
            closeSocket()
            switch failure {
            case EPIPE, ECONNRESET, ENOTCONN, EBADF:
                throw InlinePreviewTransportError.closed
            default:
                throw InlinePreviewTransportError.timedOut
            }
        }
    }

    private func readLine() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 512)
        var reply: [UInt8] = []
        for _ in 0..<maximumReadChunks {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            // Zero is end-of-stream: the probe hung up, which is not the same
            // event as a slow reply even though callers must treat the delivery
            // of the sent command as equally unknown.
            if count == 0 { throw InlinePreviewTransportError.replyPeerClosed }
            guard count > 0 else { throw InlinePreviewTransportError.replyTimedOut }
            reply.append(contentsOf: buffer[0..<count])
            if reply.contains(0x0A) {
                return String(decoding: reply, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw InlinePreviewTransportError.replyTimedOut
    }

    private func closeSocket() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}

import Foundation

enum InlinePreviewTransportError: Error {
    /// The probe input method is not running, or its socket is gone.
    case unavailable
    case closed
    /// A bounded read or write did not complete inside the per-operation budget.
    case timedOut
}

/// Line-oriented command channel to the palette-IME preview probe. The seam that
/// keeps `InlinePreviewSession` unit-testable without a real socket.
protocol InlinePreviewTransport: Sendable {
    func open() async throws
    func send(_ line: String) async throws -> String
    func close() async
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

        var budget = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - TimeInterval(Int(timeout))) * 1_000_000)
        )
        let budgetSize = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &budget, budgetSize)
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &budget, budgetSize)
        descriptor = socketDescriptor
    }

    private func write(_ line: String) throws -> String {
        guard descriptor >= 0 else { throw InlinePreviewTransportError.closed }
        let payload = Array((line + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), payload.count - offset)
            }
            guard written > 0 else { throw InlinePreviewTransportError.timedOut }
            offset += written
        }
        return try readLine()
    }

    private func readLine() throws -> String {
        var buffer = [UInt8](repeating: 0, count: 512)
        var reply: [UInt8] = []
        for _ in 0..<maximumReadChunks {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { throw InlinePreviewTransportError.timedOut }
            reply.append(contentsOf: buffer[0..<count])
            if reply.contains(0x0A) {
                return String(decoding: reply, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw InlinePreviewTransportError.timedOut
    }

    private func closeSocket() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}

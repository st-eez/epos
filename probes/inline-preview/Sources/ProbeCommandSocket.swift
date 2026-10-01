import AppKit
import Foundation

/// Line-oriented AF_UNIX command channel. Exactly one client is legitimate, so a
/// new connection supersedes the current one; each is served on its own thread so
/// a peer that stops reading can never wedge the accept loop.
///
/// Losing a connection is a teardown, not a pause: the peer that dropped is the
/// only process that could have asked us to remove its marked text, so the
/// composition and focus lock it owned are released for it.
final class ProbeCommandSocket {
    static let shared = ProbeCommandSocket()

    /// Bounds one reply write to a peer that has stopped reading. Epos reads each
    /// reply inside its own 75 ms budget (500 ms for the commit ack), so this sits
    /// far outside normal operation: it exists only so a wedged peer costs one
    /// bounded write instead of blocking its connection thread forever.
    private static let replyWriteTimeout = timeval(tv_sec: 2, tv_usec: 0)

    private var listenerDescriptor: Int32 = -1
    /// Guards `currentConnection` and serialises shutdown against close, so a
    /// superseding connection can never signal a descriptor number that has
    /// already been closed and recycled.
    private let connectionLock = NSLock()
    private let ownership = ProbeConnectionOwnership()
    private var currentConnection: Int32 = -1
    private var nextConnectionID: UInt64 = 1

    func start() {
        // A peer that departs between sending a command and reading its reply
        // would otherwise kill this process with SIGPIPE mid-composition. The
        // per-connection SO_NOSIGPIPE covers the same ground; both are cheap.
        signal(SIGPIPE, SIG_IGN)

        let path = ProbePaths.socketPath
        unlink(path)

        listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerDescriptor >= 0 else {
            ProbeLog.write("socket() failed errno=\(errno)")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            ProbeLog.write("socket path too long: \(path)")
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenerDescriptor, sockaddrPointer, addressLength)
            }
        }
        guard bindResult == 0 else {
            ProbeLog.write("bind() failed errno=\(errno) path=\(path)")
            return
        }
        chmod(path, 0o600)

        guard listen(listenerDescriptor, 4) == 0 else {
            ProbeLog.write("listen() failed errno=\(errno)")
            return
        }

        ProbeLog.write("listening on \(path)")
        Thread.detachNewThread { [listenerDescriptor] in
            let transient: Set<Int32> = [ECONNABORTED, EMFILE, ENFILE, ENOBUFS, ENOMEM]
            while true {
                let connection = accept(listenerDescriptor, nil, nil)
                if connection < 0 {
                    if errno == EINTR { continue }
                    // Transient resource pressure must not retire the resident
                    // input method's only listener: the socket stays bound, so
                    // Epos's connect() would keep succeeding against a process
                    // that no longer answers. The pause keeps EMFILE from
                    // spinning hot while descriptors recover.
                    if transient.contains(errno) {
                        ProbeLog.write("accept() transient errno=\(errno); retrying")
                        usleep(100_000)
                        continue
                    }
                    ProbeLog.write("accept() failed errno=\(errno); listener retired")
                    return
                }
                ProbeCommandSocket.shared.adopt(connection)
            }
        }
    }

    /// Takes over as the one live connection, shutting the previous peer down so
    /// its thread unblocks and runs its teardown. That is what makes a stuck or
    /// dead peer recoverable: reconnecting is enough.
    private func adopt(_ descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var budget = Self.replyWriteTimeout
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &budget, socklen_t(MemoryLayout<timeval>.size))

        connectionLock.lock()
        let identifier = nextConnectionID
        nextConnectionID += 1
        let superseded = currentConnection
        if superseded >= 0 {
            shutdown(superseded, SHUT_RDWR)
        }
        ownership.adopt(identifier)
        currentConnection = descriptor
        connectionLock.unlock()

        if superseded >= 0 {
            ProbeLog.write("connection \(identifier) accepted, superseding the previous peer")
        } else {
            ProbeLog.write("connection \(identifier) accepted")
        }

        Thread.detachNewThread {
            ProbeCommandSocket.serve(descriptor, connection: identifier)
            ProbeCommandSocket.shared.retire(descriptor, connection: identifier)
            ProbeCommandSocket.onMain {
                EposProbeInputController.releaseConnection(identifier, reason: "peer disconnected")
            }
        }
    }

    /// Clears the slot and closes under the same lock a superseding `shutdown`
    /// takes, so the descriptor number cannot be recycled mid-signal.
    private func retire(_ descriptor: Int32, connection: UInt64) {
        connectionLock.lock()
        ownership.retire(connection)
        if currentConnection == descriptor {
            currentConnection = -1
        }
        close(descriptor)
        connectionLock.unlock()
    }

    private static func serve(_ descriptor: Int32, connection: UInt64) {
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                ProbeLog.write("connection \(connection) ended read=\(count) errno=\(count < 0 ? errno : 0)")
                return
            }
            pending.append(contentsOf: buffer[0..<count])

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[0..<newlineIndex], as: UTF8.self)
                pending.removeSubrange(0...newlineIndex)
                let response = handle(line, connection: connection) + "\n"
                guard writeAll(descriptor, response) else {
                    ProbeLog.write("connection \(connection) reply write failed errno=\(errno)")
                    return
                }
            }
        }
    }

    /// A short write would desynchronise every later reply from its command, so
    /// the loop finishes the line or ends the connection.
    private static func writeAll(_ descriptor: Int32, _ text: String) -> Bool {
        let payload = Array(text.utf8)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(descriptor, base.advanced(by: offset), payload.count - offset)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private static func handle(_ line: String, connection: UInt64) -> String {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        let (verb, argument) = split(trimmed)

        return runOnMain {
            shared.ownership.perform(connection) {
                dispatch(verb, argument: argument, connection: connection)
            }
        }
    }

    private static func dispatch(_ verb: String, argument: String, connection: UInt64) -> String {
        switch verb {
        case "ping":
            return "pong"
        case "status":
            return EposProbeInputController.status()
        case "begin":
            return EposProbeInputController.begin(
                expected: argument.isEmpty ? "any" : argument,
                connection: connection
            )
        case "end":
            return EposProbeInputController.end(connection: connection)
        case "mark":
            return EposProbeInputController.mark(argument, styled: true, connection: connection)
        case "markplain":
            return EposProbeInputController.mark(argument, styled: false, connection: connection)
        case "commit":
            return EposProbeInputController.commit(argument.isEmpty ? nil : argument, connection: connection)
        case "cancel":
            return EposProbeInputController.cancel(connection: connection)
        case "rect":
            return EposProbeInputController.rect(connection: connection)
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return "ok quitting"
        default:
            return "err unknown command: \(verb)"
        }
    }

    private static func split(_ line: String) -> (String, String) {
        guard let spaceIndex = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[line.startIndex..<spaceIndex]), String(line[line.index(after: spaceIndex)...]))
    }

    private static func runOnMain(_ body: @escaping () -> String) -> String {
        if Thread.isMainThread { return body() }
        var response = ""
        DispatchQueue.main.sync { response = body() }
        return response
    }

    private static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { return body() }
        DispatchQueue.main.sync(execute: body)
    }
}

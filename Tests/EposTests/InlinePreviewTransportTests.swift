import XCTest
@testable import Epos

/// The socket transport's failure classification, driven over a real AF_UNIX
/// connection: the probe dies routinely (install scripts pkill it), and how that
/// death is reported decides whether Epos survives it, whether the connection
/// stays usable, and what the log blames. A fake transport cannot exercise any
/// of that — the behavior under test is the syscalls themselves.
final class InlinePreviewTransportTests: XCTestCase {
    // MARK: - Doubles

    /// Minimal AF_UNIX server standing in for the probe input method.
    private final class ProbeSocketServer: @unchecked Sendable {
        enum Behavior {
            /// Accept the connection, then hang up without reading anything.
            case hangUp
            /// Accept, consume the request, then hang up without replying.
            case readThenHangUp
            /// Accept and read nothing, so the client's send buffer fills up.
            case stall
        }

        enum Failure: Error { case setup }

        let path: String
        private let listener: Int32
        private let drainGate = DispatchSemaphore(value: 0)
        private let drainFinished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var clientClosed = false

        init(behavior: Behavior) throws {
            // sun_path is 104 bytes and the temp directory eats about half of
            // that, so the socket name stays short.
            path = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("epos-t-\(UUID().uuidString.prefix(8)).sock")
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { throw Failure.setup }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8)
            guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                Darwin.close(listener)
                throw Failure.setup
            }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: pathBytes)
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else {
                Darwin.close(listener)
                throw Failure.setup
            }
            DispatchQueue(label: "com.steez.EposTests.probe-server").async {
                self.serve(behavior)
            }
        }

        /// Releases a stalled server to drain the backlog, reporting whether the
        /// client had already closed its end (read reaching end-of-stream).
        func drainUntilClientClosed(timeout: TimeInterval = 3) -> Bool {
            drainGate.signal()
            guard drainFinished.wait(timeout: .now() + timeout) == .success else { return false }
            return lock.withLock { clientClosed }
        }

        func shutdown() {
            Darwin.close(listener)
            unlink(path)
        }

        private func serve(_ behavior: Behavior) {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            switch behavior {
            case .hangUp:
                return
            case .readThenHangUp:
                _ = Darwin.read(connection, &buffer, buffer.count)
            case .stall:
                drainGate.wait()
                var reachedEndOfStream = false
                while true {
                    let count = Darwin.read(connection, &buffer, buffer.count)
                    if count <= 0 {
                        reachedEndOfStream = count == 0
                        break
                    }
                }
                lock.withLock { clientClosed = reachedEndOfStream }
                drainFinished.signal()
            }
        }
    }

    // MARK: - Tests

    /// Without SO_NOSIGPIPE this test kills the whole test process: writing to a
    /// socket whose peer is gone raises SIGPIPE, and in the app that is Epos
    /// dying mid-recording with the transcript lost and no outcome logged.
    func testDeadPeerIsAClassifiedErrorRatherThanASignalDeath() async throws {
        let server = try ProbeSocketServer(behavior: .hangUp)
        defer { server.shutdown() }
        let transport = UnixSocketInlinePreviewTransport(path: server.path, timeout: 0.05)
        try await transport.open()

        var errors: [InlinePreviewTransportError] = []
        for _ in 0..<4 {
            do {
                _ = try await transport.send("mark hello")
            } catch let error as InlinePreviewTransportError {
                errors.append(error)
            }
        }
        await transport.close()

        // Surviving to the assertions is itself the SIGPIPE regression check.
        XCTAssertTrue(
            errors.contains(.closed),
            "a write to a hung-up peer must classify as closed, got \(errors)"
        )
    }

    /// A peer that hangs up without replying is not a slow peer; the log must be
    /// able to say which happened.
    func testPeerClosingWithoutReplyingIsDistinctFromAReplyTimeout() async throws {
        let server = try ProbeSocketServer(behavior: .readThenHangUp)
        defer { server.shutdown() }
        let transport = UnixSocketInlinePreviewTransport(path: server.path, timeout: 0.5)
        try await transport.open()

        var thrown: InlinePreviewTransportError?
        do {
            _ = try await transport.send("commit Hello there.")
        } catch let error as InlinePreviewTransportError {
            thrown = error
        }
        await transport.close()

        XCTAssertEqual(thrown, .replyPeerClosed)
    }

    /// A send that fails partway leaves a truncated line on the wire. Reusing
    /// that connection would concatenate the next command onto the fragment, so
    /// the socket must be closed before the failure propagates.
    func testPartialSendClosesTheConnectionSoNoCommandIsEverConcatenatedOntoIt() async throws {
        let server = try ProbeSocketServer(behavior: .stall)
        defer { server.shutdown() }
        let transport = UnixSocketInlinePreviewTransport(path: server.path, timeout: 0.05)
        try await transport.open()

        // Far past any socket buffer: the send budget expires mid-payload.
        var thrown: InlinePreviewTransportError?
        do {
            _ = try await transport.send("mark " + String(repeating: "a", count: 4_000_000))
        } catch let error as InlinePreviewTransportError {
            thrown = error
        }

        XCTAssertEqual(thrown, .timedOut)
        XCTAssertTrue(
            server.drainUntilClientClosed(),
            "a partially sent command must close the socket instead of leaving it poisoned"
        )
        // The connection is gone, so nothing can be appended to the fragment.
        var afterFailure: InlinePreviewTransportError?
        do {
            _ = try await transport.send("commit Hello there.")
        } catch let error as InlinePreviewTransportError {
            afterFailure = error
        }
        await transport.close()

        XCTAssertEqual(afterFailure, .closed)
    }
}

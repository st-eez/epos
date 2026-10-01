import Foundation
import XCTest
@testable import Epos

final class TranscriberStartupTests: XCTestCase {
    /// The fake framework call ignores cancellation until explicitly released.
    /// The caller must return on its own deadline while that call is still hung.
    func testUncooperativeFrameworkStartCannotStrandItsCaller() async {
        let framework = FrameworkStartGate()
        let task = Task<Void, Error> { await framework.wait() }
        let returned = expectation(description: "startup caller returned")
        let caller = Task {
            do {
                try await Transcriber.awaitStart(task, timeout: .milliseconds(50))
                XCTFail("a hung framework start must time out")
            } catch TranscriberError.startTimedOut {
                XCTAssertFalse(framework.wasReleased)
            } catch {
                XCTFail("unexpected startup error: \(error)")
            }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        framework.release()
        await caller.value
        _ = try? await task.value
    }

    func testCompletedStartupPreservesFrameworkError() async {
        let task = Task<Void, Error> { throw FrameworkFailure.unavailable }
        do {
            try await Transcriber.awaitStart(task, timeout: .seconds(1))
            XCTFail("the framework error must reach the caller")
        } catch FrameworkFailure.unavailable {
            // The bounded wait must not turn a real startup failure into a timeout.
        } catch {
            XCTFail("unexpected startup error: \(error)")
        }
    }

    private enum FrameworkFailure: Error { case unavailable }
}

private final class FrameworkStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    var wasReleased: Bool { lock.withLock { released } }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if released { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

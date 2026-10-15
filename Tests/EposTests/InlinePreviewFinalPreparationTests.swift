import XCTest
@testable import Epos

final class InlinePreviewFinalPreparationTests: XCTestCase {
    private static let begin = "begin com.test.app"

    func testFinalPreparationDoesNotWaitForAcknowledgedMarkThrottle() async {
        let throttleEntered = expectation(description: "acknowledged mark entered its throttle")
        let throttle = SuspensionGate(entered: throttleEntered)
        let transport = FakeInlinePreviewTransport()
        let preview = InlinePreviewSession(
            transport: transport,
            bundleIdentifier: "com.test.app",
            sleep: { _ in await throttle.wait() }
        )
        await preview.begin()
        await preview.mark("first")
        await fulfillment(of: [throttleEntered], timeout: 1)
        await preview.mark("queued revision")

        let cancellationFinished = expectation(description: "preparation finished with throttle still closed")
        let cancellation = Task {
            let cancelled = await preview.prepareFinalCommit()
            cancellationFinished.fulfill()
            return cancelled
        }
        await fulfillment(of: [cancellationFinished], timeout: 1)
        // Release even on failure so the regression cannot strand its task.
        await throttle.open()
        let cancelled = await cancellation.value
        XCTAssertEqual(cancelled, "first")
        await preview.mark("late revision")
        let outcome = await preview.commitFinalTranscript("Final text.")
        XCTAssertEqual(outcome, .committed)
        await preview.discard()
        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark first", "commit Final text.", "end"])
    }

    func testFinalPreparationWaitsForPendingMarkReply() async {
        await checkPendingMarkReply("ok marked", expectedCancellation: true)
    }

    func testFinalPreparationPreservesPendingMarkSafetyRefusal() async {
        await checkPendingMarkReply("err unsafe unmarked composition", expectedCancellation: false)
    }

    private func checkPendingMarkReply(_ reply: String, expectedCancellation: Bool) async {
        let throttleEntered = expectation(description: "first mark entered its throttle")
        let throttle = SuspensionGate(entered: throttleEntered)
        let secondMarkSent = expectation(description: "second mark is awaiting its reply")
        let transport = SuspendedMarkTransport(secondMarkSent: secondMarkSent)
        let cancellationStarted = expectation(description: "final preparation stopped marking")
        let preview = InlinePreviewSession(
            transport: transport,
            bundleIdentifier: "com.test.app",
            sleep: { _ in await throttle.wait() },
            onMarkingActivityChange: { active in
                if !active { cancellationStarted.fulfill() }
            }
        )
        await preview.begin()
        await preview.mark("first")
        await fulfillment(of: [throttleEntered], timeout: 1)
        await preview.mark("second")
        await throttle.open()
        await fulfillment(of: [secondMarkSent], timeout: 1)

        let cancellation = Task { await preview.prepareFinalCommit() }
        await fulfillment(of: [cancellationStarted], timeout: 1)
        await preview.mark("late revision")
        let linesBeforeReply = await transport.lines
        XCTAssertEqual(linesBeforeReply, [Self.begin, "mark first", "mark second"])
        await transport.replyToSecondMark(reply)

        let cancelled = await cancellation.value
        XCTAssertEqual(cancelled, expectedCancellation ? "second" : nil)
        let unsafe = await preview.hasUnsafeTarget()
        XCTAssertEqual(unsafe, !expectedCancellation)
        let linesAfterReply = await transport.lines
        XCTAssertEqual(
            linesAfterReply,
            [Self.begin, "mark first", "mark second"]
        )
        if !expectedCancellation {
            let outcome = await preview.commitFinalTranscript("Final text.")
            XCTAssertEqual(outcome, .targetUnsafe)
        }
        await preview.discard()
    }
}

private actor SuspensionGate {
    private let entered: XCTestExpectation
    private var waiter: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        await withCheckedContinuation {
            waiter = $0
            entered.fulfill()
        }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

private actor SuspendedMarkTransport: InlinePreviewTransport {
    private let secondMarkSent: XCTestExpectation
    private var replyWaiter: CheckedContinuation<String, Never>?
    private(set) var lines: [String] = []

    init(secondMarkSent: XCTestExpectation) {
        self.secondMarkSent = secondMarkSent
    }

    func open() {}

    func send(_ line: String) async throws -> String {
        lines.append(line)
        if line == "mark second" {
            return await withCheckedContinuation {
                replyWaiter = $0
                secondMarkSent.fulfill()
            }
        }
        return "ok"
    }

    func replyToSecondMark(_ reply: String) {
        replyWaiter?.resume(returning: reply)
        replyWaiter = nil
    }

    func close() {}
}

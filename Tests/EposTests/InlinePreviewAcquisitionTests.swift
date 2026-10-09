import XCTest
@testable import Epos

final class InlinePreviewAcquisitionTests: XCTestCase {
    func testDraftWaitsForActualNativeActivation() async {
        let waiting = expectation(description: "source selected but native client not activated")
        let gate = ActivationGate(waiting: waiting)
        let transport = ActivationTransport()
        let session = InlinePreviewSession(
            transport: transport,
            bundleIdentifier: "com.test.host",
            acquisitionArgument: "acquire-layout com.test.layout com.test.layout",
            throttle: .zero,
            sleep: { duration in if duration != .zero { await gate.wait() } }
        )
        let beginning = Task { await session.begin() }
        await fulfillment(of: [waiting], timeout: 1)
        await session.mark("first draft")
        await session.mark("revised draft")
        let before = await transport.lines
        XCTAssertEqual(before, ["begin com.test.host acquire-layout com.test.layout com.test.layout"])

        await gate.release()
        await beginning.value
        await session.awaitDrainCompletion()
        let after = await transport.lines
        XCTAssertEqual(after, [before[0], before[0], "mark revised draft"])
        await session.discard()
    }

    func testDiscardDuringActivationDoesNotAcquireOrSendDraftLater() async {
        let waiting = expectation(description: "activation pending")
        let gate = ActivationGate(waiting: waiting)
        let transport = ActivationTransport()
        let session = InlinePreviewSession(
            transport: transport,
            bundleIdentifier: "com.test.host",
            acquisitionArgument: "acquire-layout com.test.layout com.test.layout",
            sleep: { _ in await gate.wait() }
        )
        let beginning = Task { await session.begin() }
        await fulfillment(of: [waiting], timeout: 1)
        await session.mark("obsolete draft")
        await session.discard()
        await gate.release()
        await beginning.value

        let lines = await transport.lines
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("begin "))
        let report = await session.report()
        XCTAssertFalse(report.began)
        XCTAssertFalse(report.didAttemptMark)
    }
}

private actor ActivationTransport: InlinePreviewTransport {
    private(set) var lines: [String] = []
    private var beginCount = 0

    func open() async throws {}
    func close() async {}
    func send(_ line: String) async throws -> String {
        lines.append(line)
        if line.hasPrefix("begin ") {
            beginCount += 1
            return beginCount == 1 ? "err input method activation pending" : "ok locked"
        }
        return "ok"
    }
}

private actor ActivationGate {
    private let waiting: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(waiting: XCTestExpectation) { self.waiting = waiting }
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            waiting.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

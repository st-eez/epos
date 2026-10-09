import XCTest
@testable import Epos

final class InlinePreviewDiscardTests: XCTestCase {
    func testDiscardConsumesPendingSafetyRefusalBeforeReturning() async {
        await consumesPendingSafetyRefusal(command: "mark")
    }

    func testDiscardConsumesPendingBeginSafetyRefusalBeforeReturning() async {
        await consumesPendingSafetyRefusal(command: "begin")
    }

    func testFirstConclusiveMarkRefusalNeedsNoCancelAfterDiscardStarts() async {
        let commandSent = expectation(description: "mark awaiting its refusal")
        let transport = PendingCommandTransport(
            command: "mark", sent: commandSent, reply: "err unmarked preview requires an empty selection"
        )
        let discardStarted = expectation(description: "preview left the marking phase")
        let preview = InlinePreviewSession(
            transport: transport,
            bundleIdentifier: "com.test.app",
            onMarkingActivityChange: { if !$0 { discardStarted.fulfill() } }
        )
        await preview.begin()
        await preview.mark("provisional text")
        await fulfillment(of: [commandSent], timeout: 1)
        let discard = Task { await preview.discard() }
        await fulfillment(of: [discardStarted], timeout: 1)
        await transport.releaseReply()
        await discard.value
        let cancelCount = await transport.cancelCount
        let unsafeTarget = await preview.hasUnsafeTarget()
        let report = await preview.report()
        XCTAssertEqual(cancelCount, 0, "initial selection refusal created no Epos mark")
        XCTAssertFalse(unsafeTarget, "the original selection remains eligible for guarded final replacement")
        XCTAssertFalse(report.mayHaveRendered, "discard must retain the pending mark's conclusive refusal")
    }

    func testPendingPostWriteMarkErrorsAttemptCleanupAfterDiscardStarts() async {
        for reply in ["err unsafe mark readback changed", "err unsafe session retired during mark"] {
            let commandSent = expectation(description: "mark awaiting its post-write reply")
            let transport = PendingCommandTransport(command: "mark", sent: commandSent, reply: reply)
            let discardStarted = expectation(description: "preview left the marking phase")
            let preview = InlinePreviewSession(
                transport: transport, bundleIdentifier: "com.test.app",
                onMarkingActivityChange: { if !$0 { discardStarted.fulfill() } }
            )
            await preview.begin()
            await preview.mark("provisional text")
            await fulfillment(of: [commandSent], timeout: 1)
            let discard = Task { await preview.discard() }
            await fulfillment(of: [discardStarted], timeout: 1)
            await transport.releaseReply()
            await discard.value

            let cancelCount = await transport.cancelCount
            let unsafeTarget = await preview.hasUnsafeTarget()
            let report = await preview.report()
            XCTAssertEqual(cancelCount, 1, reply)
            XCTAssertTrue(unsafeTarget, reply)
            XCTAssertTrue(report.mayHaveRendered, reply)
        }
    }

    private func consumesPendingSafetyRefusal(command: String) async {
        let commandSent = expectation(description: "\(command) awaiting its reply")
        let transport = PendingCommandTransport(
            command: command, sent: commandSent,
            reply: command == "mark" ? "err unsafe unmarked composition" : "err unsafe composition"
        )
        let preview = InlinePreviewSession(transport: transport, bundleIdentifier: "com.test.app")
        let begin = Task { await preview.begin() }
        if command == "mark" {
            await begin.value
            await preview.mark("provisional text")
        }
        await fulfillment(of: [commandSent], timeout: 1)

        let returned = expectation(description: "discard returned")
        let discard = Task {
            await preview.discard()
            returned.fulfill()
        }
        let earlyReturn = await XCTWaiter.fulfillment(of: [returned], timeout: 0.05)
        XCTAssertEqual(earlyReturn, .timedOut, "discard must consume the pending command's safety result")

        await transport.releaseReply()
        await begin.value
        await discard.value
        let unsafeTarget = await preview.hasUnsafeTarget()
        XCTAssertTrue(unsafeTarget, "a late safety refusal was lost after preview stopped")
    }
}

private actor PendingCommandTransport: InlinePreviewTransport {
    private let command: String
    private let sent: XCTestExpectation
    private let reply: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0

    init(command: String, sent: XCTestExpectation, reply: String = "err unsafe composition") {
        self.command = command
        self.sent = sent
        self.reply = reply
    }

    func open() async throws {}

    func send(_ line: String) async throws -> String {
        if line == "cancel" {
            cancelCount += 1
            return "err unsafe selection"
        }
        guard line.hasPrefix("\(command) ") else { return "ok" }
        await withCheckedContinuation {
            continuation = $0
            sent.fulfill()
        }
        return reply
    }

    func releaseReply() {
        continuation?.resume()
        continuation = nil
    }

    func close() async {}
}

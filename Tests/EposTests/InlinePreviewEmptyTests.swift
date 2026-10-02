import XCTest
@testable import Epos

final class InlinePreviewEmptyTests: XCTestCase {
    private static let begin = "begin com.test.app"

    func testEmptyPreviewCancelsAndTheSameTextCanResumeBeforeDiscard() async {
        let first = expectation(description: "first mark acknowledged")
        let cleared = expectation(description: "empty update acknowledged")
        let resumed = expectation(description: "resumed mark acknowledged")
        let throttle = PreviewGate(pauses: [first, cleared, resumed])
        let transport = EmptyPreviewTransport()
        let rendered = expectation(description: "first rendered callback occurs once")
        rendered.assertForOverFulfill = true
        let preview = makePreview(transport, throttle: throttle, onFirstMarkRendered: { rendered.fulfill() })
        await preview.begin()
        await preview.mark("same text")
        await fulfillment(of: [first, rendered], timeout: 1)

        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [cleared], timeout: 1)
        var report = await preview.report()
        XCTAssertTrue(report.cancelAcknowledged)
        XCTAssertEqual(report.marksSent, 1)
        let eligible = await preview.isEligibleForFinalCommit()
        XCTAssertTrue(eligible, "clearing preserves the healthy channel and focus lock")

        await preview.mark("same text")
        await throttle.open()
        await fulfillment(of: [resumed], timeout: 1)
        report = await preview.report()
        XCTAssertFalse(report.cancelAcknowledged, "an earlier clear cannot authorize cleanup of a fresh mark")
        XCTAssertEqual(report.marksSent, 2)
        await preview.discard()
        await throttle.open()

        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark same text", "cancel", "mark same text", "cancel", "end"])
        report = await preview.report()
        XCTAssertTrue(report.cancelAcknowledged)
        XCTAssertNil(report.failure)
    }

    func testEmptyBeforeBeginReplacesThePendingMarkWithoutSendingACompositionCommand() async {
        let drained = expectation(description: "empty state drained")
        let throttle = PreviewGate(pauses: [drained])
        let transport = EmptyPreviewTransport()
        let preview = makePreview(transport, throttle: throttle)
        await preview.mark("stale pending text")
        await preview.mark("")
        await preview.begin()
        await fulfillment(of: [drained], timeout: 1)
        await preview.discard()
        await throttle.open()

        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "end"])
        let report = await preview.report()
        XCTAssertFalse(report.didAttemptMark)
        XCTAssertEqual(report.marksSent, 0)
        XCTAssertFalse(report.cancelAcknowledged)
    }

    func testEmptyDuringThrottleReplacesThePendingNonemptyMark() async {
        let first = expectation(description: "first mark acknowledged")
        let cleared = expectation(description: "empty state drained")
        let throttle = PreviewGate(pauses: [first, cleared])
        let transport = EmptyPreviewTransport()
        let preview = makePreview(transport, throttle: throttle)
        await preview.begin()
        await preview.mark("visible text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("stale pending text")
        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [cleared], timeout: 1)
        await preview.discard()
        await throttle.open()

        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark visible text", "cancel", "end"])
        let report = await preview.report()
        XCTAssertEqual(report.marksSent, 1)
    }

    func testEmptyDuringAnInflightMarkWaitsForItsReplyBeforeClearing() async {
        let sent = expectation(description: "mark awaiting its reply")
        let commandGate = PreviewGate(pauses: [sent])
        let first = expectation(description: "mark reply consumed")
        let cleared = expectation(description: "clear reply consumed")
        let throttle = PreviewGate(pauses: [first, cleared])
        let transport = EmptyPreviewTransport(heldLine: "mark pending text", commandGate: commandGate)
        let preview = makePreview(transport, throttle: throttle)
        await preview.begin()
        await preview.mark("pending text")
        await fulfillment(of: [sent], timeout: 1)
        await preview.mark("")
        let linesBeforeReply = await transport.lines
        XCTAssertEqual(linesBeforeReply, [Self.begin, "mark pending text"])

        await commandGate.open()
        await fulfillment(of: [first], timeout: 1)
        await throttle.open()
        await fulfillment(of: [cleared], timeout: 1)
        await preview.discard()
        await throttle.open()

        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark pending text", "cancel", "end"])
    }

    func testDiscardConsumesAnInflightEmptyClearWithoutCancellingTwice() async {
        await discardDuringClear(firstCancel: .success("ok cancelled"), expectedUnsafe: false)
    }

    func testRevisionBackToPriorTextDuringAnInflightMarkIsSent() async {
        let first = expectation(description: "original text acknowledged")
        let intermediate = expectation(description: "intermediate text acknowledged")
        let latest = expectation(description: "latest text acknowledged")
        let throttle = PreviewGate(pauses: [first, intermediate, latest])
        let sent = expectation(description: "intermediate mark awaiting its reply")
        let commandGate = PreviewGate(pauses: [sent])
        let transport = EmptyPreviewTransport(heldLine: "mark intermediate text", commandGate: commandGate)
        let preview = makePreview(transport, throttle: throttle)
        await preview.begin()
        await preview.mark("original text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("intermediate text")
        await throttle.open()
        await fulfillment(of: [sent], timeout: 1)
        await preview.mark("original text")
        await commandGate.open()
        await fulfillment(of: [intermediate], timeout: 1)
        await throttle.open()
        await fulfillment(of: [latest], timeout: 1)

        let linesBeforeDiscard = await transport.lines
        XCTAssertEqual(linesBeforeDiscard, [Self.begin, "mark original text", "mark intermediate text", "mark original text"])
        await preview.discard()
        await throttle.open()
    }

    func testPriorTextCanResumeWhileAnEmptyClearReplyIsPending() async {
        let first = expectation(description: "original text acknowledged")
        let cleared = expectation(description: "empty update acknowledged")
        let resumed = expectation(description: "original text resumed")
        let throttle = PreviewGate(pauses: [first, cleared, resumed])
        let sent = expectation(description: "clear awaiting its reply")
        let commandGate = PreviewGate(pauses: [sent])
        let transport = EmptyPreviewTransport(heldLine: "cancel", commandGate: commandGate)
        let preview = makePreview(transport, throttle: throttle)
        await preview.begin()
        await preview.mark("original text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [sent], timeout: 1)
        await preview.mark("original text")
        await commandGate.open()
        await fulfillment(of: [cleared], timeout: 1)
        await throttle.open()
        await fulfillment(of: [resumed], timeout: 1)

        let linesBeforeDiscard = await transport.lines
        XCTAssertEqual(linesBeforeDiscard, [Self.begin, "mark original text", "cancel", "mark original text"])
        let report = await preview.report()
        XCTAssertFalse(report.cancelAcknowledged)
        XCTAssertEqual(report.marksSent, 2)
        await preview.discard()
        await throttle.open()
        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark original text", "cancel", "mark original text", "cancel", "end"])
    }

    func testEmptyDuringAResumedInflightMarkRemainsTheLatestState() async {
        let first = expectation(description: "first mark acknowledged")
        let cleared = expectation(description: "first empty update acknowledged")
        let resumed = expectation(description: "resumed mark acknowledged")
        let clearedAgain = expectation(description: "newest empty update acknowledged")
        let throttle = PreviewGate(pauses: [first, cleared, resumed, clearedAgain])
        let sent = expectation(description: "resumed mark awaiting its reply")
        let commandGate = PreviewGate(pauses: [sent])
        let transport = EmptyPreviewTransport(heldLine: "mark fresh text", commandGate: commandGate)
        let preview = makePreview(transport, throttle: throttle)
        await preview.begin()
        await preview.mark("old text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [cleared], timeout: 1)
        await preview.mark("fresh text")
        await throttle.open()
        await fulfillment(of: [sent], timeout: 1)
        await preview.mark("")
        await commandGate.open()
        await fulfillment(of: [resumed], timeout: 1)
        await throttle.open()
        await fulfillment(of: [clearedAgain], timeout: 1)

        let linesBeforeDiscard = await transport.lines
        XCTAssertEqual(linesBeforeDiscard, [Self.begin, "mark old text", "cancel", "mark fresh text", "cancel"])
        let report = await preview.report()
        XCTAssertTrue(report.cancelAcknowledged)
        XCTAssertEqual(report.marksSent, 2)
        await preview.discard()
        await throttle.open()
    }

    func testDiscardPreservesAnInflightEmptyClearSafetyRefusal() async {
        await discardDuringClear(firstCancel: .success("err unsafe composition"), expectedUnsafe: true)
    }

    @MainActor
    func testEmptyClearRefusalsSuppressFinalDeliveryEvenAfterSuccessfulDiscardCleanup() async {
        for reply in ["err unsafe composition", "err locked session gone", "unexpected reply"] {
            await refusesFinalDeliveryAfterEmptyClear(.success(reply))
        }
    }

    @MainActor
    func testEmptyClearTimeoutAndSendFailureSuppressFinalDelivery() async {
        for error in [InlinePreviewTransportError.replyTimedOut, .closed] {
            await refusesFinalDeliveryAfterEmptyClear(.failure(error))
        }
    }

    func testFreshMarkWithLostReplyAfterEmptyClearStillRequiresDiscardCancellation() async {
        let first = expectation(description: "first mark acknowledged")
        let cleared = expectation(description: "empty update acknowledged")
        let throttle = PreviewGate(pauses: [first, cleared])
        let degraded = expectation(description: "fresh mark reply lost")
        let transport = EmptyPreviewTransport(failingMark: "mark fresh text")
        let preview = makePreview(transport, throttle: throttle, onMarkingActivityChange: {
            if !$0 { degraded.fulfill() }
        })
        await preview.begin()
        await preview.mark("old text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [cleared], timeout: 1)
        await preview.mark("fresh text")
        await throttle.open()
        await fulfillment(of: [degraded], timeout: 1)
        let beforeDiscard = await preview.report()
        XCTAssertFalse(beforeDiscard.cancelAcknowledged)
        await preview.discard()

        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark old text", "cancel", "mark fresh text", "cancel", "end"])
        let unsafe = await preview.hasUnsafeTarget()
        XCTAssertTrue(unsafe, "a successful retry does not resolve the lost mark reply")
    }

    func testDiscardWhileFreshMarkReplyIsPendingAfterEmptyClearCancelsTheFreshComposition() async {
        let first = expectation(description: "first mark acknowledged")
        let cleared = expectation(description: "empty update acknowledged")
        let throttle = PreviewGate(pauses: [first, cleared])
        let sent = expectation(description: "fresh mark awaiting its reply")
        let commandGate = PreviewGate(pauses: [sent])
        let stopped = expectation(description: "discard started")
        let transport = EmptyPreviewTransport(heldLine: "mark fresh text", commandGate: commandGate)
        let preview = makePreview(transport, throttle: throttle, onMarkingActivityChange: {
            if !$0 { stopped.fulfill() }
        })
        await preview.begin()
        await preview.mark("old text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [cleared], timeout: 1)
        await preview.mark("fresh text")
        await throttle.open()
        await fulfillment(of: [sent], timeout: 1)
        let discard = Task { await preview.discard() }
        await fulfillment(of: [stopped], timeout: 1)
        await commandGate.open()
        await discard.value

        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark old text", "cancel", "mark fresh text", "cancel", "end"])
        let report = await preview.report()
        XCTAssertTrue(report.cancelAcknowledged)
    }

    private func makePreview(
        _ transport: EmptyPreviewTransport,
        throttle: PreviewGate,
        onMarkingActivityChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onFirstMarkRendered: @escaping @Sendable () -> Void = {}
    ) -> InlinePreviewSession {
        InlinePreviewSession(
            transport: transport, bundleIdentifier: "com.test.app", sleep: { _ in await throttle.wait() },
            onMarkingActivityChange: onMarkingActivityChange, onFirstMarkRendered: onFirstMarkRendered
        )
    }

    private func discardDuringClear(
        firstCancel: Result<String, InlinePreviewTransportError>, expectedUnsafe: Bool
    ) async {
        let first = expectation(description: "first mark acknowledged")
        let throttle = PreviewGate(pauses: [first])
        let sent = expectation(description: "clear awaiting its reply")
        let commandGate = PreviewGate(pauses: [sent])
        let stopped = expectation(description: "discard started")
        let transport = EmptyPreviewTransport(
            firstCancel: firstCancel, heldLine: "cancel", commandGate: commandGate
        )
        let preview = makePreview(transport, throttle: throttle, onMarkingActivityChange: {
            if !$0 { stopped.fulfill() }
        })
        await preview.begin()
        await preview.mark("visible text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [sent], timeout: 1)
        let discard = Task { await preview.discard() }
        await fulfillment(of: [stopped], timeout: 1)
        let pendingLines = await transport.lines
        XCTAssertEqual(pendingLines, [Self.begin, "mark visible text", "cancel"])
        await commandGate.open()
        await discard.value

        let lines = await transport.lines
        let cancels = expectedUnsafe ? ["cancel", "cancel"] : ["cancel"]
        XCTAssertEqual(lines, [Self.begin, "mark visible text"] + cancels + ["end"])
        let unsafe = await preview.hasUnsafeTarget()
        XCTAssertEqual(unsafe, expectedUnsafe)
    }

    @MainActor
    private func refusesFinalDeliveryAfterEmptyClear(_ firstCancel: Result<String, InlinePreviewTransportError>) async {
        let first = expectation(description: "first mark acknowledged")
        let throttle = PreviewGate(pauses: [first])
        let degraded = expectation(description: "empty clear failed")
        let transport = EmptyPreviewTransport(firstCancel: firstCancel)
        let preview = makePreview(transport, throttle: throttle, onMarkingActivityChange: {
            if !$0 { degraded.fulfill() }
        })
        let backend = RecordingInsertionBackend()
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver()
        )
        await preview.begin()
        await preview.mark("visible text")
        await fulfillment(of: [first], timeout: 1)
        await preview.mark("")
        await throttle.open()
        await fulfillment(of: [degraded], timeout: 1)
        await preview.discard()

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: "Final text.", preview: preview, insertion: insertion, settle: {}
        )
        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertEqual(backend.inserted, [])
        XCTAssertEqual(insertion.insertFinalResult("Final text."), .backendRefused)
        let lines = await transport.lines
        XCTAssertEqual(lines, [Self.begin, "mark visible text", "cancel", "cancel", "end"])
    }
}

/// Controls command replies and throttle intervals without timed sleeps.
private actor PreviewGate {
    private let pauses: [XCTestExpectation]
    private var arrivals = 0
    private var credits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(pauses: [XCTestExpectation]) { self.pauses = pauses }

    func wait() async {
        let arrival = arrivals
        arrivals += 1
        if pauses.indices.contains(arrival) { pauses[arrival].fulfill() }
        if credits > 0 {
            credits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        if waiters.isEmpty {
            credits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor EmptyPreviewTransport: InlinePreviewTransport {
    private let firstCancel: Result<String, InlinePreviewTransportError>
    private let heldLine: String?
    private let commandGate: PreviewGate?
    private let failingMark: String?
    private var held = false
    private var cancelCount = 0
    private(set) var lines: [String] = []

    init(
        firstCancel: Result<String, InlinePreviewTransportError> = .success("ok cancelled"),
        heldLine: String? = nil,
        commandGate: PreviewGate? = nil,
        failingMark: String? = nil
    ) {
        self.firstCancel = firstCancel
        self.heldLine = heldLine
        self.commandGate = commandGate
        self.failingMark = failingMark
    }

    func open() async throws {}

    func send(_ line: String) async throws -> String {
        lines.append(line)
        if line == heldLine, !held {
            held = true
            await commandGate?.wait()
        }
        if line == failingMark { throw InlinePreviewTransportError.replyTimedOut }
        if line == "cancel" {
            cancelCount += 1
            if cancelCount == 1 { return try firstCancel.get() }
        }
        return "ok"
    }

    func close() async {}
}

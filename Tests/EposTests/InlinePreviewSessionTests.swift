import XCTest
@testable import Epos

/// The inline-preview spike drives an out-of-process input method, so the
/// contracts that matter are ordering and containment: preview text is coalesced,
/// the composition is always discarded before the authoritative write, and every
/// failure mode ends as HUD-only silence rather than a stalled dictation. The real
/// socket is never touched here; `FakeInlinePreviewTransport` is the seam.
final class InlinePreviewSessionTests: XCTestCase {
    private static let target = "com.test.app"
    private static let begin = "begin com.test.app"

    // MARK: - Doubles

    private actor FakeInlinePreviewTransport: InlinePreviewTransport {
        enum Failure: Error { case denied }

        private let openThrows: Bool
        private let beginReply: String
        private let beginError: InlinePreviewTransportError?
        private let markThrows: Bool
        private let markReply: String
        private let markError: InlinePreviewTransportError?
        private let markReplyAfterFirst: String?
        private let cancelReply: String
        private let cancelError: InlinePreviewTransportError?
        /// Marks beyond this count throw, for degradation mid- or post-recording.
        private let failMarksAfter: Int?
        private let commitReply: String
        private let commitError: InlinePreviewTransportError?

        private(set) var lines: [String] = []
        private(set) var openCount = 0
        private(set) var closeCount = 0
        private(set) var replyTimeouts: [TimeInterval] = []
        private var marksSeen = 0

        init(
            openThrows: Bool = false,
            beginReply: String = "ok locked",
            beginError: InlinePreviewTransportError? = nil,
            markThrows: Bool = false,
            markReply: String = "ok marked",
            markError: InlinePreviewTransportError? = nil,
            markReplyAfterFirst: String? = nil,
            cancelReply: String = "ok",
            cancelError: InlinePreviewTransportError? = nil,
            failMarksAfter: Int? = nil,
            commitReply: String = "ok committed 1",
            commitError: InlinePreviewTransportError? = nil
        ) {
            self.openThrows = openThrows
            self.beginReply = beginReply
            self.beginError = beginError
            self.markThrows = markThrows
            self.markReply = markReply
            self.markError = markError
            self.markReplyAfterFirst = markReplyAfterFirst
            self.cancelReply = cancelReply
            self.cancelError = cancelError
            self.failMarksAfter = failMarksAfter
            self.commitReply = commitReply
            self.commitError = commitError
        }

        func open() async throws {
            openCount += 1
            if openThrows { throw Failure.denied }
        }

        func send(_ line: String) async throws -> String {
            lines.append(line)
            if line.hasPrefix("begin") {
                if let beginError { throw beginError }
                return beginReply
            }
            if line == "cancel" {
                if let cancelError { throw cancelError }
                return cancelReply
            }
            if line.hasPrefix("mark") {
                marksSeen += 1
                if let markError { throw markError }
                if markThrows { throw Failure.denied }
                if let failMarksAfter, marksSeen > failMarksAfter { throw Failure.denied }
                if marksSeen > 1, let markReplyAfterFirst { return markReplyAfterFirst }
                return markReply
            }
            if line.hasPrefix("commit") {
                if let commitError { throw commitError }
                return commitReply
            }
            return "ok"
        }

        func send(_ line: String, replyTimeout: TimeInterval) async throws -> String {
            replyTimeouts.append(replyTimeout)
            return try await send(line)
        }

        func close() async {
            closeCount += 1
        }
    }

    /// Thread-safe recorder for the session's marking-activity callback.
    private final class MarkingActivityRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        func record(_ value: Bool) {
            lock.withLock { values.append(value) }
        }

        var snapshot: [Bool] { lock.withLock { values } }
    }

    /// Thread-safe counter for the session's one-shot first-mark callback.
    private final class FirstMarkRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.withLock { count += 1 }
        }

        var snapshot: Int { lock.withLock { count } }
    }

    private final class SilentInsertionSession: TextInsertionSession {
        func insert(_ text: String) -> Bool { true }
        func finish() {}
        func cancel() {}
    }

    private final class SilentInsertionBackend: TextInsertionBackend {
        func startInsertionSession() -> any TextInsertionSession { SilentInsertionSession() }
    }

    /// Records keystroke writes, so "zero keystrokes on the IME path" is provable.
    private final class RecordingInsertionBackend: TextInsertionBackend {
        private(set) var inserted: [String] = []

        func startInsertionSession() -> any TextInsertionSession { Session(backend: self) }

        private final class Session: TextInsertionSession {
            private let backend: RecordingInsertionBackend

            init(backend: RecordingInsertionBackend) { self.backend = backend }

            func insert(_ text: String) -> Bool {
                backend.inserted.append(text)
                return true
            }

            func finish() {}
            func cancel() {}
        }
    }

    /// Opaque but stable fn-press target: the guard's focus/frame checks pass and
    /// the value guard is inert, as on Electron targets.
    private final class StableOpaqueObserver: InsertionTargetObserver {
        func captureBaseline() {}
        func hasCapturedTarget() -> Bool { true }
        func focusChangedSinceStart() -> Bool { false }
        func observedValue() -> String? { nil }
        func observedSelectedRange() -> InsertionTargetTextRange? { nil }
        func requiresTextContextValidation() -> Bool { false }
        func baselineInsertionContext() -> InsertionTargetContext? { nil }
        func targetApplicationBundleIdentifier() -> String? { InlinePreviewSessionTests.target }
        func targetWindowTitle() -> String? { nil }
    }

    /// Stand-in for the throttle interval, so a burst is coalesced deterministically
    /// instead of against wall-clock timing.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var credits = 0

        func wait() async {
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

    private func makeSession(
        transport: FakeInlinePreviewTransport,
        gate: Gate,
        onMarkingActivityChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onFirstMarkRendered: @escaping @Sendable () -> Void = {}
    ) -> InlinePreviewSession {
        InlinePreviewSession(
            transport: transport,
            bundleIdentifier: Self.target,
            throttle: .milliseconds(100),
            sleep: { _ in await gate.wait() },
            onMarkingActivityChange: onMarkingActivityChange,
            onFirstMarkRendered: onFirstMarkRendered
        )
    }

    private static func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "condition not met in time", file: file, line: line)
    }

    private static func waitForLines(
        _ expected: [String],
        from transport: FakeInlinePreviewTransport,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var observed: [String] = []
        while Date() < deadline {
            observed = await transport.lines
            if observed == expected { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(observed, expected, file: file, line: line)
    }

    // MARK: - Throttling

    func testBurstOfPartialsCollapsesToTheNewestTextPerInterval() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("one")
        await Self.waitForLines([Self.begin, "mark one"], from: transport)

        // Both arrive inside the throttle window; only the newest may be sent.
        await session.mark("one two")
        await session.mark("one two three")
        await gate.open()

        await Self.waitForLines([Self.begin, "mark one", "mark one two three"], from: transport)
        let report = await session.report()
        XCTAssertEqual(report.marksSent, 2)
        XCTAssertNil(report.failure)
        await gate.open()
    }

    func testRepeatedIdenticalDisplayTextIsNotResent() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("same")
        await Self.waitForLines([Self.begin, "mark same"], from: transport)

        // A committed segment plus a cleared partial reproduces the previous
        // display text; re-marking it would churn the composition for nothing.
        await session.mark("same")
        await gate.open()
        await session.discard()

        await Self.waitForLines([Self.begin, "mark same", "cancel", "end"], from: transport)
    }

    // MARK: - First rendered mark (pill hide signal)

    func testFirstMarkRenderedFiresExactlyOnceAcrossManyMarks() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let recorder = FirstMarkRecorder()
        let session = makeSession(transport: transport, gate: gate, onFirstMarkRendered: recorder.record)

        await session.begin()
        await session.mark("one")
        await Self.waitForLines([Self.begin, "mark one"], from: transport)
        XCTAssertEqual(recorder.snapshot, 1)

        await session.mark("one two")
        await gate.open()
        await Self.waitForLines([Self.begin, "mark one", "mark one two"], from: transport)
        XCTAssertEqual(recorder.snapshot, 1)
        await gate.open()
    }

    func testFirstMarkRenderedNeverFiresWhenTheMarkFails() async {
        let transport = FakeInlinePreviewTransport(markThrows: true)
        let gate = Gate()
        let recorder = FirstMarkRecorder()
        let session = makeSession(transport: transport, gate: gate, onFirstMarkRendered: recorder.record)

        await session.begin()
        await session.mark("one")
        await Self.waitUntil { await session.report().failure == "markFailed" }

        // The probe never acknowledged rendering anything, so the pill must
        // never have been told to hide.
        XCTAssertEqual(recorder.snapshot, 0)
    }

    // MARK: - Discard ordering

    func testDiscardCancelsAndEndsAfterTheLastMarkAndIgnoresLaterMarks() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello there")
        await Self.waitForLines([Self.begin, "mark hello there"], from: transport)

        await session.discard()
        // Releasing the throttle afterwards must not resurrect the composition.
        await gate.open()
        await session.mark("too late")

        await Self.waitForLines([Self.begin, "mark hello there", "cancel", "end"], from: transport)
        let report = await session.report()
        XCTAssertTrue(report.began)
        XCTAssertEqual(report.marksSent, 1)
        XCTAssertTrue(report.cancelAcknowledged)
        let closes = await transport.closeCount
        XCTAssertEqual(closes, 1)

        await session.discard()
        await Self.waitForLines([Self.begin, "mark hello there", "cancel", "end"], from: transport)
        let closesAfterSecondDiscard = await transport.closeCount
        XCTAssertEqual(closesAfterSecondDiscard, 1)
    }

    func testMarkWriteFailureStillCancelsBecauseTheCompositionMayBeOnScreen() async {
        let transport = FakeInlinePreviewTransport(markThrows: true)
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello")
        await Self.waitForLines([Self.begin, "mark hello"], from: transport)

        await session.discard()

        await Self.waitForLines([Self.begin, "mark hello", "cancel", "end"], from: transport)
        let report = await session.report()
        XCTAssertEqual(report.marksSent, 0)
        XCTAssertEqual(report.failure, "markFailed")
        // The mark reached the wire, so the composition may be drawn even though
        // nothing was acked. The report has to say so: the coordinator keys the
        // pre-keystroke settle on this, not on the acked count.
        XCTAssertTrue(report.didAttemptMark)
    }

    // MARK: - Silent degradation

    func testProbeAbsentDegradesToHudOnlyWithoutSendingAnything() async {
        let transport = FakeInlinePreviewTransport(openThrows: true)
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello")
        await session.discard()

        let sent = await transport.lines
        XCTAssertEqual(sent, [])
        let report = await session.report()
        XCTAssertFalse(report.began)
        XCTAssertEqual(report.failure, "connectFailed")
        XCTAssertFalse(report.cancelAcknowledged)
    }

    func testRefusedFocusLockMarksNothingAndNeedsNoCancel() async {
        let transport = FakeInlinePreviewTransport(beginReply: "err no client session for com.test.app")
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello")
        await session.discard()

        let sent = await transport.lines
        XCTAssertEqual(sent, [Self.begin])
        let report = await session.report()
        XCTAssertFalse(report.began)
        XCTAssertEqual(report.marksSent, 0)
        XCTAssertEqual(report.failure, "beginRefused")
    }

    func testNewlinesNeverSplitTheProbeLineProtocol() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("first\nsecond")

        await Self.waitForLines([Self.begin, "mark first second"], from: transport)
        await gate.open()
    }

    // MARK: - Marking activity (HUD suppression signal)

    func testMarkingObserverTracksBeginAckAndMidRecordingDegradation() async {
        let transport = FakeInlinePreviewTransport(markThrows: true)
        let gate = Gate()
        let recorder = MarkingActivityRecorder()
        let session = makeSession(transport: transport, gate: gate, onMarkingActivityChange: recorder.record)

        await session.begin()
        XCTAssertEqual(recorder.snapshot, [true])

        // The mark send fails mid-recording; the HUD line must come back.
        await session.mark("hello")
        await Self.waitUntil { recorder.snapshot == [true, false] }
        let report = await session.report()
        XCTAssertEqual(report.failure, "markFailed")
    }

    func testBeginRefusalNeverActivatesMarkingObserver() async {
        let transport = FakeInlinePreviewTransport(beginReply: "err no client session")
        let gate = Gate()
        let recorder = MarkingActivityRecorder()
        let session = makeSession(transport: transport, gate: gate, onMarkingActivityChange: recorder.record)

        await session.begin()
        await session.discard()

        XCTAssertEqual(recorder.snapshot, [])
    }

    // MARK: - Final IME commit

    private func makeMarkedSession(
        transport: FakeInlinePreviewTransport,
        gate: Gate
    ) async -> InlinePreviewSession {
        let session = makeSession(transport: transport, gate: gate)
        await session.begin()
        await session.mark("hello there")
        await Self.waitForLines([Self.begin, "mark hello there"], from: transport)
        // Release the throttle so the drain winds down before the commit handshake.
        await gate.open()
        await Self.waitUntil { await session.report().marksSent == 1 }
        return session
    }

    func testFinalCommitSendsCancelThenCommitAndDiscardAddsNoSecondCancel() async {
        let transport = FakeInlinePreviewTransport(commitReply: "ok committed 12")
        let gate = Gate()
        let session = await makeMarkedSession(transport: transport, gate: gate)

        let eligible = await session.isEligibleForFinalCommit()
        XCTAssertTrue(eligible)
        let cancelled = await session.cancelCompositionForFinalCommit()
        XCTAssertTrue(cancelled)
        let outcome = await session.commitFinalTranscript("Hello there.")
        XCTAssertEqual(outcome, .committed)
        await session.discard()

        await Self.waitForLines(
            [Self.begin, "mark hello there", "cancel", "commit Hello there.", "end"],
            from: transport
        )
        let report = await session.report()
        XCTAssertTrue(report.committed)
        XCTAssertTrue(report.cancelAcknowledged)
        XCTAssertNil(report.failure)
        let timeouts = await transport.replyTimeouts
        XCTAssertEqual(timeouts, [InlinePreviewSession.commitAckTimeout])
    }

    func testProbeRefusedCommitIsSafeAndDiscardOnlyReleasesTheLock() async {
        let transport = FakeInlinePreviewTransport(commitReply: "err locked session gone")
        let gate = Gate()
        let session = await makeMarkedSession(transport: transport, gate: gate)

        let cancelled = await session.cancelCompositionForFinalCommit()
        XCTAssertTrue(cancelled)
        let outcome = await session.commitFinalTranscript("Hello there.")
        XCTAssertEqual(outcome, .refused)
        await session.discard()

        // The composition was already cancelled with an ack, so the discard must
        // not send a second cancel; it only releases the probe's focus lock.
        await Self.waitForLines(
            [Self.begin, "mark hello there", "cancel", "commit Hello there.", "end"],
            from: transport
        )
        let report = await session.report()
        XCTAssertFalse(report.committed)
        XCTAssertEqual(report.failure, "commitRefused")
    }

    func testUnacknowledgedCommitIsAmbiguousStickyAndNeverRetried() async {
        let transport = FakeInlinePreviewTransport(commitError: .replyTimedOut)
        let gate = Gate()
        let session = await makeMarkedSession(transport: transport, gate: gate)

        let cancelled = await session.cancelCompositionForFinalCommit()
        XCTAssertTrue(cancelled)
        let outcome = await session.commitFinalTranscript("Hello there.")
        XCTAssertEqual(outcome, .ambiguous)

        // Ambiguity is terminal: a second attempt must not produce a second commit.
        let retry = await session.commitFinalTranscript("Hello there.")
        XCTAssertEqual(retry, .unavailable)
        await session.discard()

        await Self.waitForLines(
            [Self.begin, "mark hello there", "cancel", "commit Hello there.", "end"],
            from: transport
        )
        let report = await session.report()
        XCTAssertFalse(report.committed)
        XCTAssertEqual(report.failure, "commitAckTimeout")
    }

    func testProbeHangingUpAfterAFullCommitSendIsAmbiguousNotRefused() async {
        let transport = FakeInlinePreviewTransport(commitError: .replyPeerClosed)
        let gate = Gate()
        let session = await makeMarkedSession(transport: transport, gate: gate)

        let cancelled = await session.cancelCompositionForFinalCommit()
        XCTAssertTrue(cancelled)
        let outcome = await session.commitFinalTranscript("Hello there.")

        // The commit was fully written before the probe died, so it may have
        // executed: same routing as a missing ack, different recorded reason.
        XCTAssertEqual(outcome, .ambiguous)
        let report = await session.report()
        XCTAssertEqual(report.failure, "commitPeerClosed")
    }

    func testSendSideCommitFailureIsRefusedBecauseTheLineNeverArrived() async {
        let transport = FakeInlinePreviewTransport(commitError: .timedOut)
        let gate = Gate()
        let session = await makeMarkedSession(transport: transport, gate: gate)

        let cancelled = await session.cancelCompositionForFinalCommit()
        XCTAssertTrue(cancelled)
        let outcome = await session.commitFinalTranscript("Hello there.")

        XCTAssertEqual(outcome, .refused)
        let report = await session.report()
        XCTAssertEqual(report.failure, "commitSendFailed")
    }

    func testCommitPathIsUnavailableWithoutARenderedMark() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)
        await session.begin()

        let eligible = await session.isEligibleForFinalCommit()
        XCTAssertFalse(eligible)
        let cancelled = await session.cancelCompositionForFinalCommit()
        XCTAssertFalse(cancelled)
        let outcome = await session.commitFinalTranscript("Hello there.")
        XCTAssertEqual(outcome, .unavailable)
        await Self.waitForLines([Self.begin], from: transport)
    }

    func testCommittableTextRejectsProtocolBreakingTranscripts() {
        XCTAssertTrue(InlinePreviewSession.isCommittableText("Hello there."))
        XCTAssertFalse(InlinePreviewSession.isCommittableText(""))
        XCTAssertFalse(InlinePreviewSession.isCommittableText("line one\nline two"))
        XCTAssertFalse(InlinePreviewSession.isCommittableText("line one\rline two"))
    }

    // MARK: - Launch gate

    @MainActor
    func testCoordinatorBuildsNoPreviewWhenDisabledOrTargetIsUnidentifiable() {
        let disabled = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: false,
            autoStart: false
        )
        XCTAssertNil(disabled.makeInlinePreviewSession(bundleIdentifier: Self.target))

        let enabled = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let unknownTarget: String? = nil
        XCTAssertNil(enabled.makeInlinePreviewSession(bundleIdentifier: unknownTarget))
        XCTAssertNotNil(enabled.makeInlinePreviewSession(bundleIdentifier: Self.target))
    }

    // MARK: - HUD suppression

    @MainActor
    private func waitForMirroring(
        _ expected: Bool,
        on coordinator: AppCoordinator,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if coordinator.inlinePreviewMirroring == expected { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(coordinator.inlinePreviewMirroring, expected, file: file, line: line)
    }

    @MainActor
    func testHudTranscriptLineSuppressedWhileMirroringAndRestoredOnDegradation() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport(markThrows: true)
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }

        coordinator.handlePartialTranscript("hello world")
        XCTAssertEqual(coordinator.hudTranscriptPreview, "hello world")

        await session.begin()
        await waitForMirroring(true, on: coordinator)
        XCTAssertEqual(coordinator.hudTranscriptPreview, "")

        // Mid-recording degradation must restore the HUD's transcript line.
        await session.mark("hello world")
        await waitForMirroring(false, on: coordinator)
        XCTAssertEqual(coordinator.hudTranscriptPreview, "hello world")
    }

    @MainActor
    func testHudTranscriptLineStaysWhenBeginIsRefused() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport(beginReply: "err no client session")
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }

        coordinator.handlePartialTranscript("hello")
        await session.begin()
        // Give any stray activity hop a chance to land before asserting.
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertFalse(coordinator.inlinePreviewMirroring)
        XCTAssertEqual(coordinator.hudTranscriptPreview, "hello")
    }

    // MARK: - Edge glow lifetime

    /// The glow frames the WHOLE held dictation: on through streaming (unlike
    /// the pill it occludes nothing), out at release, and it retires the
    /// moment the preview channel it advertises degrades.
    @MainActor
    func testEdgeGlowPersistsThroughStreamingEndsAtReleaseAndOnDegrade() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport(failMarksAfter: 1)
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: nil)
        coordinator.state = .recording

        await session.begin()
        await waitForMirroring(true, on: coordinator)
        // The glow is coordinator-driven at fn press; here (staged, no
        // startRecording) mirroring is live and the glow can be lit directly
        // through the presentation path the coordinator uses.
        coordinator.presentIndicatorForRecordingStart()
        XCTAssertTrue(coordinator.edgeGlowVisible)

        // Streaming text does NOT hide the glow.
        coordinator.handlePartialTranscript("hello")
        await Self.waitUntil { await session.report().marksSent == 1 }
        XCTAssertTrue(coordinator.edgeGlowVisible)

        // A degrade retires the glow with the channel it advertises.
        coordinator.handlePartialTranscript("hello again")
        await Self.waitUntil { await session.report().failure == "markFailed" }
        await waitForMirroring(false, on: coordinator)
        XCTAssertFalse(coordinator.edgeGlowVisible)
    }

    /// The fallback deadline vs a slow begin ack: past the deadline the glow
    /// retires to the pill, and when the late ack finally activates mirroring
    /// the glow must reclaim the recording — otherwise the first mark hides
    /// the pill and the user is left with no mic-hot cue at all (review
    /// finding on the persistent-glow change).
    @MainActor
    func testSlowBeginAckRetiresGlowThenGlowReclaimsOnActivation() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport()
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: nil)
        coordinator.state = .recording

        // fn press: the glow lights before the channel has confirmed.
        coordinator.presentIndicatorForRecordingStart()
        XCTAssertTrue(coordinator.edgeGlowVisible)

        // No begin ack within the deadline: the glow retires (pill takes over).
        await Self.waitUntil { await MainActor.run { !coordinator.edgeGlowVisible } }

        // The late ack activates mirroring: the glow reclaims the recording.
        await session.begin()
        await waitForMirroring(true, on: coordinator)
        await Self.waitUntil { await MainActor.run { coordinator.edgeGlowVisible } }
    }

    /// With the glow disabled in settings, the pill is the indicator and the
    /// glow never lights — including at mirroring activation, which must NOT
    /// hide the pill in that mode.
    @MainActor
    func testDisabledGlowKeepsThePillAndNeverLights() async {
        var settings = Settings()
        settings.edgeGlow.enabled = false
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: settings,
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport()
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: nil)
        coordinator.state = .recording

        coordinator.presentIndicatorForRecordingStart()
        XCTAssertFalse(coordinator.edgeGlowVisible)

        await session.begin()
        await waitForMirroring(true, on: coordinator)
        // Give the activation callback's task a beat to land.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(coordinator.edgeGlowVisible)
    }

    /// Toggling the glow off mid-recording must hand off to the pill (a hot
    /// mic with no cue at all is the failure the glow exists to prevent), and
    /// re-enabling must relight it (codex review, blocking).
    @MainActor
    func testTogglingGlowMidRecordingHandsOffToPillAndBack() async throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            settingsDefaults: defaults,
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport()
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: nil)
        coordinator.state = .recording

        coordinator.presentIndicatorForRecordingStart()
        await session.begin()
        await waitForMirroring(true, on: coordinator)
        XCTAssertTrue(coordinator.edgeGlowVisible)

        var style = coordinator.edgeGlowStyle
        style.enabled = false
        coordinator.setEdgeGlowStyle(style)
        XCTAssertFalse(coordinator.edgeGlowVisible)

        style.enabled = true
        coordinator.setEdgeGlowStyle(style)
        XCTAssertTrue(coordinator.edgeGlowVisible)
    }

    /// Release ends the glow even when the channel stayed healthy throughout.
    @MainActor
    func testEdgeGlowEndsAtRelease() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport()
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: nil)
        coordinator.state = .recording

        await session.begin()
        await waitForMirroring(true, on: coordinator)
        coordinator.presentIndicatorForRecordingStart()
        XCTAssertTrue(coordinator.edgeGlowVisible)

        coordinator.finishRecording()
        XCTAssertFalse(coordinator.edgeGlowVisible)
    }

    // MARK: - Release ordering (discard vs final IME commit)

    @MainActor
    func testUnsafeBeginRefusalBlocksOrdinaryKeystrokeDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(beginReply: "err unsafe composition owner is gone"),
            transcript: "Hello there.",
            expectedFailure: "unsafeTarget"
        )
    }

    @MainActor
    func testUnsafeMarkRefusalBlocksOrdinaryKeystrokeDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(markReply: "err unsafe composition"),
            transcript: "Hello there.",
            expectedFailure: "unsafeTarget"
        )
    }

    @MainActor
    func testUnsafeDiscardBlocksMultilineKeystrokeDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(cancelReply: "err unsafe composition"),
            transcript: "Hello\nthere."
        )
    }

    @MainActor
    func testUnknownBeginRepliesBlockFinalDelivery() async {
        for error in [InlinePreviewTransportError.replyTimedOut, .replyPeerClosed, .replyMalformed] {
            await refusesUnsafeFinalTarget(
                transport: FakeInlinePreviewTransport(beginError: error),
                transcript: "Hello there.", expectedFailure: "connectFailed"
            )
        }
    }

    @MainActor
    func testUnknownMarkRepliesBlockFinalDelivery() async {
        for error in [InlinePreviewTransportError.replyTimedOut, .replyPeerClosed, .replyMalformed] {
            await refusesUnsafeFinalTarget(
                transport: FakeInlinePreviewTransport(markError: error),
                transcript: "Hello there.", expectedFailure: "markFailed"
            )
        }
    }

    @MainActor
    func testUnconfirmedDiscardBlocksMultilineDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(cancelReply: "err locked session gone"),
            transcript: "Hello\nthere."
        )
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(cancelError: .closed),
            transcript: "Hello\nthere."
        )
    }

    @MainActor
    func testGenericRefusalAfterAcceptedPreviewBlocksFinalDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(markReplyAfterFirst: "err preview requires an empty selection"),
            transcript: "Hello there.", laterMark: "hello there again"
        )
    }

    @MainActor
    func testFirstConclusiveMarkRefusalPreservesGuardedFinalDelivery() async {
        let transport = FakeInlinePreviewTransport(markReply: "err preview requires an empty selection")
        let backend = RecordingInsertionBackend()
        let coordinator = AppCoordinator(
            textInsertion: backend, settings: Settings(), inlinePreviewEnabled: true, autoStart: false
        )
        guard let preview = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target, transport: transport
        ) else { return XCTFail("expected a preview session") }
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver()
        )
        coordinator.stageFinalizationSessions(inlinePreview: preview, insertion: insertion)
        await preview.begin()
        await preview.mark("hello there")
        await Self.waitUntil { await preview.report().failure == "markRefused" }

        let route = await coordinator.commitFinalTranscript("Hello there.")
        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, ["Hello there."])
        let lines = await transport.lines
        XCTAssertFalse(lines.contains("cancel"), "no Epos mark exists to cancel")
    }

    @MainActor
    private func refusesUnsafeFinalTarget(
        transport: FakeInlinePreviewTransport,
        transcript: String,
        expectedFailure: String? = nil,
        laterMark: String? = nil
    ) async {
        let backend = RecordingInsertionBackend()
        let coordinator = AppCoordinator(
            textInsertion: backend,
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        guard let preview = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target, transport: transport
        ) else { return XCTFail("expected a preview session") }
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver()
        )
        coordinator.stageFinalizationSessions(inlinePreview: preview, insertion: insertion)
        await preview.begin()
        await preview.mark("hello there")
        if let expectedFailure {
            await Self.waitUntil { await preview.report().failure == expectedFailure }
        } else {
            await Self.waitUntil { await preview.report().marksSent == 1 }
        }
        if let laterMark {
            await preview.mark(laterMark)
            await Self.waitUntil { await preview.report().failure == "unsafeTarget" }
        }

        let route = await coordinator.commitFinalTranscript(transcript)
        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertEqual(backend.inserted, [])
        XCTAssertNil(insertion.insertedTranscript)
        XCTAssertEqual(insertion.insertFinalResult(transcript), .backendRefused)
        XCTAssertEqual(backend.inserted, [])
    }

    /// Reviewer scenario (a): a preview actively marking at fn release must NOT
    /// be discarded there — the router must still find it eligible and finish
    /// with an acked IME commit and zero keystrokes.
    @MainActor
    func testActivelyMarkingPreviewSkipsReleaseDiscardAndCommitsViaIME() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport(commitReply: "ok committed 12")
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        let backend = RecordingInsertionBackend()
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: StableOpaqueObserver()
        )
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: insertion)

        await session.begin()
        await session.mark("hello there")
        await Self.waitUntil { await session.report().marksSent == 1 }
        await waitForMirroring(true, on: coordinator)

        coordinator.state = .recording
        coordinator.finishRecording()
        // The discard must not start at release: no cancel/end on the wire.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let linesAtRelease = await transport.lines
        XCTAssertFalse(linesAtRelease.contains("cancel"))
        XCTAssertFalse(linesAtRelease.contains("end"))
        let eligible = await session.isEligibleForFinalCommit()
        XCTAssertTrue(eligible)

        let route = await coordinator.commitFinalTranscript("Hello there.")

        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        XCTAssertEqual(backend.inserted, [])
        XCTAssertEqual(insertion.insertedTranscript, "Hello there.")
        await Self.waitForLines(
            [Self.begin, "mark hello there", "cancel", "commit Hello there.", "end"],
            from: transport
        )
    }

    /// Reviewer scenario (b): a preview already degraded at fn release is
    /// discarded there exactly as before the IME-commit path existed.
    @MainActor
    func testDegradedPreviewIsDiscardedAtReleaseExactlyAsBefore() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport(markThrows: true)
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: nil)

        await session.begin()
        await session.mark("hello")
        await Self.waitUntil { await session.report().failure == "markFailed" }
        await waitForMirroring(false, on: coordinator)

        coordinator.state = .recording
        coordinator.finishRecording()

        await Self.waitForLines([Self.begin, "mark hello", "cancel", "end"], from: transport)
    }

    /// Reviewer scenario (c): degradation between fn release and the router must
    /// land on the keystroke path, with the discard completed before the write.
    @MainActor
    func testDegradationBetweenReleaseAndRouterFallsBackToKeystrokesAfterDiscard() async {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let transport = FakeInlinePreviewTransport(failMarksAfter: 1)
        guard let session = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target,
            transport: transport
        ) else { return XCTFail("expected a preview session") }
        let backend = RecordingInsertionBackend()
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: StableOpaqueObserver()
        )
        coordinator.stageFinalizationSessions(inlinePreview: session, insertion: insertion)

        await session.begin()
        await session.mark("hello there")
        await Self.waitUntil { await session.report().marksSent == 1 }
        await waitForMirroring(true, on: coordinator)

        coordinator.state = .recording
        coordinator.finishRecording()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let linesAtRelease = await transport.lines
        XCTAssertFalse(linesAtRelease.contains("cancel"))

        // A late mark fails after release: the channel degrades before the router.
        await session.mark("hello there again")
        await Self.waitUntil { await session.report().failure == "markFailed" }

        let route = await coordinator.commitFinalTranscript("Hello there.")

        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, ["Hello there."])
        let lines = await transport.lines
        XCTAssertFalse(lines.contains { $0.hasPrefix("commit") })
        // The fallback discarded (cancel + end) before the keystroke write.
        XCTAssertTrue(lines.contains("cancel"))
        XCTAssertTrue(lines.contains("end"))
    }

    @MainActor
    func testHudTranscriptMatchesDisplayTextWheneverPreviewIsOff() {
        let coordinator = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: false,
            autoStart: false
        )

        coordinator.handlePartialTranscript("hello")

        XCTAssertFalse(coordinator.inlinePreviewMirroring)
        XCTAssertEqual(coordinator.hudTranscriptPreview, coordinator.displayText)
        XCTAssertEqual(coordinator.hudTranscriptPreview, "hello")
    }
}

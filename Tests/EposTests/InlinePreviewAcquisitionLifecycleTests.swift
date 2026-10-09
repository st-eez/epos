import AVFoundation
import XCTest
@testable import Epos

@MainActor
final class InlinePreviewAcquisitionLifecycleTests: XCTestCase {
    func testRecordingRefusesQueuedDraftAfterSameAppFieldMoveDuringActivation() async throws {
        try await checkCapturedTargetAcquisition(moveField: true)
    }

    func testRecordingStartsQueuedDraftOnlyAfterCapturedTargetValidation() async throws {
        try await checkCapturedTargetAcquisition(moveField: false)
    }

    private func checkCapturedTargetAcquisition(moveField: Bool) async throws {
        let waiting = expectation(description: "native activation awaiting acknowledgment")
        let recorder = AcquisitionEventRecorder()
        let transport = LifecycleAcquisitionTransport(recorder: recorder, waiting: waiting, pendingOnce: true)
        let restored = expectation(description: "borrowed keyboard source restored")
        let access = LifecycleKeyboardAccess(recorder: recorder, restored: restored)
        let target = AcquisitionTargetObserver()
        let backend = RecordingInsertionBackend()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EposAcquisitionTests-\(UUID())"))
        var settings = Settings(inlinePreview: true)
        settings.dictationShortcut = try XCTUnwrap(DictationShortcut(
            modifierFlags: DictationShortcut.functionFlag, keyCode: 0
        ))
        let recording = RecordingSession(
            recordingID: nil, audio: FakeMicrophoneCapture(), transcriber: FakeTranscriber(),
            textInsertion: backend, targetObserverFactory: { target }, settings: settings,
            canonicalizer: TranscriptCanonicalizer(rules: []), diagnostics: .shared,
            evidenceRecorder: CorrectionEvidenceRecorder(
                evidence: CorrectionEvidenceStore(defaults: defaults), captureDelays: [], currentRecordingID: { nil }
            ),
            isShortcutHeld: { false }, isMicrophoneAccessMissing: { false }, includeTranscriptText: false,
            previewKeyboardSourceFactory: { PreviewKeyboardSource(access: access) },
            previewTransportFactory: { transport }, onEvent: { _, _ in }
        )
        recording.start(format: try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)))
        await fulfillment(of: [waiting], timeout: 1)
        recording.handlePartialTranscript("queued draft")
        XCTAssertEqual(target.focusReads, 0, "pending activation cannot validate or drain the draft")
        if moveField { target.field = "B" }
        await transport.releaseBegin()

        if moveField {
            await fulfillment(of: [restored], timeout: 1)
            let lines = await transport.lines
            XCTAssertFalse(lines.contains { $0.hasPrefix("mark ") }, "draft must never reach field B")
            XCTAssertTrue(lines.contains("end"), "acknowledged acquisition must retire its pinned client")
        } else {
            await waitUntil { await transport.lines.contains("mark queued draft") }
            XCTAssertEqual(access.current, PreviewKeyboardSource.companionIdentifier)
            XCTAssertEqual(target.focusReads, 1, "the captured target must be checked before the first draft")
        }
        let acquiredLines = await transport.lines
        XCTAssertEqual(acquiredLines.first,
                       "begin com.test.host acquire-layout com.test.layout com.test.layout "
                           + "hold-key=0 hold-flags=\(settings.dictationShortcut.modifierFlags)")
        let task = recording.task
        recording.release()
        await task?.value
        if !moveField { await fulfillment(of: [restored], timeout: 1) }
        XCTAssertEqual(backend.inserted, [])
        let completedLines = await transport.lines
        XCTAssertEqual(completedLines.filter { $0.hasPrefix("commit ") }, moveField ? [] : ["commit queued draft"])
        XCTAssertEqual(access.current, "com.test.layout")
    }

    func testFailedAcquisitionClosesBeforeRestoringSourceDuringTheHold() async throws {
        for failure in ["open", "barrier", "activation", "reply"] {
            let recorder = AcquisitionEventRecorder()
            let restored = expectation(description: "source restored after \(failure) failure")
            let access = LifecycleKeyboardAccess(recorder: recorder, restored: restored)
            let transport = LifecycleAcquisitionTransport(
                recorder: recorder,
                openFails: failure == "open",
                beginReply: failure == "activation" ? "err input method activation pending" : "err native barrier unavailable",
                beginError: failure == "reply" ? .replyTimedOut : nil
            )
            let coordinator = makeCoordinator(access: access, transport: transport)
            coordinator.start(bundleIdentifier: "com.test.host", selectedRange: .init(location: 0, length: 0))
            coordinator.mirror("queued draft")

            await fulfillment(of: [restored], timeout: 1)

            XCTAssertEqual(access.current, "com.test.layout", "failure must not borrow the source for the rest of the hold")
            let events = recorder.entries
            XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "close")),
                              try XCTUnwrap(events.firstIndex(of: "source com.test.layout")))
            let lines = await transport.lines
            XCTAssertFalse(lines.contains { $0.hasPrefix("mark ") })
            await coordinator.finish()
            XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier, "com.test.layout"])
        }
    }

    func testLaterMarkFailureKeepsSourceUntilDraftCleanupCompletes() async throws {
        let recorder = AcquisitionEventRecorder()
        let restored = expectation(description: "source restored after draft cleanup")
        let access = LifecycleKeyboardAccess(recorder: recorder, restored: restored)
        let transport = LifecycleAcquisitionTransport(recorder: recorder, markError: .replyTimedOut)
        let coordinator = makeCoordinator(access: access, transport: transport)
        coordinator.start(
            bundleIdentifier: "com.test.host", selectedRange: .init(location: 0, length: 0), validateTarget: { true }
        )
        let preview = try XCTUnwrap(coordinator.session)
        await waitUntil { await preview.report().began }
        coordinator.mirror("draft with lost acknowledgment")
        await waitUntil { await preview.report().failure == "markFailed" }

        XCTAssertEqual(access.current, PreviewKeyboardSource.companionIdentifier)
        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier])
        await coordinator.finish()
        await fulfillment(of: [restored], timeout: 1)

        let events = recorder.entries
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "cancel")),
                          try XCTUnwrap(events.firstIndex(of: "source com.test.layout")))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "close")),
                          try XCTUnwrap(events.firstIndex(of: "source com.test.layout")))
    }

    func testStaleAcquisitionFailureCannotRestoreNewerRecordingSource() async throws {
        let recorder = AcquisitionEventRecorder()
        let restored = expectation(description: "newer source restored only at its teardown")
        let access = LifecycleKeyboardAccess(recorder: recorder, restored: restored)
        let currentTransport = LifecycleAcquisitionTransport(recorder: recorder)
        let coordinator = makeCoordinator(access: access, transport: currentTransport)
        let waiting = expectation(description: "old begin awaiting refusal")
        let oldTransport = LifecycleAcquisitionTransport(
            recorder: recorder, waiting: waiting, beginReply: "err old acquisition refused"
        )
        let old = try XCTUnwrap(coordinator.makeSession(bundleIdentifier: "com.test.host", transport: oldTransport))
        let beginning = Task { await old.begin() }
        await fulfillment(of: [waiting], timeout: 1)
        coordinator.start(
            bundleIdentifier: "com.test.host", selectedRange: .init(location: 0, length: 0), validateTarget: { true }
        )
        let current = try XCTUnwrap(coordinator.session)
        await waitUntil { await current.report().began }

        await oldTransport.releaseBegin()
        await beginning.value

        XCTAssertEqual(access.current, PreviewKeyboardSource.companionIdentifier)
        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier])
        await coordinator.finish()
        await fulfillment(of: [restored], timeout: 1)
    }

    private func makeCoordinator(
        access: LifecycleKeyboardAccess, transport: LifecycleAcquisitionTransport
    ) -> InlinePreviewCoordinator {
        InlinePreviewCoordinator(
            isEnabled: { true }, log: EposLogger(category: "inject"),
            keyboardSourceFactory: { PreviewKeyboardSource(access: access) }, transportFactory: { transport },
            onMarkingActivityChange: { _ in }, onFirstMarkRendered: {}
        )
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("acquisition lifecycle did not reach the expected state")
    }
}

private final class AcquisitionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var entries: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
}

@MainActor
private final class LifecycleKeyboardAccess: PreviewKeyboardSourceAccess {
    private let recorder: AcquisitionEventRecorder
    private let restored: XCTestExpectation
    private(set) var current = "com.test.layout"
    private(set) var selections: [String] = []

    init(recorder: AcquisitionEventRecorder, restored: XCTestExpectation) {
        self.recorder = recorder
        self.restored = restored
    }
    func currentIdentifier() -> String? { current }
    func currentIsLayout() -> Bool { true }
    func layoutIdentifier() -> String? { "com.test.layout" }
    func companionIsAvailable() -> Bool { true }
    func select(_ identifier: String) -> Bool {
        current = identifier
        selections.append(identifier)
        recorder.append("source \(identifier)")
        if identifier == "com.test.layout" { restored.fulfill() }
        return true
    }
}

private actor LifecycleAcquisitionTransport: InlinePreviewTransport {
    private let recorder: AcquisitionEventRecorder
    private let waiting: XCTestExpectation?
    private let pendingOnce: Bool
    private let openFails: Bool
    private let beginReply: String
    private let beginError: InlinePreviewTransportError?
    private let markError: InlinePreviewTransportError?
    private var beginCount = 0
    private var beginWaiter: CheckedContinuation<Void, Never>?
    private(set) var lines: [String] = []

    init(
        recorder: AcquisitionEventRecorder, waiting: XCTestExpectation? = nil,
        pendingOnce: Bool = false, openFails: Bool = false, beginReply: String = "ok locked",
        beginError: InlinePreviewTransportError? = nil, markError: InlinePreviewTransportError? = nil
    ) {
        self.recorder = recorder
        self.waiting = waiting
        self.pendingOnce = pendingOnce
        self.openFails = openFails
        self.beginReply = beginReply
        self.beginError = beginError
        self.markError = markError
    }
    func open() throws {
        if openFails { throw InlinePreviewTransportError.unavailable }
    }
    func send(_ line: String) async throws -> String {
        lines.append(line)
        recorder.append(line)
        if line.hasPrefix("begin ") {
            beginCount += 1
            if pendingOnce, beginCount == 1 { return "err input method activation pending" }
            if let waiting {
                await withCheckedContinuation {
                    beginWaiter = $0
                    waiting.fulfill()
                }
            }
            if let beginError { throw beginError }
            return beginReply
        }
        if line.hasPrefix("mark "), let markError { throw markError }
        return line.hasPrefix("commit ") ? "ok committed" : "ok"
    }
    func releaseBegin() {
        beginWaiter?.resume()
        beginWaiter = nil
    }
    func close() { recorder.append("close") }
}

private final class AcquisitionTargetObserver: InsertionTargetObserver {
    var field = "A"
    private var capturedField: String?
    private(set) var focusReads = 0

    func captureBaseline() { capturedField = field }
    func hasCapturedTarget() -> Bool { capturedField != nil }
    func focusChangedSinceStart() -> Bool {
        focusReads += 1
        return field != capturedField
    }
    func observedValue() -> String? { "" }
    func observedSelectedRange() -> InsertionTargetTextRange? { .init(location: 0, length: 0) }
    func requiresTextContextValidation() -> Bool { true }
    func baselineInsertionContext() -> InsertionTargetContext? { .init(prefix: "", suffix: "") }
    func targetApplicationBundleIdentifier() -> String? { "com.test.host" }
    func targetWindowTitle() -> String? { "Host" }
}

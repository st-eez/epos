import AVFoundation
import XCTest
@testable import Epos

@MainActor
final class CoordinatorAmbiguousDeliveryTests: XCTestCase {
    func testInsertedIMETextWithALostAcknowledgmentShowsANoticeWithoutRetrying() async {
        for error in [InlinePreviewTransportError.replyTimedOut, .replyPeerClosed, .replyMalformed] {
            await assertAmbiguousDelivery(error: error)
        }
    }

    private func assertAmbiguousDelivery(error: InlinePreviewTransportError) async {
        let expiry = ControlledNoticeExpiry()
        let transcriber = FakeTranscriber()
        let backend = RecordingInsertionBackend()
        let coordinator = AppCoordinator(
            audio: FakeMicrophoneCapture(),
            transcriber: transcriber,
            textInsertion: backend,
            insertionTargetObserverFactory: { UnidentifiedOpaqueObserver() },
            settings: Settings(),
            permissions: .stub(),
            isFnKeyHeld: { false },
            inlinePreviewEnabled: true,
            noticeExpiryScheduler: expiry.schedule,
            autoStart: false
        )
        coordinator.captureFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        coordinator.startRecording()
        let recording = coordinator.transcriptionTask
        await waitUntil { transcriber.didStart }

        let transport = InsertThenLoseReplyTransport(error: error)
        guard let preview = coordinator.makeInlinePreviewSession(
            bundleIdentifier: "com.test.app", transport: transport
        ) else { return XCTFail("expected a preview session") }
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver()
        )
        coordinator.stageFinalizationSessions(inlinePreview: preview, insertion: insertion)
        await preview.begin()
        await preview.mark("hello there")
        await waitUntil { await preview.report().marksSent == 1 }
        await waitUntil { coordinator.inlinePreviewMirroring }

        transcriber.emit(.final("Hello there."))
        coordinator.finishRecording()
        await recording?.value

        let inserted = await transport.inserted
        let commands = await transport.commands
        XCTAssertEqual(inserted, ["Hello there."], "the IME write actually landed before \(error)")
        XCTAssertEqual(commands.filter { $0.hasPrefix("commit ") }, ["commit Hello there."])
        XCTAssertEqual(backend.inserted, [], "the unacknowledged IME write must never be retried")
        XCTAssertEqual(insertion.insertFinalResult("Hello there."), .backendRefused)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.insertionUnavailable)
        XCTAssertEqual(coordinator.insertionNotice, "Check the field")
        XCTAssertTrue(coordinator.pillVisible, "recording teardown must preserve the delivery notice")
        XCTAssertEqual(expiry.durations, [.milliseconds(2_500)])

        expiry.expire(0)
        XCTAssertFalse(coordinator.insertionUnavailable)
        XCTAssertFalse(coordinator.pillVisible)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            await Task.yield()
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "recording did not reach the required state")
    }

    /// Models insertText succeeding before the acknowledgment disappears.
    private actor InsertThenLoseReplyTransport: InlinePreviewTransport {
        let error: InlinePreviewTransportError
        private(set) var inserted: [String] = []
        private(set) var commands: [String] = []

        init(error: InlinePreviewTransportError) { self.error = error }

        func open() async throws {}

        func send(_ line: String) async throws -> String {
            commands.append(line)
            if line.hasPrefix("commit ") {
                inserted.append(String(line.dropFirst("commit ".count)))
                throw error
            }
            return "ok"
        }

        func close() async {}
    }

    /// Keeps startRecording from opening a real companion socket before staging.
    private final class UnidentifiedOpaqueObserver: InsertionTargetObserver {
        func captureBaseline() {}
        func hasCapturedTarget() -> Bool { true }
        func focusChangedSinceStart() -> Bool { false }
        func observedValue() -> String? { nil }
        func observedSelectedRange() -> InsertionTargetTextRange? { nil }
        func requiresTextContextValidation() -> Bool { false }
        func baselineInsertionContext() -> InsertionTargetContext? { nil }
        func targetApplicationBundleIdentifier() -> String? { nil }
        func targetWindowTitle() -> String? { nil }
    }
}

import AVFoundation
import XCTest
@testable import Epos

/// The recording's audio front end: when the mic opens relative to the rest of the
/// fn-press work, and what happens when it refuses to open or dies mid-hold.
///
/// The latency this ordering exists to remove is only measurable at runtime (press
/// → capture-started, in the installed app's diagnostic log). What is pinned here
/// is the ordering itself and the two failure paths.
@MainActor
final class CoordinatorAudioLifecycleTests: XCTestCase {
    private struct CaptureUnavailable: Error {}

    private func makeCoordinator(
        audio: FakeMicrophoneCapture,
        events: RecordingStartEventLog? = nil
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            audio: audio,
            textInsertion: NoOpInsertionBackend(),
            insertionTargetObserverFactory: { LoggingInsertionTargetObserver(events: events) },
            settings: Settings(),
            permissions: .stub(),
            inlinePreviewEnabled: false,
            autoStart: false
        )
        coordinator.captureFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        return coordinator
    }

    /// The AX baseline capture is synchronous and can stall for hundreds of
    /// milliseconds; the analyzer start is an await. Both used to run before the
    /// mic opened, and everything said in that window was lost.
    func testMicrophoneOpensBeforeTheAccessibilityBaselineCapture() {
        let audio = FakeMicrophoneCapture()
        let events = RecordingStartEventLog()
        audio.events = events
        let coordinator = makeCoordinator(audio: audio, events: events)

        coordinator.startRecording()

        XCTAssertEqual(events.entries, ["mic-open", "ax-baseline"])
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(coordinator.state, .recording)
        coordinator.finishRecording()
    }

    /// The mic is open before the analyzer exists, so those buffers have to wait
    /// somewhere. The relay is unit-tested separately; here the contract is that
    /// the coordinator wired the tap up at press rather than at analyzer start.
    func testAudioCallbacksAreInstalledAtPress() {
        let audio = FakeMicrophoneCapture()
        let coordinator = makeCoordinator(audio: audio)

        coordinator.startRecording()

        XCTAssertNotNil(audio.onBuffer)
        XCTAssertNotNil(audio.onAmplitude)
        XCTAssertNotNil(audio.onCaptureFailure)
        coordinator.finishRecording()
    }

    /// A mic that will not open must take the announced recording back rather than
    /// leave the state machine in `.recording` with a dead pipeline.
    func testCaptureThatRefusesToOpenAbortsTheStartAndFlashesTheNotice() {
        let audio = FakeMicrophoneCapture()
        let events = RecordingStartEventLog()
        audio.events = events
        audio.startError = CaptureUnavailable()
        let coordinator = makeCoordinator(audio: audio, events: events)

        coordinator.startRecording()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertFalse(coordinator.edgeGlowVisible)
        // Nothing downstream of the mic was set up for a recording that never ran.
        XCTAssertEqual(events.entries, [])
        XCTAssertNil(audio.onBuffer)
    }

    /// An input-device change the engine cannot be restarted through: the mic stops
    /// producing buffers, so the recording ends where it ended instead of leaving
    /// the glow advertising a live mic for the rest of the hold.
    func testCaptureFailureMidRecordingEndsTheRecording() {
        let audio = FakeMicrophoneCapture()
        let coordinator = makeCoordinator(audio: audio)
        coordinator.startRecording()
        XCTAssertEqual(coordinator.state, .recording)

        audio.onCaptureFailure?(CaptureUnavailable())

        XCTAssertEqual(coordinator.state, .finalizing)
        XCTAssertTrue(coordinator.microphoneUnavailable)
        XCTAssertFalse(coordinator.edgeGlowVisible)
        XCTAssertGreaterThanOrEqual(audio.stopCount, 1)
    }
}

/// Records the one thing this test file cares about: when the fn-press AX baseline
/// was captured.
private final class LoggingInsertionTargetObserver: InsertionTargetObserver {
    private let events: RecordingStartEventLog?

    init(events: RecordingStartEventLog?) {
        self.events = events
    }

    func captureBaseline() { events?.append("ax-baseline") }
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { false }
    func observedValue() -> String? { nil }
    func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    func requiresTextContextValidation() -> Bool { false }
    func baselineInsertionContext() -> InsertionTargetContext? { nil }
    func targetApplicationBundleIdentifier() -> String? { nil }
    func targetWindowTitle() -> String? { nil }
}

private final class NoOpInsertionBackend: TextInsertionBackend {
    func startInsertionSession() -> any TextInsertionSession {
        NoOpInsertionSession()
    }
}

private final class NoOpInsertionSession: TextInsertionSession {
    func insert(_ text: String) -> Bool { true }
    func finish() {}
    func cancel() {}
}

import AVFoundation
import XCTest
@testable import Epos

/// The displayed partial and delivered final use the same frozen correction and
/// deterministic cleaning pipeline through a complete recording.
@MainActor
final class CoordinatorFinalCleaningTests: XCTestCase {
    private static let disfluentRaw = "the the uh build is broken"
    private static let cleaned = "the build is broken"

    func testFinalTranscriptMatchesLiveStreamCleaning() async throws {
        let transcriber = FakeTranscriber()
        transcriber.finalTranscriptOnFinish = Self.disfluentRaw
        let microphone = FakeMicrophoneCapture()
        let backend = RecordingTextInsertionBackend()
        let coordinator = AppCoordinator(
            audio: microphone,
            transcriber: transcriber,
            textInsertion: backend,
            insertionTargetObserverFactory: { StableOpaqueObserver() },
            settings: Settings(),
            permissions: .stub(),
            inlinePreviewEnabled: false,
            autoStart: false
        )
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        coordinator.captureFormat = format
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160

        coordinator.startRecording()
        coordinator.handlePartialTranscript(Self.disfluentRaw)
        let displayed = coordinator.displayText
        XCTAssertEqual(displayed, Self.cleaned)
        microphone.onBuffer?(buffer)
        coordinator.finishRecording()
        await coordinator.transcriptionTask?.value

        XCTAssertEqual(backend.insertedTexts, [displayed])
        XCTAssertEqual(coordinator.state, .idle)
    }
}

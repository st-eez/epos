import AVFoundation
import XCTest
@testable import Epos

/// What the recording state machine does when the recognizer — rather than the
/// user — ends the session: a result stream that dies while fn is still held, a
/// session that never starts, a rapid tap that tears the start down mid-flight,
/// and a recording whose words all clean away to nothing.
///
/// None of these can be provoked on a live `SpeechAnalyzer`, so they run against
/// `FakeTranscriber` through the coordinator's real `startRecording` →
/// `runSession` → `finishRecording` path.
@MainActor
final class CoordinatorRecognizerFailureTests: XCTestCase {
    private struct RecognizerUnavailable: Error {}

    /// Mutable stand-in for the live fn hardware read.
    private final class FnKeyState {
        var held = true
    }

    private let transcriber = FakeTranscriber()
    private let audio = FakeMicrophoneCapture()
    private let backend = RecordingTextInsertionBackend()
    private let fn = FnKeyState()

    /// The recognizer failed after a whole segment was already committed. Cleaning
    /// drops the stutter and the filler, so the write is the cleaned form.
    private static let recognizedRaw = "the the uh build is broken"
    private static let recognizedClean = "the build is broken"

    private func makeCoordinator(
        diagnostics: DiagnosticLogSink,
        microphone: PermissionStatus = .granted
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            audio: audio,
            transcriber: transcriber,
            textInsertion: backend,
            insertionTargetObserverFactory: { StubInsertionTargetObserver() },
            settings: Settings(),
            permissions: .stub(microphone: microphone),
            diagnostics: diagnostics,
            isFnKeyHeld: { [fn] in fn.held },
            observedEditCaptureDelays: [],
            inlinePreviewEnabled: false,
            autoStart: false
        )
        coordinator.captureFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        return coordinator
    }

    /// The recognizer's stream dies mid-dictation with the key still down. Writing
    /// there would type into the field the user is still dictating into and leave the
    /// eventual release to be swallowed by the state guard — everything said after the
    /// failure would vanish with no explanation.
    func testRecognizerFailureWhileFnHeldWaitsForTheReleaseBeforeWriting() async throws {
        let log = try TemporaryDiagnosticLog()
        let coordinator = makeCoordinator(diagnostics: log.sink)
        fn.held = true

        coordinator.startRecording()
        let session = coordinator.transcriptionTask
        await advance(until: { self.transcriber.didStart }, "the transcriber never started")

        transcriber.emit(.final(Self.recognizedRaw))
        transcriber.emit(.failed("results stream failed after 3: RecognizerUnavailable()"))
        transcriber.endStream()

        await advance(
            until: { coordinator.recognitionUnavailable },
            "the user was never told recognition died"
        )
        XCTAssertEqual(coordinator.state, .recording, "the hold is still the user's")
        XCTAssertEqual(backend.insertedTexts, [], "nothing may be typed while fn is held")

        fn.held = false
        coordinator.finishRecording()
        await session?.value

        // The release stayed meaningful: it committed what was recognized before the
        // failure, exactly once.
        XCTAssertEqual(backend.insertedTexts, [Self.recognizedClean])
        XCTAssertEqual(coordinator.state, .idle)
    }

    /// The same failure after the key is already up must not park on a release that
    /// has already happened — and the "Recognition lost" notice belongs to the
    /// mid-hold case only, where the user is still speaking.
    func testRecognizerFailureAfterReleaseCommitsWithoutParking() async throws {
        let log = try TemporaryDiagnosticLog()
        let coordinator = makeCoordinator(diagnostics: log.sink)
        fn.held = true

        coordinator.startRecording()
        let session = coordinator.transcriptionTask
        await advance(until: { self.transcriber.didStart }, "the transcriber never started")

        transcriber.emit(.final(Self.recognizedRaw))
        transcriber.emit(.failed("results stream failed after 3: RecognizerUnavailable()"))
        fn.held = false
        // The release closes the recognizer stream, exactly as `finish()` does live.
        coordinator.finishRecording()
        await session?.value

        XCTAssertEqual(backend.insertedTexts, [Self.recognizedClean])
        XCTAssertFalse(coordinator.recognitionUnavailable)
        XCTAssertEqual(coordinator.state, .idle)
    }

    /// An "um"-only recording cleans away to nothing. Deciding on the raw text sent
    /// that empty string into the insertion path, which refused it, flashed the red
    /// "Not inserted" pill — inviting a retype of something never said — and filed the
    /// recording under an insertion failure.
    func testRecordingThatCleansToNothingIsEmptyNotARefusedWrite() async throws {
        let log = try TemporaryDiagnosticLog()
        let coordinator = makeCoordinator(diagnostics: log.sink)
        // Guard against a silent no-op if the cleaner's filler list ever changes.
        XCTAssertEqual(coordinator.makeFinalTranscriptCleaner()("um"), "")

        coordinator.startRecording()
        let session = coordinator.transcriptionTask
        // The mic really did produce audio: the recording is empty because the words
        // cleaned away, which is what separates `empty-transcript` from `no-input`.
        audio.onBuffer?(try Self.makeBuffer())
        await advance(until: { self.transcriber.didStart }, "the transcriber never started")

        transcriber.emit(.final("um"))
        coordinator.finishRecording()
        await session?.value

        XCTAssertEqual(backend.insertedTexts, [])
        XCTAssertFalse(
            coordinator.insertionUnavailable,
            "an utterance that cleans to nothing must not accuse the write path"
        )
        let contents = try log.contents()
        XCTAssertTrue(contents.contains("outcome=empty-transcript"))
        XCTAssertFalse(contents.contains("outcome=backend-refused"))
    }

    /// A revoked microphone grant is not a user who said nothing. macOS keeps
    /// feeding a denied process buffers — silent ones — so the frames arrive, the
    /// audio-input check passes, and the recording used to file itself under
    /// `empty-transcript` with no feedback at all. The grant is consulted on this
    /// path only, once the transcript is known to be empty.
    func testEmptyRecordingWithARevokedMicrophoneIsReportedAsAPermissionFailure() async throws {
        let log = try TemporaryDiagnosticLog()
        let coordinator = makeCoordinator(diagnostics: log.sink, microphone: .denied)

        coordinator.startRecording()
        let session = coordinator.transcriptionTask
        // The silent buffers a denied process is fed: indistinguishable from
        // silence at the audio layer, which is the whole problem.
        audio.onBuffer?(try Self.makeBuffer())
        await advance(until: { self.transcriber.didStart }, "the transcriber never started")

        coordinator.finishRecording()
        await session?.value

        let contents = try log.contents()
        XCTAssertTrue(contents.contains("outcome=microphone-denied"))
        XCTAssertFalse(contents.contains("outcome=empty-transcript"))
        XCTAssertTrue(coordinator.startUnavailable, "a dead mic cannot be reported silently")
        XCTAssertEqual(coordinator.startNotice, "Mic blocked")
    }

    /// A tap released during `transcriber.start` either trips the state guard or
    /// loses the race and throws `tornDownDuringStart`; which one is chance. Both are
    /// the same user action and must report the same outcome — not an error-level
    /// setup failure, a "Not ready" notice, and a false row in the audit's
    /// setup-failure bucket.
    func testTapThatTearsDownTheStartReportsCancelledNotSetupFailed() async throws {
        let log = try TemporaryDiagnosticLog()
        transcriber.startError = TranscriberError.tornDownDuringStart
        let coordinator = makeCoordinator(diagnostics: log.sink)

        coordinator.startRecording()
        await coordinator.transcriptionTask?.value

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.startUnavailable, "a rapid tap is a user action, not a failure")
        let contents = try log.contents()
        XCTAssertTrue(contents.contains("outcome=cancelled-before-audio"))
        XCTAssertFalse(contents.contains("outcome=setup-failed"))
        XCTAssertFalse(contents.contains("recording setup failed"))
    }

    /// A session that genuinely fails to start used to be silent: the user held fn,
    /// saw the indicator, spoke, and got nothing back but a log line.
    func testSessionSetupFailureFlashesTheNotice() async throws {
        let log = try TemporaryDiagnosticLog()
        transcriber.startError = RecognizerUnavailable()
        let coordinator = makeCoordinator(diagnostics: log.sink)

        coordinator.startRecording()
        await coordinator.transcriptionTask?.value

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertTrue(try log.contents().contains("outcome=setup-failed"))
    }

    private static func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        return buffer
    }

    /// Lets the recording task advance to the point the test is waiting for. The
    /// coordinator runs on this actor but `transcriber.start` does not, so a plain
    /// yield is not always enough to observe the hand-off.
    private func advance(until condition: () -> Bool, _ message: String) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }
}

/// A fn-press target that captures cleanly and never moves, so the final-write
/// guard authorizes and the readback reports itself unavailable at once.
private final class StubInsertionTargetObserver: InsertionTargetObserver {
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

/// A throwaway diagnostic log the reliability outcomes can be read back out of.
private struct TemporaryDiagnosticLog {
    let directory: URL
    let sink: DiagnosticLogSink

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EposRecognizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sink = DiagnosticLogSink(configuration: .init(enabled: true), directory: directory)
    }

    func contents() throws -> String {
        sink.flush()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}

import AVFoundation
import XCTest
@testable import Epos

@MainActor
final class RecordingLatencyPipelineTests: XCTestCase {
    func testRecordingSeparatesStartupFirstResultDisplayFinalizationAndWrite() async throws {
        let log = LatencyTestLog()
        let microphone = TimedMicrophone(clock: log.clock)
        let transcriber = TimedTranscriber(clock: log.clock)
        let backend = TimedInsertionBackend(clock: log.clock)
        var published = false
        let clock = log.clock
        let session = makeSession(log: log, microphone: microphone, transcriber: transcriber, backend: backend) {
            if case .transcript(_, _, let display) = $0 {
                if display.isEmpty { clock.advance(.milliseconds(4)) }
                else if display == "hello" { published = true }
            }
        }
        session.start(format: try format())
        let task = try XCTUnwrap(session.task)
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !published, ContinuousClock().now < deadline { await Task.yield() }
        XCTAssertTrue(published)
        clock.advance(.milliseconds(10))
        session.release()
        await task.value
        await waitFor { (try? log.rows().contains { $0["stage"] == "delivery-readback" }) == true }

        XCTAssertEqual(backend.inserted, ["hello"])
        XCTAssertEqual(try log.row(.microphoneOpen)["durationMs"], "7.000")
        XCTAssertEqual(try log.row(.targetBaseline)["durationMs"], "11.000")
        XCTAssertEqual(try log.row(.analyzerStartup)["durationMs"], "13.000")
        XCTAssertEqual(try log.row(.firstRecognizerResult)["durationMs"], "31.000")
        XCTAssertEqual(try log.row(.firstDisplayPublication)["durationMs"], "35.000")
        XCTAssertEqual(try log.row(.recognizerFinalization)["durationMs"], "17.000")
        XCTAssertEqual(try log.row(.targetAuthorization)["durationMs"], "3.000")
        XCTAssertEqual(try log.row(.keystrokeWrite)["durationMs"], "5.000")
        XCTAssertEqual(try log.row(.releaseToWrite)["durationMs"], "25.000")
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "preview-cancel" })
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "first-mark-acknowledged" })
    }

    func testFailedMicrophoneLeavesNoAnalyzerOrZeroFirstResultSample() throws {
        let log = LatencyTestLog()
        let microphone = TimedMicrophone(clock: log.clock)
        microphone.failStart = true
        let backend = TimedInsertionBackend(clock: log.clock)
        let session = makeSession(
            log: log, microphone: microphone, transcriber: TimedTranscriber(clock: log.clock), backend: backend
        ) { _ in }
        session.start(format: try format())

        XCTAssertEqual(try log.row(.microphoneOpen)["durationMs"], "7.000")
        XCTAssertEqual(try log.row(.microphoneOpen)["outcome"], "failed")
        XCTAssertEqual(try log.row(.firstDisplayPublication)["durationMs"], "-1.000")
        XCTAssertEqual(try log.row(.firstRecognizerResult)["durationMs"], "-1.000")
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "analyzer-startup" })
        XCTAssertTrue(backend.inserted.isEmpty)
    }

    func testFirstMarkTimeWaitsForTheCompanionAcknowledgement() async throws {
        let log = LatencyTestLog()
        let target = TimedTarget(clock: log.clock)
        target.bundleIdentifier = nil
        var displayPublished = false
        var markAcknowledged = false
        let session = makeSession(
            log: log, microphone: TimedMicrophone(clock: log.clock),
            transcriber: TimedTranscriber(clock: log.clock), backend: TimedInsertionBackend(clock: log.clock),
            settings: Settings(inlinePreview: true), target: target
        ) {
            if case .transcript(_, _, let display) = $0 {
                if display.isEmpty { log.clock.advance(.milliseconds(4)) }
                else { displayPublished = true }
            }
            if case .firstMarkRendered = $0 { markAcknowledged = true }
        }
        session.start(format: try format())
        let task = try XCTUnwrap(session.task)
        await waitFor { displayPublished }
        XCTAssertEqual(try log.row(.firstDisplayPublication)["durationMs"], "35.000")
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "first-mark-acknowledged" })
        let preview = try XCTUnwrap(session.makeInlinePreviewSession(
            bundleIdentifier: "com.example.editor", transport: TimedMarkTransport(clock: log.clock), sleep: { _ in }
        ))
        await preview.begin()
        log.clock.advance(.milliseconds(10))
        await preview.mark("hello")
        await waitFor { markAcknowledged }
        XCTAssertEqual(try log.row(.firstMarkAcknowledged)["durationMs"], "68.000")
        await preview.discard()
        session.release()
        await task.value
        await waitFor { (try? log.rows().contains { $0["stage"] == "delivery-readback" }) == true }
    }

    func testRefusedTargetHasAuthorizationTimeButNoWriteTime() throws {
        let log = LatencyTestLog()
        let target = TimedTarget(clock: log.clock)
        target.focusChanged = true
        let backend = TimedInsertionBackend(clock: log.clock)
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: target, latency: log.timing,
            isAccessibilityTrusted: { true }
        )

        XCTAssertEqual(insertion.insertFinalResult("hello"), .targetRefused)
        XCTAssertEqual(try log.row(.targetAuthorization)["durationMs"], "3.000")
        XCTAssertEqual(try log.row(.targetAuthorization)["outcome"], "refused")
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "keystroke-write" })
        XCTAssertTrue(backend.inserted.isEmpty)
    }

    func testUnavailableReadbackDoesNotExtendReleaseToWrite() async throws {
        let log = LatencyTestLog()
        let backend = TimedInsertionBackend(clock: log.clock)
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: TimedTarget(clock: log.clock),
            latency: log.timing
        )
        log.timing.begin(.releaseToWrite)
        XCTAssertEqual(insertion.insertFinalResult("hello"), .accepted)
        log.clock.advance(.seconds(1))
        let delivery = await insertion.verifyDelivery(expected: "hello", retryDelaysNanoseconds: [])

        XCTAssertEqual(delivery, .unavailable)
        XCTAssertEqual(try log.row(.releaseToWrite)["durationMs"], "8.000")
        XCTAssertEqual(try log.row(.deliveryReadback)["outcome"], "unavailable")
        XCTAssertEqual(try log.rows().filter { $0["stage"] == "release-to-write" }.count, 1)
    }

    private func format() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    }

    private func waitFor(_ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock().now < deadline { await Task.yield() }
        XCTAssertTrue(predicate(), "the synthetic recording did not publish its expected event")
    }

    private func makeSession(
        log: LatencyTestLog, microphone: TimedMicrophone,
        transcriber: TimedTranscriber, backend: TimedInsertionBackend,
        settings: Settings = Settings(inlinePreview: false), target: TimedTarget? = nil,
        onEvent: @escaping @MainActor (RecordingSession.Event) -> Void
    ) -> RecordingSession {
        let defaults = UserDefaults(suiteName: "EposTimingTests-\(UUID())")!
        let clock = log.clock
        return RecordingSession(
            recordingID: "timed", audio: microphone, transcriber: transcriber, textInsertion: backend,
            targetObserverFactory: { target ?? TimedTarget(clock: clock) }, settings: settings,
            canonicalizer: TranscriptCanonicalizer(rules: []), diagnostics: log.sink,
            evidenceRecorder: CorrectionEvidenceRecorder(
                evidence: CorrectionEvidenceStore(defaults: defaults), captureDelays: [], currentRecordingID: { nil }
            ),
            isFnKeyHeld: { true }, isMicrophoneAccessMissing: { false }, includeTranscriptText: false,
            latencyNow: { clock.now }, onEvent: { _, event in onEvent(event) }
        )
    }
}

private final class TimedMicrophone: MicrophoneCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onAmplitude: ((Float) -> Void)?
    var onCaptureFailure: ((Error) -> Void)?
    var failStart = false
    private let clock: LatencyTestClock

    init(clock: LatencyTestClock) { self.clock = clock }

    func start(targetFormat: AVAudioFormat, echoCancellation: Bool) throws {
        clock.advance(.milliseconds(7))
        if failStart { throw CocoaError(.fileReadUnknown) }
    }

    func stop() {}
}

private final class TimedTranscriber: SpeechTranscribing, @unchecked Sendable {
    private let clock: LatencyTestClock
    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptEvent>.Continuation?

    init(clock: LatencyTestClock) { self.clock = clock }

    func bestAudioFormat() async -> AVAudioFormat? { nil }

    func start(contextualStrings: [String]) async throws -> AsyncStream<TranscriptEvent> {
        clock.advance(.milliseconds(13))
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        continuation.yield(.partial("um"))
        continuation.yield(.partial("hello"))
        return stream
    }

    func accept(_ buffer: AVAudioPCMBuffer) {}

    func finish() async {
        clock.advance(.milliseconds(17))
        lock.withLock { continuation }?.finish()
    }
}

private final class TimedTarget: InsertionTargetObserver {
    let clock: LatencyTestClock
    var focusChanged = false
    var bundleIdentifier: String? = "com.example.editor"

    init(clock: LatencyTestClock) { self.clock = clock }
    func captureBaseline() { clock.advance(.milliseconds(11)) }
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { clock.advance(.milliseconds(3)); return focusChanged }
    func observedValue() -> String? { nil }
    func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    func requiresTextContextValidation() -> Bool { false }
    func baselineInsertionContext() -> InsertionTargetContext? { nil }
    func targetApplicationBundleIdentifier() -> String? { bundleIdentifier }
    func targetWindowTitle() -> String? { nil }
}

private actor TimedMarkTransport: InlinePreviewTransport {
    let clock: LatencyTestClock
    init(clock: LatencyTestClock) { self.clock = clock }
    func open() async throws {}
    func send(_ line: String) async throws -> String {
        if line.hasPrefix("mark ") { clock.advance(.milliseconds(23)) }
        return "ok"
    }
    func close() async {}
}

private final class TimedInsertionBackend: TextInsertionBackend {
    private let clock: LatencyTestClock
    private(set) var inserted: [String] = []
    init(clock: LatencyTestClock) { self.clock = clock }
    func startInsertionSession() -> any TextInsertionSession { Session(backend: self) }

    private final class Session: TextInsertionSession {
        let backend: TimedInsertionBackend
        init(backend: TimedInsertionBackend) { self.backend = backend }
        func insert(_ text: String) -> Bool {
            backend.clock.advance(.milliseconds(5))
            backend.inserted.append(text)
            return true
        }
        func finish() {}
        func cancel() {}
    }
}

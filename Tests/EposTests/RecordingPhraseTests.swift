import AVFoundation
import XCTest
@testable import Epos

@MainActor
final class RecordingPhraseTests: XCTestCase {
    func testConfirmedCorrectionsStayFixedAndNextPhraseKeepsItsSeparator() async throws {
        let backend = RecordingInsertionBackend()
        let transport = FakeInlinePreviewTransport()
        var display = ""
        let recording = try makeRecording(backend: backend, transport: transport, rules: [
            .init(canonical: "Epos", aliases: ["epose"])
        ]) { event in
            if case .transcript(_, _, let text) = event { display = text }
        }
        let preview = await stage(recording, backend: backend, transport: transport)
        recording.handleFinalTranscriptSegment("🙂 Epose works")
        await recording.commitConfirmedPhraseIfHeld()
        recording.handlePartialTranscript(" next")
        XCTAssertEqual(display, "🙂 Epos works next", "later aliases cannot rewrite confirmed text")
        recording.handleFinalTranscriptSegment("\n um next")
        XCTAssertEqual(display, "🙂 Epos works\nnext")
        let route = await recording.commitFinalTranscript(display)
        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        XCTAssertTrue(backend.inserted.isEmpty)
        let lines = await transport.lines
        XCTAssertEqual(lines.filter { $0.hasPrefix("seal ") }, ["seal 🙂 Epos works"])
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit64 ") }, ["commit64 " + Data("\nnext".utf8).base64EncodedString()])
        await preview.discard()
    }

    func testCleanupKeepsFullContextAcrossCommittedBoundary() async throws {
        for (first, remainder, expected) in [
            ("First.", " um\nSecond.", "First.\nSecond."),
            ("Hello", " um.", "Hello."),
            ("Hello um ", "world", "Hello world"),
            ("Hello um", " world", "Hello world"),
            ("I want, um", " apples", "I want, apples"),
            ("Hello ", " um.", "Hello."),
            ("Hello, ", "um", "Hello"),
            ("the ", "the, build", "the, build")
        ] {
            let backend = RecordingInsertionBackend()
            let transport = FakeInlinePreviewTransport()
            var display = ""
            let recording = try makeRecording(backend: backend, transport: transport) { event in
                if case .transcript(_, _, let text) = event { display = text }
            }
            let preview = await stage(recording, backend: backend, transport: transport)
            recording.handleFinalTranscriptSegment(first)
            await recording.commitConfirmedPhraseIfHeld()
            recording.handleFinalTranscriptSegment(remainder)
            XCTAssertEqual(display, expected, "\(first.debugDescription) + \(remainder.debugDescription)")
            let route = await recording.commitFinalTranscript(display)
            XCTAssertEqual(route, .completed(.accepted, viaIME: true))
            XCTAssertTrue(backend.inserted.isEmpty)
            await preview.discard()
        }
    }

    func testRecordingLoopCommitsConfirmedPhraseBeforeRelease() async throws {
        let firstMark = expectation(description: "first preview sent")
        let sealed = expectation(description: "confirmed phrase delivered while held")
        let tailMark = expectation(description: "only the unfinished phrase is marked")
        let transport = FakeInlinePreviewTransport(onSend: { line in
            if line == "mark First" { firstMark.fulfill() }
            if line == "seal First." { sealed.fulfill() }
            if line == "mark  tail" { tailMark.fulfill() }
        })
        let backend = RecordingInsertionBackend()
        let transcriber = FakeTranscriber()
        let recording = try makeRecording(backend: backend, transport: transport, transcriber: transcriber)
        recording.start(format: try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)))
        let deadline = ContinuousClock.now + .seconds(1)
        while !transcriber.didStart, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(transcriber.didStart)
        transcriber.emit(.partial("First"))
        await fulfillment(of: [firstMark], timeout: 1)
        transcriber.emit(.final("First."))
        await fulfillment(of: [sealed], timeout: 1)
        transcriber.emit(.partial(" tail"))
        await fulfillment(of: [tailMark], timeout: 1)
        let task = recording.task
        recording.release()
        await task?.value
        let lines = await transport.lines
        XCTAssertEqual(lines.filter { $0.hasPrefix("seal ") }, ["seal First."])
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit ") }, ["commit  tail"])
        XCTAssertTrue(backend.inserted.isEmpty)
    }

    func testNewPhraseStillUsesPrecedingRawContext() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "Marco", aliases: ["mark"], contexts: ["ask"])
        ])
        let rawPrefix = "🙂 ask"
        let result = canonicalizer.canonicalizeSuffix(rawPrefix + " mark", afterUTF16: (rawPrefix as NSString).length)
        XCTAssertEqual(result.output, " Marco")
    }

    func testCorrectionContinuationStaysMarkedUntilSafeBoundary() async throws {
        let backend = RecordingInsertionBackend()
        let transport = FakeInlinePreviewTransport()
        var display = ""
        let recording = try makeRecording(backend: backend, transport: transport, rules: [
            .init(canonical: "DevKit", aliases: ["dev kit tools"])
        ]) { if case .transcript(_, _, let text) = $0 { display = text } }
        let preview = await stage(recording, backend: backend, transport: transport)
        recording.handleFinalTranscriptSegment("Start.")
        await recording.commitConfirmedPhraseIfHeld()
        recording.handleFinalTranscriptSegment(" 🙂 Use dev")
        await recording.commitConfirmedPhraseIfHeld()
        recording.handlePartialTranscript(" kit")
        XCTAssertEqual(display, "Start. 🙂 Use dev kit")
        recording.handleFinalTranscriptSegment(" kit")
        await recording.commitConfirmedPhraseIfHeld()
        let deferredLines = await transport.lines
        XCTAssertEqual(deferredLines.filter { $0.hasPrefix("seal ") }, ["seal Start."])
        recording.handleFinalTranscriptSegment(" tools now.")
        await recording.commitConfirmedPhraseIfHeld()
        XCTAssertEqual(display, "Start. 🙂 Use DevKit now.")
        let lines = await transport.lines
        XCTAssertEqual(lines.filter { $0.hasPrefix("seal ") }, ["seal Start.", "seal  🙂 Use DevKit now."])
        await preview.discard()
    }

    func testNameContextAndReleaseResolveDeferredPhrase() async throws {
        for (first, next, expected) in [
            ("Mark", " pushed the fix.", "Marco pushed the fix."),
            ("Ask mark", " by tomorrow.", "Ask mark by tomorrow."),
            ("Use dash", " dash fix.", "Use --fix."),
            ("Use dev", "", "Use dev")
        ] {
            let backend = RecordingInsertionBackend()
            let transport = FakeInlinePreviewTransport()
            var display = ""
            let recording = try makeRecording(backend: backend, transport: transport, rules: [
                .init(canonical: "Marco", aliases: ["mark"], matchStrategy: .personNameSlot),
                .init(canonical: "DevKit", aliases: ["dev kit"])
            ]) { if case .transcript(_, _, let text) = $0 { display = text } }
            let preview = await stage(recording, backend: backend, transport: transport)
            recording.handleFinalTranscriptSegment(first)
            await recording.commitConfirmedPhraseIfHeld()
            let deferredLines = await transport.lines
            XCTAssertFalse(deferredLines.contains { $0.hasPrefix("seal") })
            recording.release()
            recording.handleFinalTranscriptSegment(next)
            XCTAssertEqual(display, expected)
            let route = await recording.commitFinalTranscript(display)
            XCTAssertEqual(route, .completed(.accepted, viaIME: true))
            let lines = await transport.lines
            XCTAssertEqual(lines.filter { $0.hasPrefix("commit ") }, ["commit " + expected])
            XCTAssertTrue(backend.inserted.isEmpty)
            await preview.discard()
        }
    }

    private func makeRecording(
        backend: RecordingInsertionBackend, transport: FakeInlinePreviewTransport,
        transcriber: FakeTranscriber = FakeTranscriber(), rules: [TranscriptCanonicalizer.Rule] = [],
        onEvent: @escaping (RecordingSession.Event) -> Void = { _ in }
    ) throws -> RecordingSession {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EposPhraseTests-\(UUID())"))
        return RecordingSession(
            recordingID: nil, audio: FakeMicrophoneCapture(), transcriber: transcriber,
            textInsertion: backend, targetObserverFactory: { StableOpaqueObserver() },
            settings: Settings(inlinePreview: true), canonicalizer: TranscriptCanonicalizer(rules: rules),
            diagnostics: .shared,
            evidenceRecorder: CorrectionEvidenceRecorder(
                evidence: CorrectionEvidenceStore(defaults: defaults), captureDelays: [], currentRecordingID: { nil }
            ), isShortcutHeld: { true }, isMicrophoneAccessMissing: { false }, includeTranscriptText: false,
            previewKeyboardSourceFactory: { PreviewKeyboardSource(access: PhraseKeyboardSource()) },
            previewTransportFactory: { transport }, onEvent: { _, event in onEvent(event) }
        )
    }

    private func stage(
        _ recording: RecordingSession, backend: RecordingInsertionBackend, transport: FakeInlinePreviewTransport
    ) async -> InlinePreviewSession {
        let preview = recording.makeInlinePreviewSession(
            bundleIdentifier: "com.test.app", transport: transport, sleep: { _ in }
        )!
        recording.stageFinalizationSessions(
            inlinePreview: preview,
            insertion: FinalTranscriptInsertionSession(insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver())
        )
        await preview.begin()
        return preview
    }
}

@MainActor
private struct PhraseKeyboardSource: PreviewKeyboardSourceAccess {
    func currentIdentifier() -> String? { PreviewKeyboardSource.companionIdentifier }
    func currentIsLayout() -> Bool { false }
    func layoutIdentifier() -> String? { "com.test.layout" }
    func companionIsAvailable() -> Bool { true }
    func select(_ identifier: String) -> Bool { false }
}

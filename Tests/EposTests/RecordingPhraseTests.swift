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

    func testPhraseAcknowledgmentStalls() async throws {
        guard let output = ProcessInfo.processInfo.environment["EPOS_PHRASE_STALL_OUTPUT"] else {
            throw XCTSkip("Set EPOS_PHRASE_STALL_OUTPUT to run the controlled acknowledgment experiment")
        }
        var results: [PhraseStallResult] = []
        for repetition in 0..<3 {
            let delays = [0, 5, 20, 100, 400]
            for offset in delays.indices {
                let delay = delays[(offset + repetition) % delays.count]
                results.append(try await runStall(delay: delay, releaseDuringReply: false, ambiguous: false))
            }
        }
        results.append(try await runStall(delay: 100, releaseDuringReply: true, ambiguous: false))
        results.append(try await runStall(delay: 500, releaseDuringReply: true, ambiguous: true))
        try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    private func runStall(delay: Int, releaseDuringReply: Bool, ambiguous: Bool) async throws -> PhraseStallResult {
        let firstMark = expectation(description: "first preview sent")
        let sealSent = expectation(description: "first phrase sent")
        let tailPublished = expectation(description: "queued events published")
        let transport = DelayedPhraseTransport(delay: delay, ambiguous: ambiguous) { line in
            if line == "mark First" { firstMark.fulfill() }
            if line == "seal First." { sealSent.fulfill() }
        }
        let backend = RecordingInsertionBackend()
        let transcriber = FakeTranscriber()
        var queuedAt = ContinuousClock.now
        var publicationDelay: Double?
        var displays: [String] = []
        let recording = try makeRecording(backend: backend, transport: transport, transcriber: transcriber) { event in
            if case .transcript(_, _, let text) = event {
                displays.append(text)
                if text == "First. tail. end", publicationDelay == nil {
                    publicationDelay = phraseMilliseconds(queuedAt.duration(to: .now))
                    tailPublished.fulfill()
                }
            }
        }
        recording.start(format: try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)))
        let deadline = ContinuousClock.now + .seconds(1)
        while !transcriber.didStart, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(transcriber.didStart)
        transcriber.emit(.partial("First"))
        await fulfillment(of: [firstMark], timeout: 1)
        transcriber.emit(.final("First."))
        await fulfillment(of: [sealSent], timeout: 1)
        queuedAt = .now
        transcriber.emit(.partial(" tail"))
        transcriber.emit(.final(" tail."))
        transcriber.emit(.partial(" end"))
        if releaseDuringReply { recording.release() }
        await fulfillment(of: [tailPublished], timeout: 3)
        if !releaseDuringReply { recording.release() }
        await recording.task?.value
        let lines = await transport.lines
        let replyAt = await transport.firstReplyAt
        let remainingReplyDelay = max(0, phraseMilliseconds(queuedAt.duration(to: try XCTUnwrap(replyAt))))
        let publicationMilliseconds = try XCTUnwrap(publicationDelay)
        XCTAssertGreaterThanOrEqual(publicationMilliseconds, remainingReplyDelay)
        let writes = lines.filter { $0.hasPrefix("seal ") || $0.hasPrefix("commit ") }
        XCTAssertTrue(backend.inserted.isEmpty)
        XCTAssertTrue(displays.contains("First. tail"), "superseded partial was still consumed")
        XCTAssertTrue(displays.contains("First. tail."), "queued final was retained")
        if ambiguous {
            XCTAssertEqual(writes, ["seal First."], "an unknown first write forbids further insertion")
        } else if releaseDuringReply {
            XCTAssertEqual(writes, ["seal First.", "commit  tail. end"])
        } else {
            XCTAssertEqual(writes, ["seal First.", "seal  tail.", "commit  end"])
        }
        return PhraseStallResult(
            delayMilliseconds: delay, releaseDuringReply: releaseDuringReply, ambiguous: ambiguous,
            queuedToReplyMilliseconds: remainingReplyDelay,
            queuedToLastPublicationMilliseconds: publicationMilliseconds, writes: writes
        )
    }

    private func makeRecording(
        backend: RecordingInsertionBackend, transport: any InlinePreviewTransport,
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

private struct PhraseStallResult: Encodable {
    let delayMilliseconds: Int
    let releaseDuringReply: Bool
    let ambiguous: Bool
    let queuedToReplyMilliseconds: Double
    let queuedToLastPublicationMilliseconds: Double
    let writes: [String]
}

private func phraseMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private actor DelayedPhraseTransport: InlinePreviewTransport {
    let delay: Int
    let ambiguous: Bool
    let onSend: @Sendable (String) -> Void
    private(set) var lines: [String] = []
    private var seals = 0
    private(set) var firstReplyAt: ContinuousClock.Instant?

    init(delay: Int, ambiguous: Bool, onSend: @escaping @Sendable (String) -> Void) {
        self.delay = delay
        self.ambiguous = ambiguous
        self.onSend = onSend
    }
    func open() async throws {}
    func close() async {}
    func send(_ line: String) async throws -> String {
        lines.append(line)
        onSend(line)
        if line.hasPrefix("seal ") {
            seals += 1
            if seals == 1 {
                try await Task.sleep(for: .milliseconds(delay))
                firstReplyAt = .now
                if ambiguous { throw InlinePreviewTransportError.replyTimedOut }
            }
            return "ok committed 1"
        }
        if line.hasPrefix("commit") { return "ok committed 1" }
        return "ok"
    }
}

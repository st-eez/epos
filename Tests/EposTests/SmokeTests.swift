import AVFoundation
import Speech
import XCTest
@testable import Epos

final class SmokeTests: XCTestCase {
    @MainActor
    func testCoordinatorStartsIdle() {
        // autoStart: false so the global NSEvent monitor isn't installed during tests.
        let coordinator = AppCoordinator(autoStart: false)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.finalText, "")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "")
    }

    @MainActor
    func testCoordinatorPromotesPartialAsFallbackFinalWhenNoFinalArrives() {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.handlePartialTranscript("volatile words")
        coordinator.promotePartialTranscriptAsFallbackFinalIfNeeded()

        XCTAssertEqual(coordinator.finalText, "volatile words")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "volatile words")
    }

    @MainActor
    func testCoordinatorFoldsTrailingPartialIntoFallbackFinal() {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.handleFinalTranscriptSegment("settled words")
        coordinator.handlePartialTranscript(" volatile tail")
        coordinator.promotePartialTranscriptAsFallbackFinalIfNeeded()

        XCTAssertEqual(coordinator.finalText, "settled words volatile tail")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "settled words volatile tail")
    }

    @MainActor
    func testRecordingCuesSynthesizeParseableSounds() {
        // A malformed WAV header would make NSSound(data:) nil and silently
        // kill the cue; this pins the synth-to-container path for both bells.
        XCTAssertNotNil(RecordingCue.makeStartSound())
        XCTAssertNotNil(RecordingCue.makeEndSound())
    }

    func testPermissionsSnapshotReturns() {
        let snapshot = PermissionsGate().snapshot()
        _ = snapshot.microphone
        _ = snapshot.speech
        _ = snapshot.accessibility
    }

    func testSettingsPersistsAudioSampleCaptureFlag() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        Settings(saveAudioSamples: true, saveCorrectionEvidence: false).save(to: defaults)

        XCTAssertTrue(Settings.load(from: defaults).saveAudioSamples)
        XCTAssertFalse(Settings.load(from: defaults).saveCorrectionEvidence)
    }

    func testEdgeGlowSettingsPersistClampAndDefaultOn() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Never-saved defaults: the glow ships enabled with the teal base.
        let fresh = Settings.load(from: defaults).edgeGlow
        XCTAssertTrue(fresh.enabled)
        XCTAssertEqual(fresh.intensity, 0.85)
        XCTAssertEqual(fresh.red, 0.22)

        // Round-trip, including a stored false (distinct from "never set")
        // and a non-default theme.
        var settings = Settings()
        settings.edgeGlow = EdgeGlowSettings(
            enabled: false, theme: .ember, intensity: 1.3, thickness: 0.8,
            red: 0.9, green: 0.2, blue: 0.4
        )
        settings.save(to: defaults)
        let loaded = Settings.load(from: defaults).edgeGlow
        XCTAssertEqual(loaded, settings.edgeGlow)
        XCTAssertFalse(loaded.enabled)
        XCTAssertEqual(loaded.theme, .ember)

        // Out-of-range and non-finite values clamp at construction.
        let clamped = EdgeGlowSettings(intensity: 9, thickness: -2, red: .nan, green: 2, blue: -1)
        XCTAssertEqual(clamped.intensity, EdgeGlowSettings.intensityRange.upperBound)
        XCTAssertEqual(clamped.thickness, EdgeGlowSettings.thicknessRange.lowerBound)
        XCTAssertEqual(clamped.red, 0)
        XCTAssertEqual(clamped.green, 1)
        XCTAssertEqual(clamped.blue, 0)
    }

    func testRecordingIndicatorMeterRespondsToSpeechRange() {
        let quietHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.005) }
        let speechHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.03) }
        let loudHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.08) }

        XCTAssertGreaterThan(speechHeights.reduce(0, +), quietHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.reduce(0, +), speechHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.max() ?? 0, quietHeights.max() ?? 0)
    }

    func testRecordingIndicatorLabelsFinalizationStages() {
        XCTAssertEqual(
            RecordingIndicatorSurface.statusText(state: .recording, finalizationPhase: .finalizingSpeech),
            "Listening"
        )
        XCTAssertEqual(
            RecordingIndicatorSurface.statusText(state: .finalizing, finalizationPhase: .finalizingSpeech),
            "Finishing"
        )
        XCTAssertEqual(
            RecordingIndicatorSurface.statusText(state: .finalizing, finalizationPhase: .inserting),
            "Updating"
        )
    }

    func testIndicatorBottomCenterPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pillSize = CGSize(width: 144, height: 36)

        let fallback = RecordingIndicatorPlacementPolicy.bottomCenterFrame(
            in: screen,
            indicatorSize: pillSize
        )
        XCTAssertEqual(fallback.size.width, pillSize.width, accuracy: 0.001)
        XCTAssertEqual(fallback.size.height, pillSize.height, accuracy: 0.001)
        XCTAssertEqual(fallback.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(
            fallback.minY,
            screen.minY + RecordingIndicatorPlacementPolicy.fallbackBottomInset,
            accuracy: 0.001
        )
        XCTAssertTrue(screen.contains(fallback))
    }

    func testLocalInstallDoesNotRegisterInputMethod() throws {
        let root = repositoryRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/install-local-app.sh"),
            encoding: .utf8
        )

        XCTAssertFalse(script.contains("InputMethod"))
        XCTAssertFalse(script.contains("TISRegisterInputSource"))
    }

    func testProjectDoesNotDeclareInputMethodTarget() throws {
        let root = repositoryRoot()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        XCTAssertFalse(project.contains("EposInputMethod"))
        XCTAssertFalse(project.contains("com.steez.inputmethod.Epos"))
    }

    func testKeystrokeInjectorChunksWithinUnicodeLimitOnGraphemeBoundaries() {
        // Short text stays a single event.
        XCTAssertEqual(
            KeystrokeTextInjector.unicodeChunks(of: "hello world", maxUTF16Units: 20)
                .map { String(utf16CodeUnits: $0, count: $0.count) },
            ["hello world"]
        )

        // Long text splits without exceeding the per-event UTF-16 budget and
        // reassembles to the original.
        let long = String(repeating: "ab", count: 40) // 80 UTF-16 units
        let chunks = KeystrokeTextInjector.unicodeChunks(of: long, maxUTF16Units: 20)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined(), long)

        // A grapheme whose UTF-16 width exceeds the budget is never split across
        // events — it rides intact in its own chunk.
        let emoji = "👍🏽" // surrogate pair + skin-tone modifier: 4 UTF-16 units
        let emojiChunks = KeystrokeTextInjector.unicodeChunks(of: "a" + emoji + "b", maxUTF16Units: 2)
        XCTAssertEqual(
            emojiChunks.map { String(utf16CodeUnits: $0, count: $0.count) },
            ["a", emoji, "b"]
        )
    }

    func testFinalInsertionWritesOnce() {
        let backend = RecordingTextInsertionBackend()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession()
        )

        XCTAssertEqual(session.insertFinalResult("hello world from epos"), .accepted)
        XCTAssertEqual(session.insertFinalResult("duplicate"), .backendRefused)
        session.finish()

        XCTAssertEqual(backend.insertedTexts, ["hello world from epos"])
        XCTAssertEqual(backend.fieldText, "hello world from epos")
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testFinalInsertionCancelWritesNothing() {
        let backend = RecordingTextInsertionBackend()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession()
        )

        session.cancel()
        XCTAssertEqual(session.insertFinalResult("late"), .backendRefused)
        session.cancel()

        XCTAssertEqual(backend.insertedTexts, [])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testTranscriberPresetRequestsLowLatencyVolatileResults() {
        XCTAssertTrue(Transcriber.speechPreset.reportingOptions.contains(.volatileResults))
        XCTAssertTrue(Transcriber.speechPreset.reportingOptions.contains(.fastResults))
        XCTAssertFalse(Transcriber.speechPreset.reportingOptions.contains(.alternativeTranscriptions))
    }

    func testSpeechContextualStringsExcludesPostHocErrorAliases() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "CMUX", aliases: ["see mux"]),
            .init(canonical: "--", aliases: ["dash dash"]),
            .init(canonical: "/", aliases: ["slash"]),
            .init(canonical: "cmux", aliases: ["cmox"]),
            .init(canonical: "Epos", aliases: ["epos"]),
            .init(canonical: "Aster", aliases: ["esther"], contexts: ["message to"])
        ])

        XCTAssertEqual(
            canonicalizer.speechContextualStrings,
            ["CMUX", "Epos", "Aster"]
        )
    }

    func testAnalysisContextNilForEmptyOrBlankVocabulary() {
        XCTAssertNil(Transcriber.analysisContext(contextualStrings: []))
        XCTAssertNil(Transcriber.analysisContext(contextualStrings: ["   ", ""]))
        XCTAssertNotNil(Transcriber.analysisContext(contextualStrings: ["Epos"]))
    }

    func testAnalysisContextTrimsDeduplicatesAndPreservesOrder() throws {
        let context = try XCTUnwrap(Transcriber.analysisContext(contextualStrings: [
            " Epos ",
            "epos",
            "CMUX",
            "cmux"
        ]))

        XCTAssertEqual(context.contextualStrings[.general], ["Epos", "CMUX"])
    }

    /// Regression: pre-fix, `Transcriber.finish()` hung in `await drain?.value`
    /// because Apple's `SpeechTranscriber.results` does not terminate after
    /// `cancelAndFinishNow()` on an analyzer that received zero input. Reproduces
    /// when fn is tapped too fast for any audio buffer to arrive.
    func testFinishWithoutInputReturnsPromptly() async throws {
        let transcriber = Transcriber(locale: Locale(identifier: "en-US"))
        do {
            _ = try await transcriber.start()
        } catch {
            throw XCTSkip("Transcriber.start() unavailable in test env: \(error)")
        }

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await transcriber.finish()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        XCTAssertTrue(finished, "Transcriber.finish() hung with no input")
    }

    /// The settle-wait on `analyzer.start` used to sit OUTSIDE the finalize timeout,
    /// so a `setContext` or `start(inputSequence:)` that hung parked `finish()`
    /// forever: the event stream never closed, the coordinator never left
    /// `.finalizing`, and nothing watches the transcription task — the app was dead
    /// until quit. The bound now covers every framework await, and the timeout path
    /// has to leave the caller recoverable: stream closed, failure reported.
    func testFinishIsBoundedWhenTheAnalyzerStartNeverSettles() async {
        let module = Transcriber.makeTranscriber(locale: Locale(identifier: "en-US"))
        let (_, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (events, eventContinuation) = AsyncStream<TranscriptEvent>.makeStream()
        let hungStart = Task<Void, Error> {
            let (stream, _) = AsyncStream<Void>.makeStream()
            for await _ in stream {}
        }
        let drain = Task<Void, Never> {
            let (stream, _) = AsyncStream<Void>.makeStream()
            for await _ in stream {}
        }
        defer {
            hungStart.cancel()
            drain.cancel()
        }

        await Transcriber.closeSession(
            Transcriber.Session(
                analyzer: SpeechAnalyzer(modules: [module]),
                inputContinuation: inputContinuation,
                eventContinuation: eventContinuation,
                drainTask: drain,
                startTask: hungStart,
                hasReceivedBuffer: true
            ),
            timeout: .milliseconds(100)
        )

        // Reaching here at all is half the assertion: `closeSession` returned. The
        // rest is that the caller's event loop can end and learns why — this loop
        // would never terminate if the stream were left open.
        var failures: [String] = []
        for await event in events {
            if case .failed(let message) = event { failures.append(message) }
        }
        XCTAssertEqual(failures.count, 1, "the hang must be reported, not swallowed")
    }

    /// The with-input `finish()` path is bounded by racing {finalize + drain} against
    /// `Transcriber.finishTimeout` via `completed(within:_:)`. The hang itself cannot be
    /// induced on a real `SpeechAnalyzer`, so the race helper is tested in isolation:
    /// a never-returning operation must lose the race and the helper must still return.
    func testCompletedWithinReturnsFalseAndReturnsWhenOperationNeverFinishes() async {
        let result = await Transcriber.completed(within: .milliseconds(50)) {
            // Suspend indefinitely on a stream that never yields, standing in for a
            // finalize/drain await that hangs inside Apple's framework.
            let (stream, _) = AsyncStream<Void>.makeStream()
            for await _ in stream {}
        }
        XCTAssertFalse(result, "a hung operation must time out, not win the race")
    }

    /// The input stream used to use the default `.unlimited` policy, so an analyzer
    /// that stopped draining retained every mic buffer of the recording, indefinitely.
    /// The bound has to hold the opening of the utterance and refuse the overflow
    /// rather than evicting already-captured audio.
    func testInputStreamBoundsQueuedAudioBuffers() async {
        let (stream, continuation) = Transcriber.makeInputStream()

        var dropped = 0
        for _ in 0..<(Transcriber.maxQueuedInputBuffers + 8) {
            if case .dropped = continuation.yield(makeAnalyzerInput()) { dropped += 1 }
        }
        continuation.finish()

        XCTAssertEqual(dropped, 8, "everything past the bound must be refused, not buffered")
        var buffered = 0
        for await _ in stream { buffered += 1 }
        XCTAssertEqual(
            buffered,
            Transcriber.maxQueuedInputBuffers,
            "the bound must keep the opening of the utterance, not evict it for newer audio"
        )
    }

    /// Hitting the bound is a wedged analyzer, not a talkative user: the session must
    /// stop retaining audio and report the recognizer failure the coordinator already
    /// handles, instead of dropping audio silently mid-dictation.
    func testInputOverflowClosesInputAndReportsRecognizerFailure() async {
        let module = Transcriber.makeTranscriber(locale: Locale(identifier: "en-US"))
        let (input, inputContinuation) = Transcriber.makeInputStream()
        let (events, eventContinuation) = AsyncStream<TranscriptEvent>.makeStream()
        let idle = Task<Void, Error> {}
        let drain = Task<Void, Never> {}

        Transcriber.reportInputOverflow(
            Transcriber.Session(
                analyzer: SpeechAnalyzer(modules: [module]),
                inputContinuation: inputContinuation,
                eventContinuation: eventContinuation,
                drainTask: drain,
                startTask: idle,
                hasReceivedBuffer: true
            )
        )
        eventContinuation.finish()

        guard case .terminated = inputContinuation.yield(makeAnalyzerInput()) else {
            return XCTFail("the input stream must be closed so no further audio is retained")
        }
        var retained = 0
        for await _ in input { retained += 1 }
        XCTAssertEqual(retained, 0, "audio yielded after the failure must not be retained")

        var failures: [String] = []
        for await event in events {
            if case .failed(let message) = event { failures.append(message) }
        }
        XCTAssertEqual(failures.count, 1, "the wedged analyzer must be reported as a recognizer failure")
    }

    func testCompletedWithinReturnsTrueWhenOperationFinishesInTime() async {
        let result = await Transcriber.completed(within: .seconds(5)) {}
        XCTAssertTrue(result, "a completed operation must win the race")
    }
}

/// One capture-shaped buffer wrapped as analyzer input. `AnalyzerInput.init(buffer:)`
/// traps on float32 buffers, so this uses the interleaved 16 kHz int16 shape
/// `SpeechAnalyzer.bestAvailableAudioFormat` hands `AudioCapture` to convert into.
private func makeAnalyzerInput() -> AnalyzerInput {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
    buffer.frameLength = 128
    return AnalyzerInput(buffer: buffer)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("EposTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

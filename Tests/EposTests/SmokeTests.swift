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

        Settings(saveAudioSamples: true).save(to: defaults)

        XCTAssertTrue(Settings.load(from: defaults).saveAudioSamples)
    }

    func testCanonicalizerFixesSeededDeveloperTerms() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "open Siemux and edit agents dot m d then run swift lint"
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "open CMUX and edit AGENTS.md then run swift lint")
    }

    func testCanonicalizerFixesClaudeMarkdownAliases() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "Check the cloud dot MD. Check the cloud.md."
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "Check the CLAUDE.md. Check the CLAUDE.md.")
    }

    func testCanonicalizerFixesCurrentDefaultCustomEntries() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "message steph and type slash"
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "message Stath and type /")
    }

    func testCanonicalizerAppliesExposedAcronymAliases() {
        let canonicalizer = TranscriptCanonicalizer()

        XCTAssertEqual(canonicalizer.canonicalize("open see mux"), "open CMUX")
        XCTAssertEqual(canonicalizer.canonicalize("open c m u x"), "open CMUX")
        XCTAssertEqual(canonicalizer.canonicalize("open c-mux"), "open CMUX")
    }

    func testCanonicalizerOnlyAppliesListedAliases() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "WidgetPro", aliases: ["widget pro"])
        ])

        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(canonicalizer.canonicalize("open widgetpro"), "open widgetpro")
    }

    func testCorrectionDraftRoundTripsEditableFields() {
        let draft = CorrectionDraft(
            aliasesText: "widget pro, widget row",
            canonical: " WidgetPro ",
            contextsText: "open, launch"
        )

        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.rule.canonical, "WidgetPro")
        XCTAssertEqual(draft.rule.aliases, ["widget pro", "widget row"])
        XCTAssertEqual(draft.rule.contexts, ["open", "launch"])
    }

    func testCanonicalizerDoesNotRewriteSubstrings() {
        let canonicalizer = TranscriptCanonicalizer()

        XCTAssertEqual(canonicalizer.canonicalize("the simuxed branch"), "the simuxed branch")
        XCTAssertEqual(canonicalizer.canonicalize("print env before running"), "print env before running")
        XCTAssertEqual(
            canonicalizer.canonicalize("source dot env before running"),
            "source .env before running"
        )
    }

    func testCanonicalizerAppliesContextualRules() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "Aster", aliases: ["esther"], contexts: ["message to"])
        ])

        XCTAssertEqual(canonicalizer.canonicalize("message to Esther"), "message to Aster")
        XCTAssertEqual(canonicalizer.canonicalize("Esther sent the note"), "Esther sent the note")
    }

    func testCanonicalizerNormalizesCommandTokens() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "pass dash dash verbose then use dollar home and slash goal"
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "pass --verbose then use $HOME and /goal")
    }

    func testCanonicalizerLoadsSavedRulesFromUserDefaults() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rules = [
            TranscriptCanonicalizer.Rule(
                canonical: "WidgetPro",
                aliases: ["widget pro"],
                contexts: ["open"]
            )
        ]
        TranscriptCanonicalizer.saveRules(rules, to: defaults)

        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(canonicalizer.canonicalize("compare widget pro"), "compare widget pro")
        XCTAssertEqual(canonicalizer.canonicalize("open siemux"), "open siemux")
    }

    func testCanonicalizerMigratesLegacyCustomRulesBeforeDefaults() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyCustomRules: [TranscriptCanonicalizer.Rule] = [
            .init(canonical: "MUX", aliases: ["simux"])
        ]
        let data = try JSONEncoder().encode(legacyCustomRules)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertEqual(canonicalizer.canonicalize("open simux"), "open MUX")
        XCTAssertEqual(canonicalizer.canonicalize("edit agents dot md"), "edit AGENTS.md")
    }

    func testCanonicalizerSavesEmptyRuleList() {
        let suiteName = "EposTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptCanonicalizer.saveRules([], to: defaults)

        XCTAssertNotNil(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey))
        XCTAssertTrue(TranscriptCanonicalizer.rules(from: defaults).isEmpty)
        XCTAssertEqual(TranscriptCanonicalizer.load(from: defaults).canonicalize("open siemux"), "open siemux")
    }

    @MainActor
    func testCorrectionStorePersistsAndCanonicalizesWithSavedRules() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        store.save([.init(canonical: "WidgetPro", aliases: ["widget pro"])])

        // Live instance reflects the save without a reload.
        XCTAssertEqual(store.canonicalize("open widget pro"), "open WidgetPro")
        // A fresh store over the same defaults loads the persisted rule.
        XCTAssertEqual(CorrectionStore(defaults: defaults).canonicalize("open widget pro"), "open WidgetPro")
    }

    func testRecordingIndicatorMeterRespondsToSpeechRange() {
        let quietHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.005) }
        let speechHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.03) }
        let loudHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.08) }

        XCTAssertGreaterThan(speechHeights.reduce(0, +), quietHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.reduce(0, +), speechHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.max() ?? 0, quietHeights.max() ?? 0)
    }

    func testInlineStatusIndicatorOmitsTranscript() {
        let transcript = "native partial text stays in the focused field"

        let preview = RecordingIndicatorSurface.presentation(
            mode: .transcriptPreview,
            transcript: transcript
        )
        XCTAssertEqual(preview.transcriptText, transcript)
        XCTAssertGreaterThanOrEqual(preview.minWidth, 260)

        let inline = RecordingIndicatorSurface.presentation(
            mode: .inlineStatus,
            transcript: transcript
        )
        XCTAssertNil(inline.transcriptText)
        XCTAssertLessThanOrEqual(inline.minWidth, 120)
        XCTAssertLessThanOrEqual(inline.maxWidth, 160)
    }

    func testRecordingIndicatorKeepsRecentTranscriptVisible() {
        let transcript = "open the project and run the full test suite then summarize the last failure in the final response"
        let display = RecordingIndicatorSurface.recentDisplayText(transcript, maxCharacters: 54)

        XCTAssertTrue(display.hasPrefix("..."))
        XCTAssertFalse(display.contains("open the project"))
        XCTAssertTrue(display.contains("last failure in the final response"))
    }

    func testRecordingIndicatorDefaultPreviewKeepsNewestText() {
        let transcript = (0..<80).map { "word\($0)" }.joined(separator: " ")
        let display = RecordingIndicatorSurface.recentDisplayText(transcript)

        XCTAssertTrue(display.hasPrefix("..."))
        XCTAssertFalse(display.contains("word0 word1 word2"))
        XCTAssertTrue(display.contains("word77 word78 word79"))
    }

    func testDiagnosticLogSinkWritesDirectFile() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "hello\tworld\nnext")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\ttest\thello world next"))
    }

    func testDiagnosticLogSinkCanBeDisabled() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: false),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "ignored")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testDogfoodTapDiscardsRecordingWhenTranscriptIsEmpty() throws {
        let directory = try makeTemporaryDirectory()
        let tap = DogfoodTap(recordingsDirectory: directory)
        tap.write(try makePCMBuffer())
        tap.stop(keeping: false)
        tap.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testDogfoodTapKeepsRecordingWhenTranscriptExists() throws {
        let directory = try makeTemporaryDirectory()
        let tap = DogfoodTap(recordingsDirectory: directory)
        tap.write(try makePCMBuffer())
        tap.stop(keeping: true)
        tap.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.filter { $0.pathExtension == "wav" }.count, 1)
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
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("EposTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePCMBuffer() throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else {
        throw XCTSkip("Unable to create PCM buffer")
    }
    buffer.frameLength = 128
    if let samples = buffer.floatChannelData?[0] {
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.01
        }
    }
    return buffer
}

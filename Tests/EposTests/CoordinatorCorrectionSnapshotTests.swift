import AVFoundation
import XCTest
@testable import Epos

@MainActor
final class CoordinatorCorrectionSnapshotTests: XCTestCase {
    func testEditsDuringRecordingApplyToTheNextRecordingAndKeepOriginalEvidence() async throws {
        let suite = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrections = CorrectionStore(defaults: defaults)
        let originalRules = [
            rule("first", canonical: "bar", alias: "foo"),
            rule("second", canonical: "Baz", alias: "bar"),
            rule("long", canonical: "WidgetPro", alias: "widget pro"),
            rule("short", canonical: "Widget", alias: "widget")
        ]
        corrections.saveEditorRecords(originalRules)
        let evidence = CorrectionEvidenceStore(defaults: defaults)
        let transcriber = FakeTranscriber()
        let microphone = FakeMicrophoneCapture()
        let backend = RecordingTextInsertionBackend()
        let raw = "um open foo and widget pro 1st"
        transcriber.finalTranscriptOnFinish = raw
        let coordinator = AppCoordinator(
            audio: microphone,
            transcriber: transcriber,
            textInsertion: backend,
            insertionTargetObserverFactory: { SnapshotInsertionTarget() },
            settings: Settings(saveCorrectionEvidence: true),
            settingsDefaults: defaults,
            permissions: .stub(),
            corrections: corrections,
            correctionEvidence: evidence,
            observedEditCaptureDelays: [],
            inlinePreviewEnabled: false,
            autoStart: false
        )
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        coordinator.captureFormat = format
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160

        coordinator.startRecording()
        corrections.saveEditorRecords([
            rule("first", canonical: "NewName", alias: "foo"),
            originalRules[1],
            rule("new-long", canonical: "NewWidget", alias: "widget pro"),
            originalRules[3]
        ])
        // The edit changes both the output and a winning rule's identity. A live
        // dictionary read at delivery would misattribute this first recording.
        XCTAssertEqual(corrections.canonicalize(raw), "um open NewName and NewWidget 1st")
        coordinator.handlePartialTranscript(raw)
        XCTAssertEqual(coordinator.displayText, "open bar and WidgetPro first")
        microphone.onBuffer?(buffer)
        coordinator.finishRecording()
        await coordinator.transcriptionTask?.value

        XCTAssertEqual(backend.insertedTexts, ["open bar and WidgetPro first"])
        let first = try XCTUnwrap(evidence.evidence.first)
        XCTAssertEqual(first.rawTranscript, raw)
        XCTAssertEqual(first.canonicalizedTranscript, "um open bar and WidgetPro 1st")
        XCTAssertEqual(first.finalInsertedTranscript, "open bar and WidgetPro first")
        XCTAssertEqual(first.appliedRuleIDs, ["long", "first"])

        coordinator.startRecording()
        microphone.onBuffer?(buffer)
        coordinator.finishRecording()
        await coordinator.transcriptionTask?.value

        XCTAssertEqual(backend.insertedTexts, ["open bar and WidgetPro first", "open NewName and NewWidget first"])
        XCTAssertEqual(evidence.evidence.count, 2)
        let second = try XCTUnwrap(evidence.evidence.last)
        XCTAssertEqual(second.canonicalizedTranscript, "um open NewName and NewWidget 1st")
        XCTAssertEqual(second.appliedRuleIDs, ["new-long", "first"])
    }

    private func rule(_ id: String, canonical: String, alias: String) -> CorrectionRecord {
        CorrectionRecord(
            id: id,
            kind: .replacement,
            canonical: canonical,
            aliases: [alias],
            source: .manual,
            status: .active
        )
    }
}

private final class SnapshotInsertionTarget: InsertionTargetObserver {
    func captureBaseline() {}
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { false }
    func observedValue() -> String? { nil }
    func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    func requiresTextContextValidation() -> Bool { false }
    func baselineInsertionContext() -> InsertionTargetContext? { nil }
    func targetApplicationBundleIdentifier() -> String? { "com.example.editor" }
    func targetWindowTitle() -> String? { nil }
}

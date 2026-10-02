#if DEBUG
import Epos
import Foundation
import XCTest
@testable import EposEval

final class ApplePresetEvalSnapshotTests: XCTestCase {
    func testProductionReplayReceivesCanonicalVocabularyFromTheFrozenDictionary() async throws {
        var dictionary = CorrectionDictionary(records: [record(canonical: "WidgetPro", alias: "widget bro")])
        let snapshot = try ApplePresetEvalSnapshot(dictionary: dictionary)
        dictionary.records = [record(canonical: "NewWidget", alias: "widget bro")]

        let transcript = try await snapshot.transcribe(
            recording: URL(fileURLWithPath: "synthetic.wav"),
            locale: Locale(identifier: "en-US"),
            arm: .baseline
        ) { _, _, arm, context in
            XCTAssertEqual(arm, .speechProgressiveFast)
            XCTAssertEqual(context, ["Epos", "WidgetPro"])
            XCTAssertFalse(context.contains("widget bro"))
            return ApplePresetTranscription(text: "open widget bro", contextReadback: context)
        }

        XCTAssertEqual(snapshot.canonicalizer.canonicalize(transcript.text), "open WidgetPro")
        XCTAssertNotEqual(
            snapshot.dictionaryFingerprint,
            try ApplePresetEvalSnapshot(dictionary: dictionary).dictionaryFingerprint
        )
    }

    func testControlArmsRemainUnhinted() async throws {
        let snapshot = try ApplePresetEvalSnapshot(
            dictionary: CorrectionDictionary(records: [record(canonical: "WidgetPro", alias: "widget bro")])
        )
        for arm in ApplePresetArm.allCases where arm != .baseline {
            _ = try await snapshot.transcribe(
                recording: URL(fileURLWithPath: "synthetic.wav"),
                locale: Locale(identifier: "en-US"),
                arm: arm
            ) { _, _, actualArm, context in
                XCTAssertEqual(actualArm, arm)
                XCTAssertEqual(context, [])
                return ApplePresetTranscription(text: "control transcript", contextReadback: [])
            }
        }
    }

    func testMissingContextReadbackRefusesTheProductionReplay() async throws {
        let snapshot = try ApplePresetEvalSnapshot(dictionary: CorrectionDictionary(records: []))
        do {
            _ = try await snapshot.transcribe(
                recording: URL(fileURLWithPath: "synthetic.wav"),
                locale: Locale(identifier: "en-US"),
                arm: .baseline
            ) { _, _, _, _ in ApplePresetTranscription(text: "recognized", contextReadback: []) }
            XCTFail("a replay without its production context must not become a baseline")
        } catch ApplePresetContextError.readbackMismatch {
            // Recognition alone cannot prove that the requested context reached the analyzer.
        }
    }

    func testLegacyArtifactsDecodeWithoutNewProvenanceFields() throws {
        let body = #"{"arm":"speech-progressive-fast","configuration":"legacy unhinted preset","locale":"en-US","file":"synthetic.wav","audioSHA256":"0000000000000000000000000000000000000000000000000000000000000000","audioDurationSeconds":1,"humanIntendedTranscript":"hello","referenceDesignation":"legacy","transcript":"hello","transcriptScore":{"referenceWordCount":1,"comparedWordCount":1,"wordErrors":0,"substitutions":0,"insertions":0,"deletions":0,"wordErrorRate":0},"productionOutput":"hello","productionOutputTranscriptScore":{"referenceWordCount":1,"comparedWordCount":1,"wordErrors":0,"substitutions":0,"insertions":0,"deletions":0,"wordErrorRate":0},"elapsedSeconds":1}"#
        let row = try JSONDecoder().decode(ApplePresetEvalRow.self, from: Data(body.utf8))
        XCTAssertNil(row.evalProvenance)
        XCTAssertNil(row.contextualStrings)
        XCTAssertEqual(row.productionOutput, "hello")
        let report = ApplePresetEvalReport.render(
            rows: [row], enabledArms: [.baseline], unavailable: [:], expectedRowsPerArm: 1,
            outputURL: URL(fileURLWithPath: "synthetic.jsonl"),
            summaryURL: URL(fileURLWithPath: "synthetic.summary.txt")
        )
        XCTAssertTrue(report.contains("contextReadbackMatched=0"))
        XCTAssertTrue(report.contains("unrecorded in legacy artifact"))
    }

    private func record(canonical: String, alias: String) -> CorrectionRecord {
        CorrectionRecord(
            id: "manual.widget",
            kind: .replacement,
            canonical: canonical,
            aliases: [alias],
            source: .manual,
            status: .active
        )
    }
}
#endif

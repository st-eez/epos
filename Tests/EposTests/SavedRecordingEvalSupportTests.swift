import Foundation
import XCTest
@testable import Epos

final class SavedRecordingEvalSupportTests: XCTestCase {
    func testSelectedRecordingsUsesExplicitRecordingFilesInConfiguredOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeRecording("a.wav", in: directory)
        try makeRecording("b.wav", in: directory)
        try makeRecording("c.wav", in: directory)

        let selected = try SavedRecordingEvalSupport.selectedRecordings(
            in: directory,
            limit: 1,
            latest: false,
            environment: ["EPOS_EVAL_RECORDING_FILES": "b.wav, a.wav"]
        )

        XCTAssertEqual(selected.map(\.lastPathComponent), ["b.wav", "a.wav"])
    }

    func testSelectedRecordingsRejectsMissingExplicitRecording() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try SavedRecordingEvalSupport.selectedRecordings(
            in: directory,
            limit: nil,
            latest: false,
            environment: ["EPOS_EVAL_RECORDING_FILES": "missing.wav"]
        )) { error in
            XCTAssertTrue(String(describing: error).contains("recording not found"))
        }
    }

    func testGroundTruthManifestLoadsConfiguredJSONL() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("truth.jsonl")
        try """
        {"file":"a.wav","humanIntendedTranscript":"Ask Stath to review the CMOX changes."}
        {"file":"b.wav","humanIntendedTranscript":"Open cloud.md and update project.yml."}

        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let manifest = try SavedRecordingEvalSupport.groundTruthManifest(
            in: directory,
            environment: ["EPOS_EVAL_GROUND_TRUTH": manifestURL.path]
        )

        XCTAssertEqual(
            manifest.transcript(for: directory.appendingPathComponent("a.wav")),
            "Ask Stath to review the CMOX changes."
        )
        XCTAssertEqual(
            manifest.transcript(for: directory.appendingPathComponent("b.wav")),
            "Open cloud.md and update project.yml."
        )
    }

    func testGroundTruthManifestDefaultsToRecordingsDirectoryJSONLWhenPresent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        {"file":"a.wav","humanIntendedTranscript":"Use the default manifest."}
        """.write(to: directory.appendingPathComponent("ground-truth.jsonl"), atomically: true, encoding: .utf8)

        let manifest = try SavedRecordingEvalSupport.groundTruthManifest(in: directory, environment: [:])

        XCTAssertEqual(
            manifest.transcript(for: directory.appendingPathComponent("a.wav")),
            "Use the default manifest."
        )
    }

    func testGroundTruthManifestRejectsDuplicateFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("truth.jsonl")
        try """
        {"file":"a.wav","humanIntendedTranscript":"First."}
        {"file":"a.wav","humanIntendedTranscript":"Second."}
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SavedRecordingEvalSupport.groundTruthManifest(
            in: directory,
            environment: ["EPOS_EVAL_GROUND_TRUTH": manifestURL.path]
        )) { error in
            XCTAssertTrue(String(describing: error).contains("duplicate ground-truth transcript"))
        }
    }

    func testWordErrorScoreComputesSubstitutionWERAndAccuracy() {
        let score = PolishEvalScoring.wordErrorScore(
            reference: "Ask Stath to review the CMOX changes.",
            hypothesis: "Ask Stas to review the CMOX changes."
        )

        XCTAssertEqual(score.referenceWordCount, 7)
        XCTAssertEqual(score.comparedWordCount, 7)
        XCTAssertEqual(score.wordErrors, 1)
        XCTAssertEqual(score.substitutions, 1)
        XCTAssertEqual(score.insertions, 0)
        XCTAssertEqual(score.deletions, 0)
        XCTAssertEqual(score.wordErrorRate, 1.0 / 7.0, accuracy: 0.000_001)
        XCTAssertEqual(score.wordAccuracy, 6.0 / 7.0, accuracy: 0.000_001)
    }

    func testWordErrorScoreCountsInsertionsAndDeletions() {
        let insertion = PolishEvalScoring.wordErrorScore(
            reference: "Make two tickets.",
            hypothesis: "Make two tickets now."
        )
        let deletion = PolishEvalScoring.wordErrorScore(
            reference: "Make two tickets.",
            hypothesis: "Make tickets."
        )

        XCTAssertEqual(insertion.insertions, 1)
        XCTAssertEqual(insertion.wordErrors, 1)
        XCTAssertEqual(deletion.deletions, 1)
        XCTAssertEqual(deletion.wordErrors, 1)
    }

    func testWordErrorTokenizationKeepsDeveloperTokens() {
        XCTAssertEqual(
            PolishEvalScoring.wordErrorTokens("Open cloud.md, then /goal, $HOME, and --."),
            ["open", "cloud.md", "then", "/goal", "$home", "and", "--"]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRecording(_ name: String, in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(name))
    }
}

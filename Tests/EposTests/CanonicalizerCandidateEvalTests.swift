import Foundation
import XCTest
@testable import Epos

final class CanonicalizerCandidateEvalTests: XCTestCase {
    func testCandidateAgainstFrozenCorpus() throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_CORRECTION_EVAL"]) else {
            throw XCTSkip("Run scripts/correct with a candidate CorrectionRecord JSON file")
        }
        let candidateURL = try XCTUnwrap(environment["EPOS_CORRECTION_CANDIDATE"].map {
            URL(fileURLWithPath: $0)
        })
        let artifactURL = URL(fileURLWithPath: environment["EPOS_CORRECTION_EVAL_ARTIFACT"]
            ?? ".build/evals/corrected-apple-presets-signed-114.jsonl")
        let recordingsDirectory = SavedRecordingEvalSupport.recordingsDirectory(environment: environment)
        let manifest = try CandidateCorpusManifest.load(
            recordingsDirectory.appendingPathComponent("ground-truth.jsonl")
        )
        let rows = try CandidateCorpusRow.loadProductionArm(artifactURL)
        try CandidateCorpus.validate(rows: rows, manifest: manifest)
        let candidates = try JSONDecoder().decode(
            CandidatePayload.self,
            from: Data(contentsOf: candidateURL)
        ).records
        try CandidatePayload.validate(candidates)

        let baseline = TranscriptCanonicalizer()
        let variant = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(
                records: CorrectionDictionary.defaultRecords + candidates
            )
        )
        let evaluations = rows.map { row in
            CandidateEvaluation(
                row: row,
                slice: manifest.slice(for: row.file),
                baseline: TranscriptDeterministicCleaner.streamClean(
                    baseline.canonicalize(row.transcript)
                ),
                variant: TranscriptDeterministicCleaner.streamClean(
                    variant.canonicalize(row.transcript)
                )
            )
        }
        let verdict = CandidateVerdict(evaluations: evaluations)
        print(verdict.report(candidates: candidates, artifact: artifactURL))

        XCTAssertGreaterThan(
            verdict.confirmedHoldoutRows,
            0,
            "candidate promotion disabled: no human-confirmed holdout rows"
        )
        XCTAssertFalse(verdict.changed.isEmpty, "candidate is a no-op on the frozen corpus")
        XCTAssertEqual(
            verdict.developmentRegressions,
            0,
            "candidate regressed confirmed development rows"
        )
        XCTAssertEqual(verdict.holdoutRegressions, 0, "candidate regressed holdout rows")
        XCTAssertGreaterThan(verdict.holdoutWins, 0, "candidate has no holdout win")
    }

    func testVerdictRequiresHoldoutWinWithoutRegressions() {
        let safe = [
            CandidateEvaluation.synthetic(slice: .development, before: 1, after: 1),
            CandidateEvaluation.synthetic(slice: .holdout, before: 1, after: 0),
        ]
        let regressing = safe + [
            CandidateEvaluation.synthetic(slice: .development, before: 0, after: 1),
            CandidateEvaluation.synthetic(slice: .holdout, before: 0, after: 1),
        ]
        let inferredOnlyWin = [
            CandidateEvaluation.synthetic(slice: .development, before: 1, after: 1),
            CandidateEvaluation.synthetic(slice: .reviewOnly, before: 1, after: 0),
        ]

        XCTAssertTrue(CandidateVerdict(evaluations: safe).passes)
        XCTAssertFalse(CandidateVerdict(evaluations: regressing).passes)
        XCTAssertFalse(CandidateVerdict(evaluations: inferredOnlyWin).passes)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).baselineWordErrors, 2)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).variantWordErrors, 1)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).baselineExactRows, 0)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).variantExactRows, 1)
    }

    func testLegacyManifestPartitionHasNoConfirmedHoldout() {
        let files = (1...114).map { "sample-\($0).wav" }
        let manifest = CandidateCorpusManifest(
            orderedFiles: files,
            transcripts: Dictionary(
                uniqueKeysWithValues: files.map { ($0, "reference") }
            )
        )

        XCTAssertEqual(manifest.slice(for: files[34]), .development)
        XCTAssertEqual(manifest.slice(for: files[35]), .reviewOnly)
        XCTAssertFalse(files.contains { manifest.slice(for: $0) == .holdout })
    }

    func testCandidateValidationRejectsBuiltInIDCollision() {
        var colliding = CorrectionDictionary.defaultRecords[0]
        colliding.source = .manual

        XCTAssertThrowsError(try CandidatePayload.validate([colliding])) { error in
            XCTAssertEqual(error as? CandidateEvalError, .candidateIDCollidesWithBuiltIn)
        }
    }
}

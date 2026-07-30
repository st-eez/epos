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
            ?? ".build/evals/apple-presets-signed-confirmed75.jsonl")
        let rows = try CandidateCorpusRow.loadProductionArm(artifactURL)
        try CandidateCorpus.validate(rows: rows)
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
        let developmentOnlyWin = [
            CandidateEvaluation.synthetic(slice: .development, before: 1, after: 0),
        ]

        XCTAssertTrue(CandidateVerdict(evaluations: safe).passes)
        XCTAssertFalse(CandidateVerdict(evaluations: regressing).passes)
        XCTAssertFalse(CandidateVerdict(evaluations: developmentOnlyWin).passes)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).baselineWordErrors, 2)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).variantWordErrors, 1)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).baselineExactRows, 0)
        XCTAssertEqual(CandidateVerdict(evaluations: safe).variantExactRows, 1)
    }

    func testCorpusValidationRequiresTheConfirmedSeventyFiveShape() throws {
        XCTAssertNoThrow(try CandidateCorpus.validate(rows: Self.confirmedRows()))

        let short = Array(Self.confirmedRows().dropLast())
        let missingHoldout = short
        let duplicatedFile = short + [Self.row(slice: .holdout, index: 0)]
        let failedRow = short + [Self.row(slice: .holdout, index: 99, error: "recognition failed")]
        let emptyTranscript = short + [Self.row(slice: .holdout, index: 99, transcript: "")]

        for invalid in [missingHoldout, duplicatedFile, failedRow, emptyTranscript] {
            XCTAssertThrowsError(try CandidateCorpus.validate(rows: invalid)) { error in
                XCTAssertEqual(error as? CandidateEvalError, .invalidCorpus)
            }
        }
    }

    func testProductionArmRowsCarryArtifactDesignations() throws {
        let artifact = FileManager.default.temporaryDirectory
            .appendingPathComponent("candidate-designations-\(UUID().uuidString).jsonl")
        try """
        {"arm":"speech-progressive-fast","file":"a.wav","referenceDesignation":"legacy",\
        "humanIntendedTranscript":"right","transcript":"wrong","error":null}
        {"arm":"speech-progressive-fast","file":"b.wav","referenceDesignation":"holdout",\
        "humanIntendedTranscript":"right","transcript":"wrong","error":null}
        {"arm":"speech-volatile","file":"c.wav","referenceDesignation":"holdout",\
        "humanIntendedTranscript":"right","transcript":"wrong","error":null}
        """.write(to: artifact, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: artifact) }

        let rows = try CandidateCorpusRow.loadProductionArm(artifact)

        XCTAssertEqual(rows.map(\.file), ["a.wav", "b.wav"])
        XCTAssertEqual(rows.map(\.referenceDesignation), [.development, .holdout])
    }

    private static func confirmedRows() -> [CandidateCorpusRow] {
        (0..<CandidateCorpus.expectedDevelopmentRows).map { row(slice: .development, index: $0) }
            + (0..<CandidateCorpus.expectedHoldoutRows).map { row(slice: .holdout, index: $0) }
    }

    private static func row(
        slice: CandidateSlice,
        index: Int,
        transcript: String = "wrong",
        error: String? = nil
    ) -> CandidateCorpusRow {
        CandidateCorpusRow(
            arm: "speech-progressive-fast",
            file: "\(slice.rawValue)-\(index).wav",
            referenceDesignation: slice,
            humanIntendedTranscript: "right",
            transcript: transcript,
            error: error
        )
    }

    func testCandidateValidationRejectsBuiltInIDCollision() {
        var colliding = CorrectionDictionary.defaultRecords[0]
        colliding.source = .manual

        XCTAssertThrowsError(try CandidatePayload.validate([colliding])) { error in
            XCTAssertEqual(error as? CandidateEvalError, .candidateIDCollidesWithBuiltIn)
        }
    }
}

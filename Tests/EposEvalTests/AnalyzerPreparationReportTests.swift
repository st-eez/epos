import Foundation
import XCTest
@testable import EposEval

final class AnalyzerPreparationReportTests: XCTestCase {
    func testFirstResultComparisonPairsTheSameRecordingAndRepeat() {
        let rows = [
            row(arm: .unprepared, repeatIndex: 0, firstResult: 100),
            row(arm: .inline, repeatIndex: 0, firstResult: 300),
            row(arm: .unprepared, repeatIndex: 1, firstResult: 200),
            row(arm: .inline, repeatIndex: 1, firstResult: 150),
            row(arm: .unprepared, repeatIndex: 2, firstResult: 1_000),
            row(arm: .inline, repeatIndex: 2, firstResult: 250),
        ]
        let report = AnalyzerPreparationEvalReport.render(rows: rows, output: URL(fileURLWithPath: "/tmp/eval.jsonl"))
        XCTAssertTrue(report.contains("paired median first-result delta from unprepared ms=-50.000"))
        XCTAssertTrue(report.contains("output differences from matching unprepared trials=0"))
    }

    private func row(
        arm: AnalyzerPreparationArm, repeatIndex: Int, firstResult: Double
    ) -> AnalyzerPreparationEvalRow {
        let score = WordErrorScoring.score(reference: "hello", hypothesis: "hello")
        return AnalyzerPreparationEvalRow(
            trialOrdinal: repeatIndex * 2 + (arm == .unprepared ? 1 : 2), repeatIndex: repeatIndex, arm: arm,
            file: "same.wav", audioSHA256: String(repeating: "0", count: 64),
            referenceDesignation: .legacy, reference: "hello", correctionDictionaryFingerprint: String(repeating: "1", count: 64),
            correctionDictionaryRecords: [],
            contextualStrings: ["Epos"], contextReadback: ["Epos"], evalProvenance: nil,
            locale: "en-US", audioDurationSeconds: 1,
            metrics: AnalyzerPreparationMetrics(
                preparationMilliseconds: 0, setupBeforeHoldMilliseconds: 0, idleSeconds: 0,
                analyzerStartMilliseconds: 0, holdToFirstResultMilliseconds: firstResult,
                inputToFirstResultMilliseconds: firstResult, releaseToFinalMilliseconds: 0,
                holdToCompletionMilliseconds: firstResult + 1_000,
                expectedAudioFrames: 1_000, submittedAudioFrames: 1_000, consumedAudioFrames: 1_000,
                rssBeforeSetupBytes: nil, rssAtReadinessBytes: nil, rssAfterIdleBytes: nil
            ),
            rssAfterCleanupBytes: nil, transcript: "hello", productionOutput: "hello",
            transcriptScore: score, productionOutputScore: score, error: nil
        )
    }
}

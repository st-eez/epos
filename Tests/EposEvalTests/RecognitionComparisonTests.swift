import Epos
import XCTest
@testable import EposEval

final class RecognitionComparisonTests: XCTestCase {
    func testCandidatesChangeExactlyOneProductionOption() {
        let baseline = Transcriber.speechPreset
        XCTAssertEqual(AnalyzerPreparationArm.unprepared.preset, baseline)
        let noFast = AnalyzerPreparationArm.noFastResults.preset
        XCTAssertEqual(noFast.transcriptionOptions, baseline.transcriptionOptions)
        XCTAssertEqual(noFast.attributeOptions, baseline.attributeOptions)
        XCTAssertEqual(noFast.reportingOptions, baseline.reportingOptions.subtracting([.fastResults]))
        XCTAssertTrue(noFast.reportingOptions.contains(.volatileResults))
        let noConfidence = AnalyzerPreparationArm.noConfidence.preset
        XCTAssertEqual(noConfidence.transcriptionOptions, baseline.transcriptionOptions)
        XCTAssertEqual(noConfidence.reportingOptions, baseline.reportingOptions)
        XCTAssertEqual(noConfidence.attributeOptions, baseline.attributeOptions.subtracting([.transcriptionConfidence]))
    }

    func testPreparationDefaultsStaySeparateFromExplicitRecognitionComparison() throws {
        XCTAssertEqual(try SignedAnalyzerPreparationEvalHost.configuredArms(environment: [:]),
                       [.unprepared, .inline, .advance])
        let arms = try SignedAnalyzerPreparationEvalHost.configuredArms(environment: [
            "EPOS_PREPARE_ARMS": "unprepared,no-fast-results,no-confidence"
        ])
        XCTAssertEqual(arms, [.unprepared, .noFastResults, .noConfidence])
        XCTAssertEqual(SignedAnalyzerPreparationEvalHost.rotatedArms(arms, by: 1),
                       [.noFastResults, .noConfidence, .unprepared])
        XCTAssertEqual(SignedAnalyzerPreparationEvalHost.rotatedArms(arms, by: 2),
                       [.noConfidence, .unprepared, .noFastResults])
        XCTAssertEqual(SignedAnalyzerPreparationEvalHost.rotatedArms(arms, by: 3), arms)
        XCTAssertEqual(try SignedAnalyzerPreparationEvalHost.configuredArms(environment: [
            "EPOS_PREPARE_ONLY_ARM": "advance"
        ]), [.advance])
    }

    func testInvalidArmSelectionFailsInsteadOfSilentlyRunningAnotherComparison() {
        for value in ["", "unprepared,", "missing", "unprepared,unprepared"] {
            XCTAssertThrowsError(try SignedAnalyzerPreparationEvalHost.configuredArms(environment: [
                "EPOS_PREPARE_ARMS": value
            ]))
        }
        XCTAssertThrowsError(try SignedAnalyzerPreparationEvalHost.configuredArms(environment: [
            "EPOS_PREPARE_ARMS": "unprepared,no-confidence", "EPOS_PREPARE_ONLY_ARM": "unprepared"
        ]))
    }

    func testDevelopmentSelectionExcludesHoldoutAndPreservesOrder() throws {
        let entries = [entry("holdout.wav", .holdout), entry("first.wav", .legacy), entry("last.wav", .legacy)]
        XCTAssertEqual(try SignedAnalyzerPreparationEvalHost.selectedEntries(entries, designation: "legacy").map(\.file),
                       ["first.wav", "last.wav"])
        XCTAssertEqual(try SignedAnalyzerPreparationEvalHost.selectedEntries(entries, designation: "holdout").map(\.file),
                       ["holdout.wav"])
        XCTAssertEqual(try SignedAnalyzerPreparationEvalHost.selectedEntries(entries, designation: nil).count, 3)
        XCTAssertThrowsError(try SignedAnalyzerPreparationEvalHost.selectedEntries(entries, designation: "unknown"))
    }

    func testFirstUsefulResultExcludesFillersRemovedByProductionCleanup() {
        let timeline = RecognitionReplayTimeline(releaseMilliseconds: 1_000, events: [
            .init(milliseconds: 100, isFinal: false, text: "um"),
            .init(milliseconds: 200, isFinal: true, text: "uh "),
            .init(milliseconds: 300, isFinal: false, text: "hello"),
            .init(milliseconds: 400, isFinal: true, text: "hello there")
        ])
        XCTAssertEqual(timeline.firstUsefulResultMilliseconds(canonicalizer: .init(rules: [])), 300)
        XCTAssertNil(RecognitionReplayTimeline(releaseMilliseconds: 1_000, events: [
            .init(milliseconds: 100, isFinal: true, text: "um")
        ]).firstUsefulResultMilliseconds(canonicalizer: .init(rules: [])))
    }

    private func entry(_ file: String, _ designation: ReferenceDesignation) -> ConfirmedEvalCorpus.Entry {
        .init(file: file, audioSHA256: String(repeating: "0", count: 64), reference: "hello", designation: designation)
    }
}

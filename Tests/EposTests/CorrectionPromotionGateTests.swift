import XCTest
@testable import Epos

final class CorrectionPromotionGateTests: XCTestCase {
    func testPromotionGateBlocksUntilSuggestionRecurs() throws {
        let singleEvidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: singleEvidence).first)

        let singleAssessment = CorrectionPromotionGate.assess(record: record, evidence: singleEvidence)

        XCTAssertFalse(singleAssessment.canPromote)
        XCTAssertEqual(singleAssessment.positiveEvidenceIDs, ["one"])
        XCTAssertEqual(singleAssessment.blockers, [.insufficientRecurrence])

        let repeatedEvidence = singleEvidence + [
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let repeatedAssessment = CorrectionPromotionGate.assess(record: record, evidence: repeatedEvidence)
        let promoted = try XCTUnwrap(repeatedAssessment.promotedRecord)

        XCTAssertTrue(repeatedAssessment.canPromote)
        XCTAssertEqual(repeatedAssessment.positiveEvidenceIDs, ["one", "two"])
        XCTAssertEqual(promoted.status, .active)
        XCTAssertEqual(
            TranscriptCanonicalizer(
                rules: CorrectionRuleCompiler.compile(records: [promoted])
            ).canonicalize("open widget pro"),
            "open WidgetPro"
        )
    }

    func testPromotionGateDoesNotCountDuplicateEvidenceAsRecurrence() throws {
        let duplicateEvidence = [
            editedEvidence(id: "dup", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "dup", final: "open widget pro", edited: "open WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: duplicateEvidence).first)

        let assessment = CorrectionPromotionGate.assess(record: record, evidence: duplicateEvidence)

        XCTAssertFalse(assessment.canPromote)
        XCTAssertEqual(assessment.positiveEvidenceIDs, ["dup"])
        XCTAssertEqual(assessment.blockers, [.insufficientRecurrence])
        XCTAssertNil(assessment.promotedRecord)
    }

    func testPromotionGateBlocksExplicitNegativeExamples() throws {
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro"),
            editedEvidence(id: "no-change", final: "compare widget pro", edited: "compare widget pro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)

        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertFalse(assessment.canPromote)
        XCTAssertEqual(assessment.negativeEvidenceIDs, ["no-change"])
        XCTAssertTrue(assessment.blockers.contains(.negativeExamples))
        XCTAssertNil(assessment.promotedRecord)
    }

    func testPromotionGateBlocksAmbiguousShortPhrases() throws {
        let evidence = [
            editedEvidence(id: "one", final: "open db", edited: "open Database"),
            editedEvidence(id: "two", final: "launch db", edited: "launch Database")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)

        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertEqual(assessment.phraseRisk, .high)
        XCTAssertTrue(assessment.blockers.contains(.highPhraseRisk))
        XCTAssertFalse(assessment.canPromote)
    }

    func testPromotionGateBlocksLockedBaselineRegressions() throws {
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)

        let assessment = CorrectionPromotionGate.assess(
            record: record,
            evidence: evidence,
            activeRecords: [],
            lockedBaselineTexts: ["compare widget pro"]
        )

        XCTAssertEqual(assessment.lockedBaselineRegressions, ["compare widget pro"])
        XCTAssertTrue(assessment.blockers.contains(.lockedBaselineRegression))
        XCTAssertFalse(assessment.canPromote)
    }

    func testPromotionGateScoresSingleAppEvidenceAsMediumScopeRisk() throws {
        let evidence = [
            editedEvidence(
                id: "one",
                final: "open widget pro",
                edited: "open WidgetPro",
                applicationBundleIdentifier: "com.example.app"
            ),
            editedEvidence(
                id: "two",
                final: "launch widget pro",
                edited: "launch WidgetPro",
                applicationBundleIdentifier: "com.example.app"
            )
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)

        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertEqual(assessment.scopeRisk, .medium)
        XCTAssertTrue(assessment.canPromote)
    }

    func testPromotionGateBlocksConflictingCanonicalSuggestions() throws {
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro"),
            editedEvidence(id: "conflict", final: "compare widget pro", edited: "compare Widget Professional")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)

        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertEqual(assessment.conflictingEvidenceIDs, ["conflict"])
        XCTAssertEqual(assessment.scopeRisk, .high)
        XCTAssertTrue(assessment.blockers.contains(.conflictingSuggestions))
        XCTAssertTrue(assessment.blockers.contains(.highScopeRisk))
        XCTAssertFalse(assessment.canPromote)
    }

    func testEvidenceStoreExposesPromotionAssessmentsForSuggestions() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionEvidenceStore(defaults: defaults)
        store.record(editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"))
        store.record(editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro"))

        let assessment = try XCTUnwrap(store.promotionAssessments.first)

        XCTAssertEqual(assessment.record.id, "suggested.widget-pro.to-widgetpro")
        XCTAssertTrue(assessment.canPromote)
        XCTAssertEqual(assessment.positiveEvidenceIDs, ["one", "two"])
    }

    private func editedEvidence(
        id: String,
        final: String,
        edited: String,
        applicationBundleIdentifier: String? = nil
    ) -> CorrectionEvidence {
        CorrectionEvidence(
            id: id,
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: id,
            rawTranscript: final,
            canonicalizedTranscript: final,
            finalInsertedTranscript: final,
            userEditedTranscript: edited,
            applicationBundleIdentifier: applicationBundleIdentifier,
            appliedRuleIDs: []
        )
    }
}

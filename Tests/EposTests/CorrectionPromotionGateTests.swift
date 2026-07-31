import XCTest
@testable import Epos

final class CorrectionPromotionGateTests: XCTestCase {
    func testPromotionGateBlocksUntilSuggestionRecurs() throws {
        let singleEvidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: singleEvidence).first)

        let singleAssessment = assess(record: record, evidence: singleEvidence)

        XCTAssertFalse(singleAssessment.canPromote)
        XCTAssertEqual(singleAssessment.positiveEvidenceIDs, ["one"])
        XCTAssertEqual(singleAssessment.blockers, [.insufficientRecurrence])

        let repeatedEvidence = singleEvidence + [
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let repeatedAssessment = assess(record: record, evidence: repeatedEvidence)
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

        let assessment = assess(record: record, evidence: duplicateEvidence)

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

        let assessment = assess(record: record, evidence: evidence)

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

        let assessment = assess(record: record, evidence: evidence)

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
            lockedBaseline: .confirmed(["compare widget pro"])
        )

        XCTAssertEqual(assessment.lockedBaselineRegressions, ["compare widget pro"])
        XCTAssertTrue(assessment.blockers.contains(.lockedBaselineRegression))
        XCTAssertFalse(assessment.canPromote)
    }

    func testPromotionGateBlocksWhenTheLockedBaselineCannotBeRead() throws {
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)

        let assessment = CorrectionPromotionGate.assess(
            record: record,
            evidence: evidence,
            activeRecords: [],
            lockedBaseline: .unavailable("ground-truth.jsonl is missing or unreadable")
        )

        XCTAssertEqual(assessment.blockers, [.lockedBaselineUnavailable])
        XCTAssertFalse(assessment.canPromote)
        XCTAssertNil(assessment.promotedRecord)
    }

    func testLockedBaselineLoadFailsClosedOnAnIncompleteCorpus() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("epos-locked-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            CorrectionLockedBaseline.load(recordingsDirectory: directory),
            .unavailable("ground-truth.jsonl is missing or unreadable")
        )

        let manifest = directory.appendingPathComponent("ground-truth.jsonl")
        let confirmedRow = #"{"file":"a.wav","humanIntendedTranscript":"the codebase is fine"}"#
        try Array(repeating: confirmedRow, count: 3)
            .joined(separator: "\n")
            .write(to: manifest, atomically: true, encoding: .utf8)

        // Too few legacy rows: the frozen migration promises 35 human-confirmed ones, so
        // a short manifest means the corpus is not the one the gate is meant to protect.
        XCTAssertEqual(
            CorrectionLockedBaseline.load(recordingsDirectory: directory),
            .unavailable("ground-truth.jsonl has 3 rows, expected at least 35")
        )

        try Array(repeating: confirmedRow, count: CorrectionLockedBaseline.humanConfirmedLegacyRowCount)
            .joined(separator: "\n")
            .write(to: manifest, atomically: true, encoding: .utf8)

        // Legacy rows alone are not the bar: promotion needs the holdout too.
        XCTAssertEqual(
            CorrectionLockedBaseline.load(recordingsDirectory: directory),
            .unavailable("holdout-confirmations.jsonl is missing or unreadable")
        )

        try #"{"file":"b.wav","humanIntendedTranscript":"open the Epos app"}"#
            .write(
                to: directory.appendingPathComponent("holdout-confirmations.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        XCTAssertEqual(
            CorrectionLockedBaseline.load(recordingsDirectory: directory),
            .confirmed(
                Array(repeating: "the codebase is fine", count: 35) + ["open the Epos app"]
            )
        )
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

        let assessment = assess(record: record, evidence: evidence)

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

        let assessment = assess(record: record, evidence: evidence)

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

        let assessment = try XCTUnwrap(
            store.promotionAssessments(
                activeRecords: CorrectionDictionary.defaultRecords,
                lockedBaseline: .confirmed(["nothing this alias touches"])
            ).first
        )

        XCTAssertEqual(assessment.record.id, "suggested.widget-pro.to-widgetpro")
        XCTAssertTrue(assessment.canPromote)
        XCTAssertEqual(assessment.positiveEvidenceIDs, ["one", "two"])
    }

    /// The scenarios above each isolate one evidence-derived blocker, so they score
    /// against an empty dictionary and a locked baseline the candidate cannot touch.
    private func assess(
        record: CorrectionRecord,
        evidence: [CorrectionEvidence]
    ) -> CorrectionPromotionAssessment {
        CorrectionPromotionGate.assess(
            record: record,
            evidence: evidence,
            activeRecords: [],
            lockedBaseline: .confirmed(["nothing this alias touches"])
        )
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

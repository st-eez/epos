import XCTest
@testable import Epos

final class CorrectionSuggestionReviewTests: XCTestCase {
    @MainActor
    func testReviewItemsExposeAcceptableAndBlockedSuggestions() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults, lockedBaseline: .confirmed(lockedBaselineTexts))
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro"),
            editedEvidence(id: "three", final: "open db", edited: "open Database"),
            editedEvidence(id: "four", final: "launch db", edited: "launch Database")
        ]
        let assessments = CorrectionCandidateSuggester.suggestedRecords(from: evidence).map { record in
            CorrectionPromotionGate.assess(
                record: record,
                evidence: evidence,
                activeRecords: store.dictionary.records,
                lockedBaseline: .confirmed(lockedBaselineTexts)
            )
        }

        let items = CorrectionSuggestionReviewItem.items(
            assessments: assessments,
            evidence: evidence,
            resolvedRecordIDs: store.resolvedSuggestionRecordIDs
        )

        XCTAssertEqual(items.map(\.id), ["suggested.widget-pro.to-widgetpro", "suggested.db.to-database"])
        XCTAssertEqual(items.first?.heardPhrase, "widget pro")
        XCTAssertEqual(items.first?.replacementText, "WidgetPro")
        XCTAssertEqual(items.first?.positiveEvidenceCount, 2)
        XCTAssertTrue(try XCTUnwrap(items.first).canAccept)
        XCTAssertFalse(try XCTUnwrap(items.last).canAccept)
        XCTAssertEqual(items.last?.blockerNames, ["highPhraseRisk"])
    }

    @MainActor
    func testReviewItemsHideAcceptedAndRejectedSuggestions() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults, lockedBaseline: .confirmed(lockedBaselineTexts))
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro"),
            editedEvidence(id: "three", final: "open db", edited: "open Database"),
            editedEvidence(id: "four", final: "launch db", edited: "launch Database")
        ]
        let assessments = CorrectionCandidateSuggester.suggestedRecords(from: evidence).map { record in
            CorrectionPromotionGate.assess(
                record: record,
                evidence: evidence,
                activeRecords: store.dictionary.records,
                lockedBaseline: .confirmed(lockedBaselineTexts)
            )
        }
        let acceptable = try XCTUnwrap(assessments.first { $0.record.id == "suggested.widget-pro.to-widgetpro" })
        let blocked = try XCTUnwrap(assessments.first { $0.record.id == "suggested.db.to-database" })

        XCTAssertTrue(store.acceptPromotion(acceptable))
        XCTAssertTrue(store.rejectSuggestion(blocked))

        let items = CorrectionSuggestionReviewItem.items(
            assessments: assessments,
            evidence: evidence,
            resolvedRecordIDs: store.resolvedSuggestionRecordIDs
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testReviewItemsExposeEvidenceAndRiskSummary() throws {
        let finalText = "open widget pro " + String(repeating: "inside a long review sentence ", count: 8)
        let editedText = "open WidgetPro " + String(repeating: "inside a long review sentence ", count: 8)
        let evidence = [
            editedEvidence(
                id: "one",
                final: finalText,
                edited: editedText,
                bundleID: "com.example.editor",
                windowTitle: "Draft.md"
            ),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)
        let assessment = CorrectionPromotionGate.assess(
            record: record,
            evidence: evidence,
            activeRecords: [],
            lockedBaseline: .confirmed(lockedBaselineTexts)
        )

        let item = try XCTUnwrap(CorrectionSuggestionReviewItem.items(
            assessments: [assessment],
            evidence: evidence,
            resolvedRecordIDs: []
        ).first)

        XCTAssertEqual(item.positiveEvidenceIDs, ["one", "two"])
        XCTAssertEqual(item.positiveEvidenceCount, 2)
        XCTAssertEqual(item.phraseRiskName, "low")
        XCTAssertEqual(item.scopeRiskName, "medium")
        XCTAssertTrue(try XCTUnwrap(item.evidenceExampleText).count <= 184)
        XCTAssertTrue(try XCTUnwrap(item.evidenceExampleText).hasSuffix("..."))
        XCTAssertEqual(item.evidenceContextText, "com.example.editor - Draft.md")
    }

    /// Confirmed-corpus stand-in: real rows none of these candidates rewrite, so the
    /// locked-baseline check passes on its merits instead of on an empty row set.
    private let lockedBaselineTexts = ["the codebase is fine", "open the Epos app"]

    private func editedEvidence(id: String, final: String, edited: String) -> CorrectionEvidence {
        editedEvidence(id: id, final: final, edited: edited, bundleID: nil, windowTitle: nil)
    }

    private func editedEvidence(
        id: String,
        final: String,
        edited: String,
        bundleID: String?,
        windowTitle: String?
    ) -> CorrectionEvidence {
        CorrectionEvidence(
            id: id,
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: id,
            rawTranscript: final,
            canonicalizedTranscript: final,
            finalInsertedTranscript: final,
            userEditedTranscript: edited,
            applicationBundleIdentifier: bundleID,
            windowTitle: windowTitle,
            appliedRuleIDs: []
        )
    }
}

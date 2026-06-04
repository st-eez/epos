import XCTest
@testable import Epos

final class CorrectionEvidenceTests: XCTestCase {
    func testEvidenceStorePersistsRecentFinalizationEvidence() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionEvidenceStore(defaults: defaults, maxEvidenceCount: 2)
        store.record(.init(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "open siemux",
            canonicalizedTranscript: "open CMUX",
            finalInsertedTranscript: "open CMUX",
            userEditedTranscript: nil,
            appliedRuleIDs: ["builtin.cmux"],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        ))

        let reloaded = CorrectionEvidenceStore(defaults: defaults)

        XCTAssertEqual(reloaded.evidence.map(\.id), ["evidence-1"])
        XCTAssertEqual(reloaded.evidence.first?.rawTranscript, "open siemux")
        XCTAssertEqual(reloaded.evidence.first?.canonicalizedTranscript, "open CMUX")
        XCTAssertEqual(reloaded.evidence.first?.finalInsertedTranscript, "open CMUX")
        XCTAssertEqual(reloaded.evidence.first?.appliedRuleIDs, ["builtin.cmux"])
    }

    func testEditedMissEvidenceCreatesSuggestedRecordThatDoesNotCompile() throws {
        let evidence = CorrectionEvidence(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "open widget pro",
            canonicalizedTranscript: "open widget pro",
            finalInsertedTranscript: "open widget pro",
            userEditedTranscript: "open WidgetPro",
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        )

        let suggestions = CorrectionCandidateSuggester.suggestedRecords(from: [evidence])

        XCTAssertEqual(suggestions, [
            CorrectionRecord(
                id: "suggested.widget-pro.to-widgetpro",
                kind: .replacement,
                canonical: "WidgetPro",
                aliases: ["widget pro"],
                source: .suggested,
                status: .suggested
            )
        ])
        XCTAssertTrue(CorrectionRuleCompiler.compile(records: suggestions).isEmpty)
    }

    func testAppliedRuleIDsFollowCanonicalizerOverlapOrdering() {
        let dictionary = CorrectionDictionary(records: [
            CorrectionRecord(
                id: "long",
                kind: .replacement,
                canonical: "AlphaBeta",
                aliases: ["alpha beta"],
                source: .manual,
                status: .active
            ),
            CorrectionRecord(
                id: "short",
                kind: .replacement,
                canonical: "Alpha",
                aliases: ["alpha"],
                source: .manual,
                status: .active
            )
        ])

        XCTAssertEqual(
            TranscriptCanonicalizer(
                rules: CorrectionRuleCompiler.compile(records: dictionary.records)
            ).canonicalize("alpha beta"),
            "AlphaBeta"
        )
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "alpha beta"), ["long"])
    }

    func testAppliedRuleIDsRespectContextualRules() {
        let dictionary = CorrectionDictionary(records: [
            CorrectionRecord(
                id: "ctx",
                kind: .replacement,
                canonical: "Aster",
                aliases: ["esther"],
                contexts: ["message to"],
                source: .manual,
                status: .active
            )
        ])

        XCTAssertEqual(
            TranscriptCanonicalizer(
                rules: CorrectionRuleCompiler.compile(records: dictionary.records)
            ).canonicalize("Esther sent the note"),
            "Esther sent the note"
        )
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "Esther sent the note"), [String]())
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "message to Esther"), ["ctx"])
    }

    func testAppliedRuleIDsIncludeCascadedRules() {
        let dictionary = CorrectionDictionary(records: [
            CorrectionRecord(
                id: "first",
                kind: .replacement,
                canonical: "bar",
                aliases: ["foo"],
                source: .manual,
                status: .active
            ),
            CorrectionRecord(
                id: "second",
                kind: .replacement,
                canonical: "Baz",
                aliases: ["bar"],
                source: .manual,
                status: .active
            )
        ])

        XCTAssertEqual(
            TranscriptCanonicalizer(
                rules: CorrectionRuleCompiler.compile(records: dictionary.records)
            ).canonicalize("foo"),
            "Baz"
        )
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "foo"), ["first", "second"])
    }

    @MainActor
    func testCoordinatorCapturesCorrectionEvidenceAtFinalization() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            recordingIDGenerator: { "rec-1" },
            autoStart: false
        )

        coordinator.recordCorrectionEvidence(
            rawTranscript: "open siemux",
            polishResult: PolishResult(
                text: "open CMUX",
                outcome: .disabled,
                rawCharacterCount: "open CMUX".count
            ),
            effectiveOutcome: .disabled,
            applied: true,
            recordingID: "rec-1"
        )

        let evidence = try XCTUnwrap(evidenceStore.evidence.first)
        XCTAssertEqual(evidence.recordingID, "rec-1")
        XCTAssertEqual(evidence.rawTranscript, "open siemux")
        XCTAssertEqual(evidence.canonicalizedTranscript, "open CMUX")
        XCTAssertEqual(evidence.finalInsertedTranscript, "open CMUX")
        XCTAssertEqual(evidence.appliedRuleIDs, ["builtin.cmux"])
        XCTAssertEqual(evidence.polishOutcome, "disabled")
    }
}

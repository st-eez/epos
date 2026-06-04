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

    func testEvidenceStoreUpdatesExistingRowWithObservedUserEdit() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionEvidenceStore(defaults: defaults)
        let evidenceID = store.record(.init(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "open widget pro",
            canonicalizedTranscript: "open widget pro",
            finalInsertedTranscript: "open widget pro",
            userEditedTranscript: nil,
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        ))

        XCTAssertTrue(store.recordUserEdit(
            evidenceID: evidenceID,
            userEditedTranscript: "open WidgetPro"
        ))

        let updated = try XCTUnwrap(CorrectionEvidenceStore(defaults: defaults).evidence.first)
        XCTAssertEqual(updated.id, "evidence-1")
        XCTAssertEqual(updated.rawTranscript, "open widget pro")
        XCTAssertEqual(updated.canonicalizedTranscript, "open widget pro")
        XCTAssertEqual(updated.finalInsertedTranscript, "open widget pro")
        XCTAssertEqual(updated.userEditedTranscript, "open WidgetPro")
        XCTAssertEqual(
            CorrectionCandidateSuggester.suggestedRecords(from: [updated]).map(\.canonical),
            ["WidgetPro"]
        )
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

    @MainActor
    func testCoordinatorReturnsStableEvidenceIDForLaterEditCapture() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            recordingIDGenerator: { "rec-1" },
            autoStart: false
        )

        let evidenceID = coordinator.recordCorrectionEvidence(
            rawTranscript: "open widget pro",
            polishResult: PolishResult(
                text: "open widget pro",
                outcome: .disabled,
                rawCharacterCount: "open widget pro".count
            ),
            effectiveOutcome: .disabled,
            applied: true,
            recordingID: "rec-1"
        )

        XCTAssertTrue(evidenceStore.recordUserEdit(
            evidenceID: evidenceID,
            userEditedTranscript: "open WidgetPro"
        ))
        XCTAssertEqual(evidenceStore.suggestedRecords.map(\.id), ["suggested.widget-pro.to-widgetpro"])
    }

    @MainActor
    func testCoordinatorSchedulesObservedUserEditCapture() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            observedEditCaptureDelay: 0,
            autoStart: false
        )
        let evidenceID = evidenceStore.record(.init(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "widget pro",
            canonicalizedTranscript: "widget pro",
            finalInsertedTranscript: "widget pro",
            userEditedTranscript: nil,
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptFinalTranscript("widget pro")
        session.finish()
        observer.value = "open WidgetPro please"
        coordinator.scheduleObservedUserEditCapture(
            evidenceID: evidenceID,
            finalInsertedTranscript: "widget pro",
            session: session
        )

        XCTAssertEqual(evidenceStore.evidence.first?.userEditedTranscript, "WidgetPro")
        XCTAssertEqual(evidenceStore.suggestedRecords.map(\.canonical), ["WidgetPro"])
    }
}

private final class EvidenceFakeTargetObserver: InsertionTargetObserver {
    var focusChanged = false
    var value: String?
    var exposesText = false
    var insertionContext: InsertionTargetContext?

    func captureBaseline() {}
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? { value }
    func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    func exposesTextValue() -> Bool { exposesText }
    func baselineInsertionContext() -> InsertionTargetContext? { insertionContext }
}

private final class EvidenceNoopTextInsertionSession: TextInsertionSession {
    func insert(_ text: String) {}
    func deleteBackward(count: Int) {}
    func finish() {}
    func cancel() {}
}

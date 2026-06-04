import XCTest
@testable import Epos

final class CorrectionDictionaryPersistenceTests: XCTestCase {
    @MainActor
    func testCorrectionStoreSavesRulesAsDictionaryRecords() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        store.save([
            .init(canonical: "WidgetPro", aliases: ["widget pro"], contexts: ["open"])
        ])

        XCTAssertNotNil(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        XCTAssertEqual(
            CorrectionDictionary.load(from: defaults).records,
            [
                CorrectionRecord(
                    id: "manual.0.widgetpro",
                    kind: .replacement,
                    canonical: "WidgetPro",
                    aliases: ["widget pro"],
                    contexts: ["open"],
                    source: .manual,
                    status: .active
                )
            ]
        )
        XCTAssertEqual(CorrectionStore(defaults: defaults).canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(CorrectionStore(defaults: defaults).canonicalize("open siemux"), "open siemux")
    }

    func testTranscriptCanonicalizerLoadsPersistedDictionaryRecords() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CorrectionDictionary.saveRecords(
            [
                CorrectionRecord(
                    id: "manual.widgetpro",
                    kind: .lexicon,
                    canonical: "WidgetPro",
                    aliases: ["widget pro"],
                    source: .manual,
                    status: .active
                )
            ],
            to: defaults
        )

        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(canonicalizer.canonicalize("open siemux"), "open siemux")
    }

    func testDictionaryMigratesVersionedFlatRulesAsReplacementRecords() throws {
        struct StoredRules: Codable {
            var version: Int
            var rules: [TranscriptCanonicalizer.Rule]
        }

        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyPayload = StoredRules(
            version: 1,
            rules: [
                .init(canonical: "WidgetPro", aliases: ["widget pro"], contexts: ["open"])
            ]
        )
        let data = try JSONEncoder().encode(legacyPayload)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let dictionary = CorrectionDictionary.load(from: defaults)
        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertNotNil(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        XCTAssertEqual(dictionary.records.map(\.source), [.manual])
        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(canonicalizer.canonicalize("open siemux"), "open siemux")
    }

    func testDictionaryMigratesLegacyFlatRulesBeforeDefaults() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyCustomRules: [TranscriptCanonicalizer.Rule] = [
            .init(canonical: "MUX", aliases: ["simux"])
        ]
        let data = try JSONEncoder().encode(legacyCustomRules)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let dictionary = CorrectionDictionary.load(from: defaults)
        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertNotNil(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        XCTAssertEqual(dictionary.records.first?.source, .manual)
        XCTAssertEqual(Array(dictionary.records.dropFirst()), CorrectionDictionary.defaultRecords)
        XCTAssertEqual(canonicalizer.canonicalize("open simux"), "open MUX")
        XCTAssertEqual(canonicalizer.canonicalize("edit agents dot md"), "edit AGENTS.md")
    }

    @MainActor
    func testCorrectionStoreAcceptsPromotedSuggestion() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)
        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertTrue(store.acceptPromotion(assessment))

        let promoted = try XCTUnwrap(assessment.promotedRecord)
        XCTAssertEqual(CorrectionDictionary.load(from: defaults).records.last, promoted)
        XCTAssertEqual(store.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(CorrectionStore(defaults: defaults).canonicalize("launch widget pro"), "launch WidgetPro")
    }

    @MainActor
    func testCorrectionStoreRejectsBlockedPromotion() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)
        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertFalse(store.acceptPromotion(assessment))
        XCTAssertEqual(CorrectionDictionary.load(from: defaults).records, CorrectionDictionary.defaultRecords)
        XCTAssertEqual(store.canonicalize("open widget pro"), "open widget pro")
    }

    @MainActor
    func testCorrectionStorePersistsRejectedSuggestion() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        let evidence = [
            editedEvidence(id: "one", final: "open db", edited: "open Database"),
            editedEvidence(id: "two", final: "launch db", edited: "launch Database")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)
        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertTrue(store.rejectSuggestion(assessment))

        let rejected = try XCTUnwrap(CorrectionDictionary.load(from: defaults).records.last)
        XCTAssertEqual(rejected.id, "suggested.db.to-database")
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(rejected.source, .suggested)
        XCTAssertTrue(CorrectionRuleCompiler.compile(records: [rejected]).isEmpty)
        XCTAssertEqual(store.resolvedSuggestionRecordIDs, ["suggested.db.to-database"])
    }

    @MainActor
    func testCorrectionStoreSavePreservesResolvedSuggestions() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        let acceptedEvidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let acceptedRecord = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: acceptedEvidence).first)
        let acceptedAssessment = CorrectionPromotionGate.assess(record: acceptedRecord, evidence: acceptedEvidence)
        XCTAssertTrue(store.acceptPromotion(acceptedAssessment))

        let rejectedEvidence = [
            editedEvidence(id: "three", final: "open db", edited: "open Database"),
            editedEvidence(id: "four", final: "launch db", edited: "launch Database")
        ]
        let rejectedRecord = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: rejectedEvidence).first)
        let rejectedAssessment = CorrectionPromotionGate.assess(record: rejectedRecord, evidence: rejectedEvidence)
        XCTAssertTrue(store.rejectSuggestion(rejectedAssessment))

        store.save(store.rules)

        let records = CorrectionDictionary.load(from: defaults).records
        XCTAssertEqual(records.first { $0.id == "suggested.widget-pro.to-widgetpro" }?.status, .active)
        XCTAssertEqual(records.first { $0.id == "suggested.db.to-database" }?.status, .rejected)
        XCTAssertEqual(
            CorrectionStore(defaults: defaults).resolvedSuggestionRecordIDs,
            ["suggested.db.to-database", "suggested.widget-pro.to-widgetpro"]
        )
    }

    @MainActor
    func testCorrectionStoreDoesNotAcceptStaleRejectedSuggestion() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let record = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)
        let assessment = CorrectionPromotionGate.assess(record: record, evidence: evidence)

        XCTAssertTrue(store.rejectSuggestion(assessment))
        XCTAssertFalse(store.acceptPromotion(assessment))
        XCTAssertEqual(CorrectionDictionary.load(from: defaults).records.first { $0.id == record.id }?.status, .rejected)
        XCTAssertEqual(store.canonicalize("open widget pro"), "open widget pro")
    }

    private func editedEvidence(id: String, final: String, edited: String) -> CorrectionEvidence {
        CorrectionEvidence(
            id: id,
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: id,
            rawTranscript: final,
            canonicalizedTranscript: final,
            finalInsertedTranscript: final,
            userEditedTranscript: edited,
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        )
    }
}

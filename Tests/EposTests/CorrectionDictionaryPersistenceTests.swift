import XCTest
@testable import Epos

final class CorrectionDictionaryPersistenceTests: XCTestCase {
    func testFutureDictionaryLoadsReadableRecordsWithoutRewritingStorage() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let futureJSON = """
        {"version": 2, "futureDictionaryField": "preserve me", "records": [
          {"id": "builtin.yesterday-saying", "kind": "replacement", "canonical": "future canonical", \
        "aliases": ["future alias"], "contexts": [], "source": "builtIn", "status": "disabled", \
        "futureRecordField": {"meaning": "preserve me too"}}
        ]}
        """
        let legacyJSON = #"{"version":1,"rules":[],"futureLegacyField":"preserve me"}"#
        defaults.set(futureJSON, forKey: CorrectionDictionary.recordsDefaultsKey)
        defaults.set(legacyJSON, forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let loaded = CorrectionDictionary.load(from: defaults)

        XCTAssertEqual(
            loaded.records,
            [
                CorrectionRecord(
                    id: "builtin.yesterday-saying",
                    kind: .replacement,
                    canonical: "future canonical",
                    aliases: ["future alias"],
                    source: .builtIn,
                    status: .disabled
                )
            ]
        )
        XCTAssertEqual(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey), futureJSON)
        XCTAssertEqual(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey), legacyJSON)
    }

    @MainActor
    func testCorrectionStoreRefusesToSaveFutureDictionary() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let futureJSON = """
        {"version": 2, "futureDictionaryField": "preserve me", "records": [
          {"id": "manual.future", "kind": "replacement", "canonical": "Future", \
        "aliases": ["future"], "contexts": [], "source": "manual", "status": "active"}
        ]}
        """
        let legacyJSON = #"{"version":1,"rules":[],"futureLegacyField":"preserve me"}"#
        defaults.set(futureJSON, forKey: CorrectionDictionary.recordsDefaultsKey)
        defaults.set(legacyJSON, forKey: TranscriptCanonicalizer.rulesDefaultsKey)
        let store = CorrectionStore(defaults: defaults)

        XCTAssertTrue(store.isReadOnly)
        store.saveEditorRecords(CorrectionDictionary.defaultRecords)
        XCTAssertFalse(CorrectionDictionary.saveRecords(CorrectionDictionary.defaultRecords, to: defaults))

        XCTAssertEqual(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey), futureJSON)
        XCTAssertEqual(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey), legacyJSON)
        XCTAssertEqual(store.dictionary.records.map(\.id), ["manual.future"])
    }

    @MainActor
    func testFutureDictionaryWithChangedRecordsShapeRemainsProtected() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let futureJSON = """
        {"version": 2, "records": {"items": [{"id": "future.record"}]}}
        """
        defaults.set(futureJSON, forKey: CorrectionDictionary.recordsDefaultsKey)

        let store = CorrectionStore(defaults: defaults)

        XCTAssertTrue(store.isReadOnly)
        XCTAssertTrue(store.dictionary.records.isEmpty)
        store.saveEditorRecords(CorrectionDictionary.defaultRecords)
        XCTAssertFalse(CorrectionDictionary.saveRecords(CorrectionDictionary.defaultRecords, to: defaults))
        XCTAssertEqual(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey), futureJSON)
    }

    func testDictionaryMigratesPersistedBuiltInRecordsToCurrentDefinitions() throws {
        struct StoredDictionary: Codable {
            var version: Int
            var records: [CorrectionRecord]
        }

        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let staleBuiltIn = CorrectionRecord(
            id: "builtin.yesterday-saying",
            kind: .replacement,
            canonical: "yesterday, saying",
            aliases: ["history, seeing"],
            source: .builtIn,
            status: .disabled
        )
        let data = try JSONEncoder().encode(StoredDictionary(version: 1, records: [staleBuiltIn]))
        defaults.set(String(decoding: data, as: UTF8.self), forKey: CorrectionDictionary.recordsDefaultsKey)

        let loaded = CorrectionDictionary.load(from: defaults)
        let record = try XCTUnwrap(loaded.records.first)

        XCTAssertEqual(record.id, "builtin.yesterday-saying")
        XCTAssertEqual(record.aliases, ["history seeing"])
        XCTAssertEqual(record.status, .disabled)
        XCTAssertEqual(loaded.records.count, 1)

        let persistedRaw = try XCTUnwrap(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        let persistedData = try XCTUnwrap(persistedRaw.data(using: .utf8))
        let persisted = try JSONDecoder().decode(StoredDictionary.self, from: persistedData)
        XCTAssertEqual(persisted.records.first?.aliases, ["history seeing"])
        XCTAssertEqual(persisted.records.first?.status, .disabled)
        XCTAssertEqual(persisted.records.count, 1)
    }

    @MainActor
    func testDictionaryKeepsReadableRecordsWhenOneRecordIsUndecodable() throws {
        // One record carrying an unknown enum case (written by a future build that
        // was then downgraded) must not fail the whole array decode — that silently
        // reset every user correction to defaults, and the next save made the reset
        // permanent. The readable records survive; the bad one is dropped.
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let json = """
        {"version": 1, "records": [
          {"id": "manual.cmux", "kind": "replacement", "canonical": "cmux", \
        "aliases": ["seamux"], "contexts": [], "source": "manual", "status": "active"},
          {"id": "future.unknown", "kind": "some-future-kind", "canonical": "x", \
        "aliases": ["y"], "contexts": [], "source": "manual", "status": "active"}
        ]}
        """
        defaults.set(json, forKey: CorrectionDictionary.recordsDefaultsKey)

        let loaded = CorrectionDictionary.load(from: defaults)

        XCTAssertEqual(loaded.records.map(\.id), ["manual.cmux"])
        XCTAssertTrue(loaded.isReadOnly)
        let store = CorrectionStore(defaults: defaults)
        XCTAssertTrue(store.isReadOnly)
        store.saveEditorRecords(CorrectionDictionary.defaultRecords)
        XCTAssertFalse(CorrectionDictionary.saveRecords(CorrectionDictionary.defaultRecords, to: defaults))
        // Neither load nor an explicit save may overwrite the unreadable record.
        XCTAssertEqual(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey), json)
    }

    func testBuiltInMigrationDoesNotPersistOverUndecodableRecords() throws {
        // The common upgrade shape: a stale built-in needing migration PLUS a
        // record written by a newer schema. The migration must not use its
        // persistence pass to rewrite the blob — that would destroy the
        // future-schema record the tolerant decode just preserved on disk.
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let json = """
        {"version": 1, "records": [
          {"id": "builtin.yesterday-saying", "kind": "replacement", "canonical": "yesterday, saying", \
        "aliases": ["history, seeing"], "contexts": [], "source": "builtIn", "status": "disabled"},
          {"id": "future.unknown", "kind": "some-future-kind", "canonical": "x", \
        "aliases": ["y"], "contexts": [], "source": "manual", "status": "active"}
        ]}
        """
        defaults.set(json, forKey: CorrectionDictionary.recordsDefaultsKey)

        let loaded = CorrectionDictionary.load(from: defaults)

        // In-memory records still migrate to the current built-in definition…
        let record = try XCTUnwrap(loaded.records.first)
        XCTAssertEqual(record.id, "builtin.yesterday-saying")
        XCTAssertEqual(record.aliases, ["history seeing"])
        // …but the blob on disk is untouched, future record included.
        XCTAssertEqual(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey), json)
    }

    func testDictionaryConvertsPersistedRetiredBuiltInRecordsToManualRecords() throws {
        struct StoredDictionary: Codable {
            var version: Int
            var records: [CorrectionRecord]
        }

        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retiredBuiltIn = CorrectionRecord(
            id: "builtin.retired-private-term",
            kind: .replacement,
            canonical: "ExampleTerm",
            aliases: ["example term"],
            source: .builtIn,
            status: .active
        )
        let manual = CorrectionRecord(
            id: "manual.example",
            kind: .replacement,
            canonical: "ManualTerm",
            aliases: ["manual term"],
            source: .manual,
            status: .active
        )
        let data = try JSONEncoder().encode(StoredDictionary(version: 1, records: [retiredBuiltIn, manual]))
        defaults.set(String(decoding: data, as: UTF8.self), forKey: CorrectionDictionary.recordsDefaultsKey)
        defaults.set("stale legacy rules", forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let loaded = CorrectionDictionary.load(from: defaults)

        var expectedRetiredRecord = retiredBuiltIn
        expectedRetiredRecord.source = .manual
        XCTAssertEqual(
            loaded.records,
            [expectedRetiredRecord, manual]
        )
        XCTAssertNil(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey))

        let persistedRaw = try XCTUnwrap(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        let persistedData = try XCTUnwrap(persistedRaw.data(using: .utf8))
        let persisted = try JSONDecoder().decode(StoredDictionary.self, from: persistedData)
        XCTAssertEqual(
            persisted.records,
            [expectedRetiredRecord, manual]
        )
    }

    func testDictionaryAddsBuiltInsIntroducedAfterStoredVersion() throws {
        struct StoredDictionary: Codable {
            var version: Int
            var records: [CorrectionRecord]
        }

        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let data = try JSONEncoder().encode(StoredDictionary(version: 0, records: []))
        defaults.set(String(decoding: data, as: UTF8.self), forKey: CorrectionDictionary.recordsDefaultsKey)

        let loaded = CorrectionDictionary.load(from: defaults)

        XCTAssertEqual(loaded.records, CorrectionDictionary.defaultRecords)
        let persistedRaw = try XCTUnwrap(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        let persistedData = try XCTUnwrap(persistedRaw.data(using: .utf8))
        let persisted = try JSONDecoder().decode(StoredDictionary.self, from: persistedData)
        XCTAssertEqual(persisted.version, CorrectionDictionary.storedDictionaryVersion)
        XCTAssertEqual(persisted.records, CorrectionDictionary.defaultRecords)
    }

    func testEveryBuiltInDeclaresAValidIntroductionVersion() {
        let defaultIDs = Set(CorrectionDictionary.defaultRecords.map(\.id))
        let introductionIDs = Set(CorrectionDictionary.builtInIntroductionVersions.keys)

        XCTAssertEqual(defaultIDs.count, CorrectionDictionary.defaultRecords.count)
        XCTAssertEqual(introductionIDs, defaultIDs)
        XCTAssertTrue(CorrectionDictionary.builtInIntroductionVersions.values.allSatisfy {
            (1...CorrectionDictionary.storedDictionaryVersion).contains($0)
        })
    }

    func testCurrentManualRecordSavePersistsNonDefaultRules() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let record = CorrectionRecord(
            id: "manual.widget-pro",
            kind: .replacement,
            canonical: "WidgetPro",
            aliases: ["widget pro"],
            source: .manual,
            status: .active
        )

        CorrectionDictionary.saveRecords([record], to: defaults)

        let loaded = try XCTUnwrap(CorrectionDictionary.load(from: defaults).records.first)
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(TranscriptCanonicalizer.load(from: defaults).canonicalize("open widget pro"), "open WidgetPro")
    }

    @MainActor
    func testCorrectionStoreSavesEditorRecords() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        let record = CorrectionRecord(
            id: "manual.widget-pro",
            kind: .replacement,
            canonical: "WidgetPro",
            aliases: ["widget pro"],
            contexts: ["open"],
            source: .manual,
            status: .active
        )
        store.saveEditorRecords([record])

        XCTAssertNotNil(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        XCTAssertEqual(
            CorrectionDictionary.load(from: defaults).records,
            [record]
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

    func testTranscriptCanonicalizerLoadsPersistedPersonLexiconRecords() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CorrectionDictionary.saveRecords(
            [
                CorrectionRecord(
                    id: "manual.person",
                    kind: .lexicon,
                    canonical: "Test Person",
                    aliases: ["test person", "tas"],
                    ambiguousAliases: ["steph", "step"],
                    lexiconClass: .person,
                    source: .manual,
                    status: .active
                )
            ],
            to: defaults
        )

        let dictionary = CorrectionDictionary.load(from: defaults)
        let record = try XCTUnwrap(dictionary.records.first)
        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertEqual(record.ambiguousAliases, ["steph", "step"])
        XCTAssertEqual(record.lexiconClass, .person)
        XCTAssertEqual(canonicalizer.canonicalize("ask Steph to review"), "ask Test Person to review")
        XCTAssertEqual(canonicalizer.canonicalize("message to Step"), "message to Test Person")
        XCTAssertEqual(canonicalizer.canonicalize("next step"), "next step")
    }

    @MainActor
    func testEditorRoundTripPreservesPersonNameSlotRules() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CorrectionDictionary.saveRecords(
            [
                CorrectionRecord(
                    id: "manual.person",
                    kind: .lexicon,
                    canonical: "Test Person",
                    aliases: ["test person", "tas"],
                    ambiguousAliases: ["steph", "step", "stuff"],
                    lexiconClass: .person,
                    source: .manual,
                    status: .active
                )
            ],
            to: defaults
        )

        let store = CorrectionStore(defaults: defaults)
        let editorRecords = CorrectionDraft.fromRecords(store.dictionary.records).map(\.record)
        store.saveEditorRecords(editorRecords)

        let saved = CorrectionDictionary.load(from: defaults)
        let canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: saved.records)
        )

        XCTAssertTrue(saved.records.contains { record in
            record.kind == .lexicon &&
                record.lexiconClass == .person &&
                record.ambiguousAliases == ["steph", "step", "stuff"]
        })
        XCTAssertEqual(canonicalizer.canonicalize("message to Step"), "message to Test Person")
        XCTAssertEqual(canonicalizer.canonicalize("next step"), "next step")
        XCTAssertEqual(canonicalizer.canonicalize("Stuff should stay common."), "Stuff should stay common.")
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
        XCTAssertNil(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey))
        XCTAssertEqual(dictionary.records.map(\.source), [.manual])
        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(canonicalizer.canonicalize("open siemux"), "open siemux")
    }

    func testDictionaryMigratesLegacyFlatBuiltInRulesToCurrentDefinitions() throws {
        struct StoredRules: Codable {
            var version: Int
            var rules: [TranscriptCanonicalizer.Rule]
        }
        struct StoredDictionary: Codable {
            var version: Int
            var records: [CorrectionRecord]
        }

        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyPayload = StoredRules(
            version: 1,
            rules: [
                .init(canonical: "yesterday, saying", aliases: ["history, seeing"])
            ]
        )
        let data = try JSONEncoder().encode(legacyPayload)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let dictionary = CorrectionDictionary.load(from: defaults)
        let record = try XCTUnwrap(dictionary.records.first)

        XCTAssertEqual(record.id, "builtin.yesterday-saying")
        XCTAssertEqual(record.source, .builtIn)
        XCTAssertEqual(record.aliases, ["history seeing"])

        let persistedRaw = try XCTUnwrap(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        let persistedData = try XCTUnwrap(persistedRaw.data(using: .utf8))
        let persisted = try JSONDecoder().decode(StoredDictionary.self, from: persistedData)
        XCTAssertEqual(persisted.records.first?.id, "builtin.yesterday-saying")
        XCTAssertEqual(persisted.records.first?.aliases, ["history seeing"])
        XCTAssertNil(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey))
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
        XCTAssertNil(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey))
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
    func testAcceptingEquivalentSuggestionPreservesExistingRecordIdentity() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = CorrectionRecord(
            id: "imported.widget-pro",
            kind: .replacement,
            canonical: "WidgetPro",
            aliases: ["widget pro"],
            source: .imported,
            status: .active
        )
        XCTAssertTrue(CorrectionDictionary.saveRecords([existing], to: defaults))
        let store = CorrectionStore(defaults: defaults)
        let evidence = [
            editedEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"),
            editedEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro")
        ]
        let suggestion = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: evidence).first)
        let assessment = CorrectionPromotionGate.assess(
            record: suggestion,
            evidence: evidence,
            activeRecords: [existing]
        )

        XCTAssertTrue(store.acceptPromotion(assessment))
        let resolved = try XCTUnwrap(store.dictionary.records.last)
        XCTAssertEqual(store.dictionary.records.first, existing)
        XCTAssertEqual(resolved.id, suggestion.id)
        XCTAssertEqual(resolved.source, .suggested)
        XCTAssertEqual(resolved.status, .disabled)

        let unsaved = CorrectionRecord(
            id: "manual.other",
            kind: .replacement,
            canonical: "Other",
            aliases: ["other phrase"],
            source: .manual,
            status: .active
        )
        store.saveEditorRecords(CorrectionDraft.fromRecords(store.dictionary.records).map(\.record) + [unsaved])

        let saved = CorrectionDictionary.load(from: defaults).records
        XCTAssertEqual(saved.first, existing)
        XCTAssertTrue(saved.contains(resolved))
        XCTAssertTrue(saved.contains(unsaved))
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

        store.saveEditorRecords(CorrectionDraft.fromRecords(store.dictionary.records).map(\.record))

        let records = CorrectionDictionary.load(from: defaults).records
        XCTAssertEqual(records.first { $0.id == "suggested.widget-pro.to-widgetpro" }?.status, .active)
        XCTAssertEqual(records.first { $0.id == "suggested.db.to-database" }?.status, .rejected)
        XCTAssertEqual(
            CorrectionStore(defaults: defaults).resolvedSuggestionRecordIDs,
            ["suggested.db.to-database", "suggested.widget-pro.to-widgetpro"]
        )
    }

    @MainActor
    func testCorrectionStoreSaveAllowsAcceptedSuggestionDeletion() throws {
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

        store.saveEditorRecords([])

        XCTAssertNil(CorrectionDictionary.load(from: defaults).records.first { $0.id == record.id })
        XCTAssertEqual(CorrectionStore(defaults: defaults).canonicalize("open widget pro"), "open widget pro")
    }

    @MainActor
    func testCorrectionStoreSaveKeepsRejectedSuggestionSuppression() throws {
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

        store.saveEditorRecords([])

        let rejected = try XCTUnwrap(CorrectionDictionary.load(from: defaults).records.first { $0.id == record.id })
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(rejected.source, .suggested)
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

import XCTest
@testable import Epos

final class CorrectionEditorRecordIntegrityTests: XCTestCase {
    @MainActor
    func testNoOpEditorSavePreservesStableRecordIdentityAndPersonAliases() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = CorrectionRecord(
            id: "imported.person",
            kind: .lexicon,
            canonical: "Test Person",
            aliases: ["test person", "tas"],
            ambiguousAliases: ["steph", "step", "stuff"],
            lexiconClass: .person,
            source: .imported,
            status: .active
        )
        CorrectionDictionary.saveRecords([original], to: defaults)
        let store = CorrectionStore(defaults: defaults)

        let drafts = CorrectionDraft.fromRecords(store.dictionary.records)
        _ = saveCorrectionDrafts(drafts, to: store)

        XCTAssertEqual(CorrectionDictionary.load(from: defaults).records, [original])
    }

    @MainActor
    func testEditorReorderPreservesRecordIDsAndSource() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = CorrectionRecord(
            id: "imported.first",
            kind: .replacement,
            canonical: "First",
            aliases: ["one"],
            source: .imported,
            status: .active
        )
        let second = CorrectionRecord(
            id: "manual.second",
            kind: .replacement,
            canonical: "Second",
            aliases: ["two"],
            source: .manual,
            status: .active
        )
        CorrectionDictionary.saveRecords([first, second], to: defaults)
        let store = CorrectionStore(defaults: defaults)

        let drafts = CorrectionDraft.fromRecords(store.dictionary.records).reversed()
        _ = saveCorrectionDrafts(Array(drafts), to: store)

        XCTAssertEqual(CorrectionDictionary.load(from: defaults).records, [second, first])
    }

    @MainActor
    func testEditorPreservesHiddenRejectedSuggestion() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let active = CorrectionRecord(
            id: "manual.active",
            kind: .replacement,
            canonical: "WidgetPro",
            aliases: ["widget pro"],
            source: .manual,
            status: .active
        )
        let rejected = CorrectionRecord(
            id: "suggested.rejected",
            kind: .replacement,
            canonical: "Database",
            aliases: ["db"],
            source: .suggested,
            status: .rejected
        )
        CorrectionDictionary.saveRecords([active, rejected], to: defaults)
        let store = CorrectionStore(defaults: defaults)

        _ = saveCorrectionDrafts(CorrectionDraft.fromRecords(store.dictionary.records), to: store)

        XCTAssertEqual(CorrectionDictionary.load(from: defaults).records, [active, rejected])
    }

    func testDuplicateUnsavedDraftAdoptsAcceptedSuggestionIdentity() {
        let unsaved = CorrectionDraft(
            aliasesText: "widget pro",
            canonical: "WidgetPro",
            contextsText: ""
        )
        let accepted = CorrectionDraft(
            recordID: "suggested.widget-pro.to-widgetpro",
            recordKind: .replacement,
            recordSource: .suggested,
            recordStatus: .active,
            aliasesText: "widget pro",
            canonical: "WidgetPro",
            contextsText: ""
        )

        let merged = unsaved.adoptingRecordIdentity(from: accepted)

        XCTAssertEqual(merged.record.id, "suggested.widget-pro.to-widgetpro")
        XCTAssertEqual(merged.record.source, .suggested)
        XCTAssertEqual(merged.record.status, .active)
    }

    @MainActor
    func testNoOpEditorSavePreservesEscapedCommasAndBackslashes() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = CorrectionRecord(
            id: "imported.punctuation",
            kind: .replacement,
            canonical: "Acme",
            aliases: ["ACME, Inc.", #"path\name"#],
            contexts: ["ask ACME, Inc."],
            source: .imported,
            status: .active
        )
        XCTAssertTrue(CorrectionDictionary.saveRecords([original], to: defaults))
        let store = CorrectionStore(defaults: defaults)

        let drafts = CorrectionDraft.fromRecords(store.dictionary.records)
        _ = saveCorrectionDrafts(drafts, to: store)

        XCTAssertEqual(CorrectionDictionary.load(from: defaults).records, [original])
    }

    func testAcceptedSuggestionWithDuplicateContentIsNewByIdentity() {
        let existing = CorrectionDraft(
            recordID: "manual.widget",
            aliasesText: "widget pro",
            canonical: "WidgetPro",
            contextsText: ""
        )
        let accepted = CorrectionDraft(
            recordID: "suggested.widget",
            recordSource: .suggested,
            aliasesText: "widget pro",
            canonical: "WidgetPro",
            contextsText: ""
        )

        XCTAssertEqual(
            CorrectionDraft.newDrafts(in: [existing, accepted], notIn: [existing]),
            [accepted]
        )
    }

    func testNewDraftPreservesAnUnescapedBackslash() {
        let draft = CorrectionDraft(
            aliasesText: #"path\name"#,
            canonical: "Path",
            contextsText: ""
        )

        XCTAssertEqual(draft.aliases, [#"path\name"#])
    }
}

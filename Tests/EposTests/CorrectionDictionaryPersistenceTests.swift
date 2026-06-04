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
}

import XCTest
@testable import Epos

final class CorrectionDictionaryCompilerTests: XCTestCase {
    func testDefaultRecordsCompileToCurrentDefaultRules() {
        XCTAssertEqual(
            CorrectionRuleCompiler.compile(records: CorrectionDictionary.defaultRecords),
            TranscriptCanonicalizer.defaultRules
        )
    }

    func testCompiledCanonicalizerMatchesDefaultCanonicalizer() {
        let defaultCanonicalizer = TranscriptCanonicalizer()
        let compiledCanonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: CorrectionDictionary.defaultRecords)
        )

        let samples = [
            "open Siemux and edit agents dot m d then run swift lint",
            "Do we need to make any updates to the cloud.MD?",
            "Is your net, suite, login set up?",
            "pass dash dash verbose then use dollar home and slash goal",
            "message to Esther",
            "visit netsuitehq dot com"
        ]

        for sample in samples {
            XCTAssertEqual(
                compiledCanonicalizer.canonicalize(sample),
                defaultCanonicalizer.canonicalize(sample),
                sample
            )
        }
    }

    func testCompiledVocabularyMatchesDefaultVocabulary() {
        let defaultCanonicalizer = TranscriptCanonicalizer()
        let compiledCanonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: CorrectionDictionary.defaultRecords)
        )

        XCTAssertEqual(
            compiledCanonicalizer.canonicalVocabularyStrings,
            defaultCanonicalizer.canonicalVocabularyStrings
        )
        XCTAssertEqual(
            compiledCanonicalizer.speechContextualStrings,
            defaultCanonicalizer.speechContextualStrings
        )
    }

    func testSuggestedDisabledAndRejectedRecordsDoNotCompile() {
        let records: [CorrectionRecord] = [
            .init(
                id: "active-lexicon",
                kind: .lexicon,
                canonical: "WidgetPro",
                aliases: ["widget pro"],
                source: .manual,
                status: .active
            ),
            .init(
                id: "suggested",
                kind: .replacement,
                canonical: "Risky",
                aliases: ["risky"],
                source: .suggested,
                status: .suggested
            ),
            .init(
                id: "disabled",
                kind: .spokenCommand,
                canonical: "--",
                aliases: ["dash dash"],
                source: .manual,
                status: .disabled
            ),
            .init(
                id: "rejected",
                kind: .replacement,
                canonical: "Rejected",
                aliases: ["rejected"],
                source: .mined,
                status: .rejected
            ),
            .init(
                id: "snippet",
                kind: .snippet,
                canonical: "Expanded snippet",
                aliases: ["snippet"],
                source: .manual,
                status: .active
            ),
            .init(
                id: "formatting",
                kind: .formattingPolicy,
                canonical: "Sentence case",
                aliases: ["sentence case"],
                source: .builtIn,
                status: .active
            )
        ]

        XCTAssertEqual(
            CorrectionRuleCompiler.compile(records: records),
            [
                TranscriptCanonicalizer.Rule(
                    canonical: "WidgetPro",
                    aliases: ["widget pro"]
                )
            ]
        )
    }
}

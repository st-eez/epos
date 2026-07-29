import XCTest
@testable import Epos

final class CorrectionDictionaryCompilerTests: XCTestCase {
    func testDefaultRecordsCompileToCurrentDefaultRules() {
        XCTAssertEqual(
            CorrectionRuleCompiler.compile(records: CorrectionDictionary.defaultRecords),
            TranscriptCanonicalizer.defaultRules
        )
    }

    func testBuiltInSpokenCommandRecordsCarryRecordSemantics() {
        let commandRecords = CorrectionDictionary.defaultRecords.filter { record in
            ["/", "--", "/goal", "$HOME"].contains(record.canonical)
        }

        XCTAssertEqual(commandRecords.map(\.canonical), ["/", "--", "/goal", "$HOME"])
        XCTAssertTrue(commandRecords.allSatisfy { $0.kind == .spokenCommand })
        XCTAssertTrue(commandRecords.allSatisfy { $0.source == .builtIn })
        XCTAssertTrue(commandRecords.allSatisfy { $0.status == .active })
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

    func testSentenceInitialMatchPreservesRecognizerCapital() {
        let canonicalizer = TranscriptCanonicalizer()

        // String-start match: the lowercase canonical "codebase" keeps the capital.
        XCTAssertEqual(
            canonicalizer.canonicalize("Code base needs a refactor."),
            "Codebase needs a refactor."
        )
        // Second-sentence match after ". " also counts as sentence-initial.
        XCTAssertEqual(
            canonicalizer.canonicalize("Done. Code base next."),
            "Done. Codebase next."
        )
        // Mid-sentence lowercase source stays lowercase.
        XCTAssertEqual(
            canonicalizer.canonicalize("the code base is"),
            "the codebase is"
        )
        // Uppercase-by-design canonical ("Epos app") is unaffected by the recasing.
        XCTAssertEqual(
            canonicalizer.canonicalize("Ipos app crashed."),
            "Epos app crashed."
        )
    }

    func testAliasBoundariesAreUnicodeAware() {
        let canonicalizer = TranscriptCanonicalizer(
            rules: [.init(canonical: "Epos", aliases: ["epos"])]
        )

        // An accented letter neighbor is still mid-word; the alias must not fire.
        XCTAssertEqual(
            canonicalizer.canonicalize("caféepos thing"),
            "caféepos thing"
        )
        // Plain ASCII word boundaries still fire.
        XCTAssertEqual(
            canonicalizer.canonicalize("cafe epos thing"),
            "cafe Epos thing"
        )
    }

    func testSemanticAliasPunctuationMustBePresent() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "CPlusPlus", aliases: ["C++"]),
            .init(canonical: "GitFile", aliases: [".git"]),
            .init(canonical: "FooCall", aliases: ["foo()"]),
            .init(canonical: "--", aliases: ["dash++dash"])
        ])

        XCTAssertEqual(
            canonicalizer.canonicalize("C git foo dash dash verbose"),
            "C git foo dash dash verbose"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("C++ .git foo() dash++dash"),
            "CPlusPlus GitFile FooCall --"
        )
    }

    func testContextMatchingUsesWholeTokens() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "WidgetPro", aliases: ["widget pro"], contexts: ["ask"])
        ])

        XCTAssertEqual(canonicalizer.canonicalize("task widget pro"), "task widget pro")
        XCTAssertEqual(canonicalizer.canonicalize("ask widget pro"), "ask WidgetPro")
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
        XCTAssertEqual(
            TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: records))
                .canonicalize("dash dash verbose"),
            "dash dash verbose"
        )
    }

    func testPersonLexiconCompilesAmbiguousAliasesAsNameSlotRules() {
        let records = [
            CorrectionRecord(
                id: "person",
                kind: .lexicon,
                canonical: "Test Person",
                aliases: ["test person", "tas"],
                ambiguousAliases: ["steph", "step", "stuff"],
                lexiconClass: .person,
                source: .manual,
                status: .active
            )
        ]

        XCTAssertEqual(
            CorrectionRuleCompiler.compile(records: records),
            [
                TranscriptCanonicalizer.Rule(
                    canonical: "Test Person",
                    aliases: ["test person", "tas"]
                ),
                TranscriptCanonicalizer.Rule(
                    canonical: "Test Person",
                    aliases: ["steph", "step", "stuff"],
                    matchStrategy: .personNameSlot
                )
            ]
        )
    }

    func testPersonLexiconBiasesRecognizerTowardCanonicalOnly() {
        let canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: [
                CorrectionRecord(
                    id: "person",
                    kind: .lexicon,
                    canonical: "Test Person",
                    aliases: ["test person", "tas"],
                    ambiguousAliases: ["steph", "step", "stuff"],
                    lexiconClass: .person,
                    source: .manual,
                    status: .active
                )
            ])
        )

        XCTAssertTrue(canonicalizer.speechContextualStrings.contains("Test Person"))
        XCTAssertFalse(canonicalizer.speechContextualStrings.contains("tas"))
        XCTAssertFalse(canonicalizer.speechContextualStrings.contains("steph"))
        XCTAssertFalse(canonicalizer.speechContextualStrings.contains("step"))
        XCTAssertFalse(canonicalizer.speechContextualStrings.contains("stuff"))
    }
}

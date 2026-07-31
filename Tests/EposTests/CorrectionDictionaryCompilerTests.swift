import XCTest
@testable import Epos

final class CorrectionDictionaryCompilerTests: XCTestCase {
    /// Compilation is not one rule per record — a record can emit zero, one, or two —
    /// so every compiled rule has to carry the record it actually came from. Recovering
    /// the record by position instead lets one arity change shift every later pairing,
    /// which is how a built-in migration could overwrite unrelated user records.
    func testCompiledRulesCarryTheRecordTheyCameFrom() {
        let silent = CorrectionRecord(
            id: "silent",
            kind: .replacement,
            canonical: "Ignored",
            aliases: [],
            source: .manual,
            status: .active
        )
        let single = CorrectionRecord(
            id: "single",
            kind: .replacement,
            canonical: "WidgetPro",
            aliases: ["widget pro"],
            source: .manual,
            status: .active
        )
        let doubled = CorrectionRecord(
            id: "doubled",
            kind: .lexicon,
            canonical: "Test Person",
            aliases: ["test person"],
            ambiguousAliases: ["steph"],
            lexiconClass: .person,
            source: .manual,
            status: .active
        )
        let trailing = CorrectionRecord(
            id: "trailing",
            kind: .replacement,
            canonical: "CMUX",
            aliases: ["simux"],
            source: .manual,
            status: .active
        )

        let compiled = CorrectionRuleCompiler.compileWithSources(
            records: [silent, single, doubled, trailing]
        )

        XCTAssertEqual(compiled.map(\.record.id), ["single", "doubled", "doubled", "trailing"])
        XCTAssertEqual(compiled.map(\.rule.canonical), ["WidgetPro", "Test Person", "Test Person", "CMUX"])
        XCTAssertEqual(compiled.map(\.rule), CorrectionRuleCompiler.compile(records: [silent, single, doubled, trailing]))
    }

    /// A stored flat rule must migrate back to the built-in record that owns it today,
    /// not to whichever default happens to sit at the same position.
    func testLegacyFlatRulesMigrateBackToTheirOwnBuiltInRecord() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Deliberately out of default order, and with the pre-migration alias spelling
        // of the first rule, so a positional pairing would mislabel both.
        let legacyJSON = """
        {"version":1,"rules":[
          {"canonical":"codebase","aliases":["code basis","code base"],"contexts":[]},
          {"canonical":"yesterday, saying","aliases":["history, seeing"],"contexts":[]}
        ]}
        """
        defaults.set(legacyJSON, forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let migrated = CorrectionDictionary.load(from: defaults).records

        XCTAssertEqual(
            migrated.prefix(2).map(\.id),
            ["builtin.codebase", "builtin.yesterday-saying"]
        )
        XCTAssertEqual(migrated.prefix(2).map(\.canonical), ["codebase", "yesterday, saying"])
        // The legacy alias spelling adopts the record's current aliases.
        XCTAssertEqual(migrated.prefix(2).last?.aliases, ["history seeing"])
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

        XCTAssertEqual(canonicalizer.canonicalize("C git foo bar"), "C git foo bar")
        XCTAssertEqual(
            canonicalizer.canonicalize("C++ .git foo() dash++dash"),
            "CPlusPlus GitFile FooCall --"
        )
    }

    /// `dash dash <flag>` prepends `--` to a captured word, which no alias->canonical row
    /// can express, so it is not attached to one. Editing or deleting the `dash dash`
    /// row changes what bare "dash dash" produces; it must not silently take the flag
    /// form with it, because nothing in the editor hints at that coupling.
    func testFlagExpansionSurvivesEditingAndDeletingTheDashDashRecord() {
        let withoutDashDash = CorrectionDictionary.defaultRecords.filter {
            $0.id != "builtin.dash-dash"
        }
        let edited = CorrectionDictionary.defaultRecords.map { record -> CorrectionRecord in
            guard record.id == "builtin.dash-dash" else { return record }
            var record = record
            record.aliases = ["double dash"]
            return record
        }

        for records in [CorrectionDictionary.defaultRecords, withoutDashDash, edited] {
            XCTAssertEqual(
                TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: records))
                    .canonicalize("pass dash dash verbose now"),
                "pass --verbose now"
            )
        }

        // Bare "dash dash" is still the row's own job, so deleting it does take that away.
        XCTAssertEqual(
            TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: withoutDashDash))
                .canonicalize("append dash dash"),
            "append dash dash"
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
                .canonicalize("append dash dash"),
            "append dash dash"
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

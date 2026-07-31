import XCTest
@testable import Epos

/// Smoke coverage for the canonicalizer and the corrections dictionary,
/// drafts, and suggestion-review flow.
final class CorrectionSmokeTests: XCTestCase {
    func testCanonicalizerFixesSeededDeveloperTerms() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "open Siemux and edit agents dot m d then run swift lint"
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "open CMUX and edit AGENTS.md then run swift lint")
        XCTAssertEqual(canonicalizer.canonicalize("LOL polish slash cleanup"), "LLM polish / cleanup")
        XCTAssertEqual(canonicalizer.canonicalize("next step in the code basis"), "next step in the codebase")
        XCTAssertEqual(canonicalizer.canonicalize("unslop the fight the code base"), "unslopify the codebase")
        XCTAssertEqual(
            canonicalizer.canonicalize("Plot has been vibe coding this branch"),
            "Claude has been vibe coding this branch"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("work around using these foundational models"),
            "work around using these Foundation Models"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("what's the point of having the foundation models"),
            "what's the point of having Foundation Models"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("So you're seeing deprecate the foundation models altogether?"),
            "So you're saying deprecate Foundation Models altogether?"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("Claude, I want to add something to our Ipos app."),
            "Claude, I want to add something to our Epos app."
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("Let's check the read me and the agent's file."),
            "Let's check the README and the AGENTS file."
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("Use of agents as needed to keep your context window clean."),
            "Use subagents as needed to keep your context window clean."
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("They'd be closed phase one of the ticket."),
            "Did we close phase one of the ticket."
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("this history, seeing people never continue"),
            "this yesterday, saying people never continue"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("it's kind of not working progress"),
            "it's kind of not working properly"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("meaning the new fields for state, cities, and 3 litter code"),
            "meaning the new fields for state, cities, and three-letter code"
        )
        XCTAssertEqual(canonicalizer.canonicalize("Make 2 tickets for this."), "Make two tickets for this.")
        XCTAssertEqual(canonicalizer.canonicalize("mixing up the 2 things"), "mixing up the two things")
        XCTAssertEqual(canonicalizer.canonicalize("part 2 where we map customers"), "part two where we map customers")
        XCTAssertEqual(
            canonicalizer.canonicalize("At a comment to the ticket, so we can pick this up later."),
            "Add a comment to the ticket, so we can pick this up later."
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("I recommend to the tickets so we can pick this up later."),
            "Add a comment to the tickets so we can pick this up later."
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("different than Maine and focus"),
            "different than main and focus"
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("causing regressions in the sweet"),
            "causing regressions in the suite"
        )
        XCTAssertEqual(canonicalizer.canonicalize("vacation in Maine"), "vacation in Maine")
        XCTAssertEqual(canonicalizer.canonicalize("the dessert is sweet"), "the dessert is sweet")
        XCTAssertEqual(
            canonicalizer.canonicalize("different than release. Later vacation in Maine."),
            "different than release. Later vacation in Maine."
        )
        XCTAssertEqual(
            canonicalizer.canonicalize("regressions in the checkout were fixed; dessert is sweet"),
            "regressions in the checkout were fixed; dessert is sweet"
        )
    }

    func testCanonicalizerFixesClaudeMarkdownAliases() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "Check the cloud dot MD. Check the cloud.md."
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "Check the CLAUDE.md. Check the CLAUDE.md.")
        XCTAssertEqual(
            canonicalizer.canonicalize("Do we need to make any updates to the cloud.MD?"),
            "Do we need to make any updates to CLAUDE.md?"
        )
    }

    func testCanonicalizerDoesNotShipWorkplaceAliases() {
        let canonicalizer = TranscriptCanonicalizer()

        XCTAssertEqual(canonicalizer.canonicalize("open net suite today"), "open net suite today")
        XCTAssertEqual(canonicalizer.canonicalize("Is your next week login set up?"), "Is your next week login set up?")
        XCTAssertEqual(canonicalizer.canonicalize("Open next feed and check tickets."), "Open next feed and check tickets.")
        XCTAssertEqual(canonicalizer.canonicalize("Open up CMUX and send a team's message to staff."), "Open up CMUX and send a team's message to staff.")
        XCTAssertEqual(canonicalizer.canonicalize("Stuff instructions, please."), "Stuff instructions, please.")
        XCTAssertEqual(canonicalizer.canonicalize("Ask Tas to review the CMUX changes."), "Ask Tas to review the CMUX changes.")

        XCTAssertEqual(canonicalizer.canonicalize("visit netsuitehq dot com"), "visit netsuitehq dot com")
        XCTAssertEqual(canonicalizer.canonicalize("Talk about that suite later."), "Talk about that suite later.")
    }

    func testPersonLexiconAmbiguousAliasesRequireNameSlots() {
        let records = [
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
        ]
        let canonicalizer = TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: records))

        XCTAssertEqual(
            canonicalizer.canonicalize("Open up Teams and send a message to Step"),
            "Open up Teams and send a message to Test Person"
        )
        XCTAssertEqual(canonicalizer.canonicalize("Ping stuff about the CMUX issue"), "Ping Test Person about the CMUX issue")
        XCTAssertEqual(canonicalizer.canonicalize("Ask Steph to review it"), "Ask Test Person to review it")
        XCTAssertEqual(canonicalizer.canonicalize("Tas said the branch is ready"), "Test Person said the branch is ready")

        XCTAssertEqual(canonicalizer.canonicalize("What is the next step?"), "What is the next step?")
        XCTAssertEqual(canonicalizer.canonicalize("Step one is done."), "Step one is done.")
        XCTAssertEqual(canonicalizer.canonicalize("Stuff instructions, please."), "Stuff instructions, please.")
        XCTAssertEqual(canonicalizer.canonicalize("Stuff was already handled."), "Stuff was already handled.")
        XCTAssertEqual(canonicalizer.canonicalize("Stuff should stay as a common word."), "Stuff should stay as a common word.")
        XCTAssertEqual(canonicalizer.canonicalize("Step should remain unchanged."), "Step should remain unchanged.")
    }

    func testCanonicalizerFixesCurrentDefaultCustomEntries() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "type slash"
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "type /")
    }

    func testCanonicalizerAppliesExposedAcronymAliases() {
        let canonicalizer = TranscriptCanonicalizer()

        XCTAssertEqual(canonicalizer.canonicalize("open see mux"), "open CMUX")
        XCTAssertEqual(canonicalizer.canonicalize("open Semux"), "open CMUX")
        XCTAssertEqual(canonicalizer.canonicalize("open c m u x"), "open CMUX")
        XCTAssertEqual(canonicalizer.canonicalize("open c-mux"), "open CMUX")
    }

    func testCanonicalizerNormalizesProjectYamlToYmlExtension() {
        let canonicalizer = TranscriptCanonicalizer()

        XCTAssertEqual(canonicalizer.canonicalize("edit project dot yaml"), "edit project.yml")
        XCTAssertEqual(canonicalizer.canonicalize("edit project dot yml"), "edit project.yml")
        XCTAssertEqual(canonicalizer.canonicalize("update the project.yamo"), "update the project.yml")
        XCTAssertEqual(canonicalizer.canonicalize("edit project.yml"), "edit project.yml")
    }

    func testDefaultCorrectionAliasesAreEditorSafe() {
        for record in CorrectionDictionary.defaultRecords {
            XCTAssertFalse(
                record.aliases.contains { $0.contains(",") },
                "\(record.id) has an alias containing a comma"
            )
        }
    }

    func testCanonicalizerOnlyAppliesListedAliases() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "WidgetPro", aliases: ["widget pro"])
        ])

        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(canonicalizer.canonicalize("open widgetpro"), "open widgetpro")
    }

    func testCorrectionDraftRoundTripsEditableFields() {
        let draft = CorrectionDraft(
            aliasesText: "widget pro, widget row",
            canonical: " WidgetPro ",
            contextsText: "open, launch"
        )

        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.rule.canonical, "WidgetPro")
        XCTAssertEqual(draft.rule.aliases, ["widget pro", "widget row"])
        XCTAssertEqual(draft.rule.contexts, ["open", "launch"])
    }

    func testCorrectionDraftKeepsMatchStrategyWhenEdited() throws {
        var draft = try XCTUnwrap(CorrectionDraft.fromRules([
            TranscriptCanonicalizer.Rule(
                canonical: "Test Person",
                aliases: ["steph", "step"],
                matchStrategy: .personNameSlot
            )
        ]).first)

        XCTAssertEqual(draft.rule.matchStrategy, .personNameSlot)

        draft.aliasesText = "widget pro"
        draft.canonical = "WidgetPro"

        XCTAssertEqual(draft.rule.matchStrategy, .personNameSlot)
        XCTAssertEqual(
            TranscriptCanonicalizer(rules: [draft.rule]).canonicalize("open widget pro"),
            "open widget pro"
        )
    }

    func testCorrectionDraftKeepsMatchStrategyAcrossFormattingOnlyEdits() throws {
        var draft = try XCTUnwrap(CorrectionDraft.fromRules([
            TranscriptCanonicalizer.Rule(
                canonical: "Test Person",
                aliases: ["steph", "step"],
                contexts: ["message to", "ping"],
                matchStrategy: .personNameSlot
            )
        ]).first)

        draft.aliasesText = "steph,step"
        draft.canonical = " Test Person "
        draft.contextsText = "message to,ping"

        XCTAssertEqual(draft.rule.matchStrategy, .personNameSlot)
        XCTAssertEqual(draft.rule.canonical, "Test Person")
        XCTAssertEqual(draft.rule.aliases, ["steph", "step"])
        XCTAssertEqual(draft.rule.contexts, ["message to", "ping"])
    }

    func testCorrectionDraftKeepsMatchStrategyWhenPersonAliasesChange() throws {
        var draft = try XCTUnwrap(CorrectionDraft.fromRules([
            TranscriptCanonicalizer.Rule(
                canonical: "Test Person",
                aliases: ["steph", "step"],
                matchStrategy: .personNameSlot
            )
        ]).first)

        draft.aliasesText = "step"

        XCTAssertEqual(draft.rule.matchStrategy, .personNameSlot)
        let canonicalizer = TranscriptCanonicalizer(rules: [draft.rule])
        XCTAssertEqual(canonicalizer.canonicalize("message to Step"), "message to Test Person")
        XCTAssertEqual(canonicalizer.canonicalize("next step"), "next step")
    }

    @MainActor
    func testCorrectionDraftSaveRebaseKeepsMatchStrategy() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var draft = try XCTUnwrap(CorrectionDraft.fromRules([
            TranscriptCanonicalizer.Rule(
                canonical: "Test Person",
                aliases: ["steph", "step"],
                matchStrategy: .personNameSlot
            )
        ]).first)
        draft.aliasesText = "widget pro"
        draft.canonical = "WidgetPro"

        let store = CorrectionStore(defaults: defaults, lockedBaseline: fixtureBaseline)
        var savedDraft = try XCTUnwrap(saveCorrectionDrafts([draft], to: store).first)
        savedDraft.aliasesText = "step"
        savedDraft.canonical = "Test Person"

        XCTAssertEqual(savedDraft.rule.matchStrategy, .personNameSlot)
        let canonicalizer = TranscriptCanonicalizer(rules: [savedDraft.rule])
        XCTAssertEqual(canonicalizer.canonicalize("message to Step"), "message to Test Person")
        XCTAssertEqual(canonicalizer.canonicalize("next step"), "next step")
    }

    func testCorrectionDraftCanExplicitlySwitchPersonNameRuleToLiteral() throws {
        var draft = try XCTUnwrap(CorrectionDraft.fromRules([
            TranscriptCanonicalizer.Rule(
                canonical: "Test Person",
                aliases: ["steph", "step"],
                matchStrategy: .personNameSlot
            )
        ]).first)

        draft.matchStrategy = .literal
        draft.aliasesText = "widget pro"
        draft.canonical = "WidgetPro"

        XCTAssertEqual(draft.rule.matchStrategy, .literal)
        let canonicalizer = TranscriptCanonicalizer(rules: [draft.rule])
        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
    }

    func testNewDraftsMergeAcceptedSuggestionWithoutTouchingUnsavedEdits() {
        // Accepting a suggestion mid-edit must surface ONLY the newly accepted
        // rule; a full reload here would discard the user's unsaved rows.
        let saved = CorrectionDraft.fromRules([
            .init(canonical: "WidgetPro", aliases: ["widget pro"])
        ])
        let loadedAfterAccept = CorrectionDraft.fromRules([
            .init(canonical: "WidgetPro", aliases: ["widget pro"]),
            .init(canonical: "cmux", aliases: ["seamux"])
        ])

        let accepted = CorrectionDraft.newDrafts(in: loadedAfterAccept, notIn: saved)

        XCTAssertEqual(accepted.map(\.canonical), ["cmux"])
        // Content already present appends nothing on a repeat merge.
        XCTAssertTrue(CorrectionDraft.newDrafts(in: loadedAfterAccept, notIn: saved + accepted).isEmpty)
        // An identical UNSAVED row is invisible to the savedRows diff, so the
        // accepted draft still surfaces — the editor's rows-filter must drop it
        // before appending or the user sees (and later persists) a duplicate.
        let rowsWithUnsavedDuplicate = saved + CorrectionDraft.fromRules([
            .init(canonical: "cmux", aliases: ["seamux"])
        ])
        XCTAssertEqual(accepted.map(\.canonical), ["cmux"])
        XCTAssertTrue(accepted.filter { !rowsWithUnsavedDuplicate.contains($0) }.isEmpty)
    }

    @MainActor
    func testSuggestionReviewItemsBackCorrectionsEditorActions() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults, lockedBaseline: fixtureBaseline)
        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        evidenceStore.record(correctionEvidence(id: "one", final: "open widget pro", edited: "open WidgetPro"))
        evidenceStore.record(correctionEvidence(id: "two", final: "launch widget pro", edited: "launch WidgetPro"))

        let item = try XCTUnwrap(CorrectionSuggestionReviewItem.items(
            evidenceStore: evidenceStore,
            store: store
        ).first)

        XCTAssertTrue(item.canAccept)
        XCTAssertTrue(store.acceptPromotion(item.assessment))
        XCTAssertTrue(CorrectionSuggestionReviewItem.items(evidenceStore: evidenceStore, store: store).isEmpty)
        XCTAssertEqual(store.canonicalize("open widget pro"), "open WidgetPro")
    }

    func testCanonicalizerDoesNotRewriteSubstrings() {
        let canonicalizer = TranscriptCanonicalizer()

        XCTAssertEqual(canonicalizer.canonicalize("the simuxed branch"), "the simuxed branch")
        XCTAssertEqual(canonicalizer.canonicalize("print env before running"), "print env before running")
        XCTAssertEqual(
            canonicalizer.canonicalize("source dot env before running"),
            "source .env before running"
        )
    }

    func testCanonicalizerAppliesContextualRules() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "Aster", aliases: ["esther"], contexts: ["message to"])
        ])

        XCTAssertEqual(canonicalizer.canonicalize("message to Esther"), "message to Aster")
        XCTAssertEqual(canonicalizer.canonicalize("Esther sent the note"), "Esther sent the note")
    }

    func testCanonicalizerNormalizesCommandTokens() {
        let canonicalizer = TranscriptCanonicalizer()

        let raw = "pass dash dash verbose then use dollar home and slash goal"
        let cleaned = canonicalizer.canonicalize(raw)

        XCTAssertEqual(cleaned, "pass --verbose then use $HOME and /goal")
    }

    func testCanonicalizerNormalizesRecognizerPunctuatedDashDashCommand() {
        // The recognizer punctuates the spoken command "dash dash fix" as
        // "Dash, dash, fix." (verified by replaying the saved audio). The flag-prefix
        // pre-pass must consume the whole run despite the commas, or the bare
        // `dash dash`->`--` alias matches only "Dash, dash" and strands the comma as
        // "--, fix". The trailing period is the recognizer's sentence punctuation.
        let canonicalizer = TranscriptCanonicalizer()
        XCTAssertEqual(canonicalizer.canonicalize("Dash, dash, fix."), "--fix.")
        XCTAssertEqual(canonicalizer.canonicalize("dash dash fix"), "--fix")
        XCTAssertEqual(canonicalizer.canonicalize("dash dash, fix"), "--fix")
    }

    func testCanonicalizerLoadsSavedRulesFromUserDefaults() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CorrectionDictionary.saveRecords(
            [
                CorrectionRecord(
                    id: "manual.widget-pro",
                    kind: .replacement,
                    canonical: "WidgetPro",
                    aliases: ["widget pro"],
                    contexts: ["open"],
                    source: .manual,
                    status: .active
                )
            ],
            to: defaults
        )

        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertEqual(canonicalizer.canonicalize("open widget pro"), "open WidgetPro")
        XCTAssertEqual(canonicalizer.canonicalize("compare widget pro"), "compare widget pro")
        XCTAssertEqual(canonicalizer.canonicalize("open siemux"), "open siemux")
    }

    func testCanonicalizerMigratesLegacyCustomRulesBeforeDefaults() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyCustomRules: [TranscriptCanonicalizer.Rule] = [
            .init(canonical: "MUX", aliases: ["simux"])
        ]
        let data = try JSONEncoder().encode(legacyCustomRules)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: TranscriptCanonicalizer.rulesDefaultsKey)

        let canonicalizer = TranscriptCanonicalizer.load(from: defaults)

        XCTAssertEqual(canonicalizer.canonicalize("open simux"), "open MUX")
        XCTAssertEqual(canonicalizer.canonicalize("edit agents dot md"), "edit AGENTS.md")
        XCTAssertNil(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey))
    }

    func testCanonicalizerLoadsEmptyDictionary() {
        let suiteName = "EposTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CorrectionDictionary.saveRecords([], to: defaults)

        XCTAssertNotNil(defaults.string(forKey: CorrectionDictionary.recordsDefaultsKey))
        XCTAssertTrue(TranscriptCanonicalizer.rules(from: defaults).isEmpty)
        XCTAssertEqual(TranscriptCanonicalizer.load(from: defaults).canonicalize("open siemux"), "open siemux")
    }

    @MainActor
    func testCorrectionStorePersistsAndCanonicalizesWithSavedRules() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults, lockedBaseline: fixtureBaseline)
        store.saveEditorRecords(
            [
                CorrectionRecord(
                    id: "manual.widget-pro",
                    kind: .replacement,
                    canonical: "WidgetPro",
                    aliases: ["widget pro"],
                    source: .manual,
                    status: .active
                )
            ]
        )

        // Live instance reflects the save without a reload.
        XCTAssertEqual(store.canonicalize("open widget pro"), "open WidgetPro")
        // A fresh store over the same defaults loads the persisted rule.
        XCTAssertEqual(CorrectionStore(defaults: defaults, lockedBaseline: fixtureBaseline).canonicalize("open widget pro"), "open WidgetPro")
    }
}

/// Fixture baseline so store construction never reads the machine's frozen corpus.
private let fixtureBaseline = CorrectionLockedBaseline.confirmed([
    "the meeting starts at noon",
    "please review the draft"
])

private func correctionEvidence(id: String, final: String, edited: String) -> CorrectionEvidence {
    CorrectionEvidence(
        id: id,
        observedAt: Date(timeIntervalSince1970: 1),
        recordingID: id,
        rawTranscript: final,
        canonicalizedTranscript: final,
        finalInsertedTranscript: final,
        userEditedTranscript: edited,
        appliedRuleIDs: []
    )
}

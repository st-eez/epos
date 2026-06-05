import AVFoundation
import Speech
import XCTest
@testable import Epos

final class SmokeTests: XCTestCase {
    @MainActor
    func testCoordinatorStartsIdle() {
        // autoStart: false so the global NSEvent monitor isn't installed during tests.
        let coordinator = AppCoordinator(autoStart: false)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.finalText, "")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "")
    }

    @MainActor
    func testCoordinatorPromotesPartialAsFallbackFinalWhenNoFinalArrives() {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.handlePartialTranscript("volatile words")
        coordinator.promotePartialTranscriptAsFallbackFinalIfNeeded()

        XCTAssertEqual(coordinator.finalText, "volatile words")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "volatile words")
    }

    @MainActor
    func testCoordinatorFoldsTrailingPartialIntoFallbackFinal() {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.handleFinalTranscriptSegment("settled words")
        coordinator.handlePartialTranscript(" volatile tail")
        coordinator.promotePartialTranscriptAsFallbackFinalIfNeeded()

        XCTAssertEqual(coordinator.finalText, "settled words volatile tail")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "settled words volatile tail")
    }

    func testPermissionsSnapshotReturns() {
        let snapshot = PermissionsGate().snapshot()
        _ = snapshot.microphone
        _ = snapshot.speech
        _ = snapshot.accessibility
    }

    func testSettingsPersistsAudioSampleCaptureFlag() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        Settings(saveAudioSamples: true, saveCorrectionEvidence: false).save(to: defaults)

        XCTAssertTrue(Settings.load(from: defaults).saveAudioSamples)
        XCTAssertFalse(Settings.load(from: defaults).saveCorrectionEvidence)
    }

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

        let store = CorrectionStore(defaults: defaults)
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

    func testCanonicalizerLoadsSavedRulesFromUserDefaults() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rules = [
            TranscriptCanonicalizer.Rule(
                canonical: "WidgetPro",
                aliases: ["widget pro"],
                contexts: ["open"]
            )
        ]
        TranscriptCanonicalizer.saveRules(rules, to: defaults)

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

    func testCanonicalizerSavesEmptyRuleList() {
        let suiteName = "EposTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TranscriptCanonicalizer.saveRules([], to: defaults)

        XCTAssertNotNil(defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey))
        XCTAssertTrue(TranscriptCanonicalizer.rules(from: defaults).isEmpty)
        XCTAssertEqual(TranscriptCanonicalizer.load(from: defaults).canonicalize("open siemux"), "open siemux")
    }

    @MainActor
    func testCorrectionStorePersistsAndCanonicalizesWithSavedRules() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CorrectionStore(defaults: defaults)
        store.save([.init(canonical: "WidgetPro", aliases: ["widget pro"])])

        // Live instance reflects the save without a reload.
        XCTAssertEqual(store.canonicalize("open widget pro"), "open WidgetPro")
        // A fresh store over the same defaults loads the persisted rule.
        XCTAssertEqual(CorrectionStore(defaults: defaults).canonicalize("open widget pro"), "open WidgetPro")
    }

    func testRecordingIndicatorMeterRespondsToSpeechRange() {
        let quietHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.005) }
        let speechHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.03) }
        let loudHeights = (0..<5).map { RecordingIndicatorSurface.barHeight($0, amplitude: 0.08) }

        XCTAssertGreaterThan(speechHeights.reduce(0, +), quietHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.reduce(0, +), speechHeights.reduce(0, +))
        XCTAssertGreaterThan(loudHeights.max() ?? 0, quietHeights.max() ?? 0)
    }

    func testRecordingIndicatorLabelsFinalizationStages() {
        XCTAssertEqual(
            RecordingIndicatorSurface.statusText(state: .recording, finalizationPhase: .finalizingSpeech),
            "Listening"
        )
        XCTAssertEqual(
            RecordingIndicatorSurface.statusText(state: .finalizing, finalizationPhase: .finalizingSpeech),
            "Finishing"
        )
        XCTAssertEqual(
            RecordingIndicatorSurface.statusText(state: .finalizing, finalizationPhase: .polishing),
            "Polishing"
        )
        XCTAssertEqual(
            RecordingIndicatorSurface.statusText(state: .finalizing, finalizationPhase: .inserting),
            "Updating"
        )
    }

    func testInlineIndicatorFallsBackWhenCaretRectIsUnavailable() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let pillSize = CGSize(width: 144, height: 36)

        let fallback = RecordingIndicatorPlacementPolicy.frame(
            in: screen,
            indicatorSize: pillSize,
            protectedRect: nil
        )
        XCTAssertEqual(fallback.size.width, pillSize.width, accuracy: 0.001)
        XCTAssertEqual(fallback.size.height, pillSize.height, accuracy: 0.001)
        XCTAssertEqual(fallback.midX, screen.midX, accuracy: 0.001)
        XCTAssertEqual(
            fallback.minY,
            screen.minY + RecordingIndicatorPlacementPolicy.fallbackBottomInset,
            accuracy: 0.001
        )
        XCTAssertTrue(screen.contains(fallback))

        let caret = CGRect(x: 520, y: 420, width: 2, height: 24)
        let nearCaret = RecordingIndicatorPlacementPolicy.frame(
            in: screen,
            indicatorSize: pillSize,
            protectedRect: caret
        )
        XCTAssertTrue(screen.contains(nearCaret))
        XCTAssertLessThanOrEqual(nearCaret.maxY, caret.minY - RecordingIndicatorPlacementPolicy.clearance)
        XCTAssertFalse(nearCaret.intersects(caret.insetBy(
            dx: -RecordingIndicatorPlacementPolicy.clearance,
            dy: -RecordingIndicatorPlacementPolicy.clearance
        )))

        let lowCaret = CGRect(x: 520, y: 20, width: 2, height: 24)
        let flippedAbove = RecordingIndicatorPlacementPolicy.frame(
            in: screen,
            indicatorSize: pillSize,
            protectedRect: lowCaret
        )
        XCTAssertTrue(screen.contains(flippedAbove))
        XCTAssertGreaterThanOrEqual(
            flippedAbove.minY,
            lowCaret.maxY + RecordingIndicatorPlacementPolicy.clearance
        )

        let rightEdgeCaret = CGRect(x: 1410, y: 420, width: 2, height: 24)
        let nudgedInside = RecordingIndicatorPlacementPolicy.frame(
            in: screen,
            indicatorSize: pillSize,
            protectedRect: rightEdgeCaret
        )
        XCTAssertTrue(screen.contains(nudgedInside))
        XCTAssertEqual(nudgedInside.maxX, screen.maxX, accuracy: 0.001)
    }

    func testLocalInstallDoesNotRegisterInputMethod() throws {
        let root = repositoryRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/install-local-app.sh"),
            encoding: .utf8
        )

        XCTAssertFalse(script.contains("InputMethod"))
        XCTAssertFalse(script.contains("TISRegisterInputSource"))
    }

    func testProjectDoesNotDeclareInputMethodTarget() throws {
        let root = repositoryRoot()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        XCTAssertFalse(project.contains("EposInputMethod"))
        XCTAssertFalse(project.contains("com.steez.inputmethod.Epos"))
    }

    func testKeystrokeInjectorChunksWithinUnicodeLimitOnGraphemeBoundaries() {
        // Short text stays a single event.
        XCTAssertEqual(
            KeystrokeTextInjector.unicodeChunks(of: "hello world", maxUTF16Units: 20)
                .map { String(utf16CodeUnits: $0, count: $0.count) },
            ["hello world"]
        )

        // Long text splits without exceeding the per-event UTF-16 budget and
        // reassembles to the original.
        let long = String(repeating: "ab", count: 40) // 80 UTF-16 units
        let chunks = KeystrokeTextInjector.unicodeChunks(of: long, maxUTF16Units: 20)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined(), long)

        // A grapheme whose UTF-16 width exceeds the budget is never split across
        // events — it rides intact in its own chunk.
        let emoji = "👍🏽" // surrogate pair + skin-tone modifier: 4 UTF-16 units
        let emojiChunks = KeystrokeTextInjector.unicodeChunks(of: "a" + emoji + "b", maxUTF16Units: 2)
        XCTAssertEqual(
            emojiChunks.map { String(utf16CodeUnits: $0, count: $0.count) },
            ["a", emoji, "b"]
        )
    }

    func testProgressiveInsertionStreamsEachPartialImmediately() {
        let backend = RecordingTextInsertionBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        session.acceptPartialTranscript("hello")
        session.acceptPartialTranscript("hello world")
        session.acceptPartialTranscript("hello world from")
        session.acceptPartialTranscript("hello world from epos")
        session.acceptFinalTranscript("hello world from epos")
        session.finish()

        // Each partial appends its new tail with no confirmation delay; the final
        // equals the committed text and is a no-op.
        XCTAssertEqual(backend.insertedTexts, ["hello", " world", " from", " epos"])
        XCTAssertEqual(backend.fieldText, "hello world from epos")
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testProgressiveInsertionCorrectsRevisionLiveOnPartials() {
        let backend = RecordingTextInsertionBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        session.acceptPartialTranscript("open the")
        session.acceptPartialTranscript("open the door")
        // The partial revises an already-typed word ("the" -> "a"); the session
        // backspaces the diverged suffix and retypes it live, no waiting for a final.
        session.acceptPartialTranscript("open a door")
        session.acceptFinalTranscript("open a door")
        session.finish()

        XCTAssertEqual(
            backend.operations,
            [.insert("open the"), .insert(" door"), .delete(8), .insert("a door")]
        )
        XCTAssertEqual(backend.fieldText, "open a door")
    }

    func testProgressiveInsertionAppliesCanonicalizerBeforeStreaming() {
        let backend = RecordingTextInsertionBackend()
        let canonicalizer = TranscriptCanonicalizer()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: canonicalizer.canonicalize
        )

        session.acceptPartialTranscript("run dash dash verbose mode")
        session.acceptPartialTranscript("run dash dash verbose mode now")
        session.acceptFinalTranscript("run dash dash verbose mode now")
        session.finish()

        XCTAssertEqual(backend.insertedTexts, ["run --verbose mode", " now"])
        XCTAssertEqual(backend.fieldText, "run --verbose mode now")
    }

    func testProgressiveInsertionSelfCorrectsLiveWhenPartialRevisesTypedWord() {
        let backend = RecordingTextInsertionBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        session.acceptPartialTranscript("hello world foo")
        // Each revising partial backspaces the diverged suffix and retypes it, so
        // the correction lands live instead of waiting for the segment final.
        session.acceptPartialTranscript("hello world bar")
        session.acceptPartialTranscript("hello there bar")
        session.acceptFinalTranscript("hello there bar")
        session.finish()

        XCTAssertEqual(
            backend.operations,
            [
                .insert("hello world foo"),
                .delete(3), .insert("bar"),
                .delete(9), .insert("there bar")
            ]
        )
        // The field converges exactly to the recognizer's final transcript.
        XCTAssertEqual(backend.fieldText, "hello there bar")
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testProgressiveInsertionCancelClosesSessionWithoutFinishing() {
        let backend = RecordingTextInsertionBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        session.acceptPartialTranscript("hello world from")
        session.acceptPartialTranscript("hello world from epos")
        session.cancel()
        // Post-cancel calls are no-ops; cancel is idempotent.
        session.acceptPartialTranscript("hello world from epos now")
        session.cancel()

        XCTAssertEqual(backend.insertedTexts, ["hello world from", " epos"])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testProgressiveInsertionRepeatedFinalCommitInsertsOnce() {
        // Mirrors the coordinator flow where handleFinalTranscriptSegment and
        // insertFinalTranscript both call acceptFinalTranscript with the same text.
        let backend = RecordingTextInsertionBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        session.acceptPartialTranscript("hello world from")
        session.acceptPartialTranscript("hello world from epos")
        session.acceptFinalTranscript("hello world from epos")
        session.acceptFinalTranscript("hello world from epos")
        session.finish()

        XCTAssertEqual(backend.insertedTexts, ["hello world from", " epos"])
        XCTAssertEqual(backend.finishCount, 1)
    }

    @MainActor
    func testCoordinatorFinalInsertionUsesProgressiveSession() {
        let backend = RecordingTextInsertionBackend()
        let coordinator = AppCoordinator(textInsertion: backend, autoStart: false)

        coordinator.insertFinalTranscript("hello final")

        XCTAssertEqual(backend.insertedTexts, ["hello final"])
        XCTAssertEqual(backend.finishCount, 1)
    }

    func testDiagnosticLogSinkWritesDirectFile() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "hello\tworld\nnext")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\ttest\thello world next"))
    }

    func testDiagnosticLogSinkCanBeDisabled() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: false),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "ignored")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testDiagnosticLogConfigurationDefaultsAreDogfoodSized() {
        let configuration = DiagnosticLogConfiguration.load(from: [:])

        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.maxFileBytes, 10_000_000)
        XCTAssertEqual(configuration.maxFileCount, 14)
        XCTAssertEqual(configuration.maxMessageCharacters, 20_000)
    }

    func testDiagnosticLogConfigurationReadsDogfoodLimitOverrides() {
        let configuration = DiagnosticLogConfiguration.load(from: [
            "EPOS_DIAGNOSTIC_MAX_FILE_BYTES": "123456",
            "EPOS_DIAGNOSTIC_MAX_FILE_COUNT": "3",
            "EPOS_DIAGNOSTIC_MAX_MESSAGE_CHARS": "4567"
        ])

        XCTAssertEqual(configuration.maxFileBytes, 123_456)
        XCTAssertEqual(configuration.maxFileCount, 3)
        XCTAssertEqual(configuration.maxMessageCharacters, 4_567)
    }

    func testDiagnosticLogSinkUsesConfiguredMessageLimit() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(
                enabled: true,
                maxFileBytes: 100_000,
                maxFileCount: 7,
                maxMessageCharacters: 12
            ),
            directory: directory
        )

        sink.append(level: .info, category: "test", message: "abcdefghijklmnop")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\ttest\tabcdefghijkl\n"))
    }

    func testEposLoggerPrefixesActiveRecordingID() throws {
        RecordingLogContext.clear()
        defer { RecordingLogContext.clear() }
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )
        let logger = EposLogger(category: "test", diagnostics: sink)

        RecordingLogContext.activate("rec-test")
        logger.info("hello")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\ttest\trecordingID=rec-test hello"))
    }

    func testRecordingLogContextClearSpecificIDDoesNotClearNewerID() {
        RecordingLogContext.clear()
        defer { RecordingLogContext.clear() }

        RecordingLogContext.activate("old-rec")
        RecordingLogContext.activate("new-rec")
        RecordingLogContext.clear("old-rec")

        XCTAssertEqual(RecordingLogContext.currentRecordingID, "new-rec")
    }

    func testTranscriptTimingDiagnosticsRedactsTranscriptTextByDefault() {
        var diagnostics = TranscriptTimingDiagnostics()
        diagnostics.start(now: Date(timeIntervalSince1970: 100))

        let message = diagnostics.eventMessage(
            kind: .partial,
            eventText: "private dictated phrase\nnext\tline",
            finalText: "private",
            partialText: "dictated phrase\nnext\tline",
            now: Date(timeIntervalSince1970: 101.234)
        )

        XCTAssertTrue(message.contains("transcript timing"))
        XCTAssertTrue(message.contains("seq=1"))
        XCTAssertTrue(message.contains("kind=partial"))
        XCTAssertTrue(message.contains("elapsedMs=1234"))
        XCTAssertTrue(message.contains("eventChars=33"))
        XCTAssertTrue(message.contains("finalChars=7"))
        XCTAssertTrue(message.contains("partialChars=25"))
        XCTAssertTrue(message.contains("displayChars=32"))
        XCTAssertFalse(message.contains("private dictated phrase"))
        XCTAssertFalse(message.contains("eventText="))
        XCTAssertFalse(message.contains("finalText="))
        XCTAssertFalse(message.contains("partialText="))
        XCTAssertFalse(message.contains("displayText="))
    }

    func testTranscriptTimingDiagnosticsCanOptIntoTranscriptText() {
        var diagnostics = TranscriptTimingDiagnostics(includeTranscriptText: true)
        diagnostics.start(now: Date(timeIntervalSince1970: 100))

        let message = diagnostics.eventMessage(
            kind: .partial,
            eventText: "private dictated phrase\nnext\tline",
            finalText: "private",
            partialText: "dictated phrase\nnext\tline",
            now: Date(timeIntervalSince1970: 101.234)
        )

        XCTAssertTrue(message.contains(#"eventText="private dictated phrase\nnext\tline""#))
        XCTAssertTrue(message.contains(#"finalText="private""#))
        XCTAssertTrue(message.contains(#"partialText="dictated phrase\nnext\tline""#))
        XCTAssertTrue(message.contains(#"displayText="privatedictated phrase\nnext\tline""#))
    }

    @MainActor
    func testCoordinatorTranscriptTimingLogRedactsRawTranscriptTextByDefault() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )
        let coordinator = AppCoordinator(
            textInsertion: RecordingTextInsertionBackend(),
            diagnostics: sink,
            autoStart: false
        )

        coordinator.handlePartialTranscript("raw partial\nnext\tline")
        coordinator.logTranscriptTiming(kind: .partial, eventText: "raw partial\nnext\tline")
        coordinator.handleFinalTranscriptSegment("raw final")
        coordinator.logTranscriptTiming(kind: .final, eventText: "raw final")
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("\tinfo\tcoordinator\ttranscript timing seq=1 kind=partial"))
        XCTAssertTrue(contents.contains("\tinfo\tcoordinator\ttranscript timing seq=2 kind=final"))
        XCTAssertFalse(contents.contains("raw partial"))
        XCTAssertFalse(contents.contains("raw final"))
        XCTAssertFalse(contents.contains("eventText="))
        XCTAssertFalse(contents.contains("finalText="))
        XCTAssertFalse(contents.contains("partialText="))
        XCTAssertFalse(contents.contains("displayText="))
    }

    @MainActor
    func testCoordinatorPolishRejectionLogRedactsRawAndCandidateTextByDefault() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )
        let coordinator = AppCoordinator(
            textInsertion: RecordingTextInsertionBackend(),
            diagnostics: sink,
            autoStart: false
        )
        let rejection = PolishGuardRejection(
            reason: .contentTokensChanged,
            candidateText: "Test first thing.\nNext line",
            candidateCharacterCount: 27,
            diff: "kind=raw-token-changed hint=ordinal-normalization"
        )

        coordinator.logPolishOutcome(
            outcome: .guardRejected,
            rawText: "test 1st thing\nnext line",
            polishedCount: 0,
            rawCount: 24,
            guardRejection: rejection,
            elapsedMs: 12
        )
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("polish rejected: retention guard"))
        XCTAssertTrue(contents.contains("rawText=<redacted>"))
        XCTAssertFalse(contents.contains("test 1st thing"))
        XCTAssertFalse(contents.contains("Test first thing"))
        XCTAssertFalse(contents.contains("candidateText="))
        XCTAssertTrue(contents.contains("reason=content-tokens-changed"))
        XCTAssertTrue(contents.contains("candidateChars=27"))
        XCTAssertTrue(contents.contains("hint=ordinal-normalization"))
    }

    @MainActor
    func testCoordinatorPolishRejectionLogCanOptIntoRawAndCandidateText() throws {
        let directory = try makeTemporaryDirectory()
        let sink = DiagnosticLogSink(
            configuration: .init(enabled: true, maxFileBytes: 100_000, maxFileCount: 7),
            directory: directory
        )
        let coordinator = AppCoordinator(
            textInsertion: RecordingTextInsertionBackend(),
            diagnostics: sink,
            includeTranscriptTextInDiagnostics: true,
            autoStart: false
        )
        let rejection = PolishGuardRejection(
            reason: .contentTokensChanged,
            candidateText: "Test first thing.\nNext line",
            candidateCharacterCount: 27,
            diff: "kind=raw-token-changed hint=ordinal-normalization"
        )

        coordinator.logPolishOutcome(
            outcome: .guardRejected,
            rawText: "test 1st thing\nnext line",
            polishedCount: 0,
            rawCount: 24,
            guardRejection: rejection,
            elapsedMs: 12
        )
        sink.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(contents.contains(#"rawText="test 1st thing\nnext line""#))
        XCTAssertTrue(contents.contains(#"candidateText="Test first thing.\nNext line""#))
    }

    func testDogfoodTapDiscardsRecordingWhenTranscriptIsEmpty() throws {
        let directory = try makeTemporaryDirectory()
        let tap = DogfoodTap(recordingsDirectory: directory)
        tap.write(try makePCMBuffer())
        tap.stop(keeping: false)
        tap.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }

    func testDogfoodTapKeepsRecordingWhenTranscriptExists() throws {
        let directory = try makeTemporaryDirectory()
        let tap = DogfoodTap(recordingsDirectory: directory)
        tap.write(try makePCMBuffer())
        tap.stop(keeping: true)
        tap.flush()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.filter { $0.pathExtension == "wav" }.count, 1)
    }

    func testTranscriberPresetRequestsLowLatencyVolatileResults() {
        XCTAssertTrue(Transcriber.speechPreset.reportingOptions.contains(.volatileResults))
        XCTAssertTrue(Transcriber.speechPreset.reportingOptions.contains(.fastResults))
        XCTAssertFalse(Transcriber.speechPreset.reportingOptions.contains(.alternativeTranscriptions))
    }

    func testCanonicalVocabularyStringsSkipsPureSymbolsAndDeduplicates() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "CMUX", aliases: ["see mux"]),
            .init(canonical: "--", aliases: ["dash dash"]),
            .init(canonical: "/", aliases: ["slash"]),
            .init(canonical: "cmux", aliases: ["cmox"]),
            .init(canonical: "Epos", aliases: ["epos"])
        ])

        // Pure-punctuation canonicals are dropped; case-insensitive duplicates collapse.
        XCTAssertEqual(canonicalizer.canonicalVocabularyStrings, ["CMUX", "Epos"])
    }

    func testSpeechContextualStringsIncludesUsefulUnguardedAliases() {
        let canonicalizer = TranscriptCanonicalizer(rules: [
            .init(canonical: "CMUX", aliases: ["see mux"]),
            .init(canonical: "--", aliases: ["dash dash"]),
            .init(canonical: "/", aliases: ["slash"]),
            .init(canonical: "cmux", aliases: ["cmox"]),
            .init(canonical: "Epos", aliases: ["epos"]),
            .init(canonical: "Aster", aliases: ["esther"], contexts: ["message to"])
        ])

        XCTAssertEqual(
            canonicalizer.speechContextualStrings,
            ["CMUX", "see mux", "dash dash", "slash", "cmox", "Epos", "Aster"]
        )
    }

    func testAnalysisContextNilForEmptyOrBlankVocabulary() {
        XCTAssertNil(Transcriber.analysisContext(contextualStrings: []))
        XCTAssertNil(Transcriber.analysisContext(contextualStrings: ["   ", ""]))
        XCTAssertNotNil(Transcriber.analysisContext(contextualStrings: ["Epos"]))
    }

    func testAnalysisContextTrimsDeduplicatesAndPreservesOrder() throws {
        let context = try XCTUnwrap(Transcriber.analysisContext(contextualStrings: [
            " Epos ",
            "epos",
            "CMUX",
            "cmux"
        ]))

        XCTAssertEqual(context.contextualStrings[.general], ["Epos", "CMUX"])
    }

    /// Regression: pre-fix, `Transcriber.finish()` hung in `await drain?.value`
    /// because Apple's `SpeechTranscriber.results` does not terminate after
    /// `cancelAndFinishNow()` on an analyzer that received zero input. Reproduces
    /// when fn is tapped too fast for any audio buffer to arrive.
    func testFinishWithoutInputReturnsPromptly() async throws {
        let transcriber = Transcriber(locale: Locale(identifier: "en-US"))
        do {
            _ = try await transcriber.start()
        } catch {
            throw XCTSkip("Transcriber.start() unavailable in test env: \(error)")
        }

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await transcriber.finish()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        XCTAssertTrue(finished, "Transcriber.finish() hung with no input")
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("EposTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func correctionEvidence(id: String, final: String, edited: String) -> CorrectionEvidence {
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

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private final class RecordingTextInsertionBackend: TextInsertionBackend {
    enum Operation: Equatable {
        case insert(String)
        case delete(Int)
    }

    private(set) var operations: [Operation] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    /// Inserted strings, in order — convenience for tests that only care about
    /// what was typed.
    var insertedTexts: [String] {
        operations.compactMap { if case .insert(let text) = $0 { text } else { nil } }
    }

    /// Replays the recorded inserts/deletes to reconstruct the focused field's
    /// contents — the assertion that matters for self-correction.
    var fieldText: String {
        operations.reduce(into: "") { field, operation in
            switch operation {
            case .insert(let text): field += text
            case .delete(let count): field.removeLast(min(count, field.count))
            }
        }
    }

    func startInsertionSession() -> any TextInsertionSession {
        RecordingTextInsertionSession(backend: self)
    }

    fileprivate func record(_ operation: Operation) {
        operations.append(operation)
    }

    private func finishSession() {
        finishCount += 1
    }

    private func cancelSession() {
        cancelCount += 1
    }

    private final class RecordingTextInsertionSession: TextInsertionSession {
        private let backend: RecordingTextInsertionBackend

        init(backend: RecordingTextInsertionBackend) {
            self.backend = backend
        }

        func insert(_ text: String) {
            backend.record(.insert(text))
        }

        func deleteBackward(count: Int) {
            backend.record(.delete(count))
        }

        func finish() {
            backend.finishSession()
        }

        func cancel() {
            backend.cancelSession()
        }
    }
}

private func makePCMBuffer() throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128) else {
        throw XCTSkip("Unable to create PCM buffer")
    }
    buffer.frameLength = 128
    if let samples = buffer.floatChannelData?[0] {
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = 0.01
        }
    }
    return buffer
}

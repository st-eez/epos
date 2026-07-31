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
            appliedRuleIDs: ["builtin.cmux"]
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
            appliedRuleIDs: []
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

    func testEditedMissEvidenceTrimsSentencePunctuationFromSuggestedRecord() throws {
        let evidence = CorrectionEvidence(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "open widget pro.",
            canonicalizedTranscript: "open widget pro.",
            finalInsertedTranscript: "open widget pro.",
            userEditedTranscript: "open WidgetPro.",
            appliedRuleIDs: []
        )

        let suggested = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: [evidence]).first)

        XCTAssertEqual(suggested.canonical, "WidgetPro")
        XCTAssertEqual(suggested.aliases, ["widget pro"])

        let accepted = CorrectionRecord(
            id: suggested.id,
            kind: suggested.kind,
            canonical: suggested.canonical,
            aliases: suggested.aliases,
            source: suggested.source,
            status: .active
        )
        let canonicalizer = TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: [accepted]))
        XCTAssertEqual(canonicalizer.canonicalize("open widget pro."), "open WidgetPro.")
    }

    func testEditedMissEvidenceTrimsEditedOnlySentencePunctuationFromSuggestedRecord() throws {
        let evidence = CorrectionEvidence(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "open widget pro",
            canonicalizedTranscript: "open widget pro",
            finalInsertedTranscript: "open widget pro",
            userEditedTranscript: "open WidgetPro.",
            appliedRuleIDs: []
        )

        let suggested = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: [evidence]).first)

        XCTAssertEqual(suggested.canonical, "WidgetPro")
        XCTAssertEqual(suggested.aliases, ["widget pro"])

        let accepted = CorrectionRecord(
            id: suggested.id,
            kind: suggested.kind,
            canonical: suggested.canonical,
            aliases: suggested.aliases,
            source: suggested.source,
            status: .active
        )
        let canonicalizer = TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: [accepted]))
        XCTAssertEqual(canonicalizer.canonicalize("launch widget pro now"), "launch WidgetPro now")
    }

    func testEditedMissEvidencePreservesInternalCanonicalPunctuation() throws {
        let evidence = CorrectionEvidence(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "edit agents dot md,",
            canonicalizedTranscript: "edit agents dot md,",
            finalInsertedTranscript: "edit agents dot md,",
            userEditedTranscript: "edit AGENTS.md,",
            appliedRuleIDs: []
        )

        let suggested = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: [evidence]).first)

        XCTAssertEqual(suggested.canonical, "AGENTS.md")
        XCTAssertEqual(suggested.aliases, ["agents dot md"])
    }

    func testEditedMissEvidencePreservesMeaningfulEdgePunctuation() throws {
        let suggestions = CorrectionCandidateSuggester.suggestedRecords(from: [
            CorrectionEvidence(
                id: "evidence-1",
                observedAt: Date(timeIntervalSince1970: 1),
                recordingID: "rec-1",
                rawTranscript: "open git ignore",
                canonicalizedTranscript: "open git ignore",
                finalInsertedTranscript: "open git ignore",
                userEditedTranscript: "open .gitignore",
                appliedRuleIDs: []
            ),
            CorrectionEvidence(
                id: "evidence-2",
                observedAt: Date(timeIntervalSince1970: 2),
                recordingID: "rec-2",
                rawTranscript: "call foo parens",
                canonicalizedTranscript: "call foo parens",
                finalInsertedTranscript: "call foo parens",
                userEditedTranscript: "call foo()",
                appliedRuleIDs: []
            ),
            CorrectionEvidence(
                id: "evidence-3",
                observedAt: Date(timeIntervalSince1970: 3),
                recordingID: "rec-3",
                rawTranscript: "call widget pro()",
                canonicalizedTranscript: "call widget pro()",
                finalInsertedTranscript: "call widget pro()",
                userEditedTranscript: "call WidgetPro()",
                appliedRuleIDs: []
            )
        ])

        XCTAssertEqual(suggestions.map(\.canonical), [".gitignore", "foo()", "WidgetPro()"])
        XCTAssertEqual(suggestions.map(\.aliases), [["git ignore"], ["foo parens"], ["widget pro()"]])
    }

    func testEditedMissEvidencePreservesSharedMeaningfulLeadingPunctuation() throws {
        let evidence = CorrectionEvidence(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "open .git ignore",
            canonicalizedTranscript: "open .git ignore",
            finalInsertedTranscript: "open .git ignore",
            userEditedTranscript: "open .gitignore",
            appliedRuleIDs: []
        )

        let suggested = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: [evidence]).first)

        XCTAssertEqual(suggested.canonical, ".gitignore")
        XCTAssertEqual(suggested.aliases, [".git ignore"])
    }

    func testEditedMissEvidencePreservesPurePunctuationCanonical() throws {
        let evidence = CorrectionEvidence(
            id: "evidence-1",
            observedAt: Date(timeIntervalSince1970: 1),
            recordingID: "rec-1",
            rawTranscript: "question mark",
            canonicalizedTranscript: "question mark",
            finalInsertedTranscript: "question mark",
            userEditedTranscript: "?",
            appliedRuleIDs: []
        )

        let suggested = try XCTUnwrap(CorrectionCandidateSuggester.suggestedRecords(from: [evidence]).first)

        XCTAssertEqual(suggested.canonical, "?")
        XCTAssertEqual(suggested.aliases, ["question mark"])
    }

    func testEditedMissEvidencePreservesSpokenPunctuationAttachedToWord() throws {
        let suggestions = CorrectionCandidateSuggester.suggestedRecords(from: [
            CorrectionEvidence(
                id: "evidence-1",
                observedAt: Date(timeIntervalSince1970: 1),
                recordingID: "rec-1",
                rawTranscript: "are you sure question mark",
                canonicalizedTranscript: "are you sure question mark",
                finalInsertedTranscript: "are you sure question mark",
                userEditedTranscript: "are you sure?",
                appliedRuleIDs: []
            ),
            CorrectionEvidence(
                id: "evidence-2",
                observedAt: Date(timeIntervalSince1970: 2),
                recordingID: "rec-2",
                rawTranscript: "are you sure exclamation point",
                canonicalizedTranscript: "are you sure exclamation point",
                finalInsertedTranscript: "are you sure exclamation point",
                userEditedTranscript: "are you sure!",
                appliedRuleIDs: []
            )
        ])

        XCTAssertEqual(suggestions.map(\.canonical), ["sure?", "sure!"])
        XCTAssertEqual(suggestions.map(\.aliases), [["sure question mark"], ["sure exclamation point"]])

        let accepted = suggestions.map { suggested in
            CorrectionRecord(
                id: suggested.id,
                kind: suggested.kind,
                canonical: suggested.canonical,
                aliases: suggested.aliases,
                source: suggested.source,
                status: .active
            )
        }
        let canonicalizer = TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: accepted))
        XCTAssertEqual(canonicalizer.canonicalize("are you sure question mark"), "are you sure?")
        XCTAssertEqual(canonicalizer.canonicalize("are you sure exclamation point"), "are you sure!")
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
            appliedRuleIDs: []
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

    func testAppliedRuleIDsRespectPersonNameSlotRules() {
        let dictionary = CorrectionDictionary(records: [
            CorrectionRecord(
                id: "person",
                kind: .lexicon,
                canonical: "Test Person",
                aliases: ["test person", "tas"],
                ambiguousAliases: ["steph", "step"],
                lexiconClass: .person,
                source: .manual,
                status: .active
            )
        ])

        XCTAssertEqual(dictionary.appliedRecordIDs(in: "ask Steph to review"), ["person"])
        XCTAssertEqual(
            TranscriptCanonicalizer(
                rules: CorrectionRuleCompiler.compile(records: dictionary.records)
            ).canonicalize("message to Step"),
            "message to Test Person"
        )
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "message to Step"), ["person"])
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "next step"), [String]())
    }

    func testRulesMatchOnlyOriginalTranscriptAndAppliedIDsAgree() {
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
            "bar"
        )
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "foo"), ["first"])
    }

    /// `dash dash <flag>` is a pre-pass, not a rule: it is credited to no record, and it
    /// keeps working when the `dash dash` -> `--` row is disabled. Bare "dash dash" is
    /// that row's own job, so it is attributed to the row and stops when the row does.
    func testDashDashFlagExpansionIsUnattributedAndRuleIndependent() {
        let active = CorrectionRecord(
            id: "flag",
            kind: .spokenCommand,
            canonical: "--",
            aliases: ["dash dash"],
            source: .manual,
            status: .active
        )
        var disabled = active
        disabled.status = .disabled

        for record in [active, disabled] {
            let dictionary = CorrectionDictionary(records: [record])
            XCTAssertEqual(
                TranscriptCanonicalizer(
                    rules: CorrectionRuleCompiler.compile(records: dictionary.records)
                ).canonicalize("dash dash verbose"),
                "--verbose",
                record.status.rawValue
            )
            XCTAssertEqual(dictionary.appliedRecordIDs(in: "dash dash verbose"), [], record.status.rawValue)
        }

        XCTAssertEqual(CorrectionDictionary(records: [active]).appliedRecordIDs(in: "append dash dash"), ["flag"])
        XCTAssertEqual(CorrectionDictionary(records: [disabled]).appliedRecordIDs(in: "append dash dash"), [])
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
            finalTranscript: "open CMUX",
            applied: true,
            recordingID: "rec-1"
        )

        let evidence = try XCTUnwrap(evidenceStore.evidence.first)
        XCTAssertEqual(evidence.recordingID, "rec-1")
        XCTAssertEqual(evidence.rawTranscript, "open siemux")
        XCTAssertEqual(evidence.canonicalizedTranscript, "open CMUX")
        XCTAssertEqual(evidence.finalInsertedTranscript, "open CMUX")
        XCTAssertEqual(evidence.appliedRuleIDs, ["builtin.cmux"])
    }

    @MainActor
    func testCoordinatorSkipsCorrectionEvidenceWhenCorrectionEvidenceCaptureDisabled() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            recordingIDGenerator: { "rec-1" },
            autoStart: false
        )

        let evidenceID = coordinator.recordCorrectionEvidenceIfEnabled(
            enabled: false,
            rawTranscript: "open siemux",
            finalTranscript: "open CMUX",
            applied: true,
            recordingID: "rec-1"
        )

        XCTAssertNil(evidenceID)
        XCTAssertTrue(evidenceStore.evidence.isEmpty)
    }

    @MainActor
    func testCoordinatorSkipsCorrectionEvidenceWhenFinalInsertDidNotLand() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            recordingIDGenerator: { "rec-1" },
            autoStart: false
        )

        let evidenceID = coordinator.recordCorrectionEvidenceIfEnabled(
            enabled: true,
            rawTranscript: "open siemux",
            finalTranscript: "open CMUX",
            applied: false,
            finalInsertedTranscript: nil,
            recordingID: "rec-1"
        )

        XCTAssertNil(evidenceID)
        XCTAssertTrue(evidenceStore.evidence.isEmpty)
    }

    @MainActor
    func testCoordinatorRecordsCorrectionEvidenceWhenFinalInsertLanded() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            recordingIDGenerator: { "rec-1" },
            autoStart: false
        )

        let evidenceID = coordinator.recordCorrectionEvidenceIfEnabled(
            enabled: true,
            rawTranscript: "open siemux",
            finalTranscript: "open CMUX",
            applied: true,
            finalInsertedTranscript: "open CMUX",
            recordingID: "rec-1"
        )

        XCTAssertNotNil(evidenceID)
        XCTAssertEqual(evidenceStore.evidence.first?.finalInsertedTranscript, "open CMUX")
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
            finalTranscript: "open widget pro",
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
    func testCoordinatorCapturesInsertionTargetContext() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            recordingIDGenerator: { "rec-1" },
            autoStart: false
        )
        let observer = EvidenceFakeTargetObserver()
        observer.applicationBundleIdentifier = "com.example.editor"
        observer.windowTitle = "Draft.md"
        let session = FinalTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            target: observer
        )

        _ = session.insertFinalResult("open widget pro")
        coordinator.recordCorrectionEvidence(
            rawTranscript: "open widget pro",
            finalTranscript: "open widget pro",
            applied: true,
            recordingID: "rec-1",
            session: session
        )

        let evidence = try XCTUnwrap(evidenceStore.evidence.first)
        XCTAssertEqual(evidence.applicationBundleIdentifier, "com.example.editor")
        XCTAssertEqual(evidence.windowTitle, "Draft.md")
    }

    @MainActor
    func testCoordinatorSchedulesObservedUserEditCapture() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            observedEditCaptureDelays: [0],
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
            appliedRuleIDs: []
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        let session = FinalTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            target: observer
        )

        _ = session.insertFinalResult("widget pro")
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

    @MainActor
    func testCoordinatorCapturesObservedUserEditAcrossSparseWindow() async throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            observedEditCaptureDelays: [0.02, 0.06, 0.10],
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
            appliedRuleIDs: []
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        let session = FinalTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            target: observer
        )

        _ = session.insertFinalResult("widget pro")
        session.finish()
        observer.value = "open widget pro please"
        coordinator.scheduleObservedUserEditCapture(
            evidenceID: evidenceID,
            finalInsertedTranscript: "widget pro",
            session: session
        )

        try await Task.sleep(nanoseconds: 40_000_000)
        observer.value = "open WidgetPro please"
        try await Task.sleep(nanoseconds: 40_000_000)
        observer.value = "open WidgetProX please"
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(evidenceStore.evidence.first?.userEditedTranscript, "WidgetPro")
        XCTAssertEqual(evidenceStore.suggestedRecords.map(\.canonical), ["WidgetPro"])
    }

    @MainActor
    func testCoordinatorNilObservedEditSessionCancelsPendingChecks() async throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            observedEditCaptureDelays: [0.04],
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
            appliedRuleIDs: []
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        observer.value = "open WidgetPro please"
        let session = FinalTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            target: observer
        )

        _ = session.insertFinalResult("widget pro")
        session.finish()
        coordinator.scheduleObservedUserEditCapture(
            evidenceID: evidenceID,
            finalInsertedTranscript: "widget pro",
            session: session
        )
        coordinator.scheduleObservedUserEditCapture(
            evidenceID: evidenceID,
            finalInsertedTranscript: "widget pro",
            session: nil
        )

        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(evidenceStore.evidence.first?.userEditedTranscript)
        XCTAssertTrue(evidenceStore.suggestedRecords.isEmpty)
    }

    func testObservedEditFilterRejectsEmptyObservedText() {
        XCTAssertNil(ObservedUserEditFilter.validatedEdit(
            observed: "",
            final: "open widget pro"
        ))
    }

    func testObservedEditFilterRejectsWhitespaceOnlyObservedText() {
        XCTAssertNil(ObservedUserEditFilter.validatedEdit(
            observed: " \n\t\u{00A0} ",
            final: "open widget pro"
        ))
    }

    func testObservedEditFilterRejectsStrictTruncationPrefixOfFinal() {
        // Deletion-in-progress read; trailing NBSP mirrors real record 7dae3556
        // and must not defeat the prefix comparison.
        XCTAssertNil(ObservedUserEditFilter.validatedEdit(
            observed: "is using the on-hand quantity of\u{00A0}",
            final: "is using the on-hand quantity of today / live so the numbers stay current"
        ))
    }

    func testObservedEditFilterRejectsMidEditReadShorterThanHalfTheFinal() {
        // Real record 7dae3556: a mid-edit typo defeats the strict prefix test,
        // so the word-count gate has to catch it (7 of 16 words).
        XCTAssertNil(ObservedUserEditFilter.validatedEdit(
            observed: "is using the onh hand quantity of\u{00A0}",
            final: "is using the on-hand quantity of today / live so the numbers stay current and correct"
        ))
    }

    func testObservedEditFilterAcceptsGenuineWordCorrection() {
        XCTAssertEqual(
            ObservedUserEditFilter.validatedEdit(
                observed: "open WidgetPro please",
                final: "open widget pro please"
            ),
            "open WidgetPro please"
        )
    }

    func testObservedEditFilterAcceptsSpokenPunctuationCorrection() {
        XCTAssertEqual(
            ObservedUserEditFilter.validatedEdit(
                observed: "are you sure?",
                final: "are you sure question mark"
            ),
            "are you sure?"
        )
    }

    @MainActor
    func testCoordinatorSkipsObservedEditCaptureWhenFieldReadsBackEmpty() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let evidenceStore = CorrectionEvidenceStore(defaults: defaults)
        let coordinator = AppCoordinator(
            correctionEvidence: evidenceStore,
            observedEditCaptureDelays: [0],
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
            appliedRuleIDs: []
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        let session = FinalTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            target: observer
        )

        _ = session.insertFinalResult("widget pro")
        session.finish()
        // The inserted segment was wiped: only the baseline prefix/suffix remain.
        observer.value = "open  please"
        coordinator.scheduleObservedUserEditCapture(
            evidenceID: evidenceID,
            finalInsertedTranscript: "widget pro",
            session: session
        )

        XCTAssertNil(evidenceStore.evidence.first?.userEditedTranscript)
        XCTAssertTrue(evidenceStore.suggestedRecords.isEmpty)
    }
}

private final class EvidenceFakeTargetObserver: InsertionTargetObserver {
    var focusChanged = false
    var value: String?
    var insertionContext: InsertionTargetContext?
    var applicationBundleIdentifier: String?
    var windowTitle: String?

    func captureBaseline() {}
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? {
        return value ?? insertionContext.map { $0.prefix + $0.selectedText + $0.suffix }
    }
    func observedSelectedRange() -> InsertionTargetTextRange? { insertionContext?.selectedRange }
    func requiresTextContextValidation() -> Bool { insertionContext != nil }
    func baselineInsertionContext() -> InsertionTargetContext? { insertionContext }
    func targetApplicationBundleIdentifier() -> String? { applicationBundleIdentifier }
    func targetWindowTitle() -> String? { windowTitle }
}

private final class EvidenceNoopTextInsertionSession: TextInsertionSession {
    func insert(_ text: String) -> Bool { true }
    func finish() {}
    func cancel() {}
}

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
            appliedRuleIDs: ["builtin.cmux"],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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
                appliedRuleIDs: [],
                polishOutcome: "disabled",
                engineOutcome: nil,
                guardRejectionReason: nil
            ),
            CorrectionEvidence(
                id: "evidence-2",
                observedAt: Date(timeIntervalSince1970: 2),
                recordingID: "rec-2",
                rawTranscript: "call foo parens",
                canonicalizedTranscript: "call foo parens",
                finalInsertedTranscript: "call foo parens",
                userEditedTranscript: "call foo()",
                appliedRuleIDs: [],
                polishOutcome: "disabled",
                engineOutcome: nil,
                guardRejectionReason: nil
            ),
            CorrectionEvidence(
                id: "evidence-3",
                observedAt: Date(timeIntervalSince1970: 3),
                recordingID: "rec-3",
                rawTranscript: "call widget pro()",
                canonicalizedTranscript: "call widget pro()",
                finalInsertedTranscript: "call widget pro()",
                userEditedTranscript: "call WidgetPro()",
                appliedRuleIDs: [],
                polishOutcome: "disabled",
                engineOutcome: nil,
                guardRejectionReason: nil
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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
                appliedRuleIDs: [],
                polishOutcome: "disabled",
                engineOutcome: nil,
                guardRejectionReason: nil
            ),
            CorrectionEvidence(
                id: "evidence-2",
                observedAt: Date(timeIntervalSince1970: 2),
                recordingID: "rec-2",
                rawTranscript: "are you sure exclamation point",
                canonicalizedTranscript: "are you sure exclamation point",
                finalInsertedTranscript: "are you sure exclamation point",
                userEditedTranscript: "are you sure!",
                appliedRuleIDs: [],
                polishOutcome: "disabled",
                engineOutcome: nil,
                guardRejectionReason: nil
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
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

    func testAppliedRuleIDsIncludeCascadedRules() {
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
            "Baz"
        )
        XCTAssertEqual(dictionary.appliedRecordIDs(in: "foo"), ["first", "second"])
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
            polishResult: PolishResult(
                text: "open CMUX",
                outcome: .disabled,
                rawCharacterCount: "open CMUX".count
            ),
            effectiveOutcome: .disabled,
            applied: true,
            recordingID: "rec-1"
        )

        let evidence = try XCTUnwrap(evidenceStore.evidence.first)
        XCTAssertEqual(evidence.recordingID, "rec-1")
        XCTAssertEqual(evidence.rawTranscript, "open siemux")
        XCTAssertEqual(evidence.canonicalizedTranscript, "open CMUX")
        XCTAssertEqual(evidence.finalInsertedTranscript, "open CMUX")
        XCTAssertEqual(evidence.appliedRuleIDs, ["builtin.cmux"])
        XCTAssertEqual(evidence.polishOutcome, "disabled")
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
            polishResult: PolishResult(
                text: "open CMUX",
                outcome: .disabled,
                rawCharacterCount: "open CMUX".count
            ),
            effectiveOutcome: .disabled,
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
            polishResult: PolishResult(
                text: "open CMUX",
                outcome: .disabled,
                rawCharacterCount: "open CMUX".count
            ),
            effectiveOutcome: .disabled,
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
            polishResult: PolishResult(
                text: "open CMUX",
                outcome: .disabled,
                rawCharacterCount: "open CMUX".count
            ),
            effectiveOutcome: .disabled,
            applied: false,
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
            polishResult: PolishResult(
                text: "open widget pro",
                outcome: .disabled,
                rawCharacterCount: "open widget pro".count
            ),
            effectiveOutcome: .disabled,
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
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptFinalTranscript("open widget pro")
        coordinator.recordCorrectionEvidence(
            rawTranscript: "open widget pro",
            polishResult: PolishResult(
                text: "open widget pro",
                outcome: .disabled,
                rawCharacterCount: "open widget pro".count
            ),
            effectiveOutcome: .disabled,
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptFinalTranscript("widget pro")
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        observer.value = "open widget pro please"
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptFinalTranscript("widget pro")
        session.finish()
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
            appliedRuleIDs: [],
            polishOutcome: "disabled",
            engineOutcome: nil,
            guardRejectionReason: nil
        ))
        let observer = EvidenceFakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        observer.value = "open WidgetPro please"
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: EvidenceNoopTextInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptFinalTranscript("widget pro")
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
}

private final class EvidenceFakeTargetObserver: InsertionTargetObserver {
    var focusChanged = false
    var value: String?
    var exposesText = false
    var insertionContext: InsertionTargetContext?
    var applicationBundleIdentifier: String?
    var windowTitle: String?

    func captureBaseline() {}
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? { value }
    func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    func exposesTextValue() -> Bool { exposesText }
    func verifiesFocusIdentity() -> Bool { false }
    func baselineInsertionContext() -> InsertionTargetContext? { insertionContext }
    func targetApplicationBundleIdentifier() -> String? { applicationBundleIdentifier }
    func targetWindowTitle() -> String? { windowTitle }
}

private final class EvidenceNoopTextInsertionSession: TextInsertionSession {
    func insert(_ text: String) {}
    func deleteBackward(count: Int) {}
    func finish() {}
    func cancel() {}
}

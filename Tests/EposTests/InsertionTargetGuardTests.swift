import XCTest
@testable import Epos

/// Unit tests for the pure guard decision. The Accessibility I/O it gates is not
/// unit-testable (it needs the installed signed app dictating into real apps), so
/// only the decision policy is covered here. A fake observer drives the session
/// tests so the latch behavior is exercised without touching AX.
final class InsertionTargetGuardTests: XCTestCase {
    func testFocusChangedAlwaysAborts() {
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "hello world", observed: .focusChanged),
            .abort
        )
        // Even with nothing typed yet, a moved focus aborts: a later append would
        // land in the wrong field.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "", observed: .focusChanged),
            .abort
        )
    }

    func testNotReadProceeds() {
        // We deliberately skipped the value read (append-only reconcile): proceed.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "hello", observed: .notRead),
            .proceed
        )
    }

    func testReadFactoryDistinguishesOpaqueFromTextExposingTargets() {
        // AX-opaque app that has never exposed text (e.g. cmux): empty/nil reads
        // are uninformative — keep self-correcting.
        XCTAssertEqual(InsertionTargetObservation.read(nil, exposesText: false), .notRead)
        XCTAssertEqual(InsertionTargetObservation.read("", exposesText: false), .notRead)
        // Field that has shown real text this session but now reads empty/nil: its
        // text vanished, which is genuine divergence.
        XCTAssertEqual(InsertionTargetObservation.read("", exposesText: true), .emptyExposed)
        XCTAssertEqual(InsertionTargetObservation.read(nil, exposesText: true), .emptyExposed)
        // A non-empty read is always a usable value regardless of the flag.
        XCTAssertEqual(InsertionTargetObservation.read("hello", exposesText: false), .value("hello"))
    }

    func testFocusFrameFailsSoftOnNonFiniteAXComponents() {
        // AX is a system boundary: a transitioning AX server can return NaN or
        // infinite frame components. Int(_: Double) traps on those, so the init
        // must fail to nil ("frame unreadable") instead of crashing mid-reconcile.
        XCTAssertNil(InsertionTargetFocusFrame(
            position: CGPoint(x: CGFloat.nan, y: 200),
            size: CGSize(width: 640, height: 80)
        ))
        XCTAssertNil(InsertionTargetFocusFrame(
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: CGFloat.infinity, height: 80)
        ))
        XCTAssertNil(InsertionTargetFocusFrame(
            position: CGPoint(x: 100, y: 200),
            size: CGSize(width: 640, height: 1e300)
        ))
        XCTAssertEqual(
            InsertionTargetFocusFrame(
                position: CGPoint(x: 100.4, y: 200),
                size: CGSize(width: 640, height: 80)
            ),
            InsertionTargetFocusFrame(x: 100, y: 200, width: 640, height: 80)
        )
    }

    func testOpaqueFocusSignatureDetectsSameAppFieldMoveWithoutElementIdentity() {
        let baseline = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: "terminal-input",
            frame: InsertionTargetFocusFrame(x: 100, y: 200, width: 640, height: 80)
        )
        let sameTargetFreshElement = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: "terminal-input",
            frame: InsertionTargetFocusFrame(x: 100, y: 220, width: 640, height: 100)
        )
        let movedTarget = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: "terminal-search",
            frame: InsertionTargetFocusFrame(x: 100, y: 80, width: 640, height: 40)
        )
        let roleOnlyBaseline = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: nil,
            frame: InsertionTargetFocusFrame(x: 100, y: 200, width: 640, height: 80)
        )
        let roleOnlyMovedTarget = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: nil,
            frame: InsertionTargetFocusFrame(x: 100, y: 80, width: 640, height: 40)
        )
        let roleOnlyResizedTarget = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: nil,
            frame: InsertionTargetFocusFrame(x: 100, y: 212, width: 640, height: 160)
        )
        let frameOnlyBaseline = InsertionTargetFocusSignature(
            role: nil,
            subrole: nil,
            identifier: nil,
            frame: InsertionTargetFocusFrame(x: 100, y: 200, width: 640, height: 80)
        )
        let frameOnlyMovedTarget = InsertionTargetFocusSignature(
            role: nil,
            subrole: nil,
            identifier: nil,
            frame: InsertionTargetFocusFrame(x: 100, y: 80, width: 640, height: 40)
        )

        XCTAssertFalse(
            InsertionTargetFocusSignature.changedWithinSameProcess(from: baseline, to: sameTargetFreshElement)
        )
        XCTAssertTrue(InsertionTargetFocusSignature.changedWithinSameProcess(from: baseline, to: movedTarget))
        XCTAssertTrue(
            InsertionTargetFocusSignature.changedWithinSameProcess(
                from: roleOnlyBaseline,
                to: roleOnlyMovedTarget
            )
        )
        XCTAssertFalse(
            InsertionTargetFocusSignature.changedWithinSameProcess(
                from: roleOnlyBaseline,
                to: roleOnlyResizedTarget
            )
        )
        XCTAssertTrue(
            InsertionTargetFocusSignature.changedWithinSameProcess(
                from: frameOnlyBaseline,
                to: frameOnlyMovedTarget
            )
        )
        XCTAssertFalse(InsertionTargetFocusSignature.changedWithinSameProcess(from: baseline, to: nil))
    }

    func testOpaqueFocusSignatureToleratesFlakyAttributeReads() {
        // Signature reads run under a short AX messaging timeout, so any single
        // attribute can come back nil on one side under momentary load. A
        // one-sided nil is unknown, not a change — it must never abort the session.
        let fullBaseline = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: "terminal-input",
            frame: InsertionTargetFocusFrame(x: 100, y: 200, width: 640, height: 80)
        )
        let identifierTimedOut = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: nil,
            frame: InsertionTargetFocusFrame(x: 100, y: 210, width: 640, height: 80)
        )
        let roleTimedOutBaseline = InsertionTargetFocusSignature(
            role: nil,
            subrole: nil,
            identifier: "terminal-input",
            frame: InsertionTargetFocusFrame(x: 100, y: 200, width: 640, height: 80)
        )
        XCTAssertFalse(
            InsertionTargetFocusSignature.changedWithinSameProcess(
                from: fullBaseline,
                to: identifierTimedOut
            )
        )
        XCTAssertFalse(
            InsertionTargetFocusSignature.changedWithinSameProcess(
                from: roleTimedOutBaseline,
                to: fullBaseline
            )
        )
        // A matching identifier is authoritative same-element even when the field
        // moved beyond the frame tolerance (scrolled, window dragged).
        let sameIdentifierMovedFar = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: "terminal-input",
            frame: InsertionTargetFocusFrame(x: 400, y: 600, width: 640, height: 80)
        )
        XCTAssertFalse(
            InsertionTargetFocusSignature.changedWithinSameProcess(
                from: fullBaseline,
                to: sameIdentifierMovedFar
            )
        )
        // Two successful, differing identifier reads still count as a move.
        let differentIdentifier = InsertionTargetFocusSignature(
            role: "AXTextArea",
            subrole: nil,
            identifier: "terminal-search",
            frame: InsertionTargetFocusFrame(x: 100, y: 200, width: 640, height: 80)
        )
        XCTAssertTrue(
            InsertionTargetFocusSignature.changedWithinSameProcess(
                from: fullBaseline,
                to: differentIdentifier
            )
        )
    }

    func testEmptyExposedDivergesUnlessNothingExpected() {
        // A text-exposing field that now reads empty diverged; deleting would eat
        // content that isn't ours, so latch append-only.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "hello", observed: .emptyExposed),
            .stopAppendOnly
        )
        // Nothing typed yet → nothing to delete → appending is safe.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "", observed: .emptyExposed),
            .proceed
        )
    }

    func testValueEndingWithExpectedProceeds() {
        // Field holds exactly our text.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "hello world", observed: .value("hello world")),
            .proceed
        )
        // Field has pre-existing content before our caret; hasSuffix tolerates it.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "world", observed: .value("hello world")),
            .proceed
        )
    }

    func testPositionedValueAllowsInsertionBeforeTrailingFieldText() {
        let context = InsertionTargetContext(prefix: "hello ", suffix: " world")
        XCTAssertEqual(
            InsertionTargetGuard.decide(
                expected: "cot",
                observed: .positionedValue(
                    "hello cot world",
                    context: context,
                    selectedRange: InsertionTargetTextRange(location: "hello cot".utf16.count, length: 0)
                )
            ),
            .proceed
        )
    }

    func testPositionedValueAllowsInitialReplacementSelection() {
        let context = InsertionTargetContext(prefix: "replace ", suffix: " please")
        XCTAssertEqual(
            InsertionTargetGuard.decide(
                expected: "",
                observed: .positionedValue(
                    "replace old please",
                    context: context,
                    selectedRange: InsertionTargetTextRange(
                        location: "replace ".utf16.count,
                        length: "old".utf16.count
                    )
                )
            ),
            .proceed
        )
    }

    func testPositionedValueRejectsWhenCaretMovedAwayFromInsertion() {
        let context = InsertionTargetContext(prefix: "hello ", suffix: " world")
        XCTAssertEqual(
            InsertionTargetGuard.decide(
                expected: "cot",
                observed: .positionedValue(
                    "hello cot world",
                    context: context,
                    selectedRange: InsertionTargetTextRange(location: 0, length: 0)
                )
            ),
            .abort
        )
    }

    func testPositionedValueRejectsSuffixMatchWhenCaretMovedAwayFromEnd() {
        let context = InsertionTargetContext(prefix: "", suffix: "")
        XCTAssertEqual(
            InsertionTargetGuard.decide(
                expected: "cot",
                observed: .positionedValue(
                    "cot",
                    context: context,
                    selectedRange: InsertionTargetTextRange(location: 0, length: 0)
                )
            ),
            .abort
        )
    }

    func testPositionedValueRejectsSuffixFallbackWhenTrailingTextEndsWithExpected() {
        let context = InsertionTargetContext(prefix: "hello ", suffix: " world cot")
        XCTAssertEqual(
            InsertionTargetGuard.decide(
                expected: "cot",
                observed: .positionedValue(
                    "hello cot world cot",
                    context: context,
                    selectedRange: InsertionTargetTextRange(location: "hello cot world cot".utf16.count, length: 0)
                )
            ),
            .abort
        )
    }

    func testPositionedValueFallsBackToAppendOnlyWhenValueDivergesAtInsertionCaret() {
        let context = InsertionTargetContext(prefix: "", suffix: "")
        XCTAssertEqual(
            InsertionTargetGuard.decide(
                expected: "type teh",
                observed: .positionedValue(
                    "type the",
                    context: context,
                    selectedRange: InsertionTargetTextRange(location: "type teh".utf16.count, length: 0)
                )
            ),
            .stopAppendOnly
        )
    }

    func testValueNotEndingWithExpectedFallsBackToAppendOnly() {
        // The field mutated our tail (autocorrect "teh" -> "the"): on-screen text
        // no longer ends with what we believe we typed, so stop deleting. This is
        // also the path a same-app field move takes: the live observer reads the
        // newly-focused field, whose content does not end with our committed text,
        // so decide latches append-only instead of blind-deleting the wrong field.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "type teh", observed: .value("type the")),
            .stopAppendOnly
        )
        // Trailing field-inserted content (a closed bracket after our caret) also
        // breaks the suffix and is treated conservatively as divergence.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "foo(", observed: .value("foo()")),
            .stopAppendOnly
        )
        // A genuinely-empty on-screen value can't end with the expected text, so
        // the pure policy treats it as divergence. The live path never hits this
        // for an empty AX read — `InsertionTargetObservation.read` maps "" to
        // `.notRead` at the boundary — but `decide` stays total either way.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "hello", observed: .value("")),
            .stopAppendOnly
        )
    }

    func testEmptyExpectationAlwaysProceedsOnValue() {
        // Nothing to delete and nothing to match: appending is always safe.
        XCTAssertEqual(
            InsertionTargetGuard.decide(expected: "", observed: .value("anything on screen")),
            .proceed
        )
    }

    func testEvaluationExplainsCaretMismatchWithoutRawFieldText() {
        let context = InsertionTargetContext(prefix: "hello ", suffix: " world")
        let evaluation = InsertionTargetGuard.evaluate(
            expected: "cot",
            observed: .positionedValue(
                "hello cot world",
                context: context,
                selectedRange: InsertionTargetTextRange(location: 0, length: 0)
            )
        )

        XCTAssertEqual(evaluation.decision, .abort)
        XCTAssertEqual(evaluation.reason, "caretMismatch")
        XCTAssertEqual(evaluation.expectedChars, 3)
        XCTAssertEqual(evaluation.observedChars, "hello cot world".utf16.count)
        XCTAssertTrue(evaluation.contextAvailable)
        XCTAssertEqual(evaluation.baselinePrefixChars, "hello ".utf16.count)
        XCTAssertEqual(evaluation.baselineSuffixChars, " world".utf16.count)
        XCTAssertTrue(evaluation.caretAvailable)
        XCTAssertEqual(evaluation.caretMatches, false)
        XCTAssertEqual(evaluation.textMatches, true)
        XCTAssertNil(evaluation.suffixMatches)
        XCTAssertTrue(evaluation.logFields.contains("decision=abort"))
        XCTAssertTrue(evaluation.logFields.contains("reason=caretMismatch"))
        XCTAssertFalse(evaluation.logFields.contains("hello cot world"))
    }

    func testEvaluationExplainsSuffixMismatchWithoutRawFieldText() {
        let evaluation = InsertionTargetGuard.evaluate(
            expected: "type teh",
            observed: .value("type the")
        )

        XCTAssertEqual(evaluation.decision, .stopAppendOnly)
        XCTAssertEqual(evaluation.reason, "suffixMismatch")
        XCTAssertEqual(evaluation.expectedChars, "type teh".utf16.count)
        XCTAssertEqual(evaluation.observedChars, "type the".utf16.count)
        XCTAssertFalse(evaluation.contextAvailable)
        XCTAssertFalse(evaluation.caretAvailable)
        XCTAssertEqual(evaluation.suffixMatches, false)
        XCTAssertTrue(evaluation.logFields.contains("decision=stopAppendOnly"))
        XCTAssertTrue(evaluation.logFields.contains("suffixMatches=false"))
        XCTAssertFalse(evaluation.logFields.contains("type the"))
    }

    // MARK: - Session integration with a fake observer

    func testSessionAbortsAndStopsTypingWhenFocusChanges() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        session.acceptPartialTranscript("hello world")
        // Focus moves to another field; the next reconcile must abort without
        // typing or backspacing anything further.
        observer.focusChanged = true
        session.acceptPartialTranscript("hello world again")
        session.acceptFinalTranscript("hello world again")

        XCTAssertEqual(backend.operations, [.insert("hello"), .insert(" world")])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testSessionCapturesBaselineBeforeFirstTranscriptArrives() {
        let backend = GuardRecordingBackend()
        let observer = MovingTargetObserver()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        observer.currentTargetID = "field-b"
        session.acceptPartialTranscript("hello")

        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testSessionAbortsPureAppendWhenTextExposingTargetDiverges() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.value = ""
        session.acceptPartialTranscript("hello world")
        session.acceptFinalTranscript("hello world")

        XCTAssertEqual(backend.operations, [.insert("hello")])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testIdentityVerifiedPureAppendLatchesInsteadOfCancellingOnSameFieldMutation() {
        // The home element advertised AXValue at baseline, so the focus check proves
        // same-element identity via CFEqual on every reconcile. A divergent non-empty
        // value during a pure append is then same-field mutation (the app
        // auto-corrected an earlier word), NOT a field move — the session must latch
        // append-only and keep the dictation flowing, not cancel and silently drop
        // every later word.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.verifiesIdentity = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello wrold")
        // The app autocorrects the typed text; the field no longer ends with the commit.
        observer.value = "hello world"
        session.acceptPartialTranscript("hello wrold again")
        session.acceptFinalTranscript("hello wrold again and again")
        session.finish()

        XCTAssertEqual(backend.fieldText, "hello wrold again and again")
        XCTAssertEqual(backend.cancelCount, 0)
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
    }

    func testIdentityVerifiedPureAppendLatchesWhenValueReadsAlwaysEmpty() {
        // A field that advertises AXValue but never returns text (Electron-style
        // web inputs): every read comes back empty, so the first pure append after
        // typing begins observes emptyExposed divergence. The focus check has
        // already pinned the same element via CFEqual, so the empty read cannot
        // mean a field move — unreadable-or-cleared on the home field. The session
        // must latch append-only and keep the dictation flowing, not cancel at
        // word one and silently drop everything after it.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.verifiesIdentity = true
        observer.value = ""
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("i")
        session.acceptPartialTranscript("i want")
        session.acceptFinalTranscript("i want this to keep flowing")
        session.finish()

        XCTAssertEqual(backend.fieldText, "i want this to keep flowing")
        XCTAssertEqual(backend.cancelCount, 0)
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
        XCTAssertEqual(backend.finishCount, 1)
    }

    func testPureAppendStillCancelsOnDivergenceWithoutIdentityProof() {
        // A target that became text-exposing only via a later non-empty read
        // (everReadNonEmptyValue) has NO element-identity check — the value read is
        // the last backstop against a same-app field move the signature check
        // missed. Divergence there must still cancel, not latch, or the session
        // would keep typing into the wrong field.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.verifiesIdentity = false
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        // Focus slid to another field whose text doesn't end with the commit.
        observer.value = "grocery list"
        session.acceptPartialTranscript("hello world")
        session.acceptFinalTranscript("hello world")

        XCTAssertEqual(backend.operations, [.insert("hello")])
        XCTAssertEqual(backend.cancelCount, 1)
    }

    func testSessionKeepsPureAppendingWhenSameTargetMutatesCommittedTextAtCaret() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "", suffix: "")
        observer.value = ""
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.value = "Hello"
        observer.selectedRange = InsertionTargetTextRange(location: "Hello".utf16.count, length: 0)
        session.acceptPartialTranscript("hello world")
        session.finish()

        XCTAssertEqual(backend.operations, [.insert("hello"), .insert(" world")])
        XCTAssertEqual(backend.cancelCount, 0)
        XCTAssertEqual(backend.finishCount, 1)
    }

    func testFirstInsertAbortsWhenTextExposingTargetNoLongerMatchesBaselineContext() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "before ", suffix: " after")
        observer.value = "different field"
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")

        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testFirstInsertProceedsWhenTextExposingTargetStillMatchesBaselineContext() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "before ", suffix: " after")
        observer.value = "before  after"
        observer.selectedRange = InsertionTargetTextRange(location: "before ".utf16.count, length: 0)
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")

        XCTAssertEqual(backend.operations, [.insert("hello")])
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testFirstInsertProceedsWhenReplacingOriginalSelection() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "replace ", suffix: " please")
        observer.value = "replace old please"
        observer.selectedRange = InsertionTargetTextRange(
            location: "replace ".utf16.count,
            length: "old".utf16.count
        )
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("new")

        XCTAssertEqual(backend.operations, [.insert("new")])
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testCancelAndRetractInsertedTextDeletesOnlyWhenTargetStillMatches() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "", suffix: "")
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.value = "hello"
        observer.selectedRange = InsertionTargetTextRange(location: "hello".utf16.count, length: 0)
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("hello"), .delete(5)])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testCancelAndRetractInsertedTextDeletesCaretInsertionInExistingText() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "before ", suffix: " after")
        observer.value = "before  after"
        observer.selectedRange = InsertionTargetTextRange(location: "before ".utf16.count, length: 0)
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.value = "before hello after"
        observer.selectedRange = InsertionTargetTextRange(location: "before hello".utf16.count, length: 0)
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("hello"), .delete(5)])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testCancelAndRetractInsertedTextSkipsDeleteAfterFocusChange() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.focusChanged = true
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("hello")])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testCancelAndRetractInsertedTextDeletesWhenValueMatchesWithoutBaselineContext() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.value = "hello"
        observer.selectedRange = InsertionTargetTextRange(location: "hello".utf16.count, length: 0)
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("hello"), .delete(5)])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testCancelAndRetractInsertedTextSkipsDeleteWhenValueMatchesButCaretIsUnverified() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.value = "hello"
        observer.selectedRange = nil
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("hello")])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testCancelAndRetractInsertedTextSkipsDeleteWhenTargetReadIsUninformative() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = false
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("hello")])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testCancelAndRetractInsertedTextSkipsDeleteWhenTextExposingTargetIsEmpty() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello")
        observer.value = ""
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("hello")])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testCancelAndRetractInsertedTextSkipsDeleteAfterReplacingInitialSelection() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "replace ", suffix: " please")
        observer.value = "replace old please"
        observer.selectedRange = InsertionTargetTextRange(
            location: "replace ".utf16.count,
            length: "old".utf16.count
        )
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("new")
        observer.value = "replace new please"
        observer.selectedRange = InsertionTargetTextRange(location: "replace new".utf16.count, length: 0)
        session.cancelAndRetractInsertedText()

        XCTAssertEqual(backend.operations, [.insert("new")])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testSessionLatchesAppendOnlyAfterValueDivergesAndNeverDeletes() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("the door")
        // The field's autocorrect changed our text out from under us. The pending
        // revision would delete a suffix; the value read reveals divergence.
        observer.value = "THE DOOR"
        session.acceptPartialTranscript("the window")
        // Latch is load-bearing: this revision shares only "the " with the commit,
        // so unguarded code would backspace and retype. Once latched the session must
        // NOT delete. These lateral revisions ("the window" → "the glass" → "the
        // glass pane") do not EXTEND our last consistent commit ("the door"), so they
        // append nothing — grafting a tail onto a field that already diverged would
        // corrupt it. Crucially the commit stays "the door" and never regresses to a
        // shorter revision (a regress is what duplicated word endings; see
        // testAppendOnlyDoesNotDuplicateWordEndingOnShrinkThenGrowRevision).
        observer.value = "anything"
        session.acceptPartialTranscript("the glass")
        session.acceptPartialTranscript("the glass pane")
        // A genuine EXTENSION of the commit still appends only the new tail.
        session.acceptPartialTranscript("the door is open")
        session.acceptFinalTranscript("the door is open")

        // First insert is unguarded (deleteCount 0). The revision to "the window"
        // diverged → latched append-only with no delete; the lateral revisions append
        // nothing; only "the door is open", which extends the commit, appends " is open".
        XCTAssertEqual(
            backend.operations,
            [.insert("the door"), .insert(" is open")]
        )
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testAppendOnlyDoesNotDuplicateWordEndingOnShrinkThenGrowRevision() {
        // Regression: a word ending was duplicated ("check the ticket" → "ticketet").
        // Once append-only latched, a recognizer partial that revised the last word
        // SHORTER regressed `committedText` below the on-screen text (the delete it
        // wanted was suppressed), and the next partial growing the word back appended
        // the suffix that was already there. Under the latch the commit must track
        // only what was actually appended, never regress to a shorter revision.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("check the ticket")
        // A divergent read latches append-only just as the recognizer revises the
        // final word shorter — the delete it wants can no longer be applied.
        observer.value = ""
        session.acceptPartialTranscript("check the tick")
        // The recognizer revises the word back to its full form.
        session.acceptPartialTranscript("check the ticket")
        session.acceptFinalTranscript("check the ticket")
        session.finish()

        XCTAssertEqual(
            backend.fieldText, "check the ticket",
            "append-only must not duplicate the word ending"
        )
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
    }

    func testAppendOnlyRawFinalRecoversReCasedExtensionInsteadOfFreezing() {
        // Regression for silent data loss: a lowercase partial latched append-only,
        // then the recognizer's authoritative final re-cased the already-typed prefix
        // ("hello ..." -> "Hello ...") AND extended it. The byte-prefix gate saw no
        // clean prefix-extension and froze, dropping the entire tail of the dictation
        // ("bar baz qux" here; the full clause in production). A raw final is loss-proof:
        // it appends everything past what we already typed, so the words always land.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("hello world foo")
        // A divergent value read on the next guarded delete latches append-only.
        observer.value = ""
        session.acceptPartialTranscript("hello world")
        // Authoritative final re-cases the prefix (H) and extends past the commit.
        session.acceptFinalTranscript("Hello world foo bar baz qux")
        session.finish()

        // Pre-fix the byte-prefix gate froze at "hello world foo" and dropped the tail.
        // Casing of the already-typed prefix can't be fixed under the latch (no delete),
        // but the new words must land.
        XCTAssertEqual(backend.fieldText, "hello world foo bar baz qux")
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
    }

    func testAppendOnlyRawFinalSuppressesMisalignedTailAfterInteriorRewording() {
        // Under the latch a raw final that re-words the INTERIOR ("a cat" ->
        // "a big cat") keeps the length-offset boundary on a word boundary by
        // coincidence ("I saw a big| cat"). Grafting that tail would render
        // "I saw a cat cat" — last word duplicated, revision dropped. The
        // committed prefix is not a re-cased rendering of the target's prefix,
        // so the append must be suppressed (do no harm: freeze, never garble).
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("I saw a cat")
        // A divergent read latches append-only as the partial shrinks.
        observer.value = ""
        session.acceptPartialTranscript("I saw a")
        session.acceptFinalTranscript("I saw a big cat")
        session.finish()

        XCTAssertEqual(
            backend.fieldText, "I saw a cat",
            "append-only must not graft a misaligned tail after interior re-wording"
        )
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
    }

    func testAppendOnlyRawFinalsAdvanceByLengthWithoutStackingAcrossFinals() {
        // Locks the loss-proof append to slice by COMMITTED LENGTH, not common prefix.
        // A common-prefix slice re-anchors at the low divergence point on every final
        // ("the door" vs "The door" share nothing at char 0), grafting and then STACKING
        // a duplicate across successive finals ("the doorThe doorThe door is open").
        // Slicing by length advances monotonically: one bounded seam, no stacking.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("the door")
        observer.value = ""
        session.acceptPartialTranscript("the do") // revision -> guarded delete -> latch
        // Two finals: the first re-cases the prefix (same length, nothing to append),
        // the second extends. Neither byte-prefix-matches the committed lowercase text.
        session.acceptFinalTranscript("The door")
        session.acceptFinalTranscript("The door is open")
        session.finish()

        XCTAssertEqual(backend.fieldText, "the door is open")
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
    }

    func testOpaqueAppEmptyReadStillSelfCorrects() {
        // Apps that expose no editable text via Accessibility (web/Electron
        // terminals like cmux) report an empty value regardless of content and
        // never set `exposesText`. That is uninformative — not proof the field
        // diverged — so the session must still backspace-and-retype a revised
        // word, the same as when the value is unreadable (nil). Latching
        // append-only here would silently break self-correction (and the polish
        // retype) in every such app.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = false // never exposed real text → AX-opaque app
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("open the")
        session.acceptPartialTranscript("open the door")
        // Empty read just before a delete: uninformative, must not force append-only.
        observer.value = ""
        session.acceptPartialTranscript("open a door")
        session.acceptFinalTranscript("open a door")
        session.finish()

        XCTAssertEqual(
            backend.operations,
            [.insert("open the"), .insert(" door"), .delete(8), .insert("a door")]
        )
        XCTAssertEqual(backend.fieldText, "open a door")
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testTextExposingFieldEmptyReadLatchesAppendOnlyAndNeverDeletes() {
        // A native field that HAS shown real text this session (exposesText true) but
        // now reads empty has diverged — its content vanished. The session must latch
        // append-only and NEVER blind-backspace into content that isn't ours.
        //
        // It must also not graft mid-token tails. A replacement final ("the door" ->
        // "the window") cannot be fixed without deleting, so under the latch the raw
        // final stays conservative instead of producing a bounded but visible seam
        // glitch ("the doorow"). Clean word-boundary extensions are covered separately.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("the door")
        // Field emptied mid-session (focus unchanged); the pending revision would
        // delete a suffix. The empty read from a text-exposing field is divergence.
        observer.value = ""
        session.acceptPartialTranscript("the window")
        session.acceptFinalTranscript("the window")

        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "empty read from a text-exposing field must not trigger a blind delete"
        )
        XCTAssertEqual(backend.operations, [.insert("the door")])
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testAppendOnlyFallbackFinalAppendsSafePrefixExtension() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("the door")
        observer.value = ""
        session.acceptPartialTranscript("the do")
        let committed = session.acceptFallbackFinalTranscript("the door is open")

        XCTAssertEqual(committed, "the door is open")
        XCTAssertEqual(backend.fieldText, "the door is open")
        XCTAssertEqual(backend.operations, [.insert("the door"), .insert(" is open")])
    }

    func testAppendOnlyFallbackFinalDoesNotGraftUnsafeNonPrefixTail() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("the door")
        observer.value = ""
        session.acceptPartialTranscript("the do")
        let committed = session.acceptFallbackFinalTranscript("the window is open")

        XCTAssertEqual(committed, "the door")
        XCTAssertEqual(backend.fieldText, "the door")
        XCTAssertEqual(backend.operations, [.insert("the door")])
    }

    func testAppendOnlyRawFinalDoesNotGraftMidWordCorrectionTail() {
        // Real dogfood regression: the recognizer emitted a partial ending in
        // "bched.", then final-corrected it to "batched.". If the AX guard latches
        // append-only before that correction, appending by raw length grafts "d." and
        // leaves visible corruption like "bched.d.". Under the latch, do no harm:
        // leave the partial rather than append a suffix from inside a word.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("seems to getting bched.")
        observer.value = ""
        session.acceptFinalTranscript("seems to getting batched.")

        XCTAssertEqual(backend.fieldText, "seems to getting bched.")
        XCTAssertEqual(backend.operations, [.insert("seems to getting bched.")])
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
    }

    func testSessionSelfCorrectsWhenDictatingBeforeTrailingText() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "hello ", suffix: " world")
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("cot")
        observer.value = "hello cot world"
        observer.selectedRange = InsertionTargetTextRange(location: "hello cot".utf16.count, length: 0)
        session.acceptPartialTranscript("caught")
        session.acceptFinalTranscript("caught")
        session.finish()

        XCTAssertEqual(backend.operations, [.insert("cot"), .delete(2), .insert("aught")])
        XCTAssertEqual(backend.fieldText, "caught")
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testSessionDoesNotDeleteWhenCaretLeavesMidFieldInsertionSpan() {
        let backend = FieldBackedRecordingBackend(initialText: "hello  world cot", caretOffset: "hello ".utf16.count)
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "hello ", suffix: " world cot")
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("cot")
        observer.value = "hello cot world cot"
        observer.selectedRange = InsertionTargetTextRange(location: "hello cot world cot".utf16.count, length: 0)
        backend.caretOffset = "hello cot world cot".utf16.count
        session.acceptPartialTranscript("caught")
        session.acceptFinalTranscript("caught")
        session.finish()

        XCTAssertEqual(backend.operations, [.insert("cot")])
        XCTAssertEqual(backend.fieldText, "hello cot world cot")
        XCTAssertEqual(backend.finishCount, 0)
        XCTAssertEqual(backend.cancelCount, 1)
    }

    // MARK: - Final polished insert (issue 4) and minimal-edit diff (issue 8)

    func testFinalPolishedReturnsFalseWhenAppendOnlyLatchSuppressesIt() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("the door")
        observer.value = ""
        session.acceptPartialTranscript("the window") // latches append-only

        // A polished final that isn't a prefix-extension of the commit types
        // nothing under the latch, and must report that it did not apply.
        XCTAssertFalse(session.acceptFinalPolishedTranscript("Completely different polished text."))
        XCTAssertFalse(backend.operations.contains { if case .delete = $0 { true } else { false } })
    }

    func testFinalPolishedReturnsTrueWhenItTypes() {
        let backend = GuardRecordingBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        XCTAssertTrue(session.acceptFinalPolishedTranscript("hello world."))
        XCTAssertEqual(backend.operations, [.insert("hello world.")])
    }

    func testFinalPolishedReturnsFalseWhenTargetEqualsCommitted() {
        let backend = GuardRecordingBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        session.acceptFinalTranscript("hello world")
        // Already on screen → no keystrokes, returns false.
        XCTAssertFalse(session.acceptFinalPolishedTranscript("hello world"))
    }

    func testFinalPolishedDoesNotReCanonicalizeTheValidatedString() {
        // insertFinalTranscript hands acceptFinalPolishedTranscript the exact
        // guard-validated string; the session must type it verbatim, NOT run the
        // session's own canonicalize over it again.
        let backend = GuardRecordingBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 + " MUTATED" }
        )

        XCTAssertTrue(session.acceptFinalPolishedTranscript("run --verbose"))
        XCTAssertEqual(backend.operations, [.insert("run --verbose")])
    }

    func testSessionObservesEditedInsertedSpanAfterFinish() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = true
        observer.insertionContext = InsertionTargetContext(prefix: "open ", suffix: " please")
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptFinalTranscript("widget pro")
        session.finish()
        observer.value = "open WidgetPro please"

        XCTAssertEqual(session.observedInsertedText(), "WidgetPro")
    }

    func testSessionDoesNotObserveInsertedSpanForOpaqueTarget() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        observer.exposesText = false
        observer.insertionContext = InsertionTargetContext(prefix: "", suffix: "")
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptFinalTranscript("widget pro")
        session.finish()
        observer.value = ""

        XCTAssertNil(session.observedInsertedText())
    }

    func testMinimalEditIsPrefixOnly() {
        let pureAppend = ProgressiveTranscriptInsertionSession.minimalEdit(
            from: "the server is down", to: "the server is down."
        )
        XCTAssertEqual(pureAppend.deleteCount, 0)
        XCTAssertEqual(pureAppend.insertTail, ".")

        // Leading capitalization breaks the common prefix at char 0, so the whole
        // line is retyped — the backspace-from-caret backend's floor.
        let leadingCap = ProgressiveTranscriptInsertionSession.minimalEdit(
            from: "the server is down", to: "The server is down."
        )
        XCTAssertEqual(leadingCap.deleteCount, 18)
        XCTAssertEqual(leadingCap.insertTail, "The server is down.")

        let midEdit = ProgressiveTranscriptInsertionSession.minimalEdit(
            from: "open the door", to: "open a door"
        )
        XCTAssertEqual(midEdit.deleteCount, 8)
        XCTAssertEqual(midEdit.insertTail, "a door")

        let noChange = ProgressiveTranscriptInsertionSession.minimalEdit(from: "x", to: "x")
        XCTAssertEqual(noChange.deleteCount, 0)
        XCTAssertEqual(noChange.insertTail, "")
    }

    func testFinalPolishedPureAppendDeletesNothing() {
        let backend = GuardRecordingBackend()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 }
        )

        session.acceptPartialTranscript("the server is down")
        XCTAssertTrue(session.acceptFinalPolishedTranscript("the server is down."))
        XCTAssertEqual(backend.operations, [.insert("the server is down"), .insert(".")])
    }

    func testSessionProceedsNormallyWhenTargetStaysConsistent() {
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
        let session = ProgressiveTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            canonicalize: { $0 },
            target: observer
        )

        session.acceptPartialTranscript("open the")
        session.acceptPartialTranscript("open the door")
        // A revision deletes the diverged suffix and retypes; the field value
        // matches what we typed, so the guard permits the delete.
        observer.value = "open the door"
        session.acceptPartialTranscript("open a door")
        session.acceptFinalTranscript("open a door")
        session.finish()

        XCTAssertEqual(
            backend.operations,
            [.insert("open the"), .insert(" door"), .delete(8), .insert("a door")]
        )
        XCTAssertEqual(backend.fieldText, "open a door")
        XCTAssertEqual(backend.finishCount, 1)
    }
}

private final class FakeTargetObserver: InsertionTargetObserver {
    var focusChanged = false
    var value: String?
    var exposesText = false
    var verifiesIdentity = false
    var insertionContext: InsertionTargetContext?
    var selectedRange: InsertionTargetTextRange?
    var applicationBundleIdentifier: String?
    var windowTitle: String?
    private(set) var baselineCaptured = false

    func captureBaseline() { baselineCaptured = true }
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? { value }
    func observedSelectedRange() -> InsertionTargetTextRange? { selectedRange }
    func exposesTextValue() -> Bool { exposesText }
    func verifiesFocusIdentity() -> Bool { verifiesIdentity }
    func baselineInsertionContext() -> InsertionTargetContext? { insertionContext }
    func targetApplicationBundleIdentifier() -> String? { applicationBundleIdentifier }
    func targetWindowTitle() -> String? { windowTitle }
}

private final class MovingTargetObserver: InsertionTargetObserver {
    var currentTargetID = "field-a"
    private var baselineTargetID: String?

    func captureBaseline() { baselineTargetID = currentTargetID }
    func focusChangedSinceStart() -> Bool { baselineTargetID != currentTargetID }
    func observedValue() -> String? { nil }
    func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    func exposesTextValue() -> Bool { false }
    func verifiesFocusIdentity() -> Bool { false }
    func baselineInsertionContext() -> InsertionTargetContext? { nil }
    func targetApplicationBundleIdentifier() -> String? { nil }
    func targetWindowTitle() -> String? { nil }
}

private final class GuardRecordingBackend: TextInsertionBackend {
    enum Operation: Equatable {
        case insert(String)
        case delete(Int)
    }

    private(set) var operations: [Operation] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    var fieldText: String {
        operations.reduce(into: "") { field, operation in
            switch operation {
            case .insert(let text): field += text
            case .delete(let count): field.removeLast(min(count, field.count))
            }
        }
    }

    func startInsertionSession() -> any TextInsertionSession {
        Session(backend: self)
    }

    fileprivate func record(_ operation: Operation) { operations.append(operation) }
    fileprivate func finishSession() { finishCount += 1 }
    fileprivate func cancelSession() { cancelCount += 1 }

    private final class Session: TextInsertionSession {
        private let backend: GuardRecordingBackend
        init(backend: GuardRecordingBackend) { self.backend = backend }
        func insert(_ text: String) { backend.record(.insert(text)) }
        func deleteBackward(count: Int) { backend.record(.delete(count)) }
        func finish() { backend.finishSession() }
        func cancel() { backend.cancelSession() }
    }
}

private final class FieldBackedRecordingBackend: TextInsertionBackend {
    enum Operation: Equatable {
        case insert(String)
        case delete(Int)
    }

    private(set) var operations: [Operation] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private var field: String
    var caretOffset: Int

    var fieldText: String { field }

    init(initialText: String, caretOffset: Int) {
        self.field = initialText
        self.caretOffset = caretOffset
    }

    func startInsertionSession() -> any TextInsertionSession {
        Session(backend: self)
    }

    fileprivate func recordInsert(_ text: String) {
        operations.append(.insert(text))
        let index = field.utf16.index(field.utf16.startIndex, offsetBy: caretOffset)
        guard let stringIndex = String.Index(index, within: field) else { return }
        field.insert(contentsOf: text, at: stringIndex)
        caretOffset += text.utf16.count
    }

    fileprivate func recordDelete(_ count: Int) {
        operations.append(.delete(count))
        let utf16 = field.utf16
        guard
            let endUTF16 = utf16.index(utf16.startIndex, offsetBy: caretOffset, limitedBy: utf16.endIndex),
            let startUTF16 = utf16.index(endUTF16, offsetBy: -count, limitedBy: utf16.startIndex),
            let start = String.Index(startUTF16, within: field),
            let end = String.Index(endUTF16, within: field)
        else {
            return
        }
        field.removeSubrange(start..<end)
        caretOffset -= count
    }

    fileprivate func finishSession() { finishCount += 1 }
    fileprivate func cancelSession() { cancelCount += 1 }

    private final class Session: TextInsertionSession {
        private let backend: FieldBackedRecordingBackend
        init(backend: FieldBackedRecordingBackend) { self.backend = backend }
        func insert(_ text: String) { backend.recordInsert(text) }
        func deleteBackward(count: Int) { backend.recordDelete(count) }
        func finish() { backend.finishSession() }
        func cancel() { backend.cancelSession() }
    }
}

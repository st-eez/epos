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
        // so unguarded code would backspace 6 and retype. Once latched the session
        // must NOT delete — it appends nothing here ("the glass" isn't a prefix of
        // the commit "the window") and leaves the field's own text intact.
        observer.value = "anything"
        session.acceptPartialTranscript("the glass")
        // A later growth still appends only the genuinely-new tail past the commit.
        session.acceptPartialTranscript("the glass pane")
        session.acceptFinalTranscript("the glass pane")

        // First insert is unguarded (deleteCount 0). The revision to "the window"
        // diverged → latched append-only with no delete. "the glass" shares no
        // appendable prefix → no op. "the glass pane" appends " pane".
        XCTAssertEqual(
            backend.operations,
            [.insert("the door"), .insert(" pane")]
        )
        XCTAssertFalse(
            backend.operations.contains { if case .delete = $0 { true } else { false } },
            "append-only latch must never backspace"
        )
        XCTAssertEqual(backend.cancelCount, 0)
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
        // A native field that HAS shown real text this session (exposesText true)
        // but now reads empty has genuinely diverged — its content vanished. An
        // empty read here is divergence, not noise, so the session must latch
        // append-only and never blind-backspace into content that isn't ours.
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
    private(set) var baselineCaptured = false

    func captureBaseline() { baselineCaptured = true }
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? { value }
    func exposesTextValue() -> Bool { exposesText }
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

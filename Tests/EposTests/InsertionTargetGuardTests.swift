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

    func testReadFactoryTreatsNilAndEmptyAsNotRead() {
        // A failed read (nil) and an app that exposes no AX text ("", e.g. cmux)
        // are both uninformative — only a non-empty read becomes a usable value.
        XCTAssertEqual(InsertionTargetObservation.read(nil), .notRead)
        XCTAssertEqual(InsertionTargetObservation.read(""), .notRead)
        XCTAssertEqual(InsertionTargetObservation.read("hello"), .value("hello"))
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
        // no longer ends with what we believe we typed, so stop deleting.
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

    func testSessionProceedsWhenValueReadsEmptyRatherThanLatchingAppendOnly() {
        // Apps that expose no editable text via Accessibility (web/Electron
        // terminals like cmux) report an empty value regardless of content. That
        // is uninformative — not proof the field diverged — so the session must
        // still backspace-and-retype a revised word, the same as when the value
        // is unreadable (nil). Latching append-only here would silently break
        // self-correction (and the polish retype) in every such app.
        let backend = GuardRecordingBackend()
        let observer = FakeTargetObserver()
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
    private(set) var baselineCaptured = false

    func captureBaseline() { baselineCaptured = true }
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? { value }
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

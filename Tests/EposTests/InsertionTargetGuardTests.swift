import XCTest
@testable import Epos

final class InsertionTargetGuardTests: XCTestCase {
    func testFinalSessionWritesExactlyOnceWhenTargetIsUnchanged() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver(
            value: "before selected after",
            range: .init(location: 7, length: 8),
            context: .init(prefix: "before ", selectedText: "selected", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(backend.operations, [])
        XCTAssertTrue(session.insertFinal("replacement"))
        XCTAssertFalse(session.insertFinal("duplicate"))
        session.finish()
        session.finish()

        XCTAssertEqual(backend.operations, [.insert("replacement")])
        XCTAssertEqual(session.insertedTranscript, "replacement")
        XCTAssertEqual(backend.finishCount, 1)
        XCTAssertEqual(backend.cancelCount, 0)
    }

    func testFinalSessionRefusesChangedFocusWithoutWriting() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )
        observer.focusChanged = true

        XCTAssertFalse(session.insertFinal("must not land"))
        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(backend.cancelCount, 1)
    }

    func testFinalSessionRefusesChangedValue() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver(
            value: "draft",
            range: .init(location: 5, length: 0),
            context: .init(prefix: "draft", suffix: "")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )
        observer.value = "user edit"
        observer.range = .init(location: 9, length: 0)

        XCTAssertFalse(session.insertFinal("must not land"))
        XCTAssertEqual(backend.operations, [])
    }

    func testFinalSessionRefusesChangedSelection() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver(
            value: "draft",
            range: .init(location: 5, length: 0),
            context: .init(prefix: "draft", suffix: "")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )
        observer.range = .init(location: 0, length: 5)

        XCTAssertFalse(session.insertFinal("must not land"))
        XCTAssertEqual(backend.operations, [])
    }

    func testFinalSessionAllowsOpaqueStableTarget() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )

        XCTAssertTrue(session.insertFinal("terminal text"))
        XCTAssertEqual(backend.operations, [.insert("terminal text")])
    }

    func testFinalSessionRefusesTextTargetWithoutReadableBaselineContext() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver(requiresTextContextValidation: true)
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )

        XCTAssertFalse(session.insertFinal("must not land"))
        XCTAssertEqual(backend.operations, [])
    }

    func testFinalSessionReportsBackendRefusalWithoutClaimingInsertion() {
        let backend = FinalRecordingBackend(insertionSucceeds: false)
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession()
        )

        XCTAssertFalse(session.insertFinal("must not be claimed"))
        XCTAssertNil(session.insertedTranscript)
        XCTAssertEqual(backend.operations, [.insert("must not be claimed")])
        XCTAssertEqual(backend.cancelCount, 1)
    }

    func testFinalSessionCancelAndEmptyFinalEmitNoWrites() {
        let backend = FinalRecordingBackend()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession()
        )

        XCTAssertFalse(session.insertFinal(" \n "))
        session.cancel()
        session.cancel()
        XCTAssertFalse(session.insertFinal("late"))

        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertEqual(backend.finishCount, 0)
    }

    func testFinishedSessionCanObserveEditedInsertedSpan() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver(
            value: "open  please",
            range: .init(location: 5, length: 0),
            context: .init(prefix: "open ", suffix: " please")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )

        XCTAssertTrue(session.insertFinal("widget pro"))
        session.finish()
        observer.value = "open WidgetPro please"
        observer.range = .init(location: 14, length: 0)

        XCTAssertEqual(session.observedInsertedText(), "WidgetPro")
    }

}

private final class FinalTargetObserver: InsertionTargetObserver {
    var focusChanged = false
    var value: String?
    var range: InsertionTargetTextRange?
    var context: InsertionTargetContext?
    var textContextValidationRequired: Bool

    init(
        value: String? = nil,
        range: InsertionTargetTextRange? = nil,
        context: InsertionTargetContext? = nil,
        requiresTextContextValidation: Bool = false
    ) {
        self.value = value
        self.range = range
        self.context = context
        textContextValidationRequired = requiresTextContextValidation
    }

    func captureBaseline() {}
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? { value }
    func observedSelectedRange() -> InsertionTargetTextRange? { range }
    func requiresTextContextValidation() -> Bool { textContextValidationRequired }
    func baselineInsertionContext() -> InsertionTargetContext? { context }
    func targetApplicationBundleIdentifier() -> String? { nil }
    func targetWindowTitle() -> String? { nil }
}

private final class FinalRecordingBackend: TextInsertionBackend {
    enum Operation: Equatable {
        case insert(String)
    }

    private(set) var operations: [Operation] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private let insertionSucceeds: Bool

    init(insertionSucceeds: Bool = true) {
        self.insertionSucceeds = insertionSucceeds
    }

    func startInsertionSession() -> any TextInsertionSession {
        Session(backend: self)
    }

    private final class Session: TextInsertionSession {
        private let backend: FinalRecordingBackend

        init(backend: FinalRecordingBackend) {
            self.backend = backend
        }

        func insert(_ text: String) -> Bool {
            backend.operations.append(.insert(text))
            return backend.insertionSucceeds
        }

        func finish() {
            backend.finishCount += 1
        }

        func cancel() {
            backend.cancelCount += 1
        }
    }
}

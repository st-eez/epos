import XCTest
@testable import Epos

/// The pre-write guard. Every refusal test states the process's Accessibility
/// trust explicitly: the same refusal means two different things depending on it,
/// and the xctest host's own trust varies by machine.
final class InsertionTargetGuardTests: XCTestCase {
    /// With Accessibility revoked the baseline is empty and every AX read fails, so
    /// the guard refuses for a reason that has nothing to do with focus. The only
    /// check that can name it — the keystroke backend's own trust read — sits
    /// behind this refusal and never runs, so both the log and the reliability
    /// outcome used to say the fn-press target had changed.
    func testUntrustedAccessibilityIsRefusedAsAPermissionFailureNotAMovedTarget() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver()
        observer.focusChanged = true
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer,
            isAccessibilityTrusted: { false }
        )

        XCTAssertEqual(session.insertFinalResult("must not land"), .accessibilityUntrusted)
        // The refusal itself is unchanged: nothing is ever written blind.
        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(backend.cancelCount, 1)
    }

    /// A target that never moved is authorized whatever the trust read says — the
    /// backend's own check is the one that stops an untrusted write there.
    func testTrustIsOnlyConsultedOnRefusal() {
        let backend = FinalRecordingBackend()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: FinalTargetObserver(),
            isAccessibilityTrusted: { XCTFail("trust must not be read on the accepting path"); return true }
        )

        XCTAssertEqual(session.insertFinalResult("terminal text"), .accepted)
    }

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
        XCTAssertEqual(session.insertFinalResult("replacement"), .accepted)
        XCTAssertEqual(session.insertFinalResult("duplicate"), .backendRefused)
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
            target: observer,
            isAccessibilityTrusted: { true }
        )
        observer.focusChanged = true

        XCTAssertEqual(session.insertFinalResult("must not land"), .targetRefused)
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
            target: observer,
            isAccessibilityTrusted: { true }
        )
        observer.value = "user edit"
        observer.range = .init(location: 9, length: 0)

        XCTAssertEqual(session.insertFinalResult("must not land"), .targetRefused)
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
            target: observer,
            isAccessibilityTrusted: { true }
        )
        observer.range = .init(location: 0, length: 5)

        XCTAssertEqual(session.insertFinalResult("must not land"), .targetRefused)
        XCTAssertEqual(backend.operations, [])
    }

    func testBaselineSettleWaitsOutStaleCompositionBeforeTheGuardReads() async {
        let backend = FinalRecordingBackend()
        // A Chromium host still showing cancelled marked text for the first two
        // reads, then reflecting the un-mark into its AX value.
        let observer = SequencedFinalTargetObserver(
            values: ["abc draft", "abc draft", "abc", "abc"],
            range: .init(location: 3, length: 0),
            context: .init(prefix: "abc", suffix: "")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer,
            isAccessibilityTrusted: { true }
        )

        await session.settleReadableBaseline(retryDelaysNanoseconds: [0, 1_000_000, 1_000_000])
        XCTAssertEqual(session.insertFinalResult("final"), .accepted)
        XCTAssertEqual(backend.operations, [.insert("final")])
    }

    func testBaselineSettleGivesUpOnAGenuinelyEditedTarget() async {
        let backend = FinalRecordingBackend()
        let observer = SequencedFinalTargetObserver(
            values: ["abc user edit", "abc user edit", "abc user edit", "abc user edit"],
            range: .init(location: 3, length: 0),
            context: .init(prefix: "abc", suffix: "")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer,
            isAccessibilityTrusted: { true }
        )

        await session.settleReadableBaseline(retryDelaysNanoseconds: [0, 1_000_000, 1_000_000])
        XCTAssertEqual(session.insertFinalResult("must not land"), .targetRefused)
        XCTAssertEqual(backend.operations, [])
    }

    func testFinalSessionAllowsOpaqueStableTarget() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("terminal text"), .accepted)
        XCTAssertEqual(backend.operations, [.insert("terminal text")])
    }

    func testFinalSessionRefusesTextTargetWithoutReadableBaselineContext() {
        let backend = FinalRecordingBackend()
        let observer = FinalTargetObserver(requiresTextContextValidation: true)
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer,
            isAccessibilityTrusted: { true }
        )

        XCTAssertEqual(session.insertFinalResult("must not land"), .targetRefused)
        XCTAssertEqual(backend.operations, [])
    }

    func testFinalSessionReportsBackendRefusalWithoutClaimingInsertion() {
        let backend = FinalRecordingBackend(insertionSucceeds: false)
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession()
        )

        XCTAssertEqual(session.insertFinalResult("must not be claimed"), .backendRefused)
        XCTAssertNil(session.insertedTranscript)
        XCTAssertEqual(backend.operations, [.insert("must not be claimed")])
        XCTAssertEqual(backend.cancelCount, 1)
    }

    func testFinalSessionDistinguishesTargetAndBackendRefusal() {
        let changedObserver = FinalTargetObserver()
        changedObserver.focusChanged = true
        let targetSession = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: changedObserver,
            isAccessibilityTrusted: { true }
        )
        let backendSession = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend(insertionSucceeds: false).startInsertionSession()
        )

        XCTAssertEqual(targetSession.insertFinalResult("text"), .targetRefused)
        XCTAssertEqual(backendSession.insertFinalResult("text"), .backendRefused)
    }

    func testAcceptedWriteUsesExactBoundedReadback() async {
        let observer = FinalTargetObserver(
            value: "before  after",
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected"), .accepted)
        observer.value = "before expected after"

        let matched = await session.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0]
        )
        let wrongExpectation = await session.verifyDelivery(
            expected: "different",
            retryDelaysNanoseconds: [0]
        )
        XCTAssertEqual(matched, .matched)
        XCTAssertEqual(wrongExpectation, .unavailable)
    }

    func testAcceptedWriteReportsReadableMismatchAndOpaqueUnverified() async {
        let readableObserver = FinalTargetObserver(
            value: "before  after",
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let readableSession = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: readableObserver
        )
        XCTAssertEqual(readableSession.insertFinalResult("expected"), .accepted)
        readableObserver.value = "before wrong after"

        let opaqueSession = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: FinalTargetObserver()
        )
        XCTAssertEqual(opaqueSession.insertFinalResult("expected"), .accepted)

        let mismatch = await readableSession.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0, 0]
        )
        let unavailable = await opaqueSession.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0, 0]
        )
        XCTAssertEqual(mismatch, .mismatched)
        XCTAssertEqual(unavailable, .unavailable)
    }

    func testSingleDivergentReadbackIsUnverifiedRatherThanMismatched() async {
        let observer = FinalTargetObserver(
            value: "before  after",
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected"), .accepted)
        observer.value = "before wrong after"

        let result = await session.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0]
        )

        XCTAssertEqual(result, .unavailable)
    }

    /// A long transcript posts many chunked keyboard events, so a slow field can
    /// hand back a still-growing span for the whole retry ladder. That is
    /// in-flight delivery, not the wrong text landing.
    func testStillArrivingPartialSpanIsUnverifiedRatherThanMismatched() async {
        let observer = SequencedFinalTargetObserver(
            values: [
                "before  after",
                "before expect after",
                "before expected te after",
                "before expected text so far after",
            ],
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected text so far and more"), .accepted)
        let result = await session.verifyDelivery(
            expected: "expected text so far and more",
            retryDelaysNanoseconds: [0, 0, 0]
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testGenuinelyWrongValueRepeatedAcrossReadsIsMismatched() async {
        let observer = SequencedFinalTargetObserver(
            values: [
                "before  after",
                "before wrong after",
                "before wrong after",
            ],
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected"), .accepted)
        let result = await session.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0, 0, 0]
        )

        XCTAssertEqual(result, .mismatched)
    }

    func testRepeatedStaleReadableSamplesFollowedByUnavailableReadbackAreUnverified() async {
        let observer = SequencedFinalTargetObserver(
            values: ["before  after", "before  after", "before  after", nil],
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected"), .accepted)
        let result = await session.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0, 0, 0]
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testRepeatedStaleSelectionSamplesAreUnverified() async {
        let observer = SequencedFinalTargetObserver(
            values: [
                "before old after",
                "before old after",
                "before old after",
                nil,
            ],
            range: .init(location: 7, length: 3),
            context: .init(prefix: "before ", selectedText: "old", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("new"), .accepted)
        let result = await session.verifyDelivery(
            expected: "new",
            retryDelaysNanoseconds: [0, 0, 0]
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testStaleReadableSampleCanRecoverToMatchedReadback() async {
        let observer = SequencedFinalTargetObserver(
            values: [
                "before  after",
                "before  after",
                "before expected after",
            ],
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected"), .accepted)
        let result = await session.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0, 0]
        )

        XCTAssertEqual(result, .matched)
    }

    func testRepeatedStableMismatchRemainsMismatchWhenFinalReadIsUnavailable() async {
        let observer = SequencedFinalTargetObserver(
            values: [
                "before  after",
                "before wrong after",
                "before wrong after",
                nil,
            ],
            range: .init(location: 7, length: 0),
            context: .init(prefix: "before ", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected"), .accepted)
        let result = await session.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0, 0, 0, 0]
        )

        XCTAssertEqual(result, .mismatched)
    }

    func testIdenticalSelectionReplacementCannotClaimVerifiedDelivery() async {
        let observer = FinalTargetObserver(
            value: "before expected after",
            range: .init(location: 7, length: 8),
            context: .init(prefix: "before ", selectedText: "expected", suffix: " after")
        )
        let session = FinalTranscriptInsertionSession(
            insertionSession: FinalRecordingBackend().startInsertionSession(),
            target: observer
        )

        XCTAssertEqual(session.insertFinalResult("expected"), .accepted)
        let result = await session.verifyDelivery(
            expected: "expected",
            retryDelaysNanoseconds: [0]
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testFinalSessionCancelAndEmptyFinalEmitNoWrites() {
        let backend = FinalRecordingBackend()
        let session = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession()
        )

        XCTAssertEqual(session.insertFinalResult(" \n "), .backendRefused)
        session.cancel()
        session.cancel()
        XCTAssertEqual(session.insertFinalResult("late"), .backendRefused)

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

        XCTAssertEqual(session.insertFinalResult("widget pro"), .accepted)
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

private final class SequencedFinalTargetObserver: InsertionTargetObserver {
    private let values: [String?]
    private var valueIndex = 0
    private let range: InsertionTargetTextRange
    private let context: InsertionTargetContext

    init(
        values: [String?],
        range: InsertionTargetTextRange,
        context: InsertionTargetContext
    ) {
        self.values = values
        self.range = range
        self.context = context
    }

    func captureBaseline() {}
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { false }
    func observedValue() -> String? {
        guard valueIndex < values.count else { return nil }
        defer { valueIndex += 1 }
        return values[valueIndex]
    }
    func observedSelectedRange() -> InsertionTargetTextRange? { range }
    func requiresTextContextValidation() -> Bool { true }
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

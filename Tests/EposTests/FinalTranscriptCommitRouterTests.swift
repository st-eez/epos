import XCTest
@testable import Epos

/// Pins the single-commit state machine that routes the one authoritative final
/// write between the palette-IME commit and the keystroke backend: the shared
/// guard runs before any commit, an ack means exactly one IME write and zero
/// keystrokes, a probe refusal falls back to keystrokes over a cancelled
/// composition, and an unacknowledged commit writes nothing at all.
@MainActor
final class FinalTranscriptCommitRouterTests: XCTestCase {
    private static let transcript = "Hello there."

    // MARK: - Doubles

    private actor ScriptedTransport: InlinePreviewTransport {
        private let commitReply: String
        private let commitError: InlinePreviewTransportError?

        private(set) var lines: [String] = []

        init(commitReply: String = "ok committed 12", commitError: InlinePreviewTransportError? = nil) {
            self.commitReply = commitReply
            self.commitError = commitError
        }

        func open() async throws {}

        func send(_ line: String) async throws -> String {
            lines.append(line)
            if line.hasPrefix("commit") {
                if let commitError { throw commitError }
                return commitReply
            }
            return "ok"
        }

        func close() async {}
    }

    private final class OpaqueTargetObserver: InsertionTargetObserver {
        var focusChanged = false

        func captureBaseline() {}
        func hasCapturedTarget() -> Bool { true }
        func focusChangedSinceStart() -> Bool { focusChanged }
        func observedValue() -> String? { nil }
        func observedSelectedRange() -> InsertionTargetTextRange? { nil }
        func requiresTextContextValidation() -> Bool { false }
        func baselineInsertionContext() -> InsertionTargetContext? { nil }
        func targetApplicationBundleIdentifier() -> String? { "com.test.app" }
        func targetWindowTitle() -> String? { nil }
    }

    private final class RecordingBackend: TextInsertionBackend {
        private(set) var inserted: [String] = []
        private(set) var cancelCount = 0
        private(set) var finishCount = 0

        func startInsertionSession() -> any TextInsertionSession {
            Session(backend: self)
        }

        private final class Session: TextInsertionSession {
            private let backend: RecordingBackend

            init(backend: RecordingBackend) { self.backend = backend }

            func insert(_ text: String) -> Bool {
                backend.inserted.append(text)
                return true
            }

            func finish() { backend.finishCount += 1 }
            func cancel() { backend.cancelCount += 1 }
        }
    }

    // MARK: - Helpers

    private func makeInsertion(
        backend: RecordingBackend,
        observer: OpaqueTargetObserver = OpaqueTargetObserver()
    ) -> FinalTranscriptInsertionSession {
        FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer
        )
    }

    /// A preview whose channel stayed healthy all recording: begin acked and one
    /// mark rendered.
    private func makeHealthyPreview(transport: ScriptedTransport) async -> InlinePreviewSession {
        let preview = InlinePreviewSession(
            transport: transport,
            bundleIdentifier: "com.test.app",
            sleep: { _ in }
        )
        await preview.begin()
        await preview.mark("hello there")
        let deadline = Date().addingTimeInterval(3)
        while await preview.report().marksSent == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let report = await preview.report()
        XCTAssertEqual(report.marksSent, 1)
        return preview
    }

    // MARK: - Tests

    func testUnhealthyChannelReturnsNilWithoutTouchingAnything() async {
        let transport = ScriptedTransport()
        let preview = InlinePreviewSession(
            transport: transport,
            bundleIdentifier: "com.test.app",
            sleep: { _ in }
        )
        let backend = RecordingBackend()
        let insertion = makeInsertion(backend: backend)

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript,
            preview: preview,
            insertion: insertion,
            settle: {}
        )

        XCTAssertNil(route)
        let lines = await transport.lines
        XCTAssertEqual(lines, [])
        XCTAssertEqual(backend.inserted, [])
        XCTAssertNil(insertion.insertedTranscript)
    }

    func testGuardRefusalRunsBeforeAndPreventsAnyCommit() async {
        let transport = ScriptedTransport()
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let observer = OpaqueTargetObserver()
        let insertion = makeInsertion(backend: backend, observer: observer)
        observer.focusChanged = true

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript,
            preview: preview,
            insertion: insertion,
            settle: {}
        )

        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        let lines = await transport.lines
        XCTAssertFalse(lines.contains { $0.hasPrefix("commit") })
        XCTAssertTrue(lines.contains("cancel"))
        XCTAssertEqual(backend.inserted, [])
        XCTAssertEqual(backend.cancelCount, 1)
        XCTAssertNil(insertion.insertedTranscript)
    }

    func testAckedCommitIsExactlyOnceWithNoKeystrokes() async {
        let transport = ScriptedTransport()
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let insertion = makeInsertion(backend: backend)

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript,
            preview: preview,
            insertion: insertion,
            settle: {}
        )

        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        XCTAssertEqual(insertion.insertedTranscript, Self.transcript)
        XCTAssertEqual(backend.inserted, [])
        let lines = await transport.lines
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit") }, ["commit \(Self.transcript)"])
        // The exactly-once contract holds across backends: nothing can write again.
        XCTAssertEqual(insertion.insertFinalResult("again"), .backendRefused)
        XCTAssertEqual(backend.inserted, [])
    }

    func testProbeRefusalFallsBackToKeystrokesOverACancelledComposition() async {
        let transport = ScriptedTransport(commitReply: "err locked session gone")
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let insertion = makeInsertion(backend: backend)

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript,
            preview: preview,
            insertion: insertion,
            settle: {}
        )

        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, [Self.transcript])
        XCTAssertEqual(insertion.insertedTranscript, Self.transcript)
        let lines = await transport.lines
        // The composition was cancelled (acked) before the keystrokes landed.
        XCTAssertEqual(
            lines.filter { $0 == "cancel" || $0.hasPrefix("commit") },
            ["cancel", "commit \(Self.transcript)"]
        )
    }

    func testAmbiguousCommitWritesNothingAndClosesTheInsertionSession() async {
        let transport = ScriptedTransport(commitError: .replyTimedOut)
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let insertion = makeInsertion(backend: backend)

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript,
            preview: preview,
            insertion: insertion,
            settle: {}
        )

        XCTAssertEqual(route, .imeAmbiguous)
        XCTAssertEqual(backend.inserted, [])
        XCTAssertNil(insertion.insertedTranscript)
        XCTAssertEqual(backend.cancelCount, 1)
        // The session is closed: no later path may issue the keystroke write.
        XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .backendRefused)
        XCTAssertEqual(backend.inserted, [])
    }

    /// The transport tells a dead peer apart from a slow one so the log can name
    /// what happened, but the routing must not follow that distinction: after a
    /// complete send both mean the commit may have executed.
    func testMissingAckAndDeadPeerRouteIdenticallyAfterAFullSend() async {
        for commitError in [InlinePreviewTransportError.replyTimedOut, .replyPeerClosed] {
            let transport = ScriptedTransport(commitError: commitError)
            let preview = await makeHealthyPreview(transport: transport)
            let backend = RecordingBackend()
            let insertion = makeInsertion(backend: backend)

            let route = await FinalTranscriptCommitRouter.attemptIMECommit(
                transcript: Self.transcript,
                preview: preview,
                insertion: insertion,
                settle: {}
            )

            XCTAssertEqual(route, .imeAmbiguous, "\(commitError)")
            XCTAssertEqual(backend.inserted, [], "\(commitError)")
            XCTAssertNil(insertion.insertedTranscript, "\(commitError)")
            XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .backendRefused, "\(commitError)")
            XCTAssertEqual(backend.inserted, [], "\(commitError)")
        }
    }

    func testProtocolBreakingTranscriptNeverEntersTheIMEPath() async {
        let transport = ScriptedTransport()
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let insertion = makeInsertion(backend: backend)
        let linesBefore = await transport.lines

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: "line one\nline two",
            preview: preview,
            insertion: insertion,
            settle: {}
        )

        XCTAssertNil(route)
        let lines = await transport.lines
        XCTAssertEqual(lines, linesBefore)
        XCTAssertEqual(backend.inserted, [])
    }
}

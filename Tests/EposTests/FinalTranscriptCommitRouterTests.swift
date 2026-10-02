import XCTest
@testable import Epos

/// Pins the single-commit state machine that routes the one authoritative final
/// write between the palette-IME commit and the keystroke backend: the shared
/// guard runs before any commit, an ack means exactly one IME write and zero
/// keystrokes, a probe refusal falls back to keystrokes over a cancelled
/// composition, and an unacknowledged commit suppresses every further write.
@MainActor
final class FinalTranscriptCommitRouterTests: XCTestCase {
    private static let transcript = "Hello there."

    // MARK: - Doubles

    private actor ScriptedTransport: InlinePreviewTransport {
        private let commitReply: String
        private let commitError: InlinePreviewTransportError?
        private let cancelReply: String
        private let onSend: @Sendable (String) -> Void

        private(set) var lines: [String] = []

        init(
            commitReply: String = "ok committed 12",
            commitError: InlinePreviewTransportError? = nil,
            cancelReply: String = "ok",
            onSend: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.commitReply = commitReply
            self.commitError = commitError
            self.cancelReply = cancelReply
            self.onSend = onSend
        }

        func open() async throws {}

        func send(_ line: String) async throws -> String {
            lines.append(line)
            onSend(line)
            if line == "cancel" { return cancelReply }
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
        observer: OpaqueTargetObserver = OpaqueTargetObserver(),
        latency: RecordingLatencyDiagnostics? = nil
    ) -> FinalTranscriptInsertionSession {
        FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer,
            latency: latency
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
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while await preview.report().marksSent == 0, ContinuousClock().now < deadline {
            await Task.yield()
        }
        let report = await preview.report()
        XCTAssertEqual(report.marksSent, 1)
        return preview
    }

    // MARK: - Tests

    func testCommitTimingKeepsAcknowledgedAndAmbiguousResultsDistinct() async throws {
        for error in [nil, InlinePreviewTransportError.replyTimedOut] {
            let log = LatencyTestLog()
            let clock = log.clock
            let transport = ScriptedTransport(commitError: error, onSend: { line in
                if line == "cancel" { clock.advance(.milliseconds(9)) }
                if line.hasPrefix("commit ") { clock.advance(.milliseconds(21)) }
            })
            let preview = await makeHealthyPreview(transport: transport)
            let backend = RecordingBackend()
            let insertion = makeInsertion(backend: backend, latency: log.timing)
            log.timing.begin(.releaseToWrite)

            let route = await FinalTranscriptCommitRouter.attemptIMECommit(
                transcript: Self.transcript, preview: preview, insertion: insertion, latency: log.timing,
                settle: { clock.advance(.milliseconds(30)) }
            )

            XCTAssertEqual(try log.row(.previewCancel)["durationMs"], "9.000")
            XCTAssertEqual(try log.row(.baselineSettle)["durationMs"], "30.000")
            XCTAssertEqual(try log.row(.imeCommit)["durationMs"], "21.000")
            XCTAssertEqual(try log.row(.imeCommit)["outcome"], error == nil ? "completed" : "ambiguous")
            XCTAssertTrue(backend.inserted.isEmpty)
            if error == nil {
                XCTAssertEqual(route, .completed(.accepted, viaIME: true))
                XCTAssertEqual(try log.row(.releaseToWrite)["durationMs"], "60.000")
            } else {
                XCTAssertEqual(route, .imeAmbiguous)
                XCTAssertFalse(try log.rows().contains { $0["stage"] == "release-to-write" })
            }
        }
    }

    func testForeignCompositionDuringCancelBlocksBothDeliveryBackends() async {
        let transport = ScriptedTransport(cancelReply: "err unsafe composition")
        await refusesUnsafeTarget(transport: transport)
        let lines = await transport.lines
        XCTAssertFalse(lines.contains { $0.hasPrefix("commit ") })
    }

    func testForeignCompositionBeforeCommitBlocksKeystrokeFallback() async {
        let transport = ScriptedTransport(commitReply: "err unsafe composition")
        await refusesUnsafeTarget(transport: transport)
        let lines = await transport.lines
        XCTAssertTrue(lines.contains("commit \(Self.transcript)"))
    }

    private func refusesUnsafeTarget(transport: ScriptedTransport) async {
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let insertion = makeInsertion(backend: backend)
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview, insertion: insertion, settle: {}
        )
        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertEqual(backend.inserted, [])
        XCTAssertNil(insertion.insertedTranscript)
        XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .backendRefused)
        XCTAssertEqual(backend.inserted, [])
    }

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

    func testAmbiguousCommitSuppressesFallbackAndClosesTheInsertionSession() async {
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
        for commitError in [InlinePreviewTransportError.replyTimedOut, .replyPeerClosed, .replyMalformed] {
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

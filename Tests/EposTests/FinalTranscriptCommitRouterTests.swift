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

    private final class ReadableTargetObserver: InsertionTargetObserver {
        var value = "before hello there after"
        var selection = InsertionTargetTextRange(location: 18, length: 0)
        var context = InsertionTargetContext(prefix: "before ", suffix: " after")
        func captureBaseline() {}
        func hasCapturedTarget() -> Bool { true }
        func focusChangedSinceStart() -> Bool { false }
        func observedValue() -> String? { value }
        func observedSelectedRange() -> InsertionTargetTextRange? { selection }
        func requiresTextContextValidation() -> Bool { true }
        func baselineInsertionContext() -> InsertionTargetContext? { context }
        func targetApplicationBundleIdentifier() -> String? { "com.test.app" }
        func targetWindowTitle() -> String? { nil }
    }

    func testEchoedPlaceholderAllowsOneOwnedNativeCommit() async {
        let transport = ScriptedTransport()
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let target = ReadableTargetObserver()
        target.context = .init(prefix: "", suffix: "Write a message")
        target.value = "hello there"
        target.selection = .init(location: target.value.utf16.count, length: 0)
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview,
            insertion: makeInsertion(backend: backend, observer: target)
        )
        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        XCTAssertTrue(backend.inserted.isEmpty)
        let lines = await transport.lines
        XCTAssertFalse(lines.contains("cancel"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit ") }, ["commit \(Self.transcript)"])
        await preview.discard()
    }

    func testReadablePreviewCommitsInPlaceWithoutClearingItsVisibleText() async {
        let transport = ScriptedTransport()
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let target = ReadableTargetObserver()
        let insertion = makeInsertion(backend: backend, observer: target)
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview, insertion: insertion, settle: {
                XCTFail("an intact preview must not need a blank composition settlement")
            }
        )
        await preview.discard()
        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        XCTAssertEqual(target.value, "before hello there after")
        XCTAssertTrue(backend.inserted.isEmpty)
        let lines = await transport.lines
        XCTAssertFalse(lines.contains("cancel"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit ") }, ["commit \(Self.transcript)"])
    }

    func testNativeOwnershipAcceptsDifferentAccessibilityTextRepresentation() async {
        for (baseline, value) in [("\n", "hello there"), ("before \n", "before hello there"),
                                  ("before \u{a0}after\n", "before hello there after\n")] {
            let transport = ScriptedTransport()
            let preview = await makeHealthyPreview(transport: transport)
            let backend = RecordingBackend()
            let target = ReadableTargetObserver()
            target.context = .init(prefix: "", suffix: baseline)
            target.value = value
            let route = await FinalTranscriptCommitRouter.attemptIMECommit(
                transcript: Self.transcript, preview: preview,
                insertion: makeInsertion(backend: backend, observer: target)
            )
            XCTAssertEqual(route, .completed(.accepted, viaIME: true))
            XCTAssertTrue(backend.inserted.isEmpty)
            let lines = await transport.lines
            XCTAssertFalse(lines.contains("cancel"))
            await preview.discard()
        }
    }

    func testNativeRefusalStillBlocksCommitAndFallbackWithDifferentAXText() async {
        let transport = ScriptedTransport(commitReply: "err unsafe selection or composition before commit")
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let target = ReadableTargetObserver()
        target.value = "different representation"
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview,
            insertion: makeInsertion(backend: backend, observer: target)
        )
        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertTrue(backend.inserted.isEmpty)
        await preview.discard()
    }

    func testNativeRefusalCannotBypassFallbackBaselineGuard() async {
        let transport = ScriptedTransport(commitReply: "err commit refused")
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let target = ReadableTargetObserver()
        target.value = "changed content"
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview,
            insertion: makeInsertion(backend: backend, observer: target), settle: {}
        )
        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertTrue(backend.inserted.isEmpty)
    }

    // MARK: - Helpers

    private func makeInsertion(
        backend: RecordingBackend,
        observer: any InsertionTargetObserver = OpaqueTargetObserver(),
        latency: RecordingLatencyDiagnostics? = nil
    ) -> FinalTranscriptInsertionSession {
        FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(),
            target: observer,
            latency: latency,
            isAccessibilityTrusted: { true }
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

    func testStillMarkedNativeCommitIsAmbiguousAndNeverFallsBack() async {
        let transport = ScriptedTransport(commitReply: "ambiguous native commit left marked text")
        let preview = await makeHealthyPreview(transport: transport)
        let backend = RecordingBackend()
        let insertion = makeInsertion(backend: backend)
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview, insertion: insertion, settle: {}
        )
        await preview.discard()
        XCTAssertEqual(route, .imeAmbiguous)
        XCTAssertNil(insertion.insertedTranscript)
        XCTAssertTrue(backend.inserted.isEmpty)
        let lines = await transport.lines
        XCTAssertFalse(lines.contains("cancel"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit ") }, ["commit \(Self.transcript)"])
    }

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

            XCTAssertFalse(try log.rows().contains { $0["stage"] == "preview-cancel" })
            XCTAssertFalse(try log.rows().contains { $0["stage"] == "baseline-settle" })
            XCTAssertEqual(try log.row(.imeCommit)["durationMs"], "21.000")
            XCTAssertEqual(try log.row(.imeCommit)["outcome"], error == nil ? "completed" : "ambiguous")
            XCTAssertTrue(backend.inserted.isEmpty)
            if error == nil {
                XCTAssertEqual(route, .completed(.accepted, viaIME: true))
                XCTAssertEqual(try log.row(.releaseToWrite)["durationMs"], "21.000")
            } else {
                XCTAssertEqual(route, .imeAmbiguous)
                XCTAssertFalse(try log.rows().contains { $0["stage"] == "release-to-write" })
            }
        }
    }

    func testForeignCompositionDuringCancelBlocksBothDeliveryBackends() async {
        let transport = ScriptedTransport(commitReply: "err unavailable", cancelReply: "err unsafe composition")
        await refusesUnsafeTarget(transport: transport)
        let lines = await transport.lines
        XCTAssertTrue(lines.contains { $0.hasPrefix("commit ") })
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
        XCTAssertFalse(lines.contains("cancel"))
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
            ["commit \(Self.transcript)", "cancel"]
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

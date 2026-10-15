import XCTest
@testable import Epos

@MainActor
final class InlinePreviewSettlementTests: XCTestCase {
    func testFirstMarkRefusalCannotRenderButUnknownReplyMayHaveRendered() async {
        for (transport, mayHaveRendered) in [
            (FakeInlinePreviewTransport(markReply: "err unmarked preview refused"), false),
            (FakeInlinePreviewTransport(markReply: "err preview refused"), true),
            (FakeInlinePreviewTransport(markError: .replyTimedOut), true),
            (FakeInlinePreviewTransport(markReply: "unexpected reply"), true),
        ] {
            let preview = InlinePreviewSession(
                transport: transport, bundleIdentifier: "com.test.app", sleep: { _ in }
            )
            await mark(preview)
            let report = await preview.report()
            XCTAssertTrue(report.didAttemptMark)
            XCTAssertEqual(report.mayHaveRendered, mayHaveRendered)
            await preview.discard()
        }
    }

    func testFirstConclusiveMarkRefusalSkipsSettlementBeforeFinalWrite() async throws {
        let log = LatencyTestLog()
        let transport = FakeInlinePreviewTransport(markReply: "err unmarked preview refused")
        let (recording, _, backend) = try await makeRecording(log: log, transport: transport)

        let route = await recording.commitFinalTranscript("Final text.")

        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, ["Final text."])
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "baseline-settle" })
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "composition-settle" })
        let lines = await transport.lines
        XCTAssertFalse(lines.contains("cancel"))
    }

    func testUnknownMarkReplyBlocksFinalWriteWithoutSettlement() async throws {
        let log = LatencyTestLog()
        let transport = FakeInlinePreviewTransport(markError: .replyTimedOut)
        let (recording, preview, backend) = try await makeRecording(log: log, transport: transport)

        let route = await recording.commitFinalTranscript("Final text.")

        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertEqual(backend.inserted, [])
        let report = await preview.report()
        XCTAssertTrue(report.mayHaveRendered)
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "baseline-settle" })
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "composition-settle" })
    }

    func testReadableOrdinaryWritePollsBaselineWithoutFixedSettlement() async throws {
        let log = LatencyTestLog()
        let target = SettlingReadableTarget()
        let (recording, _, backend) = try await makeRecording(
            log: log, transport: FakeInlinePreviewTransport(), target: target
        )

        let route = await recording.commitFinalTranscript("Final\ntext.")

        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, ["Final\ntext."])
        XCTAssertEqual(target.valueReads, 3, "two baseline polls must precede the final guard read")
        XCTAssertEqual(try log.rows().filter { $0["stage"] == "baseline-settle" }.count, 1)
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "composition-settle" })
    }

    func testOpaqueOrdinaryWriteSettlesOnceAfterBaselinePollBeforeAuthorization() async throws {
        let log = LatencyTestLog()
        let (recording, _, backend) = try await makeRecording(
            log: log, transport: FakeInlinePreviewTransport()
        )

        let route = await recording.commitFinalTranscript("Final\ntext.")

        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, ["Final\ntext."])
        let stages = try log.rows().compactMap { $0["stage"] }
        XCTAssertEqual(stages.filter { $0 == "composition-settle" }.count, 1)
        let poll = try XCTUnwrap(stages.firstIndex(of: "baseline-settle"))
        let settle = try XCTUnwrap(stages.firstIndex(of: "composition-settle"))
        let authorization = try XCTUnwrap(stages.firstIndex(of: "target-authorization"))
        XCTAssertLessThan(poll, settle)
        XCTAssertLessThan(settle, authorization)
    }

    func testIMERefusalDoesNotSettleAgainDuringTeardown() async throws {
        let log = LatencyTestLog()
        let transport = FakeInlinePreviewTransport(commitReply: "err commit refused")
        let (recording, _, backend) = try await makeRecording(log: log, transport: transport)

        let route = await recording.commitFinalTranscript("Final text.")

        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, ["Final text."])
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "composition-settle" })
        let lines = await transport.lines
        XCTAssertEqual(lines.filter { $0 == "cancel" }, ["cancel"])
    }

    func testUnsafeCleanupBlocksOrdinaryWriteBeforeSettlement() async throws {
        let log = LatencyTestLog()
        let transport = FakeInlinePreviewTransport(cancelReply: "err unsafe composition")
        let (recording, _, backend) = try await makeRecording(log: log, transport: transport)

        let route = await recording.commitFinalTranscript("Final\ntext.")

        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertEqual(backend.inserted, [])
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "baseline-settle" })
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "composition-settle" })
    }

    func testCoordinatorTeardownReportsPossiblePreviewWithoutSettlement() async throws {
        let log = LatencyTestLog()
        let coordinator = InlinePreviewCoordinator(
            isEnabled: { true }, log: EposLogger(category: "inject", diagnostics: log.sink),
            latency: log.timing, onMarkingActivityChange: { _ in }, onFirstMarkRendered: {}
        )
        let preview = try XCTUnwrap(coordinator.makeSession(
            bundleIdentifier: "com.test.app", transport: FakeInlinePreviewTransport(), sleep: { _ in }
        ))
        coordinator.stage(preview)
        await mark(preview)

        let mayLinger = await coordinator.finish()

        XCTAssertTrue(mayLinger)
        XCTAssertFalse(coordinator.isActive)
        XCTAssertFalse(try log.rows().contains { $0["stage"] == "composition-settle" })
    }

    private func makeRecording(
        log: LatencyTestLog, transport: FakeInlinePreviewTransport,
        target: any InsertionTargetObserver = StableOpaqueObserver()
    ) async throws -> (RecordingSession, InlinePreviewSession, RecordingInsertionBackend) {
        let backend = RecordingInsertionBackend()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EposSettlementTests-\(UUID())"))
        let recording = RecordingSession(
            recordingID: "timed", audio: FakeMicrophoneCapture(), transcriber: FakeTranscriber(),
            textInsertion: backend, targetObserverFactory: { target }, settings: Settings(inlinePreview: true),
            canonicalizer: TranscriptCanonicalizer(rules: []), diagnostics: log.sink,
            evidenceRecorder: CorrectionEvidenceRecorder(
                evidence: CorrectionEvidenceStore(defaults: defaults), captureDelays: [], currentRecordingID: { nil }
            ),
            isShortcutHeld: { false }, isMicrophoneAccessMissing: { false }, includeTranscriptText: false,
            onEvent: { _, _ in }
        )
        let preview = try XCTUnwrap(recording.makeInlinePreviewSession(
            bundleIdentifier: "com.test.app", transport: transport, sleep: { _ in }
        ))
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: target, latency: log.timing
        )
        recording.stageFinalizationSessions(inlinePreview: preview, insertion: insertion)
        await mark(preview)
        return (recording, preview, backend)
    }

    private func mark(_ preview: InlinePreviewSession) async {
        await preview.begin()
        await preview.mark("draft")
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while ContinuousClock().now < deadline {
            let report = await preview.report()
            if report.marksSent > 0 || report.failure != nil { return }
            await Task.yield()
        }
        XCTFail("preview mark never completed")
    }
}

private final class SettlingReadableTarget: InsertionTargetObserver {
    private(set) var valueReads = 0

    func captureBaseline() {}
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { false }
    func observedValue() -> String? {
        valueReads += 1
        return valueReads == 1 ? "draft" : ""
    }
    func observedSelectedRange() -> InsertionTargetTextRange? { .init(location: 0, length: 0) }
    func requiresTextContextValidation() -> Bool { true }
    func baselineInsertionContext() -> InsertionTargetContext? { .init(prefix: "", suffix: "") }
    func targetApplicationBundleIdentifier() -> String? { "com.test.app" }
    func targetWindowTitle() -> String? { nil }
}

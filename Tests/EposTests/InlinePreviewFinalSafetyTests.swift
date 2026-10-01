import XCTest
@testable import Epos

/// Final delivery must preserve another input method and the original selection
/// even when Accessibility cannot observe the field value.
@MainActor
final class InlinePreviewFinalSafetyTests: XCTestCase {
    private static let target = "com.test.app"

    func testUnsafeBeginRefusalBlocksOrdinaryKeystrokeDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(beginReply: "err unsafe composition owner is gone"),
            transcript: "Hello there.",
            expectedFailure: "unsafeTarget"
        )
    }

    func testUnsafeMarkRefusalBlocksOrdinaryKeystrokeDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(markReply: "err unsafe composition"),
            transcript: "Hello there.",
            expectedFailure: "unsafeTarget"
        )
    }

    func testUnsafeDiscardBlocksMultilineKeystrokeDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(cancelReply: "err unsafe composition"),
            transcript: "Hello\nthere."
        )
    }

    func testUnknownBeginRepliesBlockFinalDelivery() async {
        for error in [InlinePreviewTransportError.replyTimedOut, .replyPeerClosed, .replyMalformed] {
            await refusesUnsafeFinalTarget(
                transport: FakeInlinePreviewTransport(beginError: error),
                transcript: "Hello there.", expectedFailure: "connectFailed"
            )
        }
    }

    func testUnknownMarkRepliesBlockFinalDelivery() async {
        for error in [InlinePreviewTransportError.replyTimedOut, .replyPeerClosed, .replyMalformed] {
            await refusesUnsafeFinalTarget(
                transport: FakeInlinePreviewTransport(markError: error),
                transcript: "Hello there.", expectedFailure: "markFailed"
            )
        }
    }

    func testUnconfirmedDiscardBlocksMultilineDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(cancelReply: "err locked session gone"),
            transcript: "Hello\nthere."
        )
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(cancelError: .closed),
            transcript: "Hello\nthere."
        )
    }

    func testGenericRefusalAfterAcceptedPreviewBlocksFinalDelivery() async {
        await refusesUnsafeFinalTarget(
            transport: FakeInlinePreviewTransport(markReplyAfterFirst: "err preview requires an empty selection"),
            transcript: "Hello there.", laterMark: "hello there again"
        )
    }

    func testFirstConclusiveMarkRefusalPreservesGuardedFinalDelivery() async {
        let transport = FakeInlinePreviewTransport(markReply: "err preview requires an empty selection")
        let backend = RecordingInsertionBackend()
        let coordinator = AppCoordinator(
            textInsertion: backend, settings: Settings(), inlinePreviewEnabled: true, autoStart: false
        )
        guard let preview = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target, transport: transport
        ) else { return XCTFail("expected a preview session") }
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver()
        )
        coordinator.stageFinalizationSessions(inlinePreview: preview, insertion: insertion)
        await preview.begin()
        await preview.mark("hello there")
        await Self.waitUntil { await preview.report().failure == "markRefused" }

        let route = await coordinator.commitFinalTranscript("Hello there.")
        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.inserted, ["Hello there."])
        let lines = await transport.lines
        XCTAssertFalse(lines.contains("cancel"), "no Epos mark exists to cancel")
    }

    private func refusesUnsafeFinalTarget(
        transport: FakeInlinePreviewTransport,
        transcript: String,
        expectedFailure: String? = nil,
        laterMark: String? = nil
    ) async {
        let backend = RecordingInsertionBackend()
        let coordinator = AppCoordinator(
            textInsertion: backend,
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        guard let preview = coordinator.makeInlinePreviewSession(
            bundleIdentifier: Self.target, transport: transport
        ) else { return XCTFail("expected a preview session") }
        let insertion = FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver()
        )
        coordinator.stageFinalizationSessions(inlinePreview: preview, insertion: insertion)
        await preview.begin()
        await preview.mark("hello there")
        if let expectedFailure {
            await Self.waitUntil { await preview.report().failure == expectedFailure }
        } else {
            await Self.waitUntil { await preview.report().marksSent == 1 }
        }
        if let laterMark {
            await preview.mark(laterMark)
            await Self.waitUntil { await preview.report().failure == "unsafeTarget" }
        }

        let route = await coordinator.commitFinalTranscript(transcript)
        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertEqual(backend.inserted, [])
        XCTAssertNil(insertion.insertedTranscript)
        XCTAssertEqual(insertion.insertFinalResult(transcript), .backendRefused)
        XCTAssertEqual(backend.inserted, [])
    }

    private static func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "condition not met in time", file: file, line: line)
    }
}

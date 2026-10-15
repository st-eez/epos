import XCTest
@testable import Epos

@MainActor
final class InlinePreviewPhraseTests: XCTestCase {
    func testConfirmedPrefixIsNeverMarkedOrCommittedAgain() async {
        let transport = FakeInlinePreviewTransport()
        let preview = await makePreview(transport)
        let first = await preview.commitPhrase("First.")
        XCTAssertEqual(first, .committed)
        await preview.mark("First. unfinished")
        await preview.awaitDrainCompletion()
        let insertion = makeInsertion()
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: "First. Finished.", preview: preview, insertion: insertion
        )
        await preview.discard()
        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        XCTAssertEqual(insertion.insertedTranscript, "First. Finished.")
        let lines = await transport.lines
        XCTAssertEqual(lines, ["begin com.test.app", "seal First.", "mark  unfinished", "commit  Finished.", "end"])
    }

    func testReleaseAfterConfirmedPhraseNeedsNoSecondWrite() async {
        let transport = FakeInlinePreviewTransport()
        let preview = await makePreview(transport)
        _ = await preview.commitPhrase("Already delivered.")
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: "Already delivered.", preview: preview, insertion: makeInsertion()
        )
        await preview.discard()
        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        let lines = await transport.lines
        XCTAssertEqual(lines, ["begin com.test.app", "seal Already delivered.", "end"])
    }

    func testInterruptionAfterPrefixCannotFallBackToWholeTranscript() async {
        let transport = FakeInlinePreviewTransport(markReply: "err unsafe unmarked selection")
        let preview = await makePreview(transport)
        _ = await preview.commitPhrase("Delivered.")
        await preview.mark("Delivered. unfinished")
        await preview.awaitDrainCompletion()
        let backend = RecordingInsertionBackend()
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: "Delivered. Finished.", preview: preview, insertion: makeInsertion(backend)
        )
        XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
        XCTAssertTrue(backend.inserted.isEmpty)
        await preview.discard()
    }

    func testLostPhraseAcknowledgementSuppressesEveryFurtherWrite() async {
        let transport = FakeInlinePreviewTransport(commitError: .replyTimedOut)
        let preview = await makePreview(transport)
        let outcome = await preview.commitPhrase("Possibly delivered.")
        XCTAssertEqual(outcome, .ambiguous)
        await preview.mark("Possibly delivered. more")
        let backend = RecordingInsertionBackend()
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: "Possibly delivered. more", preview: preview, insertion: makeInsertion(backend)
        )
        XCTAssertEqual(route, .imeAmbiguous)
        XCTAssertTrue(backend.inserted.isEmpty)
        await preview.discard()
        let lines = await transport.lines
        XCTAssertEqual(lines, ["begin com.test.app", "seal Possibly delivered.", "end"])
    }

    func testNewlineAfterPrefixUsesNativeRemainderWithoutFallback() async {
        let transport = FakeInlinePreviewTransport()
        let preview = await makePreview(transport)
        _ = await preview.commitPhrase("First.")
        let backend = RecordingInsertionBackend()
        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: "First.\nSecond.", preview: preview, insertion: makeInsertion(backend)
        )
        XCTAssertEqual(route, .completed(.accepted, viaIME: true))
        XCTAssertTrue(backend.inserted.isEmpty)
        let lines = await transport.lines
        XCTAssertEqual(lines.last, "commit64 " + Data("\nSecond.".utf8).base64EncodedString())
        await preview.discard()
    }

    func testCancellationDiscardsOnlyTheNewDraft() async {
        let transport = FakeInlinePreviewTransport()
        let preview = await makePreview(transport)
        _ = await preview.commitPhrase("Keep this.")
        await preview.mark("Keep this. discard this")
        await preview.awaitDrainCompletion()
        await preview.discard()
        let lines = await transport.lines
        XCTAssertEqual(lines, ["begin com.test.app", "seal Keep this.", "mark  discard this", "cancel", "end"])
    }

    func testEmptyRemainderMustSafelyClearItsProvisionalSeparator() async {
        for reply in ["ok", "err unsafe selection"] {
            let transport = FakeInlinePreviewTransport(cancelReply: reply)
            let preview = await makePreview(transport)
            _ = await preview.commitPhrase("Hello")
            await preview.mark("Hello, ")
            await preview.awaitDrainCompletion()
            let backend = RecordingInsertionBackend()
            let route = await FinalTranscriptCommitRouter.attemptIMECommit(
                transcript: "Hello", preview: preview, insertion: makeInsertion(backend)
            )
            XCTAssertEqual(route, reply == "ok" ? .completed(.accepted, viaIME: true) : .completed(.targetRefused, viaIME: false))
            XCTAssertTrue(backend.inserted.isEmpty)
            let lines = await transport.lines
            XCTAssertTrue(lines.contains("cancel"))
            XCTAssertFalse(lines.contains { $0.hasPrefix("commit ") })
            await preview.discard()
        }
    }

    private func makePreview(_ transport: FakeInlinePreviewTransport) async -> InlinePreviewSession {
        let preview = InlinePreviewSession(transport: transport, bundleIdentifier: "com.test.app", sleep: { _ in })
        await preview.begin()
        return preview
    }

    private func makeInsertion(_ backend: RecordingInsertionBackend = RecordingInsertionBackend()) -> FinalTranscriptInsertionSession {
        FinalTranscriptInsertionSession(insertionSession: backend.startInsertionSession(), target: StableOpaqueObserver())
    }
}

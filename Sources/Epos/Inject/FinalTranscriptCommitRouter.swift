import Foundation

/// Routes the one authoritative final write between the palette-IME commit and
/// the keystroke backend, preserving `FinalTranscriptInsertionSession`'s
/// exactly-once contract across both.
///
/// Single-commit under every interleaving:
/// - The IME path is attempted only when the preview channel stayed healthy for
///   the entire recording and the probe rendered at least one mark; anything
///   less returns nil and the caller runs today's discard + guarded-keystroke
///   path unchanged.
/// - The composition is cancelled (with a positive ack) before the guard runs,
///   because live marked text is part of the AX-readable value and would read
///   as a user edit; the guard itself runs unchanged, before any commit.
/// - An acked commit records the transcript on the insertion session and is the
///   only write; no keystrokes follow.
/// - A probe refusal or send-side failure proves the commit did not execute, so
///   the keystroke fallback (which re-runs the guard) is safe.
/// - An unacknowledged commit after a complete send is ambiguous: the write may
///   have landed, so the insertion session is closed without claiming or
///   attempting anything, and the caller reports the recording honestly rather
///   than risking the transcript landing twice.
@MainActor
enum FinalTranscriptCommitRouter {
    enum Route: Equatable {
        case completed(FinalInsertionResult, viaIME: Bool)
        case imeAmbiguous
    }

    /// Returns nil when the IME path was not applicable and nothing was written
    /// or cancelled; the caller then follows the ordinary keystroke path.
    static func attemptIMECommit(
        transcript: String,
        preview: InlinePreviewSession,
        insertion: FinalTranscriptInsertionSession?,
        settle: () async -> Void = { try? await Task.sleep(for: .milliseconds(30)) }
    ) async -> Route? {
        guard let insertion, InlinePreviewSession.isCommittableText(transcript) else {
            return nil
        }
        guard await preview.cancelCompositionForFinalCommit() else { return nil }
        // The probe acknowledged issuing the un-mark, not the host having drawn
        // it; the same settle the keystroke path uses after its discard.
        await settle()

        switch insertion.authorizeFinalWrite(transcript) {
        case .refused(let result):
            return .completed(result, viaIME: false)
        case .authorized:
            break
        }

        switch await preview.commitFinalTranscript(transcript) {
        case .committed:
            insertion.recordExternalCommit(transcript)
            return .completed(.accepted, viaIME: true)
        case .refused, .unavailable:
            return .completed(insertion.insertFinalResult(transcript), viaIME: false)
        case .ambiguous:
            insertion.cancel()
            return .imeAmbiguous
        }
    }
}

import Foundation

/// Commits the owned native composition in place. A conclusive refusal can use
/// guarded keystrokes after cleanup; a fully sent, unacknowledged commit cannot.
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
        latency: RecordingLatencyDiagnostics? = nil,
        settle: () async -> Void = { try? await Task.sleep(for: InlinePreviewSession.compositionSettleDelay) }
    ) async -> Route? {
        if await preview.hasAmbiguousPhraseCommit() {
            insertion?.cancel()
            return .imeAmbiguous
        }
        let hasPrefix = await preview.hasCommittedPrefix()
        guard let insertion, hasPrefix || InlinePreviewSession.isCommittableText(transcript) else {
            if hasPrefix { return .completed(.targetRefused, viaIME: true) }
            return nil
        }
        guard await preview.prepareFinalCommit() else {
            if await preview.hasUnsafeTarget() || hasPrefix {
                insertion.cancel()
                return .completed(.targetRefused, viaIME: false)
            }
            return nil
        }
        switch insertion.authorizeNativeCommit(transcript) {
        case .refused(let result):
            return .completed(result, viaIME: false)
        case .authorized:
            break
        }

        latency?.begin(.imeCommit)
        switch await preview.commitFinalTranscript(transcript) {
        case .targetUnsafe:
            latency?.end(.imeCommit, outcome: .refused)
            insertion.cancel()
            return .completed(.targetRefused, viaIME: false)
        case .committed:
            latency?.end(.imeCommit)
            insertion.recordExternalCommit(transcript)
            return .completed(.accepted, viaIME: true)
        case .refused:
            latency?.end(.imeCommit, outcome: .refused)
            return await fallback(transcript, preview: preview, insertion: insertion, settle: settle)
        case .unavailable:
            latency?.end(.imeCommit, outcome: .unavailable)
            return await fallback(transcript, preview: preview, insertion: insertion, settle: settle)
        case .ambiguous:
            latency?.end(.imeCommit, outcome: .ambiguous)
            insertion.cancel()
            return .imeAmbiguous
        }
    }

    private static func fallback(
        _ transcript: String, preview: InlinePreviewSession,
        insertion: FinalTranscriptInsertionSession, settle: () async -> Void
    ) async -> Route {
        await preview.discard()
        if await preview.hasCommittedPrefix() {
            insertion.cancel()
            return .completed(.targetRefused, viaIME: true)
        }
        guard await !preview.hasUnsafeTarget() else {
            insertion.cancel()
            return .completed(.targetRefused, viaIME: false)
        }
        if await !insertion.settleReadableBaseline() { await settle() }
        return .completed(insertion.insertFinalResult(transcript), viaIME: false)
    }
}

import Foundation

/// Streams a live transcript into a `TextInsertionSession`, converging on the
/// recognizer's text as it arrives. Every update — volatile partial or
/// authoritative per-segment final — reconciles the inserted text with a minimal
/// edit: it backspaces the suffix that diverges from the new target and types the
/// corrected remainder.
///
/// So the freshest words stream in as soon as the recognizer produces them (the
/// lowest latency it allows), and a later revision — even of a word already
/// typed — corrects the field in place instead of stranding a stale word or
/// waiting for the segment final to catch up. End state equals the canonicalized
/// final transcript exactly.
///
/// The trade-off is visible churn: when the recognizer revises a word it has
/// already emitted, that word is backspaced and retyped live. This is the
/// deliberate choice to favor latency over the earlier append-only policy, which
/// held back the newest words by ~1 confirmation cycle to avoid that churn.
public final class ProgressiveTranscriptInsertionSession {
    private let insertionSession: any TextInsertionSession
    private let canonicalize: (String) -> String
    private let log = EposLogger(category: "inject")

    private var committedText = ""
    private var didFinish = false

    public init(
        insertionSession: any TextInsertionSession,
        canonicalize: @escaping (String) -> String
    ) {
        self.insertionSession = insertionSession
        self.canonicalize = canonicalize
    }

    /// Volatile partial: reconcile to the latest text immediately so the newest
    /// words appear with the lowest latency the recognizer allows. A revised word
    /// is corrected live rather than held back.
    public func acceptPartialTranscript(_ text: String) {
        guard !didFinish else { return }
        reconcile(to: canonicalize(text))
    }

    /// Authoritative per-segment final: reconcile to the committed transcript so
    /// the field matches the recognizer's final text for the segment exactly.
    public func acceptFinalTranscript(_ text: String) {
        guard !didFinish else { return }
        reconcile(to: canonicalize(text))
    }

    public func finish() {
        guard !didFinish else { return }
        didFinish = true
        insertionSession.finish()
    }

    public func cancel() {
        guard !didFinish else { return }
        didFinish = true
        insertionSession.cancel()
    }

    /// Converge the inserted text to `target` with a minimal edit: backspace the
    /// suffix that diverges from `target`, then type the corrected remainder.
    /// Shared by partials and finals so the field always tracks the recognizer's
    /// current best transcript and self-heals even when canonicalization reflows
    /// text across a previously committed boundary.
    private func reconcile(to target: String) {
        guard target != committedText else { return }

        let shared = committedText.commonPrefix(with: target)
        let deleteCount = committedText.count - shared.count
        let insertion = String(target.dropFirst(shared.count))

        if deleteCount > 0 { insertionSession.deleteBackward(count: deleteCount) }
        if !insertion.isEmpty { insertionSession.insert(insertion) }

        committedText = target
        log.info("progressive reconcile deletedChars=\(deleteCount) insertedChars=\(insertion.utf16.count) totalChars=\(committedText.utf16.count)")
    }
}

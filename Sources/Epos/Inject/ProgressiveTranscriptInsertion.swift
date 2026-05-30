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
    private let target: any InsertionTargetObserver
    private let log = EposLogger(category: "inject")

    private var committedText = ""
    private var didFinish = false
    private var didCaptureBaseline = false
    /// Latched once the target diverges: backspacing is no longer safe because
    /// `committedText` no longer models the screen. We never resume deleting; we
    /// only append, so existing on-screen text can never be corrupted.
    private var appendOnly = false

    public init(
        insertionSession: any TextInsertionSession,
        canonicalize: @escaping (String) -> String,
        target: any InsertionTargetObserver = NullInsertionTargetObserver()
    ) {
        self.insertionSession = insertionSession
        self.canonicalize = canonicalize
        self.target = target
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

    /// Reconcile to the already-canonicalized, already-guard-validated final
    /// transcript (the polish output). Does NOT canonicalize again, so the string
    /// the guard validated is byte-for-byte the string typed. Returns true iff
    /// keystrokes were emitted; false means the append-only latch suppressed the
    /// retype, so the caller must not claim the polish landed.
    @discardableResult
    public func acceptFinalPolishedTranscript(_ text: String) -> Bool {
        guard !didFinish else { return false }
        return reconcile(to: text)
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

    /// Converge the inserted text to `newTarget` with a minimal edit: backspace
    /// the suffix that diverges from `newTarget`, then type the corrected
    /// remainder. Shared by partials and finals so the field always tracks the
    /// recognizer's current best transcript and self-heals even when
    /// canonicalization reflows text across a previously committed boundary.
    ///
    /// Guarded so the backspace half can never delete characters that aren't
    /// ours. The cheap focus-identity check runs every reconcile; the expensive
    /// on-screen value read is gated to the pre-delete moment only — an append
    /// (deleteCount == 0) lands at the caret and corrupts nothing, so it needs no
    /// value read. Once focus moves we abort; once the value diverges we latch
    /// into append-only and never delete again.
    /// The minimal backspace-from-caret edit converging `committed` onto `target`:
    /// delete everything past their longest common prefix, then type the rest.
    /// With a delete-backward-only backend this prefix edit is optimal — a leading
    /// change (e.g. capitalizing the first word) necessarily retypes from there,
    /// which is the backend's floor; a pure append costs zero deletes.
    static func minimalEdit(from committed: String, to target: String) -> (deleteCount: Int, insertTail: String) {
        let shared = committed.commonPrefix(with: target).count
        return (committed.count - shared, String(target.dropFirst(shared)))
    }

    @discardableResult
    private func reconcile(to newTarget: String) -> Bool {
        guard newTarget != committedText else { return false }

        if !didCaptureBaseline {
            target.captureBaseline()
            didCaptureBaseline = true
        }

        // Cheap, every reconcile: if focus left the home field, no insertion can
        // land safely. Stop the whole session without backspacing — cleanup
        // backspacing would itself delete the wrong characters.
        if target.focusChangedSinceStart() {
            log.info("insertion guard: focus changed mid-session; aborting insertion")
            cancel()
            return false
        }

        var (deleteCount, insertion) = Self.minimalEdit(from: committedText, to: newTarget)

        // A delete is the only operation that can corrupt existing text, so it is
        // the only one that pays for the expensive value read (unless we've
        // already latched append-only). The read maps an empty/failed result to
        // `.emptyExposed` (this field has shown text before → divergence) or
        // `.notRead` (an AX-opaque app such as cmux → uninformative, keep
        // self-correcting). Only divergence forces append-only.
        if deleteCount > 0, !appendOnly {
            let observation = InsertionTargetObservation.read(
                target.observedValue(),
                exposesText: target.exposesTextValue()
            )
            switch InsertionTargetGuard.decide(expected: committedText, observed: observation) {
            case .abort:
                log.info("insertion guard: target unreadable on pre-delete check; aborting")
                cancel()
                return false
            case .stopAppendOnly:
                appendOnly = true
                log.info("insertion guard: on-screen text diverged; switching to append-only")
            case .proceed:
                break
            }
        }

        // Append-only: never delete, only type the genuinely new tail past what we
        // last committed, so we can't corrupt the field's own edits.
        if appendOnly {
            deleteCount = 0
            insertion = newTarget.hasPrefix(committedText)
                ? String(newTarget.dropFirst(committedText.count))
                : ""
        }

        let applied = deleteCount > 0 || !insertion.isEmpty
        if deleteCount > 0 { insertionSession.deleteBackward(count: deleteCount) }
        if !insertion.isEmpty { insertionSession.insert(insertion) }

        committedText = newTarget
        log.info("progressive reconcile deletedChars=\(deleteCount) insertedChars=\(insertion.utf16.count) totalChars=\(committedText.utf16.count) appendOnly=\(self.appendOnly)")
        return applied
    }
}

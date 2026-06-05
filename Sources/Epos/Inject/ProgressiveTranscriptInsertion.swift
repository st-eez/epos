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
    private var didReplaceInitialSelection = false
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
        target.captureBaseline()
        didCaptureBaseline = true
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
        // Raw per-segment finals are authoritative and only grow across a recording,
        // so under the append-only latch they take the loss-proof append (see
        // `reconcile`): the user's dictated words must never be silently dropped, even
        // when the recognizer re-cased/punctuated the prefix we already typed.
        reconcile(to: canonicalize(text), lossProofAppend: true)
    }

    /// End-of-stream fallback for a remaining volatile partial. It is more authoritative
    /// than a live partial because the recognizer produced no later final, but less
    /// trustworthy than a real final segment. In append-only mode, allow clean prefix
    /// extensions to land while suppressing non-prefix revisions that would graft a
    /// hybrid tail onto stale on-screen text.
    @discardableResult
    public func acceptFallbackFinalTranscript(_ text: String) -> String {
        guard !didFinish else { return committedText }
        let target = canonicalize(text)
        _ = reconcile(to: target, lossProofAppend: target.hasPrefix(committedText))
        return committedText
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

    public func cancelAndRetractInsertedText() {
        guard !didFinish else { return }
        retractInsertedTextIfSafe()
        didFinish = true
        insertionSession.cancel()
    }

    public func observedInsertedText() -> String? {
        guard didCaptureBaseline,
              !target.focusChangedSinceStart(),
              target.exposesTextValue(),
              let context = target.baselineInsertionContext(),
              let value = target.observedValue() else {
            return nil
        }

        return context.insertedText(in: value)
    }

    public func targetApplicationBundleIdentifier() -> String? {
        target.targetApplicationBundleIdentifier()
    }

    public func targetWindowTitle() -> String? {
        target.targetWindowTitle()
    }

    public var insertedTranscript: String { committedText }

    /// Converge the inserted text to `newTarget` with a minimal edit: backspace
    /// the suffix that diverges from `newTarget`, then type the corrected
    /// remainder. Shared by partials and finals so the field always tracks the
    /// recognizer's current best transcript and self-heals even when
    /// canonicalization reflows text across a previously committed boundary.
    ///
    /// Guarded so the backspace half can never delete characters that aren't
    /// ours. The cheap focus-identity check runs every reconcile; the expensive
    /// on-screen value read is paid before deletes and before pure appends in
    /// text-exposing targets. Once focus moves we abort; once the value diverges
    /// before a delete we latch into append-only and never delete again.
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
    private func reconcile(to newTarget: String, lossProofAppend: Bool = false) -> Bool {
        guard newTarget != committedText else { return false }

        // Every reconcile (cheap pid check; opaque targets add timeout-bounded
        // signature reads): if focus left the home field, no insertion can land
        // safely. Stop the whole session without backspacing — cleanup
        // backspacing would itself delete the wrong characters.
        if target.focusChangedSinceStart() {
            let evaluation = InsertionTargetGuard.evaluate(expected: committedText, observed: .focusChanged)
            logGuardDecision(evaluation, action: "abort")
            cancel()
            return false
        }

        var (deleteCount, insertion) = Self.minimalEdit(from: committedText, to: newTarget)

        // A delete is the operation that can corrupt existing text, so it always
        // pays for the expensive value read (unless we've already latched
        // append-only). The read maps an empty/failed result to `.emptyExposed`
        // (this field has shown text before → divergence) or `.notRead` (an
        // AX-opaque app such as cmux → uninformative, keep self-correcting).
        // Divergence before a delete forces append-only.
        //
        // On the `.value` path (no baseline context) the suffix check is the
        // deliberate ours-ness proxy for these incremental, self-correcting
        // deletes; only the bulk retract demands the stricter caret-at-end read
        // (`canRetractCommittedText`) because a wrong retract is catastrophic
        // while a wrong revision delete is bounded and immediately retyped.
        if deleteCount > 0, !appendOnly {
            let observation = targetObservation()
            let evaluation = InsertionTargetGuard.evaluate(expected: committedText, observed: observation)
            switch evaluation.decision {
            case .abort:
                logGuardDecision(evaluation, action: "abort")
                cancel()
                return false
            case .stopAppendOnly:
                appendOnly = true
                logGuardDecision(evaluation, action: "appendOnly")
            case .proceed:
                break
            }
        }

        // A pure append cannot delete user content, but it can still type into the
        // wrong field after a same-app focus move. Text-exposing targets are
        // checked before appending; AX-opaque targets stay on the cheap pid guard
        // because their value reads are uninformative.
        if deleteCount == 0,
           !appendOnly,
           !insertion.isEmpty,
            target.exposesTextValue() {
            let observation = targetObservation()
            let evaluation = InsertionTargetGuard.evaluate(expected: committedText, observed: observation)
            // When the focus check proves same-element identity (CFEqual passed at
            // the top of this reconcile), a divergent value cannot be a field move:
            // non-empty means same-field mutation (autocorrect, IME normalization),
            // empty means the pinned field reads as unreadable-or-cleared
            // (Electron-style inputs advertise AXValue but return nothing). Both
            // latch append-only like the delete branch instead of killing the rest
            // of the dictation. Without identity proof the value read is the last
            // backstop against typing into another same-app field, so divergence
            // there still cancels.
            let identityPinnedDivergence = target.verifiesFocusIdentity()
            switch evaluation.decision {
            case .proceed:
                break
            case .stopAppendOnly where !committedText.isEmpty
                && (evaluation.caretMatches == true || identityPinnedDivergence):
                appendOnly = true
                logGuardDecision(evaluation, action: "appendOnly")
            case .stopAppendOnly, .abort:
                logGuardDecision(evaluation, action: "abortAppend")
                cancel()
                return false
            }
            if committedText.isEmpty, evaluation.reason == "initialSelectionMatch" {
                didReplaceInitialSelection = true
            }
        }

        // Append-only: never delete, only type new tail past what we last committed,
        // so we can't corrupt the field's own edits. No caret revalidation here by
        // design: the latch fired BECAUSE value/caret reads proved unreliable for
        // this field, so consulting them again would either be noise or convert
        // do-no-harm into kill-the-dictation. Keystrokes land at the live caret —
        // inherent to synthesis; a mid-utterance caret move while holding fn is
        // rare and the misplaced tail is bounded, visible, and never destructive.
        // WHICH tail depends on the source:
        //
        // - A raw final (`lossProofAppend`) is the recognizer's authoritative end-
        //   state. When the final only extends the commit, append that extension. When
        //   the final re-cases/punctuates an earlier prefix and then adds new words,
        //   append only a length-based tail if it starts at a word boundary. Never
        //   graft a mid-token suffix: "bched." -> "batched." cannot be fixed without
        //   deleting, and appending "d." would make the visible text worse.
        // - A volatile partial or the polished rewrite stays conservative: it appends
        //   only a clean prefix-extension. Partials flicker (a lateral revision would
        //   graft garbage), and a polish that doesn't extend the commit must stay
        //   suppressible.
        if appendOnly {
            deleteCount = 0
            if lossProofAppend {
                insertion = Self.lossProofAppendTail(from: committedText, to: newTarget)
                if insertion.isEmpty, newTarget.count > committedText.count, !newTarget.hasPrefix(committedText) {
                    log.info("append-only raw final suppressed unsafe mid-token tail committedChars=\(committedText.utf16.count) targetChars=\(newTarget.utf16.count)")
                }
            } else {
                insertion = newTarget.hasPrefix(committedText)
                    ? String(newTarget.dropFirst(committedText.count))
                    : ""
            }
        }

        let applied = deleteCount > 0 || !insertion.isEmpty
        if deleteCount > 0 { insertionSession.deleteBackward(count: deleteCount) }
        if !insertion.isEmpty { insertionSession.insert(insertion) }

        // In normal mode the backspace-and-retype makes the field equal `newTarget`,
        // so the commit advances to it. In append-only we never delete, so the field
        // is only ever the previous commit plus what we just appended — advancing the
        // commit to `newTarget` would let it REGRESS below the on-screen text when a
        // revised partial is shorter (the delete was suppressed), and a later partial
        // growing the word back would then re-append a suffix already on screen
        // ("ticket" → "tick" → "ticket" yielded "ticketet"). Track only what landed.
        committedText = appendOnly ? committedText + insertion : newTarget
        log.info("progressive reconcile deletedChars=\(deleteCount) insertedChars=\(insertion.utf16.count) totalChars=\(committedText.utf16.count) appendOnly=\(self.appendOnly)")
        return applied
    }

    private func retractInsertedTextIfSafe() {
        guard !committedText.isEmpty, !appendOnly else { return }
        guard !didReplaceInitialSelection else {
            log.info("progressive retract skipped: initial selection replacement cannot be restored")
            return
        }
        if target.focusChangedSinceStart() {
            let evaluation = InsertionTargetGuard.evaluate(expected: committedText, observed: .focusChanged)
            logGuardDecision(evaluation, action: "skipRetract")
            return
        }

        let observation = targetObservation()
        let evaluation = InsertionTargetGuard.evaluate(expected: committedText, observed: observation)
        guard evaluation.decision == .proceed else {
            logGuardDecision(evaluation, action: "skipRetract")
            return
        }
        guard canRetractCommittedText(for: observation) else {
            logGuardDecision(evaluation, action: "skipRetract")
            return
        }

        insertionSession.deleteBackward(count: committedText.count)
        log.info("progressive retract deletedChars=\(committedText.count)")
        committedText = ""
    }

    private func canRetractCommittedText(for observation: InsertionTargetObservation) -> Bool {
        switch observation {
        case .positionedValue:
            return true
        case .value(let value):
            return target.observedSelectedRange() == InsertionTargetTextRange(
                location: value.utf16.count,
                length: 0
            )
        case .focusChanged, .emptyExposed, .notRead:
            return false
        }
    }

    /// Every guard decision logs the target's identity-verification capability and
    /// owning app alongside the evaluation: the 2026-06-05 word-one cancel regression
    /// was only diagnosable by inferring these from `reason=emptyExposed`, so they
    /// are recorded directly for the next field class that misbehaves.
    private func logGuardDecision(_ evaluation: InsertionGuardEvaluation, action: String) {
        let app = target.targetApplicationBundleIdentifier() ?? "nil"
        log.info(
            "insertion guard decision \(evaluation.logFields) identity=\(target.verifiesFocusIdentity()) app=\(app) action=\(action)"
        )
    }

    private func targetObservation() -> InsertionTargetObservation {
        let context = target.baselineInsertionContext()
        return InsertionTargetObservation.read(
            target.observedValue(),
            exposesText: target.exposesTextValue(),
            context: context,
            selectedRange: context == nil ? nil : target.observedSelectedRange()
        )
    }

    private static func lossProofAppendTail(from committed: String, to target: String) -> String {
        guard target.count > committed.count else { return "" }
        if target.hasPrefix(committed) {
            return String(target.dropFirst(committed.count))
        }
        guard let boundary = target.index(
            target.startIndex,
            offsetBy: committed.count,
            limitedBy: target.endIndex
        ), boundary < target.endIndex else {
            return ""
        }
        // The length-offset slice is only valid when the prefix is a re-RENDERING
        // (re-casing) of what's already on screen. An interior re-wording keeps the
        // boundary aligned by count but not by content ("I saw a cat" vs
        // "I saw a big| cat") — grafting that tail duplicates the last word and
        // drops the revision, so suppress it instead.
        guard String(target[..<boundary]).lowercased() == committed.lowercased() else { return "" }
        guard !isInsideWord(in: target, at: boundary) else { return "" }
        return String(target[boundary...])
    }

    private static func isInsideWord(in text: String, at index: String.Index) -> Bool {
        guard index > text.startIndex, index < text.endIndex else { return false }
        return isWordCharacter(text[text.index(before: index)]) && isWordCharacter(text[index])
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
    }
}

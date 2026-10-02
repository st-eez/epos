import ApplicationServices
import Foundation

public enum FinalInsertionResult: Equatable, Sendable {
    case targetRefused
    /// The guard could not verify the fn-press target because this process is not
    /// Accessibility-trusted: every AX read fails, so the target looks changed no
    /// matter where focus actually is. Split out from `targetRefused` because the
    /// two send the user to completely different places.
    case accessibilityUntrusted
    case backendRefused
    case accepted
}

public enum FinalInsertionDeliveryVerification: Equatable, Sendable {
    case unavailable
    case matched
    case mismatched
}

/// Decision of the shared pre-write guard, split from the write itself so an
/// alternate backend (the palette-IME commit) can run the identical verification
/// before its own write.
public enum FinalWriteAuthorization: Equatable, Sendable {
    case refused(FinalInsertionResult)
    case authorized
}

/// Captures the insertion target at fn press and performs at most one write.
///
/// This type is unchecked-Sendable only for its detached AX reads: the pre-write
/// baseline settle (whose caller is suspended awaiting it) and the post-write
/// readback. The coordinator never changes `insertedTranscript` or the captured
/// observer after accepting a write; `finish()` may close only the independent
/// backend while the detached AX read is in flight.
public final class FinalTranscriptInsertionSession: @unchecked Sendable {
    private let insertionSession: any TextInsertionSession
    private let target: any InsertionTargetObserver
    private let recordingID: String?
    private let latency: RecordingLatencyDiagnostics?
    private let isAccessibilityTrusted: @Sendable () -> Bool
    private let log = EposLogger(category: "inject")

    private var didClose = false
    public private(set) var insertedTranscript: String?

    /// `isAccessibilityTrusted` is injectable because TCC state cannot be staged
    /// from a test process, and the untrusted branch is exactly the one that used
    /// to be misreported as a moved target.
    public init(
        insertionSession: any TextInsertionSession,
        target: any InsertionTargetObserver = NullInsertionTargetObserver(),
        recordingID: String? = nil,
        latency: RecordingLatencyDiagnostics? = nil,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.insertionSession = insertionSession
        self.target = target
        self.recordingID = recordingID
        self.latency = latency
        self.isAccessibilityTrusted = isAccessibilityTrusted
        target.captureBaseline()
    }

    public func insertFinalResult(_ text: String) -> FinalInsertionResult {
        if case .refused(let result) = authorizeFinalWrite(text) {
            return result
        }

        latency?.begin(.keystrokeWrite)
        guard insertionSession.insert(text) else {
            latency?.end(.keystrokeWrite, outcome: .refused)
            log.error(
                "final insertion refused: keystroke backend unavailable",
                recordingID: recordingID
            )
            cancel()
            return .backendRefused
        }
        insertedTranscript = text
        latency?.end(.keystrokeWrite)
        latency?.end(.releaseToWrite)
        log.info(
            "final insertion wrote chars=\(text.utf16.count)",
            recordingID: recordingID
        )
        return .accepted
    }

    /// The shared pre-write verification. Refusal semantics are the keystroke
    /// path's: a changed target cancels the session, after which no write of any
    /// kind can ever be issued.
    public func authorizeFinalWrite(_ text: String) -> FinalWriteAuthorization {
        latency?.begin(.targetAuthorization)
        var outcome = RecordingLatencyDiagnostics.Outcome.refused
        defer { latency?.end(.targetAuthorization, outcome: outcome) }
        guard !didClose,
              insertedTranscript == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .refused(.backendRefused)
        }
        guard targetIsUnchanged() else {
            // With Accessibility revoked there is no baseline to compare against and
            // every AX read fails, so this refusal fires for a reason that has
            // nothing to do with focus. The keystroke backend's own trust check is
            // the only one that names it, and it sits behind this refusal where it
            // can never run — leaving triage (and the user) blaming a moved target
            // for a permissions outage.
            guard isAccessibilityTrusted() else {
                log.error(
                    "final insertion refused: Accessibility permission is not granted "
                        + "(System Settings > Privacy & Security > Accessibility)",
                    recordingID: recordingID
                )
                cancel()
                return .refused(.accessibilityUntrusted)
            }
            log.info(
                "final insertion refused: fn-press target changed",
                recordingID: recordingID
            )
            cancel()
            return .refused(.targetRefused)
        }
        outcome = .completed
        return .authorized
    }

    /// Records a write performed by the acknowledged IME-commit backend. The
    /// exactly-once contract is unchanged: `insertedTranscript` is set at most
    /// once, and only after `authorizeFinalWrite` returned `.authorized` for
    /// this recording.
    public func recordExternalCommit(_ text: String) {
        guard !didClose, insertedTranscript == nil else { return }
        insertedTranscript = text
        latency?.end(.releaseToWrite)
        log.info(
            "final insertion committed via ime chars=\(text.utf16.count)",
            recordingID: recordingID
        )
    }

    /// One poll of the readable baseline. `unverifiable` means the focus guard
    /// already has a deterministic refusal — waiting longer cannot change it.
    private enum BaselinePoll: Sendable {
        case restored
        case diverged
        case unverifiable
    }

    /// Bounded wait for the fn-press text context to be readable again before
    /// the final authorization runs.
    ///
    /// A Chromium/Electron host applies a composition teardown asynchronously:
    /// the preview's cancel ack proves the un-mark was issued, not that the
    /// host reflected it into its AX value, so an immediate guard read can see
    /// the stale marked text and refuse it as a user edit. Each poll runs the
    /// guard's own checks — the focus guard first, then the shared readable
    /// comparison — returning the moment the baseline is back or the focus
    /// guard's refusal is already certain; a target the user genuinely edited
    /// never matches and spends the ladder before the guard refuses it as
    /// before.
    ///
    /// Returns false when there is no readable baseline to poll (opaque or
    /// uncaptured target, or a closed session) so the caller can apply the
    /// fixed composition settle instead.
    @discardableResult
    public func settleReadableBaseline(
        retryDelaysNanoseconds: [UInt64] = [0, 20_000_000, 60_000_000, 120_000_000]
    ) async -> Bool {
        guard !didClose, insertedTranscript == nil,
              target.hasCapturedTarget(),
              target.baselineInsertionContext() != nil else { return false }
        var reads = 0
        for delay in retryDelaysNanoseconds {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            reads += 1
            let poll = await Task.detached(priority: .userInitiated) { [self] () -> BaselinePoll in
                guard !target.focusChangedSinceStart(),
                      let context = target.baselineInsertionContext() else {
                    return .unverifiable
                }
                return observeReadableContext(against: context).matches ? .restored : .diverged
            }.value
            switch poll {
            case .restored:
                if reads > 1 {
                    // The composition-teardown race, caught in the act: evidence
                    // that a slow host needed the wait, and how much of it.
                    log.info(
                        "final insertion baseline restored after \(reads) reads",
                        recordingID: recordingID
                    )
                }
                return true
            case .unverifiable:
                return true
            case .diverged:
                continue
            }
        }
        log.info(
            "final insertion baseline not restored after \(reads) reads; the guard decides",
            recordingID: recordingID
        )
        return true
    }

    /// Gives posted keystrokes a bounded opportunity to reach an AX-readable
    /// field, then compares the exact inserted span. AX reads run off the main
    /// actor and each live read is independently bounded by the observer.
    public func verifyDelivery(
        expected text: String,
        retryDelaysNanoseconds: [UInt64] = [20_000_000, 60_000_000, 120_000_000]
    ) async -> FinalInsertionDeliveryVerification {
        latency?.begin(.deliveryReadback)
        var timingOutcome = RecordingLatencyDiagnostics.Outcome.unavailable
        defer { latency?.end(.deliveryReadback, outcome: timingOutcome) }
        guard insertedTranscript == text,
              let context = target.baselineInsertionContext(),
              context.selectedText != text else {
            // Replacing a selection with identical text leaves the field value
            // unchanged, so readback cannot prove the posted write occurred.
            return .unavailable
        }

        var observations: [String?] = []
        for delay in retryDelaysNanoseconds {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            let observed = await Task.detached(priority: .userInitiated) { [self] in
                observedInsertedText()
            }.value
            observations.append(observed)
            if let observed {
                if observed == text {
                    timingOutcome = .completed
                    logDeliveryReadback(
                        expected: text,
                        observations: observations,
                        baselineSelectedText: context.selectedText,
                        outcome: .matched
                    )
                    return .matched
                }
            }
        }
        let outcome = Self.classify(
            observations: observations,
            baselineSelectedText: context.selectedText
        )
        timingOutcome = outcome == .mismatched ? .failed : .unavailable
        logDeliveryReadback(
            expected: text,
            observations: observations,
            baselineSelectedText: context.selectedText,
            outcome: outcome
        )
        return outcome
    }

    public func finish() {
        guard !didClose else { return }
        didClose = true
        insertionSession.finish()
    }

    public func cancel() {
        guard !didClose else { return }
        didClose = true
        insertionSession.cancel()
    }

    public func observedInsertedText() -> String? {
        guard insertedTranscript != nil,
              !target.focusChangedSinceStart(),
              let context = target.baselineInsertionContext(),
              let value = target.observedValue() else {
            return nil
        }
        return context.insertedText(in: value)
    }

    public func targetApplicationBundleIdentifier() -> String? {
        target.targetApplicationBundleIdentifier()
    }

    /// Preview must not replace text selected at fn press. Unknown selections
    /// are checked again by the input method before its first marked-text write.
    public var baselineSelectedRange: InsertionTargetTextRange? {
        target.baselineInsertionContext()?.selectedRange
    }

    public func targetWindowTitle() -> String? {
        target.targetWindowTitle()
    }

    private func targetIsUnchanged() -> Bool {
        guard target.hasCapturedTarget() else {
            // Failure A of the Electron dormant-tree bug: nothing was focusable
            // at fn press, so there is no target to verify, and "target changed"
            // alone would misname it.
            log.info(
                "insertion guard: no fn-press target was captured",
                recordingID: recordingID
            )
            return false
        }
        guard !target.focusChangedSinceStart() else {
            // The observer names which focus check failed.
            return false
        }
        guard let context = target.baselineInsertionContext() else {
            return !target.requiresTextContextValidation()
        }
        let observation = observeReadableContext(against: context)
        guard !observation.matches else { return true }
        guard let value = observation.value else {
            log.info(
                "insertion guard: target value unreadable before final write",
                recordingID: recordingID
            )
            return false
        }
        guard let selectedRange = observation.selectedRange else {
            log.info(
                "insertion guard: target selection unreadable before final write",
                recordingID: recordingID
            )
            return false
        }
        // Lengths and ranges only: this is a divergence shape, and the field
        // value is the user's content, not the transcript under test.
        let baselineUTF16 = context.prefix.utf16.count
            + context.selectedText.utf16.count + context.suffix.utf16.count
        log.info(
            "insertion guard: text context diverged from baseline "
                + "(value utf16 \(baselineUTF16) -> \(value.utf16.count), selection "
                + "\(context.selectedRange.location),\(context.selectedRange.length) -> "
                + "\(selectedRange.location),\(selectedRange.length))",
            recordingID: recordingID
        )
        return false
    }

    /// The one readable-context comparison, shared verbatim by the pre-write
    /// settle and the final guard so the two can never drift apart. The raw
    /// observations come back with the verdict because the guard's refusal
    /// logging needs to name which read failed and by how much.
    private func observeReadableContext(
        against context: InsertionTargetContext
    ) -> (matches: Bool, value: String?, selectedRange: InsertionTargetTextRange?) {
        guard let value = target.observedValue() else {
            return (false, nil, nil)
        }
        guard let selectedRange = target.observedSelectedRange() else {
            return (false, value, nil)
        }
        return (
            context.matchesBaseline(value: value, selectedRange: selectedRange),
            value,
            selectedRange
        )
    }

    /// Classifies a run of readbacks in which no attempt ever equalled the
    /// expected text.
    ///
    /// A divergent read only proves the wrong text landed when the same value
    /// comes back twice in a row. A long transcript is posted as many chunked
    /// keyboard events (`KeystrokeTextInjector.maxUTF16UnitsPerEvent`), and the
    /// retry ladder is shorter than a slow field takes to consume them, so a
    /// single read can catch a still-growing span that matches neither the
    /// expected text nor the baseline selection. Calling that a mismatch turns
    /// successful dictations into `delivery-mismatch` in the reliability log, so
    /// anything unsettled is reported as the honest "cannot verify" class.
    /// Either way this is diagnostics only; no corrective write ever follows.
    private static func classify(
        observations: [String?],
        baselineSelectedText: String
    ) -> FinalInsertionDeliveryVerification {
        for (previous, current) in zip(observations, observations.dropFirst()) {
            guard let previous, let current,
                  previous == current,
                  current != baselineSelectedText else { continue }
            return .mismatched
        }
        return .unavailable
    }

    private func logDeliveryReadback(
        expected: String,
        observations: [String?],
        baselineSelectedText: String,
        outcome: FinalInsertionDeliveryVerification
    ) {
        let readable = observations.compactMap { $0 }
        let mismatches = readable.filter { $0 != baselineSelectedText }
        let observedLengths = observations.map {
            $0.map { String($0.utf16.count) } ?? "nil"
        }.joined(separator: ",")
        log.info(
            "delivery readback " +
                "outcome=\(outcome) " +
                "attempts=\(observations.count) " +
                "readable=\(readable.count) " +
                "finalReadable=\(observations.last.flatMap { $0 } != nil) " +
                "staleBaseline=\(readable.count - mismatches.count) " +
                "divergent=\(mismatches.count) " +
                "expectedUTF16=\(expected.utf16.count) " +
                "observedUTF16=\(observedLengths)",
            recordingID: recordingID
        )
    }
}

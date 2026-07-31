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
/// This type is unchecked-Sendable only for its post-write readback. The
/// coordinator never changes `insertedTranscript` or the captured observer after
/// accepting a write; `finish()` may close only the independent backend while the
/// detached AX read is in flight.
public final class FinalTranscriptInsertionSession: @unchecked Sendable {
    private let insertionSession: any TextInsertionSession
    private let target: any InsertionTargetObserver
    private let recordingID: String?
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
        isAccessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.insertionSession = insertionSession
        self.target = target
        self.recordingID = recordingID
        self.isAccessibilityTrusted = isAccessibilityTrusted
        target.captureBaseline()
    }

    public func insertFinalResult(_ text: String) -> FinalInsertionResult {
        if case .refused(let result) = authorizeFinalWrite(text) {
            return result
        }

        guard insertionSession.insert(text) else {
            log.error(
                "final insertion refused: keystroke backend unavailable",
                recordingID: recordingID
            )
            cancel()
            return .backendRefused
        }
        insertedTranscript = text
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
        return .authorized
    }

    /// Records a write performed by the acknowledged IME-commit backend. The
    /// exactly-once contract is unchanged: `insertedTranscript` is set at most
    /// once, and only after `authorizeFinalWrite` returned `.authorized` for
    /// this recording.
    public func recordExternalCommit(_ text: String) {
        guard !didClose, insertedTranscript == nil else { return }
        insertedTranscript = text
        log.info(
            "final insertion committed via ime chars=\(text.utf16.count)",
            recordingID: recordingID
        )
    }

    /// Gives posted keystrokes a bounded opportunity to reach an AX-readable
    /// field, then compares the exact inserted span. AX reads run off the main
    /// actor and each live read is independently bounded by the observer.
    public func verifyDelivery(
        expected text: String,
        retryDelaysNanoseconds: [UInt64] = [20_000_000, 60_000_000, 120_000_000]
    ) async -> FinalInsertionDeliveryVerification {
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

    public func targetWindowTitle() -> String? {
        target.targetWindowTitle()
    }

    private func targetIsUnchanged() -> Bool {
        guard target.hasCapturedTarget(),
              !target.focusChangedSinceStart() else {
            return false
        }
        guard let context = target.baselineInsertionContext() else {
            return !target.requiresTextContextValidation()
        }
        guard let value = target.observedValue(),
              let selectedRange = target.observedSelectedRange() else {
            return false
        }
        return context.matchesBaseline(value: value, selectedRange: selectedRange)
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

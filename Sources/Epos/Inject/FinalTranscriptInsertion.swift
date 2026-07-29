import Foundation

public enum FinalInsertionResult: Equatable, Sendable {
    case targetRefused
    case backendRefused
    case accepted
}

public enum FinalInsertionDeliveryVerification: Equatable, Sendable {
    case unavailable
    case matched
    case mismatched
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
    private let log = EposLogger(category: "inject")

    private var didClose = false
    public private(set) var insertedTranscript: String?

    public init(
        insertionSession: any TextInsertionSession,
        target: any InsertionTargetObserver = NullInsertionTargetObserver(),
        recordingID: String? = nil
    ) {
        self.insertionSession = insertionSession
        self.target = target
        self.recordingID = recordingID
        target.captureBaseline()
    }

    @discardableResult
    public func insertFinal(_ text: String) -> Bool {
        insertFinalResult(text) == .accepted
    }

    public func insertFinalResult(_ text: String) -> FinalInsertionResult {
        guard !didClose,
              insertedTranscript == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .backendRefused
        }
        guard targetIsUnchanged() else {
            log.info(
                "final insertion refused: fn-press target changed",
                recordingID: recordingID
            )
            cancel()
            return .targetRefused
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
        let mismatches = observations.compactMap { observed -> String? in
            guard let observed, observed != context.selectedText else { return nil }
            return observed
        }
        let stableRepeatedMismatch = mismatches.count >= 2 &&
            Set(mismatches).count == 1
        let finalAttemptMismatch = observations.last
            .flatMap { $0 }
            .map { $0 != context.selectedText } ?? false
        let outcome: FinalInsertionDeliveryVerification =
            (finalAttemptMismatch || stableRepeatedMismatch) ? .mismatched : .unavailable
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
                "stableMismatch=\(mismatches.count >= 2 && Set(mismatches).count == 1) " +
                "expectedUTF16=\(expected.utf16.count) " +
                "observedUTF16=\(observedLengths)",
            recordingID: recordingID
        )
    }
}

import Foundation

/// Captures the insertion target at fn press and performs at most one write.
public final class FinalTranscriptInsertionSession {
    private let insertionSession: any TextInsertionSession
    private let target: any InsertionTargetObserver
    private let log = EposLogger(category: "inject")

    private var didClose = false
    public private(set) var insertedTranscript: String?

    public init(
        insertionSession: any TextInsertionSession,
        target: any InsertionTargetObserver = NullInsertionTargetObserver()
    ) {
        self.insertionSession = insertionSession
        self.target = target
        target.captureBaseline()
    }

    @discardableResult
    public func insertFinal(_ text: String) -> Bool {
        guard !didClose,
              insertedTranscript == nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard targetIsUnchanged() else {
            log.info("final insertion refused: fn-press target changed")
            cancel()
            return false
        }

        guard insertionSession.insert(text) else {
            log.error("final insertion refused: keystroke backend unavailable")
            cancel()
            return false
        }
        insertedTranscript = text
        log.info("final insertion wrote chars=\(text.utf16.count)")
        return true
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
}

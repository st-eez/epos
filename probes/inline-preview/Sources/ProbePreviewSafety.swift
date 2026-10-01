import Foundation

/// Marked text replaces the selection. Clearing it cannot restore that text,
/// so an unreadable or nonempty selection cannot start a preview composition.
enum ProbePreviewSafety {
    enum CompositionState {
        case absent
        case owned
        case foreign
        case unreadable
    }

    /// Client identity alone cannot prove ownership after the host ends a mark.
    /// Require the live document range and text to match the last Epos write.
    static func compositionState(
        markedRange: NSRange,
        expected: (range: NSRange, text: String)?,
        readText: (NSRange) -> String?
    ) -> CompositionState {
        guard markedRange.location >= 0, markedRange.length >= 0,
              markedRange.length != NSNotFound else { return .unreadable }
        if markedRange.length == 0 { return .absent }
        guard markedRange.location != NSNotFound else { return .unreadable }
        guard let expected else { return .foreign }
        guard let text = readText(markedRange),
              (text as NSString).length == markedRange.length else { return .unreadable }
        guard expected.range == markedRange,
              (expected.text as NSString).isEqual(to: text) else { return .foreign }
        return .owned
    }

    static func canWrite(
        selectedRange: NSRange,
        compositionState: CompositionState,
        continuingComposition: Bool
    ) -> Bool {
        selectedRange.location >= 0 && selectedRange.location != NSNotFound && selectedRange.length == 0
            && compositionState == (continuingComposition ? .owned : .absent)
    }

    /// A host callback may clear our record before cancellation arrives. The
    /// acknowledgement permits final insertion, so it still checks live state.
    static func cancellationReplyWithoutComposition(
        selectedRange: NSRange,
        compositionState: CompositionState
    ) -> String {
        guard canWrite(
            selectedRange: selectedRange,
            compositionState: compositionState,
            continuingComposition: false
        ) else {
            return "err unsafe selection or composition before cancellation"
        }
        return "ok cancelled nothing marked"
    }
}

/// Serializes connection replacement against commands already queued on main.
/// Holding the lock through a command makes checking and executing indivisible
/// with respect to a new connection superseding its predecessor.
final class ProbeConnectionOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64?

    func adopt(_ identifier: UInt64) {
        lock.withLock { current = identifier }
    }

    func retire(_ identifier: UInt64) {
        lock.withLock {
            if current == identifier { current = nil }
        }
    }

    func perform(_ identifier: UInt64, _ command: () -> String) -> String {
        lock.withLock {
            guard current == identifier else { return "err superseded connection" }
            return command()
        }
    }
}

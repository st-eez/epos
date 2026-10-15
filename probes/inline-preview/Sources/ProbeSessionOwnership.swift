import Foundation

/// Owns one uninterrupted native input session. The caller supplies acquisition
/// and the synchronous event barrier; client identity alone is insufficient.
final class ProbeSessionOwnership {
    enum State: Equatable {
        case ready
        case draft(NSRange)
        case retired(String)
        case finished
    }

    struct Observation {
        let selection: NSRange
        let marked: NSRange
        let composition: ProbePreviewSafety.CompositionState
    }

    private(set) var state: State = .ready
    private var expectedSelection: NSRange
    private let baselineSelection: NSRange
    private let unavailable = NSRange(location: NSNotFound, length: NSNotFound)
    private let permitsUnavailableBaseline: Bool

    convenience init?(controlledEmptyFixture: Bool, observation: Observation) {
        guard controlledEmptyFixture else { return nil }
        self.init(layoutSession: true, observation: observation)
    }

    init?(layoutSession: Bool, observation: Observation) {
        // A selected Epos client or acquisition from a layout can own an
        // unavailable baseline. Switching from another method cannot.
        permitsUnavailableBaseline = layoutSession
        guard Self.emptySelection(observation.selection),
              observation.composition == .absent || (layoutSession
                && observation.composition == .unreadable && observation.marked == unavailable) else { return nil }
        expectedSelection = observation.selection
        baselineSelection = observation.selection
    }

    var permitsFinal: Bool { state == .ready }

    func canOperate(_ observation: Observation) -> Bool {
        guard observation.selection == expectedSelection, Self.emptySelection(observation.selection) else { return false }
        switch state {
        case .ready:
            return observation.composition == .absent || (permitsUnavailableBaseline
                && observation.composition == .unreadable && observation.marked == unavailable)
        case .draft(let range):
            return observation.marked == range
                && (observation.composition == .owned || observation.composition == .unreadable)
        case .retired, .finished:
            return false
        }
    }

    /// Called only after the native mark and immediate readback. A malformed or
    /// changed range retires the pass instead of recording guessed ownership.
    @discardableResult
    func didMark(_ observation: Observation, utf16Length: Int) -> Bool {
        guard state == .ready || isDraft, utf16Length > 0,
              Self.emptySelection(observation.selection),
              observation.marked.location != NSNotFound, observation.marked.location >= 0,
              observation.marked.length == utf16Length,
              observation.composition == .owned || observation.composition == .unreadable else {
            retire("mark-readback")
            return false
        }
        if case .draft(let previous) = state, observation.marked.location != previous.location {
            retire("mark-moved")
            return false
        }
        expectedSelection = observation.selection
        state = .draft(observation.marked)
        return true
    }

    /// A controlled host may again hide its absent mark. This acknowledges the
    /// ordered discard call, not independently proven terminal cancellation.
    @discardableResult
    func didDiscard(_ observation: Observation) -> Bool {
        guard isDraft, observation.selection == baselineSelection,
              observation.composition == .absent || (permitsUnavailableBaseline
                && observation.composition == .unreadable && observation.marked == unavailable) else {
            retire("discard-readback")
            return false
        }
        expectedSelection = baselineSelection
        state = .ready
        return true
    }

    /// Retire before cleanup or forwarding an event. Even failed cleanup cannot
    /// leave the pass eligible to mark again or insert its final transcript.
    func interrupt(_ reason: String, cleanup: () -> Void) {
        guard state != .finished, !isRetired else { return }
        state = .retired(reason)
        cleanup()
    }

    func retire(_ reason: String) { interrupt(reason, cleanup: {}) }

    func finish() -> Bool {
        guard permitsFinal else { return false }
        state = .finished
        return true
    }

    /// The caller rechecks the owned selection, range and session before
    /// consuming the composition in place, including hosts with unreadable text.
    func finishNativeCommit() -> Bool {
        guard state == .ready || isDraft else { return false }
        state = .finished
        return true
    }

    var isDraft: Bool {
        if case .draft = state { return true }
        return false
    }

    var isRetired: Bool {
        if case .retired = state { return true }
        return false
    }

    static func emptySelection(_ range: NSRange) -> Bool {
        range.location >= 0 && range.location != NSNotFound && range.length == 0
    }

    static func ignoresFlagsChange(_ changed: UInt64, fnMask: UInt64) -> Bool {
        changed & ~fnMask == 0
    }

    static func ignoresControllerEvent(isFlagsChange: Bool, keyCode: UInt16?) -> Bool {
        isFlagsChange && keyCode == 63 // The native fn key, on both press and release.
    }
}

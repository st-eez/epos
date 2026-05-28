import ApplicationServices
import Foundation

/// What the session is allowed to do this reconcile, given what we observed about
/// the on-screen target. Computed by `InsertionTargetGuard.decide` — a pure
/// function — so the policy is unit-testable without any Accessibility I/O.
public enum InsertionGuardDecision: Equatable {
    /// Target is consistent (or we deliberately did not check this cycle).
    /// Proceed with the normal backspace-and-retype reconcile.
    case proceed
    /// On-screen text diverged from what we believe we typed. Stop deleting for
    /// the rest of the session and only append new text from here on — an
    /// append can never corrupt existing content.
    case stopAppendOnly
    /// Focus left the home field. No insertion can land safely (even an append
    /// would type into the wrong place), so cancel all further insertion.
    case abort
}

/// What the observer saw when asked to check the target before a reconcile.
public enum InsertionTargetObservation: Equatable {
    /// The focused element no longer matches the session's home element.
    case focusChanged
    /// Focus is unchanged and the full on-screen value was read.
    case value(String)
    /// Focus is unchanged and we deliberately skipped the expensive value read
    /// (e.g. this reconcile only appends, so no delete can corrupt anything).
    case notRead
}

public enum InsertionTargetGuard {
    /// Pure decision: given what we believe we typed (`expected`) and what we
    /// observed about the target, decide what the session may do.
    ///
    /// Divergence is `!observed.hasSuffix(expected)` — `hasSuffix`, not `==`, so
    /// content that existed in the field *before* our caret is tolerated. This is
    /// deliberately conservative: text the field inserted *after* our caret
    /// (trailing autocomplete, a bracket pair closed behind the caret) makes the
    /// suffix check fail and we fall back to append-only, which is safe. We do not
    /// track the caret to "fix" that false-positive — a false append-only is
    /// harmless, a false proceed corrupts the user's text.
    public static func decide(
        expected: String,
        observed: InsertionTargetObservation
    ) -> InsertionGuardDecision {
        switch observed {
        case .focusChanged:
            return .abort
        case .notRead:
            return .proceed
        case .value(let onScreen):
            // An empty expectation has nothing to delete and nothing to match
            // against; appending is always safe.
            guard !expected.isEmpty else { return .proceed }
            return onScreen.hasSuffix(expected) ? .proceed : .stopAppendOnly
        }
    }
}

/// Observes the focused Accessibility target so the insertion session can tell
/// whether its backspace-and-retype is still landing in the field it started in.
///
/// Two checks with very different costs:
/// - `focusChangedSinceStart()` copies the system-wide focused element and
///   compares it to the home element with `CFEqual`. Cheap — safe per reconcile.
/// - `observedValue()` reads `kAXValueAttribute` (the whole field's text). The
///   expensive call; the session gates it to the pre-delete moment only.
public protocol InsertionTargetObserver: AnyObject {
    /// Record the currently focused element as "home". Call at session start.
    func captureBaseline()
    /// True if the focused element changed since `captureBaseline()`. Cheap.
    func focusChangedSinceStart() -> Bool
    /// The focused element's full text value, or nil if it can't be read.
    /// Expensive — do not call on every partial.
    func observedValue() -> String?
}

/// A no-op observer: focus never changes, value never readable. The session then
/// always `.proceed`s, preserving the pre-guard behavior. Used by tests and the
/// one-shot final-insertion path, where guarding adds nothing.
public final class NullInsertionTargetObserver: InsertionTargetObserver {
    public init() {}
    public func captureBaseline() {}
    public func focusChangedSinceStart() -> Bool { false }
    public func observedValue() -> String? { nil }
}

/// Live Accessibility-backed observer. Uses the same trust the keystroke backend
/// already requires; reads only the focused element, never walks the tree.
public final class AXInsertionTargetObserver: InsertionTargetObserver {
    private let systemWide: AXUIElement
    private var homeElement: AXUIElement?
    private let log = EposLogger(category: "inject")

    public init() {
        systemWide = AXUIElementCreateSystemWide()
        // Bound every AX message so a wedged accessibility server in the target
        // app can't stall the main-actor reconcile. Generous relative to a normal
        // focused-element copy (sub-millisecond) but a hard ceiling on hangs.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    public func captureBaseline() {
        homeElement = copyFocusedElement()
        if homeElement == nil {
            log.info("insertion guard: no focused element at session start; focus guard inactive")
        }
    }

    public func focusChangedSinceStart() -> Bool {
        // No baseline (couldn't read focus at start) → we can't prove focus
        // moved, so don't fire the focus guard. The value guard still protects
        // deletes.
        guard let homeElement else { return false }
        guard let current = copyFocusedElement() else {
            // Focus became unreadable (field/window went away). Treat as changed:
            // continuing to type blind risks the wrong target.
            return true
        }
        return !CFEqual(homeElement, current)
    }

    public func observedValue() -> String? {
        guard let homeElement else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            homeElement, kAXValueAttribute as CFString, &value
        )
        guard result == .success, let text = value as? String else { return nil }
        return text
    }

    private func copyFocusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard result == .success, let element = focused else { return nil }
        // CFTypeRef of an AXUIElement; force-cast is safe — the attribute is
        // documented to return an AXUIElementRef.
        // swiftlint:disable:next force_cast
        return (element as! AXUIElement)
    }
}

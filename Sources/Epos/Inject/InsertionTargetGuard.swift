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

public struct InsertionTargetTextRange: Equatable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct InsertionTargetContext: Equatable {
    public let prefix: String
    public let suffix: String

    public init(prefix: String, suffix: String) {
        self.prefix = prefix
        self.suffix = suffix
    }

    func matches(value: String, expected: String, selectedRange: InsertionTargetTextRange?) -> Bool {
        guard value == prefix + expected + suffix else { return false }
        return caretMatches(expected: expected, selectedRange: selectedRange)
    }

    func caretMatches(expected: String, selectedRange: InsertionTargetTextRange?) -> Bool {
        let expectedCaret = (prefix + expected).utf16.count
        return selectedRange == InsertionTargetTextRange(location: expectedCaret, length: 0)
    }

    func insertedText(in value: String) -> String? {
        guard value.hasPrefix(prefix),
              value.hasSuffix(suffix),
              value.count >= prefix.count + suffix.count else {
            return nil
        }

        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(value[start..<end])
    }
}

/// What the observer saw when asked to check the target before a reconcile.
public enum InsertionTargetObservation: Equatable {
    /// The focused element no longer matches the session's home element.
    case focusChanged
    /// Focus is unchanged and the full on-screen value was read.
    case value(String)
    /// Focus is unchanged, the full on-screen value was read, and the observer
    /// captured the original insertion span. This is the safe mid-field path:
    /// `prefix + expected + suffix` may be consistent even when the full field no
    /// longer ends with `expected`.
    case positionedValue(String, context: InsertionTargetContext, selectedRange: InsertionTargetTextRange?)
    /// Focus is unchanged, the read came back empty, AND this element exposes its
    /// text via Accessibility (we have read a non-empty value from it earlier this
    /// session). An empty read from a text-exposing field is genuine divergence —
    /// our text vanished — so a delete here would corrupt content that isn't ours.
    case emptyExposed
    /// Focus is unchanged and the read is uninformative: it failed, or the app
    /// exposes no editable text at all (web/Electron terminals such as cmux return
    /// empty regardless of content). Neither confirms nor denies our text, so a
    /// delete is allowed (the cheap focus check is the only guard this cycle).
    case notRead
}

extension InsertionTargetObservation {
    /// Build the observation from a raw Accessibility value read and whether this
    /// element exposes text. A non-empty read is always a usable `.value`. An empty
    /// or failed read is `.emptyExposed` when the element has shown real text this
    /// session (a native field that just lost our text → divergence) and `.notRead`
    /// when it never has (cmux/Electron expose nothing → uninformative, keep
    /// self-correcting). Keeping this at the boundary means a `.value("")` never
    /// reaches `decide` from the live path.
    public static func read(
        _ value: String?,
        exposesText: Bool,
        context: InsertionTargetContext? = nil,
        selectedRange: InsertionTargetTextRange? = nil
    ) -> InsertionTargetObservation {
        if let value, !value.isEmpty {
            if let context {
                return .positionedValue(value, context: context, selectedRange: selectedRange)
            }
            return .value(value)
        }
        return exposesText ? .emptyExposed : .notRead
    }
}

public enum InsertionTargetGuard {
    /// Pure decision: given what we believe we typed (`expected`) and what we
    /// observed about the target, decide what the session may do.
    ///
    /// Without insertion context, divergence is `!observed.hasSuffix(expected)` —
    /// `hasSuffix`, not `==`, so content that existed in the field *before* our
    /// caret is tolerated. When the observer captured the original field value and
    /// selection, mid-field insertion is also safe if the current value still equals
    /// `prefix + expected + suffix` and the caret is exactly after `expected`.
    public static func decide(
        expected: String,
        observed: InsertionTargetObservation
    ) -> InsertionGuardDecision {
        evaluate(expected: expected, observed: observed).decision
    }
}

/// Observes the focused Accessibility target so the insertion session can tell
/// whether its backspace-and-retype is still landing in the field it started in.
///
/// Two checks with very different costs:
/// - `focusChangedSinceStart()` copies the system-wide focused element and
///   compares its owning process to the home element's. Cheap — safe per reconcile.
/// - `observedValue()` reads `kAXValueAttribute` off the LIVE focused element (the
///   whole field's text). The expensive call; the session gates it to the
///   pre-delete moment only. Reading current focus — not a start-of-session
///   snapshot — is what lets a same-app field move surface as value divergence.
public protocol InsertionTargetObserver: AnyObject {
    /// Record the currently focused element as "home". Call at session start.
    func captureBaseline()
    /// True if the focused element changed since `captureBaseline()`. Cheap.
    func focusChangedSinceStart() -> Bool
    /// The focused element's full text value, or nil if it can't be read.
    /// Expensive — do not call on every partial.
    func observedValue() -> String?
    /// The current selected text range/caret, when the focused element exposes it.
    func observedSelectedRange() -> InsertionTargetTextRange?
    /// True once this element has exposed real (non-empty) text this session, so an
    /// empty read can be told apart from an app that never exposes text. Cheap.
    func exposesTextValue() -> Bool
    /// The original text split around the insertion selection at session start.
    func baselineInsertionContext() -> InsertionTargetContext?
}

/// A no-op observer: focus never changes, value never readable. The session then
/// always `.proceed`s, preserving the pre-guard behavior. Used by tests and the
/// one-shot final-insertion path, where guarding adds nothing.
public final class NullInsertionTargetObserver: InsertionTargetObserver {
    public init() {}
    public func captureBaseline() {}
    public func focusChangedSinceStart() -> Bool { false }
    public func observedValue() -> String? { nil }
    public func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    public func exposesTextValue() -> Bool { false }
    public func baselineInsertionContext() -> InsertionTargetContext? { nil }
}

/// Live Accessibility-backed observer. Uses the same trust the keystroke backend
/// already requires; reads only the focused element, never walks the tree.
public final class AXInsertionTargetObserver: InsertionTargetObserver {
    private let systemWide: AXUIElement
    /// The process that owned the focused element at session start. Focus moving to a
    /// different app changes this; an element-handle churn within the same app (a
    /// Chromium/Electron terminal like cmux rebuilds its AX node between keystrokes) does
    /// not — so the focus guard compares this, not the element's identity.
    private var homePid: pid_t?
    /// True when the home element advertises `kAXValueAttribute` at session start.
    /// Set once at `captureBaseline`, before any delete, so the FIRST delete cycle
    /// already knows a text-exposing field is text-exposing — without it, the
    /// first empty read would proceed and blind-delete. A field that advertises
    /// text but reads empty has diverged; treating it as such is safe even if it
    /// costs an AX-opaque app (that happens to advertise) its self-correction.
    private var homeElementAdvertisesValue = false
    private var insertionContext: InsertionTargetContext?
    /// Latched once any read returns real text, covering elements that expose text
    /// only once populated. Together with the advertise probe this means an empty
    /// read counts as divergence whenever the element ever exposes text; an app
    /// that never does (cmux/Electron) keeps self-correcting.
    private var everReadNonEmptyValue = false
    private let log = EposLogger(category: "inject")

    public init() {
        systemWide = AXUIElementCreateSystemWide()
        // Bound every AX message so a wedged accessibility server in the target
        // app can't stall the main-actor reconcile. Generous relative to a normal
        // focused-element copy (sub-millisecond) but a hard ceiling on hangs.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    public func captureBaseline() {
        guard let baseline = copyFocusedElement() else {
            log.info("insertion guard: no focused element at session start; focus guard inactive")
            return
        }
        homePid = pid(of: baseline)
        homeElementAdvertisesValue = advertisesValueAttribute(baseline)
        if let value = textValue(of: baseline), let selectedRange = selectedTextRange(of: baseline) {
            insertionContext = Self.context(in: value, selectedRange: selectedRange)
        }
    }

    public func focusChangedSinceStart() -> Bool {
        // No baseline pid (couldn't read focus/owner at start) → we can't prove focus
        // moved, so don't fire the focus guard. The live value read still bounds deletes:
        // it reads whatever element holds focus now, so divergence there latches append-only.
        guard let homePid else { return false }
        guard let current = copyFocusedElement() else {
            // Focus became unreadable (field/window went away). Treat as changed:
            // continuing to type blind risks the wrong target.
            log.info("insertion guard: focused element unreadable mid-session; treating as focus change")
            return true
        }
        // Compare by owning process, not element identity. A Chromium/Electron terminal
        // such as cmux hands back a fresh AXUIElement for the same field between
        // keystrokes, so `CFEqual` on the element reported a change and aborted
        // mid-dictation even though focus never left the app. The pid is stable across
        // that churn and still changes when focus moves to another app — the case the
        // guard actually protects against. A move to another window/field of the SAME app
        // is NOT caught here (we can't tell it apart from cmux's churn without the
        // element-identity check that broke cmux). Instead `observedValue` reads the live
        // focused element, so the new field's content won't end with our committed text →
        // the value guard latches append-only. That tail may then append into the other
        // field, but it can never delete content that isn't ours — the existing
        // append-only contract, which we accept here rather than risk a false abort.
        guard let currentPid = pid(of: current) else { return true }
        guard currentPid != homePid else { return false }
        log.info("insertion guard: focus left the app mid-session (pid \(homePid) -> \(currentPid))")
        return true
    }

    public func observedValue() -> String? {
        // Read the element that holds focus RIGHT NOW, not a start-of-session snapshot.
        // Deciding from current truth is what makes a same-app field move detectable: it
        // reads the new field, whose text won't end with our committed text → divergence
        // → append-only. cmux/Electron churn reads the same (fresh) node → empty → not
        // text-exposing → uninformative, so self-correction proceeds exactly as before.
        // A cross-app move is already aborted by `focusChangedSinceStart`'s pid check,
        // before any reconcile reaches this read.
        guard let focused = copyFocusedElement() else { return nil }
        guard let text = textValue(of: focused) else { return nil }
        if !text.isEmpty { everReadNonEmptyValue = true }
        return text
    }

    public func observedSelectedRange() -> InsertionTargetTextRange? {
        guard let focused = copyFocusedElement() else { return nil }
        return selectedTextRange(of: focused)
    }

    public func exposesTextValue() -> Bool { homeElementAdvertisesValue || everReadNonEmptyValue }

    public func baselineInsertionContext() -> InsertionTargetContext? { insertionContext }

    private func advertisesValueAttribute(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let attributes = names as? [String] else { return false }
        return attributes.contains(kAXValueAttribute as String)
    }

    private func textValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        )
        guard result == .success, let text = value as? String else { return nil }
        return text
    }

    private func selectedTextRange(of element: AXUIElement) -> InsertionTargetTextRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &value
        )
        guard result == .success, let axValue = value else { return nil }
        var range = CFRange()
        // CFTypeRef of an AXValue; force-cast is safe after the selected-range
        // attribute succeeds and `AXValueGetValue` validates the wrapped type.
        // swiftlint:disable:next force_cast
        guard AXValueGetValue((axValue as! AXValue), .cfRange, &range) else { return nil }
        return InsertionTargetTextRange(location: range.location, length: range.length)
    }

    private static func context(
        in value: String,
        selectedRange: InsertionTargetTextRange
    ) -> InsertionTargetContext? {
        guard selectedRange.location >= 0, selectedRange.length >= 0 else { return nil }
        let utf16 = value.utf16
        guard
            let startUTF16 = utf16.index(
                utf16.startIndex,
                offsetBy: selectedRange.location,
                limitedBy: utf16.endIndex
            ),
            let endUTF16 = utf16.index(
                startUTF16,
                offsetBy: selectedRange.length,
                limitedBy: utf16.endIndex
            ),
            let start = String.Index(startUTF16, within: value),
            let end = String.Index(endUTF16, within: value)
        else {
            return nil
        }
        return InsertionTargetContext(
            prefix: String(value[..<start]),
            suffix: String(value[end...])
        )
    }

    /// Owning process of an element. `AXUIElementGetPid` is a local lookup (no IPC to the
    /// target app), so this stays cheap enough to run on every reconcile.
    private func pid(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        return AXUIElementGetPid(element, &processID) == .success ? processID : nil
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

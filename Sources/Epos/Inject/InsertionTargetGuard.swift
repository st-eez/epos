import ApplicationServices
import AppKit
import Foundation

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
    public let selectedText: String
    public let suffix: String
    public let selectedRange: InsertionTargetTextRange

    public init(
        prefix: String,
        selectedText: String = "",
        suffix: String,
        selectedRange: InsertionTargetTextRange? = nil
    ) {
        self.prefix = prefix
        self.selectedText = selectedText
        self.suffix = suffix
        self.selectedRange = selectedRange ?? InsertionTargetTextRange(
            location: prefix.utf16.count,
            length: selectedText.utf16.count
        )
    }

    func matchesBaseline(value: String, selectedRange: InsertionTargetTextRange) -> Bool {
        value == prefix + selectedText + suffix && selectedRange == self.selectedRange
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

/// Observes the focused Accessibility target so the insertion session can tell
/// whether its one final write is still landing in the field it started in.
///
/// Two checks with very different costs:
/// - `focusChangedSinceStart()` copies the system-wide focused element and
///   compares its owning process to the home element's. Cheap for text-exposing
///   targets; AX-opaque targets add up to five attribute reads, each bounded by
///   a short messaging timeout.
/// - `observedValue()` reads `kAXValueAttribute` once before final insertion.
public protocol InsertionTargetObserver: AnyObject {
    /// Record the currently focused element as "home". Call at session start.
    func captureBaseline()
    /// True only when a focused target was captured at session start.
    func hasCapturedTarget() -> Bool
    /// True if the focused element changed since `captureBaseline()`. Cheap for
    /// text-exposing targets; timeout-bounded signature reads for opaque ones.
    func focusChangedSinceStart() -> Bool
    /// The focused element's full text value, or nil if it can't be read.
    /// Read once immediately before final insertion.
    func observedValue() -> String?
    /// The current selected text range/caret, when the focused element exposes it.
    func observedSelectedRange() -> InsertionTargetTextRange?
    /// True when the captured element advertises editable text and therefore
    /// requires a readable baseline value and selection before insertion.
    func requiresTextContextValidation() -> Bool
    /// The original text split around the insertion selection at session start.
    func baselineInsertionContext() -> InsertionTargetContext?
    /// The bundle identifier for the app that owned the insertion target at baseline.
    func targetApplicationBundleIdentifier() -> String?
    /// The title of the window that owned the insertion target at baseline, if exposed.
    func targetWindowTitle() -> String?
}

/// A no-op observer used by isolated insertion tests.
public final class NullInsertionTargetObserver: InsertionTargetObserver {
    public init() {}
    public func captureBaseline() {}
    public func hasCapturedTarget() -> Bool { true }
    public func focusChangedSinceStart() -> Bool { false }
    public func observedValue() -> String? { nil }
    public func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    public func requiresTextContextValidation() -> Bool { false }
    public func baselineInsertionContext() -> InsertionTargetContext? { nil }
    public func targetApplicationBundleIdentifier() -> String? { nil }
    public func targetWindowTitle() -> String? { nil }
}

/// Live Accessibility-backed observer. Uses the same trust the keystroke backend
/// already requires; reads only the focused element, never walks the tree.
public final class AXInsertionTargetObserver: InsertionTargetObserver {
    private static let focusedElementMessagingTimeout: Float = 0.05

    private let systemWide: AXUIElement
    /// The process that owned the focused element at session start. Focus moving to a
    /// different app changes this; an element-handle churn within the same app (a
    /// Chromium/Electron terminal like cmux rebuilds its AX node between keystrokes) does
    /// not — so the focus guard compares this, not the element's identity.
    private var homeElement: AXUIElement?
    private var homePid: pid_t?
    private var homeApplicationBundleIdentifier: String?
    private var homeWindowTitle: String?
    private var homeOpaqueFocusSignature: InsertionTargetFocusSignature?
    /// A native field is treated as readable only when both its value and selection
    /// were captured. AX controls can advertise value attributes while returning no
    /// usable text; those must use the opaque-target path.
    private var homeHasReadableTextContext = false
    private var insertionContext: InsertionTargetContext?
    private let log = EposLogger(category: "inject")

    public init() {
        systemWide = AXUIElementCreateSystemWide()
        // Bound every AX message so a wedged accessibility server in the target
        // app can't stall final insertion. Generous relative to a normal
        // focused-element copy (sub-millisecond) but a hard ceiling on hangs.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
    }

    public func captureBaseline() {
        guard let baseline = copyFocusedElement() else {
            log.info("insertion guard: no focused element at session start; focus guard inactive")
            return
        }
        homeElement = baseline
        homePid = pid(of: baseline)
        if let homePid {
            homeApplicationBundleIdentifier = NSRunningApplication(
                processIdentifier: homePid
            )?.bundleIdentifier
        }
        homeWindowTitle = windowTitle(of: baseline)
        if let value = textValue(of: baseline), let selectedRange = selectedTextRange(of: baseline) {
            insertionContext = Self.context(in: value, selectedRange: selectedRange)
        }
        homeHasReadableTextContext = insertionContext != nil
        homeOpaqueFocusSignature = homeHasReadableTextContext ? nil : focusSignature(of: baseline)
    }

    public func focusChangedSinceStart() -> Bool {
        // No baseline pid means focus identity was unavailable at fn press.
        guard let homePid else { return false }
        let current: AXUIElement
        switch copyFocusedElementDetailed() {
        case .element(let element):
            current = element
        case .failure(let error):
            // Final-only delivery has not typed anything yet. An unreadable target is
            // therefore safe to refuse and unsafe to guess about.
            log.info(
                "insertion guard: focused element unreadable before final insertion " +
                    "(AXError \(error.rawValue)); refusing insertion"
            )
            return true
        }
        // Compare by owning process first, not element identity. A Chromium/Electron terminal
        // such as cmux can hand back a fresh AXUIElement for the same field. The pid is stable across
        // that churn and still changes when focus moves to another app — the case the
        // guard protects in every app. For text-exposing native controls, also compare
        // element identity so same-app field moves are caught before insertion.
        guard let currentPid = pid(of: current) else { return true }
        guard currentPid == homePid else {
            log.info("insertion guard: focus left the app mid-session (pid \(homePid) -> \(currentPid))")
            return true
        }
        if homeHasReadableTextContext,
           let homeElement,
           !CFEqual(current, homeElement) {
            log.info("insertion guard: focused text element changed within app pid \(homePid)")
            return true
        }
        if !homeHasReadableTextContext {
            if let homeWindowTitle,
               let currentWindowTitle = windowTitle(of: current),
               currentWindowTitle != homeWindowTitle {
                log.info("insertion guard: opaque target window changed within app pid \(homePid)")
                return true
            }
            if let homeElement, CFEqual(current, homeElement) {
                return false
            }
            guard InsertionTargetFocusSignature.provesSameTarget(
                from: homeOpaqueFocusSignature,
                to: focusSignature(of: current)
            ) else {
                log.info("insertion guard: opaque target identity is ambiguous within app pid \(homePid)")
                return true
            }
        }
        return false
    }

    public func hasCapturedTarget() -> Bool { homePid != nil }

    public func observedValue() -> String? {
        // Read the element that holds focus now, immediately before final insertion.
        guard let focused = copyFocusedElement() else { return nil }
        return textValue(of: focused)
    }

    public func observedSelectedRange() -> InsertionTargetTextRange? {
        guard let focused = copyFocusedElement() else { return nil }
        return selectedTextRange(of: focused)
    }

    public func requiresTextContextValidation() -> Bool { homeHasReadableTextContext }

    public func baselineInsertionContext() -> InsertionTargetContext? { insertionContext }

    public func targetApplicationBundleIdentifier() -> String? { homeApplicationBundleIdentifier }

    public func targetWindowTitle() -> String? { homeWindowTitle }

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

    private func windowTitle(of element: AXUIElement) -> String? {
        guard let window = window(of: element) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &value
        )
        guard result == .success, let title = value as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func window(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element, kAXWindowAttribute as CFString, &value
        )
        guard result == .success, let window = value else { return nil }
        // CFTypeRef of an AXUIElement; force-cast is safe after the window
        // attribute succeeds.
        // swiftlint:disable:next force_cast
        return (window as! AXUIElement)
    }

    private func focusSignature(of element: AXUIElement) -> InsertionTargetFocusSignature? {
        AXUIElementSetMessagingTimeout(element, Self.focusedElementMessagingTimeout)
        let signature = InsertionTargetFocusSignature(
            role: stringAttribute(of: element, kAXRoleAttribute as String),
            subrole: stringAttribute(of: element, kAXSubroleAttribute as String),
            identifier: stringAttribute(of: element, kAXIdentifierAttribute as String)
        )
        return signature.isInformative ? signature : nil
    }

    private func stringAttribute(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            selectedText: String(value[start..<end]),
            suffix: String(value[end...]),
            selectedRange: selectedRange
        )
    }

    /// Owning process of an element. `AXUIElementGetPid` is a local lookup (no IPC to the
    /// target app), so this is cheap enough for the final guard.
    private func pid(of element: AXUIElement) -> pid_t? {
        var processID: pid_t = 0
        return AXUIElementGetPid(element, &processID) == .success ? processID : nil
    }

    /// Outcome of a focused-element fetch when the caller needs to distinguish WHY
    /// it failed. Only `focusChangedSinceStart` consumes the error; every other
    /// read site treats any failure as nil via `copyFocusedElement`.
    enum FocusedElementRead {
        case element(AXUIElement)
        case failure(AXError)
    }

    private func copyFocusedElement() -> AXUIElement? {
        guard case .element(let element) = copyFocusedElementDetailed() else { return nil }
        return element
    }

    private func copyFocusedElementDetailed() -> FocusedElementRead {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        )
        guard result == .success, let element = focused else {
            // A `.success` with no value means "nothing is focused" — same identity
            // failure as an explicit `.noValue`.
            return .failure(result == .success ? .noValue : result)
        }
        // CFTypeRef of an AXUIElement; force-cast is safe — the attribute is
        // documented to return an AXUIElementRef.
        // swiftlint:disable:next force_cast
        return .element(element as! AXUIElement)
    }
}

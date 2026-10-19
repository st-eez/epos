import AppKit
import ApplicationServices

/// A host can expose its focused field even when the system-wide lookup fails.
/// Chromium can also expose only AXFocused on the editor. That last path searches
/// the focused window with bounded IPC and work, requiring exactly one editor.
final class FocusedElementSearch {
    typealias AttributeRead = (AXUIElement, String) -> (AXError, CFTypeRef?)

    private let frontmostApplication: () -> AXUIElement?
    private let readAttribute: AttributeRead
    private var cachedElement: AXUIElement?
    private var cachedWindow: AXUIElement?
    private(set) var lastError = AXError.noValue
    private(set) var failureDetail = "none"

    init(
        frontmostApplication: @escaping () -> AXUIElement? = {
            NSWorkspace.shared.frontmostApplication.map { AXUIElementCreateApplication($0.processIdentifier) }
        },
        readAttribute: @escaping AttributeRead = { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (error, value)
        }
    ) {
        self.frontmostApplication = frontmostApplication
        self.readAttribute = readAttribute
    }

    func resolve(in systemWide: AXUIElement) -> AXUIElement? {
        failureDetail = "none"
        let (globalError, globalValue) = readAttribute(systemWide, kAXFocusedUIElementAttribute)
        if globalError == .success, let element = Self.element(globalValue) { return element }
        lastError = globalError == .success ? .noValue : globalError
        failureDetail = "systemAXError=\(lastError.rawValue)"
        guard [.success, .noValue, .cannotComplete, .attributeUnsupported, .notImplemented].contains(globalError),
              let application = frontmostApplication() else { return nil }
        AXUIElementSetMessagingTimeout(application, 0.02)
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute) else {
            failureDetail += " stage=focused-window-unavailable"
            return nil
        }
        let (applicationError, applicationValue) = readAttribute(application, kAXFocusedUIElementAttribute)
        failureDetail += " applicationAXError=\(applicationError.rawValue)"
        guard [.success, .noValue, .cannotComplete, .attributeUnsupported, .notImplemented].contains(applicationError) else {
            return nil
        }
        if applicationError == .success, let focused = Self.element(applicationValue) {
            guard let ownerWindow = elementAttribute(focused, kAXWindowAttribute), CFEqual(window, ownerWindow),
                  scopeIsUnchanged(application: application, window: window),
                  let current = elementAttribute(application, kAXFocusedUIElementAttribute), CFEqual(focused, current) else {
                failureDetail += " stage=application-focus-changed"
                return nil
            }
            return focused
        }
        if let cachedElement, let cachedWindow, CFEqual(window, cachedWindow),
           isFocusedEditor(cachedElement) == true,
           scopeIsUnchanged(application: application, window: window) {
            return cachedElement
        }
        cachedElement = nil
        cachedWindow = nil
        let deadline = ContinuousClock.now + .milliseconds(200)
        let found = Self.find(
            root: window,
            isFocused: isFocusedEditor,
            children: { element in
                AXUIElementSetMessagingTimeout(element, 0.02)
                let (result, value) = self.readAttribute(element, kAXChildrenAttribute)
                if result == .attributeUnsupported || result == .noValue { return [] }
                guard result == .success else { return nil }
                return value as? [AXUIElement]
            },
            withinBudget: { ContinuousClock.now < deadline }
        )
        guard let found else {
            failureDetail += " stage=focused-editor-search-refused"
            return nil
        }
        guard scopeIsUnchanged(application: application, window: window), isFocusedEditor(found) == true else {
            failureDetail += " stage=searched-focus-changed"
            return nil
        }
        cachedElement = found
        cachedWindow = window
        return found
    }

    private func scopeIsUnchanged(application: AXUIElement, window: AXUIElement) -> Bool {
        guard let currentApplication = frontmostApplication(), CFEqual(application, currentApplication),
              let currentWindow = elementAttribute(currentApplication, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(window, currentWindow)
    }

    /// A partial or ambiguous search cannot establish which editor is focused.
    static func find<Element>(
        root: Element, maximumNodes: Int = 2_048,
        isFocused: (Element) -> Bool?,
        children: (Element) -> [Element]?,
        withinBudget: () -> Bool = { true }
    ) -> Element? {
        var pending = [root]
        var visited = 0
        var found: Element?
        while let element = pending.popLast() {
            guard visited < maximumNodes, withinBudget() else { return nil }
            visited += 1
            guard let focused = isFocused(element), let descendants = children(element) else { return nil }
            if focused {
                guard found == nil else { return nil }
                found = element
            }
            pending.append(contentsOf: descendants.reversed())
        }
        return found
    }

    private func isFocusedEditor(_ element: AXUIElement) -> Bool? {
        AXUIElementSetMessagingTimeout(element, 0.02)
        let (result, focused) = readAttribute(element, kAXFocusedAttribute)
        if result == .attributeUnsupported || result == .noValue { return false }
        guard result == .success, let isFocused = focused as? Bool else { return nil }
        guard isFocused else { return false }
        let (roleResult, role) = readAttribute(element, kAXRoleAttribute)
        guard roleResult == .success,
              let role = role as? String else { return nil }
        return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role)
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        let (result, value) = readAttribute(element, attribute)
        guard result == .success, let element = Self.element(value) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.02)
        return element
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }
}

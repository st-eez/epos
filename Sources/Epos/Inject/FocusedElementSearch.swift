import AppKit
import ApplicationServices

/// Some Chromium hosts expose AXFocused on their editor but return no value for
/// AXFocusedUIElement. Search only the focused window, with both an IPC and work
/// budget. Never infer focus from a text field merely being present.
final class FocusedElementSearch {
    private var cachedElement: AXUIElement?
    private var cachedWindow: AXUIElement?

    func resolve(in systemWide: AXUIElement) -> AXUIElement? {
        guard let application = elementAttribute(systemWide, kAXFocusedApplicationAttribute),
              let window = elementAttribute(application, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(application, 0.02)
        if let cachedElement, let cachedWindow, CFEqual(window, cachedWindow), isFocusedEditor(cachedElement) == true {
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
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                if result == .attributeUnsupported || result == .noValue { return [] }
                guard result == .success else { return nil }
                return value as? [AXUIElement]
            },
            withinBudget: { ContinuousClock.now < deadline }
        )
        guard let found,
              let currentApplication = elementAttribute(systemWide, kAXFocusedApplicationAttribute),
              CFEqual(application, currentApplication),
              let currentWindow = elementAttribute(currentApplication, kAXFocusedWindowAttribute),
              CFEqual(window, currentWindow), isFocusedEditor(found) == true else { return nil }
        cachedElement = found
        cachedWindow = window
        return found
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
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focused)
        if result == .attributeUnsupported || result == .noValue { return false }
        guard result == .success, let isFocused = focused as? Bool else { return nil }
        guard isFocused else { return false }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return nil }
        return [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role)
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }
}

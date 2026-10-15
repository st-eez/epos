import AppKit
import ApplicationServices

struct RecordingCaretGeometry: Sendable {
    var caret: CGRect?
    var window: CGRect?
}

enum RecordingCaretReader {
    private static let queue = DispatchQueue(label: "Epos.recording-caret", qos: .utility)

    static func read(processIdentifier: pid_t) async -> RecordingCaretGeometry {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: readGeometry(processIdentifier: processIdentifier))
            }
        }
    }

    private static func readGeometry(processIdentifier: pid_t) -> RecordingCaretGeometry {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.03)
        let window = element(application, kAXFocusedWindowAttribute)
        let windowFrame = window.flatMap { window in
            guard let position = attribute(window, kAXPositionAttribute),
                  let size = attribute(window, kAXSizeAttribute) else { return nil as CGRect? }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard extract(position, type: .cgPoint, into: &point),
                  extract(size, type: .cgSize, into: &dimensions) else { return nil }
            return CGRect(origin: point, size: dimensions)
        }
        var result = RecordingCaretGeometry(caret: nil, window: windowFrame)
        guard let focused = element(application, kAXFocusedUIElementAttribute),
              let selected = attribute(focused, kAXSelectedTextRangeAttribute) else { return result }
        var range = CFRange()
        guard extract(selected, type: .cfRange, into: &range), range.location >= 0, range.length == 0,
              let parameter = AXValueCreate(.cfRange, &range) else { return result }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success, let value else { return result }
        var rect = CGRect.zero
        guard extract(value, type: .cgRect, into: &rect),
              RecordingIndicatorPlacementPolicy.isUsableCaret(rect),
              windowFrame.map({ $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }) ?? true else { return result }
        result.caret = rect
        return result
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // AX values are Core Foundation objects; the type ID validates this cast.
        // swiftlint:disable:next force_cast
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.03)
        return element
    }

    private static func extract<Value: BitwiseCopyable>(_ object: CFTypeRef, type: AXValueType, into value: inout Value) -> Bool {
        guard CFGetTypeID(object) == AXValueGetTypeID() else { return false }
        // swiftlint:disable:next force_cast
        let object = object as! AXValue
        guard AXValueGetType(object) == type else { return false }
        return AXValueGetValue(object, type, &value)
    }
}

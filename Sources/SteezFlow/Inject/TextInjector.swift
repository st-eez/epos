import AppKit
import Foundation

/// Pastes text into the frontmost app via clipboard + synthesized cmd-v,
/// restoring the previous clipboard contents afterwards.
public final class TextInjector {
    public init() {}

    public func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterWrite = pasteboard.changeCount

        synthesizeCommandV()

        // Restore the prior clipboard after the paste lands — but only if nothing
        // else wrote to the pasteboard in the meantime (changeCount unchanged).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Re-acquire the shared pasteboard inside the closure instead of
            // capturing the outer reference, which would be sent across the
            // concurrency boundary while still in use here (Swift 6 data-race).
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCountAfterWrite, !saved.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
    }

    /// Deep-copies every type of every current pasteboard item into detached
    /// `NSPasteboardItem`s that survive a `clearContents()`.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}

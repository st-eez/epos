import AppKit
import ApplicationServices
import Foundation

public protocol TextInsertionBackend {
    func startInsertionSession() -> any TextInsertionSession
}

public protocol TextInsertionSession: AnyObject {
    func insert(_ text: String)
    func finish()
    func cancel()
}

/// Pastes text into the frontmost app via clipboard + synthesized cmd-v,
/// restoring the previous clipboard contents afterwards.
public final class PasteTextInjector: TextInsertionBackend {
    fileprivate static let log = EposLogger(category: "inject")

    public init() {}

    public func startInsertionSession() -> any TextInsertionSession {
        PasteTextInsertionSession()
    }
}

private final class PasteTextInsertionSession: TextInsertionSession {
    private let savedPasteboardItems: [PasteboardItemSnapshot]
    private var lastWriteChangeCount: Int?
    private var didClose = false

    init(pasteboard: NSPasteboard = .general) {
        self.savedPasteboardItems = Self.snapshot(pasteboard)
    }

    func insert(_ text: String) {
        guard !didClose, !text.isEmpty else { return }
        let trusted = AXIsProcessTrusted()
        if !trusted {
            PasteTextInjector.log.error("insertion of \(text.count) chars will be DROPPED: Accessibility not trusted (System Settings > Privacy & Security > Accessibility)")
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastWriteChangeCount = pasteboard.changeCount

        synthesizeCommandV()
        PasteTextInjector.log.info("inserted \(text.count) chars via paste backend (axTrusted=\(trusted))")
    }

    func finish() {
        restorePasteboardSoon()
    }

    func cancel() {
        restorePasteboardSoon()
    }

    /// Deep-copies every type of every current pasteboard item into sendable
    /// snapshots that survive a `clearContents()`.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            PasteboardItemSnapshot(
                contents: item.types.compactMap { type in
                    item.data(forType: type).map {
                        PasteboardItemSnapshot.Content(type: type.rawValue, data: $0)
                    }
                }
            )
        }
    }

    private func restorePasteboardSoon() {
        guard !didClose else { return }
        didClose = true
        guard let lastWriteChangeCount, !savedPasteboardItems.isEmpty else { return }
        let savedPasteboardItems = savedPasteboardItems

        // Restore the prior clipboard after the paste lands — but only if nothing
        // else wrote to the pasteboard in the meantime (changeCount unchanged).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Re-acquire the shared pasteboard inside the closure instead of
            // capturing the outer reference, which would be sent across the
            // concurrency boundary while still in use here (Swift 6 data-race).
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == lastWriteChangeCount else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(savedPasteboardItems.map(\.pasteboardItem))
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

private struct PasteboardItemSnapshot: Sendable {
    struct Content: Sendable {
        let type: String
        let data: Data
    }

    let contents: [Content]

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        for content in contents {
            item.setData(content.data, forType: NSPasteboard.PasteboardType(content.type))
        }
        return item
    }
}

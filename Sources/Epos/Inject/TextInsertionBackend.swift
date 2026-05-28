import AppKit
import ApplicationServices
import Foundation

public protocol TextInsertionBackend {
    func startInsertionSession() -> any TextInsertionSession
}

public protocol TextInsertionSession: AnyObject {
    func insert(_ text: String)
    /// Retract the last `count` characters of what this session inserted, so a
    /// later transcript revision can correct text already typed into the field.
    func deleteBackward(count: Int)
    func finish()
    func cancel()
}

/// Types text into the frontmost app by synthesizing Unicode keyboard events.
///
/// Unlike a clipboard + ⌘V paste, each delta rides in its own keyboard event, so
/// streaming many small deltas during one dictation preserves order and never
/// races a shared pasteboard — the failure mode that garbled streamed paste
/// output. Requires Accessibility permission to post events into another app.
public final class KeystrokeTextInjector: TextInsertionBackend {
    fileprivate static let log = EposLogger(category: "inject")

    /// `CGEventKeyboardSetUnicodeString` carries only a short run of UTF-16 units
    /// per event reliably across apps; longer payloads get truncated. Each delta
    /// is split into chunks no larger than this, never across a grapheme.
    static let maxUTF16UnitsPerEvent = 20

    public init() {}

    public func startInsertionSession() -> any TextInsertionSession {
        KeystrokeTextInsertionSession()
    }

    /// Splits `text` into UTF-16 chunks no longer than `maxUTF16Units`, never
    /// cutting across a grapheme so multi-unit characters (emoji, combining
    /// marks) survive intact.
    static func unicodeChunks(of text: String, maxUTF16Units: Int = maxUTF16UnitsPerEvent) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []

        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUTF16Units {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }

        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

private final class KeystrokeTextInsertionSession: TextInsertionSession {
    /// A private event-source state so synthesized events do not inherit the
    /// physically-held fn modifier (push-to-talk) or any other live modifier.
    private let eventSource = CGEventSource(stateID: .privateState)
    private var didClose = false

    func insert(_ text: String) {
        guard !didClose, !text.isEmpty else { return }
        let trusted = AXIsProcessTrusted()
        if !trusted {
            KeystrokeTextInjector.log.error("insertion of \(text.count) chars will be DROPPED: Accessibility not trusted (System Settings > Privacy & Security > Accessibility)")
        }

        for chunk in KeystrokeTextInjector.unicodeChunks(of: text) {
            typeChunk(chunk)
        }
        KeystrokeTextInjector.log.info("typed \(text.count) chars via keystroke backend (axTrusted=\(trusted))")
    }

    func deleteBackward(count: Int) {
        guard !didClose, count > 0 else { return }
        for _ in 0..<count {
            postKeyPress(virtualKey: Self.deleteKey)
        }
        KeystrokeTextInjector.log.info("deleted \(count) chars via keystroke backend")
    }

    func finish() { didClose = true }

    func cancel() { didClose = true }

    /// kVK_Delete — the Mac "delete" key, which erases the character before the caret.
    private static let deleteKey: CGKeyCode = 0x33

    /// Posts one chunk as a matched keyDown/keyUp pair. The Unicode payload rides
    /// only on keyDown — standard text systems insert on keyDown, and carrying it
    /// on keyUp too double-types in Chromium/Electron, which insert on both edges.
    private func typeChunk(_ chunk: [UniChar]) {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            return
        }

        down.flags = []
        down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        down.post(tap: .cghidEventTap)

        up.flags = []
        up.post(tap: .cghidEventTap)
    }

    /// Posts a bare keyDown/keyUp pair for a virtual key (no Unicode payload, no
    /// modifiers) — used for editing keys like delete.
    private func postKeyPress(virtualKey: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: virtualKey, keyDown: false) else {
            return
        }

        down.flags = []
        down.post(tap: .cghidEventTap)

        up.flags = []
        up.post(tap: .cghidEventTap)
    }
}

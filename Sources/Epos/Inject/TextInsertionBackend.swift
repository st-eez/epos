import AppKit
import ApplicationServices
import Foundation

public protocol TextInsertionBackend {
    func startInsertionSession() -> any TextInsertionSession
}

public protocol TextInsertionSession: AnyObject {
    @discardableResult
    func insert(_ text: String) -> Bool
    func finish()
    func cancel()
}

/// Types text into the frontmost app by synthesizing Unicode keyboard events.
///
/// Unlike a clipboard + ⌘V paste, the final text rides in private Unicode
/// keyboard events and never races a shared pasteboard.
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

    /// Splits `text` into UTF-16 chunks, never cutting across a grapheme so
    /// multi-unit characters (emoji, combining marks) survive intact. Chunks are
    /// at most `maxUTF16Units` units EXCEPT for a single grapheme longer than
    /// that, which forms its own oversize chunk: keeping it whole is worth more
    /// than the limit, since a split grapheme is guaranteed to render wrong while
    /// an oversize event is only at risk of truncation.
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

    func insert(_ text: String) -> Bool {
        guard !didClose, !text.isEmpty else { return false }
        guard AXIsProcessTrusted() else {
            KeystrokeTextInjector.log.error(
                "insertion refused: Accessibility is not trusted " +
                    "(System Settings > Privacy & Security > Accessibility)"
            )
            return false
        }

        let chunks = KeystrokeTextInjector.unicodeChunks(of: text)
        let eventPairs = chunks.compactMap(makeEventPair)
        guard !eventPairs.isEmpty,
              eventPairs.count == chunks.count else {
            KeystrokeTextInjector.log.error("insertion refused: could not create Unicode keyboard events")
            return false
        }
        for (down, up) in eventPairs {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        KeystrokeTextInjector.log.info("typed \(text.count) chars via keystroke backend")
        return true
    }

    func finish() { didClose = true }

    func cancel() { didClose = true }

    /// Posts one chunk as a matched keyDown/keyUp pair. The Unicode payload rides
    /// only on keyDown — standard text systems insert on keyDown, and carrying it
    /// on keyUp too double-types in Chromium/Electron, which insert on both edges.
    private func makeEventPair(_ chunk: [UniChar]) -> (CGEvent, CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
            return nil
        }

        down.flags = []
        down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        up.flags = []
        return (down, up)
    }
}

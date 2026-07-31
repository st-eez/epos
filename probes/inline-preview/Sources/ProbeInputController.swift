import AppKit
import Carbon
import InputMethodKit

/// Palette input method controller. It never consumes keystrokes; every text
/// operation arrives over the command socket so the probe can drive marked text
/// without owning the keyboard.
///
/// Every operation returns a protocol line ("ok …" / "err …") that the driver
/// prints verbatim, so a failure is visible in the transcript rather than silent.
@objc(EposProbeInputController)
final class EposProbeInputController: IMKInputController {
    private static let replacementRange = NSRange(location: NSNotFound, length: NSNotFound)
    private static let unmarkTextSelector = NSSelectorFromString("unmarkText")

    nonisolated(unsafe) private static weak var activeController: EposProbeInputController?
    /// Every live client session. `activateServer` order is NOT a reliable proxy
    /// for "the focused field" — background processes (System Settings in
    /// particular) activate spuriously and take the most-recent slot — so a pass
    /// resolves its controller by bundle id out of this table instead.
    nonisolated(unsafe) private static let controllers = NSHashTable<EposProbeInputController>.weakObjects()
    nonisolated(unsafe) private static var markedText = ""
    nonisolated(unsafe) private static weak var lockedController: EposProbeInputController?
    nonisolated(unsafe) private static var lockedBundleID: String?

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.activeController = self
        Self.controllers.add(self)
        ProbeLog.write("activateServer client=\(Self.describe(sender))")
    }

    override func deactivateServer(_ sender: Any!) {
        ProbeLog.write("deactivateServer client=\(Self.describe(sender))")
        if Self.activeController === self {
            Self.activeController = nil
        }
        Self.controllers.remove(self)
        super.deactivateServer(sender)
    }

    // A palette input method must never swallow typing.
    override func inputText(_ string: String!, client sender: Any!) -> Bool { false }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { false }

    override func commitComposition(_ sender: Any!) {
        ProbeLog.write("commitComposition (host asked us to finalize)")
        Self.markedText = ""
    }

    // MARK: - Socket-driven operations

    static func status() -> String {
        let sessions = controllers.allObjects
            .map { $0.client()?.bundleIdentifier() ?? "?" }
            .joined(separator: ",")
        let front = activeController?.client()?.bundleIdentifier() ?? "none"
        return "ok recent=\(front) sessions=[\(sessions)] locked=\(lockedBundleID ?? "-") marked=\"\(markedText)\""
    }

    /// Pins the pass to one app. `expected` of "any" takes whichever session
    /// activated most recently; anything else must have a live session or the
    /// pass is refused.
    static func begin(expected: String) -> String {
        let controller: EposProbeInputController?
        if expected == "any" {
            controller = activeController
        } else {
            controller = controllers.allObjects.first { $0.client()?.bundleIdentifier() == expected }
        }
        guard let controller, let client = controller.client() else {
            return "err no client session for \(expected); live sessions: \(status())"
        }
        lockedController = controller
        lockedBundleID = client.bundleIdentifier() ?? ""
        ProbeLog.write("begin locked=\(lockedBundleID ?? "?")")
        return "ok locked \(lockedBundleID ?? "?")"
    }

    static func end() -> String {
        let previous = lockedBundleID ?? "-"
        lockedController = nil
        lockedBundleID = nil
        ProbeLog.write("end unlocked=\(previous)")
        return "ok unlocked \(previous)"
    }

    private enum LockedClient {
        case ready(IMKTextInput & NSObjectProtocol)
        case refused(String)
    }

    private static func lockedClient() -> LockedClient {
        if let locked = lockedBundleID {
            guard let controller = lockedController, let client = controller.client() else {
                return .refused("locked session \(locked) is gone")
            }
            let current = client.bundleIdentifier() ?? ""
            guard current == locked else {
                return .refused("session changed: locked=\(locked) now=\(current)")
            }
            return .ready(client)
        }
        guard let client = activeController?.client() else { return .refused("no active client session") }
        return .ready(client)
    }

    /// `styled` sends the underlined attributed run Apple's own input methods
    /// use; a plain `String` renders with no preedit decoration at all, which is
    /// worth comparing per host.
    static func mark(_ text: String, styled: Bool) -> String {
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient() {
        case .refused(let reason): return "err \(reason)"
        case .ready(let resolved): client = resolved
        }
        let selection = NSRange(location: (text as NSString).length, length: 0)
        let payload: Any = styled ? underlinedMarkedText(text) : text
        client.setMarkedText(payload, selectionRange: selection, replacementRange: replacementRange)
        markedText = text
        ProbeLog.write("mark len=\(text.count) styled=\(styled) client=\(describe(client))")
        return "ok marked \(text.count) styled=\(styled) client=\(describe(client))"
    }

    private static func underlinedMarkedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.textColor,
            NSAttributedString.Key("NSMarkedClauseSegment"): 0,
        ])
    }

    static func commit(_ replacement: String?) -> String {
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient() {
        case .refused(let reason): return "err \(reason)"
        case .ready(let resolved): client = resolved
        }
        let text = replacement ?? markedText
        guard !text.isEmpty else { return "err nothing to commit" }
        client.insertText(text, replacementRange: replacementRange)
        markedText = ""
        ProbeLog.write("commit len=\(text.count) client=\(describe(client))")
        return "ok committed \(text.count)"
    }

    /// Caret-line rectangle of the pinned client at the composition END — where
    /// text is being inserted — queried the way candidate windows position
    /// themselves. `attributesForCharacterIndex:` is relative to the inline
    /// session and fills a one-pixel-wide rect with the height of the caret
    /// line, in screen coordinates. Hosts differ in which indexes they answer,
    /// so the end index is probed first (`rect index=N` in the log shows which
    /// one won). Falls back to `firstRectForCharacterRange:` over the tail of
    /// the marked range. Zero/garbage rects reply unavailable.
    static func rect() -> String {
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient() {
        case .refused(let reason): return "err \(reason)"
        case .ready(let resolved): client = resolved
        }
        let markedLength = (markedText as NSString).length
        var candidates = [0]
        if markedLength > 0 {
            candidates = markedLength > 1 ? [markedLength, markedLength - 1, 0] : [markedLength, 0]
        }
        var lineRect = NSRect.zero
        var wonIndex = -1
        for index in candidates {
            var probed = NSRect.zero
            _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &probed)
            if usableCaretRect(probed) {
                lineRect = probed
                wonIndex = index
                break
            }
        }
        if wonIndex < 0, markedLength > 0 {
            var actualRange = NSRange(location: NSNotFound, length: 0)
            lineRect = client.firstRect(
                forCharacterRange: NSRange(location: markedLength - 1, length: 1),
                actualRange: &actualRange
            )
        }
        guard usableCaretRect(lineRect) else {
            ProbeLog.write("rect unavailable len=\(markedLength) client=\(describe(client))")
            return "err rect unavailable client=\(describe(client))"
        }
        ProbeLog.write("rect index=\(wonIndex) len=\(markedLength) \(lineRect) client=\(describe(client))")
        return "ok rect \(Double(lineRect.origin.x)) \(Double(lineRect.origin.y)) "
            + "\(Double(lineRect.size.width)) \(Double(lineRect.size.height))"
    }

    private static func usableCaretRect(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.height > 1
    }

    static func cancel() -> String {
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient() {
        case .refused(let reason): return "err \(reason)"
        case .ready(let resolved): client = resolved
        }
        markedText = ""
        // Zero-length marked text is the reliable discard on hosts whose
        // unmarkText commits the composition instead of dropping it.
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: replacementRange)
        let unmarked = performUnmarkText(on: client)
        ProbeLog.write("cancel unmarkText=\(unmarked) client=\(describe(client))")
        return "ok cancelled unmarkText=\(unmarked)"
    }

    // MARK: - Helpers

    private static func performUnmarkText(on target: NSObjectProtocol?) -> Bool {
        guard let target, target.responds(to: unmarkTextSelector) else { return false }
        _ = target.perform(unmarkTextSelector)
        return true
    }

    private static func describe(_ target: Any?) -> String {
        guard let target else { return "nil" }
        if let client = target as? IMKTextInput {
            return "\(type(of: target))/\(client.bundleIdentifier() ?? "?")"
        }
        return "\(type(of: target))"
    }
}

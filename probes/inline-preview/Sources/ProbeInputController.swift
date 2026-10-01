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
    nonisolated(unsafe) private static weak var lockedController: EposProbeInputController?
    nonisolated(unsafe) private static weak var lockedInputClient: (IMKTextInput & NSObjectProtocol)?
    nonisolated(unsafe) private static var lockedBundleID: String?
    nonisolated(unsafe) private static var lockedConnection: UInt64?

    /// Who currently holds marked text put there by us, tracked independently of
    /// the focus lock. The lock can stop resolving while the composition is still
    /// live — hosts tear an IMK session down and build a new one mid-pass, and
    /// the recorded owner is then the only address left for text that is still on
    /// screen. Refusing to act on an unresolvable lock is what let compositions
    /// survive into document text on commit-on-unmark hosts.
    private struct Composition {
        weak var controller: EposProbeInputController?
        weak var client: (IMKTextInput & NSObjectProtocol)?
        let bundleID: String
        let connection: UInt64
        let range: NSRange
        var text: String
    }

    nonisolated(unsafe) private static var composition: Composition?

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.activeController = self
        Self.controllers.add(self)
        ProbeLog.write("activateServer client=\(Self.describe(sender))")
    }

    override func deactivateServer(_ sender: Any!) {
        ProbeLog.write("deactivateServer client=\(Self.describe(sender))")
        // The host is tearing this session down. Anything of ours still marked in
        // it comes off now: once the session is gone the composition is no longer
        // addressable, and a host that commits on unmark turns it into text.
        if Self.composition?.controller === self {
            Self.clearComposition(reason: "deactivateServer")
        }
        if Self.activeController === self {
            Self.activeController = nil
        }
        Self.controllers.remove(self)
        super.deactivateServer(sender)
    }

    // A palette input method must never swallow typing.
    override func inputText(_ string: String!, client sender: Any!) -> Bool { false }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool { false }

    /// The host asking a session to finalize. We never insert preview text on a
    /// host's schedule, so this drops the composition instead — and only when the
    /// receiving session is the one holding it: a background app finalizing must
    /// not touch a composition live in another app.
    override func commitComposition(_ sender: Any!) {
        guard Self.composition?.controller === self else {
            ProbeLog.write("commitComposition ignored (not the composition owner) client=\(Self.describe(sender))")
            return
        }
        ProbeLog.write("commitComposition (host asked us to finalize)")
        Self.clearComposition(reason: "commitComposition")
    }

    // MARK: - Socket-driven operations

    static func status() -> String {
        let sessions = controllers.allObjects
            .map { $0.client()?.bundleIdentifier() ?? "?" }
            .joined(separator: ",")
        let front = activeController?.client()?.bundleIdentifier() ?? "none"
        return "ok recent=\(front) sessions=[\(sessions)] locked=\(lockedBundleID ?? "-") "
            + "owner=\(composition?.bundleID ?? "-") marked=\"\(composition?.text ?? "")\""
    }

    /// Pins the pass to one app. `expected` of "any" takes whichever session
    /// activated most recently; anything else must have a live session or the
    /// pass is refused.
    static func begin(expected: String, connection: UInt64) -> String {
        let controller: EposProbeInputController?
        if expected == "any" {
            controller = activeController
        } else {
            let matches = controllers.allObjects.filter { $0.client()?.bundleIdentifier() == expected }
            guard matches.count == 1 else {
                return "err expected one client session for \(expected), found \(matches.count)"
            }
            controller = matches[0]
        }
        guard let controller, let client = controller.client() else {
            return "err no client session for \(expected); live sessions: \(status())"
        }
        if let current = composition,
           current.connection != connection || current.controller !== controller {
            if case .unreachable(let reason) = clearComposition(reason: "new preview pass") {
                return "err \(reason)"
            }
        }
        lockedController = controller
        lockedInputClient = client
        lockedBundleID = client.bundleIdentifier() ?? ""
        lockedConnection = connection
        ProbeLog.write("begin locked=\(lockedBundleID ?? "?") connection=\(connection)")
        return "ok locked \(lockedBundleID ?? "?")"
    }

    /// Releases the focus lock only. It must never touch text: Epos sends `end`
    /// after an ambiguous final commit, where any further composition traffic
    /// could disturb text the host has already accepted.
    static func end(connection: UInt64) -> String {
        guard lockedConnection == connection else { return "err preview pass is not owned by this connection" }
        let previous = lockedBundleID ?? "-"
        lockedController = nil
        lockedInputClient = nil
        lockedBundleID = nil
        lockedConnection = nil
        ProbeLog.write("end unlocked=\(previous)")
        return "ok unlocked \(previous)"
    }

    /// A command connection dropping is a teardown: the only process that could
    /// have asked us to remove the composition is gone. Clear it best-effort and
    /// release the lock it took, rather than leaving either for nobody.
    static func releaseConnection(_ connection: UInt64, reason: String) {
        if composition?.connection == connection {
            clearComposition(reason: "connection \(connection) \(reason)")
        }
        if lockedConnection == connection {
            ProbeLog.write("release connection=\(connection) unlocked=\(lockedBundleID ?? "-") reason=\(reason)")
            lockedController = nil
            lockedInputClient = nil
            lockedBundleID = nil
            lockedConnection = nil
        }
    }

    private enum LockedClient {
        case ready(controller: EposProbeInputController, client: IMKTextInput & NSObjectProtocol)
        case refused(String)
    }

    private static func lockedClient(connection: UInt64) -> LockedClient {
        guard lockedConnection == connection else {
            return .refused("preview pass is not owned by this connection")
        }
        if let locked = lockedBundleID {
            guard let controller = lockedController, let client = lockedInputClient,
                  let currentClient = controller.client(), currentClient === client else {
                return .refused("locked session \(locked) is gone")
            }
            let current = client.bundleIdentifier() ?? ""
            guard current == locked else {
                return .refused("session changed: locked=\(locked) now=\(current)")
            }
            return .ready(controller: controller, client: client)
        }
        return .refused("no locked client session")
    }

    /// `styled` sends the underlined attributed run Apple's own input methods
    /// use; a plain `String` renders with no preedit decoration at all, which is
    /// worth comparing per host.
    static func mark(_ text: String, styled: Bool, connection: UInt64) -> String {
        let controller: EposProbeInputController
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient(connection: connection) {
        case .refused(let reason):
            return composition?.connection == connection ? "err unsafe \(reason)" : "err \(reason)"
        case .ready(let resolved, let resolvedClient):
            controller = resolved
            client = resolvedClient
        }
        let bundleID = client.bundleIdentifier() ?? ""
        // Marking a second client would strand the first composition with nobody
        // left to address it.
        if let current = composition, current.controller !== controller {
            if case .unreachable(let reason) = clearComposition(reason: "mark moved to \(bundleID)") {
                return "err \(reason)"
            }
        }
        let selectedRange = client.selectedRange()
        let liveState = liveCompositionState(of: client, expected: composition)
        if liveState == .foreign {
            return "err unsafe composition before preview"
        }
        guard ProbePreviewSafety.canWrite(
            selectedRange: selectedRange,
            compositionState: liveState,
            continuingComposition: composition != nil
        ) else {
            return composition == nil
                ? "err preview requires a readable empty selection and no existing composition"
                : "err unsafe selection or composition before preview"
        }
        let start = composition?.range.location ?? selectedRange.location
        let selection = NSRange(location: (text as NSString).length, length: 0)
        let payload: Any = styled ? underlinedMarkedText(text) : text
        client.setMarkedText(payload, selectionRange: selection, replacementRange: replacementRange)
        composition = Composition(
            controller: controller, client: client, bundleID: bundleID, connection: connection,
            range: NSRange(location: start, length: (text as NSString).length), text: text
        )
        ProbeLog.write("mark len=\(text.count) styled=\(styled) connection=\(connection) client=\(describe(client))")
        return "ok marked \(text.count) styled=\(styled) client=\(describe(client))"
    }

    private static func underlinedMarkedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.textColor,
            NSAttributedString.Key("NSMarkedClauseSegment"): 0,
        ])
    }

    /// The one path that inserts text, and the only one that still refuses on an
    /// unresolvable lock: Epos treats an `err` reply as proof `insertText` did not
    /// run and falls back to a guarded keystroke write, so every refusal here must
    /// precede the insert.
    static func commit(_ replacement: String?, connection: UInt64) -> String {
        let controller: EposProbeInputController
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient(connection: connection) {
        case .refused(let reason):
            return composition?.connection == connection ? "err unsafe \(reason)" : "err \(reason)"
        case .ready(let resolved, let resolvedClient):
            controller = resolved
            client = resolvedClient
        }
        let text = replacement ?? composition?.text ?? ""
        guard !text.isEmpty else { return "err nothing to commit" }
        if let current = composition, current.controller !== controller {
            return "err unsafe composition belongs to another client"
        }
        guard ProbePreviewSafety.canWrite(
            selectedRange: client.selectedRange(),
            compositionState: liveCompositionState(of: client, expected: composition),
            continuingComposition: composition != nil
        ) else {
            return "err unsafe selection or composition before commit"
        }
        client.insertText(text, replacementRange: replacementRange)
        // insertText consumed the composition in this client; drop the record
        // without sending anything further.
        composition = nil
        ProbeLog.write("commit len=\(text.count) connection=\(connection) client=\(describe(client))")
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
    static func rect(connection: UInt64) -> String {
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient(connection: connection) {
        case .refused(let reason): return "err \(reason)"
        case .ready(_, let resolved): client = resolved
        }
        let markedLength = ((composition?.text ?? "") as NSString).length
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

    /// Goes to the concrete owner and clears only a live range/text match.
    /// Foreign or unreadable marked text is preserved and reported as unsafe.
    static func cancel(connection: UInt64) -> String {
        guard lockedConnection == connection else { return "err preview pass is not owned by this connection" }
        switch clearComposition(reason: "cancel") {
        case .nothingMarked:
            let client: IMKTextInput & NSObjectProtocol
            switch lockedClient(connection: connection) {
            case .refused(let reason): return "err unsafe \(reason)"
            case .ready(_, let resolved): client = resolved
            }
            let reply = ProbePreviewSafety.cancellationReplyWithoutComposition(
                selectedRange: client.selectedRange(),
                compositionState: liveCompositionState(of: client, expected: nil)
            )
            ProbeLog.write("cancel without composition reply=\(reply)")
            return reply
        case .cleared(let unmarked, let viaOwner):
            return "ok cancelled unmarkText=\(unmarked) viaOwner=\(viaOwner)"
        case .unreachable(let reason):
            return "err \(reason)"
        }
    }

    // MARK: - Composition teardown

    @discardableResult
    private static func clearComposition(reason: String) -> ClearOutcome {
        guard let current = composition else { return .nothingMarked }
        guard let target = compositionTarget(current) else {
            // A different session in the same app may address a different field.
            // Keep the record for an owner retry without mutating another client.
            ProbeLog.write("clear reason=\(reason) UNREACHABLE owner=\(current.bundleID) len=\(current.text.count)")
            return .unreachable("unsafe composition owner \(current.bundleID) is gone")
        }
        switch liveCompositionState(of: target.client, expected: current) {
        case .owned:
            break
        case .absent:
            composition = nil
            return .unreachable("unsafe Epos preview ended before cancellation")
        case .foreign, .unreadable:
            return .unreachable("unsafe composition no longer matches the Epos preview")
        }
        composition = nil
        // Zero-length marked text is the reliable discard on hosts whose
        // unmarkText commits the composition instead of dropping it.
        target.client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: replacementRange
        )
        let unmarked = performUnmarkText(on: target.client)
        ProbeLog.write(
            "clear reason=\(reason) owner=\(current.bundleID) len=\(current.text.count) "
                + "viaOwner=\(target.isOwner) unmarkText=\(unmarked)"
        )
        return .cleared(unmarkText: unmarked, viaOwner: target.isOwner)
    }

    private enum ClearOutcome {
        case nothingMarked
        case cleared(unmarkText: Bool, viaOwner: Bool)
        case unreachable(String)
    }

    private static func compositionTarget(
        _ current: Composition
    ) -> (client: IMKTextInput & NSObjectProtocol, isOwner: Bool)? {
        if let client = current.client, (client.bundleIdentifier() ?? "") == current.bundleID {
            return (client, true)
        }
        return nil
    }

    private static func liveCompositionState(
        of client: IMKTextInput & NSObjectProtocol,
        expected current: Composition?
    ) -> ProbePreviewSafety.CompositionState {
        let expected: (range: NSRange, text: String)?
        if let current, current.client === client {
            expected = (current.range, current.text)
        } else {
            expected = nil
        }
        return ProbePreviewSafety.compositionState(markedRange: client.markedRange(), expected: expected) {
            client.attributedSubstring(from: $0)?.string
        }
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

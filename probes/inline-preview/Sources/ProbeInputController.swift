import AppKit
import Carbon
import InputMethodKit

/// Keyboard input method controller. It never consumes keystrokes; every text
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
        var textBeforeMark: String? = nil

        mutating func observe(markedRange: NSRange, readText: (NSRange) -> String?) -> ProbePreviewSafety.CompositionState {
            let state = ProbePreviewSafety.compositionState(
                markedRange: markedRange, expected: (range, text), textBeforeMark: textBeforeMark,
                readText: readText
            )
            // Once the cache catches up, reverting to its old text is a change.
            if state == .owned { textBeforeMark = nil }
            return state
        }
    }

    nonisolated(unsafe) private static var composition: Composition?
    nonisolated(unsafe) private static var session: ProbeSessionOwnership?
    nonisolated(unsafe) private static var barrier: ProbeInputBarrier?
    nonisolated(unsafe) private static var savedKeyboardSource: TISInputSource?
    nonisolated(unsafe) private static var acquiredFromKeyboardLayout = false
    nonisolated(unsafe) private static var discarding = false
    nonisolated(unsafe) private static var nativeMarkInFlight = false
    nonisolated(unsafe) private static var nativeCommitInFlight = false
    private var activated = false
    nonisolated(unsafe) private static var diagnosticConnection: UInt64?

    deinit { ProbeLog.write("controller deinit id=\(ObjectIdentifier(self))") }

#if EPOS_CONTROLLER_TESTS
    static func phraseCallbackStatesForTesting() -> [ProbeSessionOwnership.State] {
        let controller = EposProbeInputController()
        let policy = ProbeSessionOwnership(layoutSession: true, observation: .init(
            selection: NSRange(location: 0, length: 0), marked: replacementRange, composition: .unreadable
        ))!
        lockedController = controller
        session = policy
        defer {
            nativeCommitInFlight = false
            lockedController = nil
            session = nil
        }
        precondition(policy.finishNativeCommit(continuing: true))
        nativeCommitInFlight = true
        controller.commitComposition(nil)
        let during = policy.state
        nativeCommitInFlight = false
        controller.commitComposition(nil)
        return [during, policy.state]
    }

    static func cachedReadbackStatesForTesting(_ readbacks: [String]) -> [ProbePreviewSafety.CompositionState] {
        var record = Composition(controller: nil, client: nil, bundleID: "test.host", connection: 1,
                                 range: NSRange(location: 0, length: 1), text: "E", textBeforeMark: "\n")
        return readbacks.map { text in record.observe(markedRange: record.range, readText: { _ in text }) }
    }

    static func stageUnreachableCompositionForTesting(connection: UInt64) {
        lockedConnection = connection
        lockedBundleID = "test.host"
        composition = Composition(controller: nil, client: nil, bundleID: "test.host", connection: connection,
                                  range: NSRange(location: 0, length: 1), text: "x")
    }
#endif

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        activated = true
        Self.activeController = self
        Self.controllers.add(self)
        ProbeLog.write("activateServer id=\(ObjectIdentifier(self)) client=\(Self.describe(sender))")
    }

    override func deactivateServer(_ sender: Any!) {
#if EPOS_SESSION_PROTOTYPE
        ProbeSessionPrototype.hostCallback(self, reason: "deactivate")
#endif
        activated = false
        if Self.lockedController === self { Self.interruptSession("deactivate", mayDiscard: true) }
        ProbeLog.write("deactivateServer id=\(ObjectIdentifier(self)) client=\(Self.describe(sender))")
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

    // Interrupted typing passes through after the owned preview is discarded.
    override func inputText(_ string: String!, client sender: Any!) -> Bool {
#if EPOS_SESSION_PROTOTYPE
        ProbeSessionPrototype.hostCallback(self, reason: "input-text")
#endif
        if Self.lockedController === self { Self.interruptSession("input-text", mayDiscard: true) }
        return false
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
#if EPOS_SESSION_PROTOTYPE
        if !ProbeSessionOwnership.ignoresControllerEvent(isFlagsChange: event?.type == .flagsChanged,
                                                         keyCode: event?.keyCode) {
            ProbeSessionPrototype.hostCallback(self, reason: "handle")
        }
#endif
        if event?.type != .flagsChanged, event?.type != .keyUp, Self.lockedController === self {
            Self.interruptSession("handle", mayDiscard: true)
        }
        return false
    }

    /// The host asking a session to finalize. We never insert preview text on a
    /// host's schedule, so this drops the composition instead — and only when the
    /// receiving session is the one holding it: a background app finalizing must
    /// not touch a composition live in another app.
    override func commitComposition(_ sender: Any!) {
        if Self.nativeCommitInFlight, Self.lockedController === self { return }
#if EPOS_SESSION_PROTOTYPE
        ProbeSessionPrototype.hostCallback(self, reason: "host-commit")
#endif
        if Self.lockedController === self { Self.interruptSession("host-commit", mayDiscard: true) }
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
            .map { "id=\(ObjectIdentifier($0)):active=\($0.activated):bundle=\($0.client()?.bundleIdentifier() ?? "?")" }
            .joined(separator: ",")
        let front = activeController?.client()?.bundleIdentifier() ?? "none"
        return "ok recent=\(front) sessions=[\(sessions)] locked=\(lockedBundleID ?? "-") "
            + "owner=\(composition?.bundleID ?? "-") markedUTF16=\(((composition?.text ?? "") as NSString).length)"
    }

    /// Developer metadata only. Run with Epos stopped: opening a new socket
    /// connection supersedes its previous peer before any command is dispatched.
    static func ranges(expected: String) -> String {
        guard lockedConnection == nil, composition == nil else {
            return "err range inspection requires an idle companion"
        }
        let matches = controllers.allObjects.filter { $0.client()?.bundleIdentifier() == expected }
        guard !expected.isEmpty, matches.count == 1, let client = matches[0].client() else {
            return "err range inspection requires one matching client"
        }
        let selection = client.selectedRange()
        let marked = client.markedRange()
        return "ok ranges selection=\(selection.location),\(selection.length) "
            + "marked=\(marked.location),\(marked.length) client=\(describe(client))"
    }

    /// Pins the pass to one app. `expected` of "any" takes whichever session
    /// activated most recently; anything else must have a live session or the
    /// pass is refused.
    static func begin(expected argument: String, connection: UInt64) -> String {
        if diagnosticConnection != connection {
            diagnosticConnection = connection
            ProbeLog.write("begin state connection=\(connection) selected=\(ProbeInputBarrier.eposIsSelected) \(status())")
        }
        let parts = argument.split(separator: " ").map(String.init)
        guard let expected = parts.first, parts.count == 1 || (4...6).contains(parts.count),
              parts.count == 1 || ["acquire-layout", "acquire-method", "adopt-layout"].contains(parts[1]) else {
            return "err invalid acquisition"
        }
        let holdKey: UInt16?
        if parts.count >= 5 {
            guard let key = ProbeInputBarrier.holdKey(from: parts[4]) else { return "err invalid hold key" }
            holdKey = key
        } else { holdKey = nil }
        let shortcut: DictationShortcut?
        if parts.count == 6 {
            guard let binding = ProbeInputBarrier.holdShortcut(keyToken: parts[4], flagsToken: parts[5]) else {
                return "err invalid hold shortcut"
            }
            shortcut = binding
        } else { shortcut = nil }
        let acquiredFromLayout = parts.count >= 4 && parts[1] == "acquire-layout"
        let adoptsSelectedSource = parts.count >= 4 && parts[1] == "adopt-layout"
        let priorSource: TISInputSource?
        if parts.count >= 4 {
            guard let prior = keyboardSource(identifier: parts[2]),
                  keyboardSource(identifier: parts[3], layoutOnly: true) != nil,
                  !acquiredFromLayout || keyboardSource(identifier: parts[2], layoutOnly: true) != nil else {
                return "err invalid saved keyboard source"
            }
            guard adoptsSelectedSource == (parts[2] == Bundle.main.bundleIdentifier) else {
                return "err invalid saved keyboard source"
            }
            // An adopted source belongs to the user and must survive teardown.
            priorSource = adoptsSelectedSource ? nil : prior
        } else { priorSource = nil }
        let controller: EposProbeInputController?
        if expected == "any" {
            controller = activeController
        } else {
            let matches = controllers.allObjects.filter { $0.client()?.bundleIdentifier() == expected }
            guard matches.count == 1 else {
                if matches.isEmpty, ProbeInputBarrier.eposIsSelected { return "err input method activation pending" }
                return "err expected one client session for \(expected), found \(matches.count)"
            }
            controller = matches[0]
        }
        guard ProbeInputBarrier.eposIsSelected else { return "err Epos keyboard source is not selected" }
        guard let controller, controller.activated, let client = controller.client() else {
            return "err input method activation pending"
        }
        if let current = composition,
           current.connection != connection || current.controller !== controller {
            if case .unreachable(let reason) = clearComposition(reason: "new preview pass") {
                return "err \(reason)"
            }
        }
        let observation = observe(client, expected: nil)
        if observation.composition == .foreign { return "err unsafe composition before acquisition" }
        guard let policy = ProbeSessionOwnership(layoutSession: acquiredFromLayout || adoptsSelectedSource,
                                                observation: observation) else {
            return "err acquisition requires readable empty selection and composition absence"
        }
        guard let inputBarrier = ProbeInputBarrier(targetBundle: client.bundleIdentifier() ?? expected, holdKey: holdKey, shortcut: shortcut, interrupt: { reason, mayDiscard in
            Self.interruptSession(reason, mayDiscard: mayDiscard)
        }) else { return "err input barrier unavailable" }
        barrier?.stop()
        barrier = inputBarrier
        session = policy
        savedKeyboardSource = priorSource
        acquiredFromKeyboardLayout = acquiredFromLayout
        lockedController = controller
        lockedInputClient = client
        lockedBundleID = client.bundleIdentifier() ?? ""
        lockedConnection = connection
        if parts.count >= 4 { client.overrideKeyboard(withKeyboardNamed: parts[3]) }
        guard !policy.isRetired else { return "err unsafe session retired during acquisition" }
        ProbeLog.write("begin locked=\(lockedBundleID ?? "?") connection=\(connection)")
        let caret = caretMetadata(client: client)
        guard session === policy, !policy.isRetired else { return "err unsafe session retired during caret query" }
        return "ok locked \(lockedBundleID ?? "?")\(caret)"
    }

    /// Releases the focus lock only. It must never touch text: Epos sends `end`
    /// after an ambiguous final commit, where any further composition traffic
    /// could disturb text the host has already accepted.
    static func end(connection: UInt64) -> String {
        guard lockedConnection == connection else { return "err preview pass is not owned by this connection" }
        let previous = lockedBundleID ?? "-"
        session?.retire("end")
        // An unsafe readback can leave a record we no longer have authority to
        // clear. Relinquish that record without touching host text. It must not
        // block a later recording in another client.
        if composition?.connection == connection { composition = nil }
        barrier?.stop()
        barrier = nil
        restoreKeyboardSource()
        session = nil
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
#if EPOS_SESSION_PROTOTYPE
        ProbeSessionPrototype.disconnect(connection)
#endif
        if lockedConnection == connection { interruptSession("disconnect", mayDiscard: true) }
        if composition?.connection == connection {
            clearComposition(reason: "connection \(connection) \(reason)")
            if composition?.connection == connection { composition = nil }
        }
        if lockedConnection == connection {
            ProbeLog.write("release connection=\(connection) unlocked=\(lockedBundleID ?? "-") reason=\(reason)")
            lockedController = nil
            lockedInputClient = nil
            lockedBundleID = nil
            lockedConnection = nil
            barrier?.stop()
            barrier = nil
            restoreKeyboardSource()
            session = nil
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
        guard session?.isRetired != true, barrier?.enabled == true, ProbeInputBarrier.eposIsSelected else {
            interruptSession("session-unavailable", mayDiscard: false)
            return .refused("unsafe preview session ended")
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
            return ProbePreviewSafety.unmarkedRefusal(reason, unsafe: composition?.connection == connection)
        case .ready(let resolved, let resolvedClient):
            controller = resolved
            client = resolvedClient
        }
        let bundleID = client.bundleIdentifier() ?? ""
        // Marking a second client would strand the first composition with nobody
        // left to address it.
        if let current = composition, current.controller !== controller {
            if case .unreachable(let reason) = clearComposition(reason: "mark moved to \(bundleID)") {
                return ProbePreviewSafety.unmarkedRefusal(reason)
            }
        }
        let selectedRange = client.selectedRange()
        let markedRange = client.markedRange()
        let liveState = liveCompositionState(of: client, expected: composition, markedRange: markedRange)
        if liveState == .foreign {
            logMarkRefusal(client: client, selection: selectedRange, marked: markedRange, state: liveState)
            return ProbePreviewSafety.unmarkedRefusal("composition before preview", unsafe: true)
        }
        guard let policy = session, policy.canOperate(.init(
            selection: selectedRange, marked: markedRange, composition: liveState
        )) else {
            logMarkRefusal(client: client, selection: selectedRange, marked: markedRange, state: liveState)
            return composition == nil
                ? ProbePreviewSafety.unmarkedRefusal("preview requires a readable empty selection and no existing composition")
                : ProbePreviewSafety.unmarkedRefusal("selection or composition before preview", unsafe: true)
        }
        let start = composition?.range.location ?? selectedRange.location
        let nextRange = NSRange(location: start, length: (text as NSString).length)
        let textBeforeMark = client.attributedSubstring(from: nextRange)?.string
        guard session === policy, !policy.isRetired else {
            return ProbePreviewSafety.unmarkedRefusal("session retired before mark", unsafe: true)
        }
        let selection = NSRange(location: (text as NSString).length, length: 0)
        let payload: Any = styled ? underlinedMarkedText(text) : text
        // Install the record before calling native code so a reentrant host
        // callback cannot leave a newly rendered draft without an owner.
        composition = Composition(
            controller: controller, client: client, bundleID: bundleID, connection: connection,
            range: nextRange, text: text, textBeforeMark: textBeforeMark
        )
        nativeMarkInFlight = true
        client.setMarkedText(payload, selectionRange: selection, replacementRange: replacementRange)
        nativeMarkInFlight = false
        let observedRange = client.markedRange()
        guard session === policy, !policy.isRetired else {
            // A native callback can retire the pass while its mark is on the
            // stack. Keep that retirement sticky and complete owned cleanup.
            if let current = composition, observedRange == current.range,
               ProbeSessionOwnership.emptySelection(client.selectedRange()) {
                _ = clearComposition(reason: "retired during mark", sessionAuthorized: true)
            }
            restoreKeyboardSource()
            return "err unsafe session retired during mark"
        }
        if let current = composition {
            composition = Composition(controller: current.controller, client: current.client,
                                      bundleID: current.bundleID, connection: current.connection,
                                      range: observedRange, text: text,
                                      textBeforeMark: observedRange == nextRange ? textBeforeMark : nil)
        }
        let readback = observe(client, expected: composition)
        guard policy.didMark(readback, utf16Length: (text as NSString).length) else {
            ProbeLog.write("mark readback refused expectedUTF16=\((text as NSString).length) "
                + "selection=\(readback.selection.location),\(readback.selection.length) "
                + "marked=\(readback.marked.location),\(readback.marked.length) "
                + "state=\(readback.composition) client=\(describe(client))")
            return "err unsafe mark readback changed"
        }
        ProbeLog.write("mark len=\(text.count) styled=\(styled) connection=\(connection) client=\(describe(client))")
        let caret = caretMetadata(client: client)
        guard session === policy, !policy.isRetired else { return "err unsafe session retired during caret query" }
        return "ok marked \(text.count) styled=\(styled) client=\(describe(client))\(caret)"
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
    static func commit(_ replacement: String?, connection: UInt64, continuing: Bool = false) -> String {
        let controller: EposProbeInputController
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient(connection: connection) {
        case .refused(let reason):
            return composition?.connection == connection ? "err unsafe \(reason)" : "err \(reason)"
        case .ready(let resolved, let resolvedClient):
            controller = resolved
            client = resolvedClient
        }
        guard let policy = session else { return "err unsafe preview session ended" }
        let text = replacement ?? composition?.text ?? ""
        guard !text.isEmpty else { return "err nothing to commit" }
        if let current = composition, current.controller !== controller {
            return "err unsafe composition belongs to another client"
        }
        guard policy.canOperate(observe(client, expected: composition)) else {
            return "err unsafe selection or composition before commit"
        }
        guard policy.finishNativeCommit(continuing: continuing) else { return "err unsafe session is not ready for final commit" }
        // Drop our record before native code: reentrant host callbacks must not
        // discard the composition while insertText is replacing it in place.
        let hadComposition = composition != nil
        composition = nil
        if acquiredFromKeyboardLayout { savedKeyboardSource = nil }
        nativeCommitInFlight = true
        client.insertText(text, replacementRange: replacementRange)
        nativeCommitInFlight = false
        let remaining = client.markedRange()
        if hadComposition, remaining.location != NSNotFound, remaining.length > 0 {
            // The call ran, so it is not safe to issue a second write. In
            // particular, a newly launched Ghostty with no native event can
            // ignore insertText and leave its preedit intact.
            return "ambiguous native commit left marked text"
        }
        if continuing, !(session === policy && policy.didCommitPhrase(observe(client, expected: nil))) {
            return "ambiguous native phrase commit lost session"
        }
        ProbeLog.write("commit continuing=\(continuing) len=\(text.count) connection=\(connection) client=\(describe(client))")
        return "ok committed \(text.count)"
    }

    /// Caret-line rectangle of the pinned client at the composition END — where
    /// text is being inserted — queried the way candidate windows position
    /// themselves. `attributesForCharacterIndex:` is relative to the inline
    /// session and fills a one-pixel-wide rect with the height of the caret
    /// line, in screen coordinates. Hosts differ in which indexes they answer,
    /// so the end index is probed first. Falls back to `firstRectForCharacterRange:` over the tail of
    /// the marked range. Zero/garbage rects reply unavailable.
    static func rect(connection: UInt64) -> String {
        let client: IMKTextInput & NSObjectProtocol
        switch lockedClient(connection: connection) {
        case .refused(let reason): return "err \(reason)"
        case .ready(_, let resolved): client = resolved
        }
        guard let rect = caretRect(client: client) else { return "err rect unavailable" }
        return "ok rect \(Double(rect.minX)) \(Double(rect.minY)) \(Double(rect.width)) \(Double(rect.height))"
    }

    private static func caretMetadata(client: IMKTextInput & NSObjectProtocol) -> String {
        guard let rect = caretRect(client: client) else { return " caret=unavailable" }
        return " caret=\(Double(rect.minX)),\(Double(rect.minY)),\(Double(rect.width)),\(Double(rect.height))"
    }

    private static func caretRect(client: IMKTextInput & NSObjectProtocol) -> NSRect? {
        let markedLength = ((composition?.text ?? "") as NSString).length
        var candidates = [0]
        if markedLength > 0 {
            candidates = markedLength > 1 ? [markedLength, markedLength - 1, 0] : [markedLength, 0]
        }
        var lineRect = NSRect.zero
        for index in candidates {
            var probed = NSRect.zero
            _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &probed)
            if usableCaretRect(probed) {
                return probed
            }
        }
        if markedLength > 0 {
            var actualRange = NSRange(location: NSNotFound, length: 0)
            lineRect = client.firstRect(
                forCharacterRange: NSRange(location: markedLength - 1, length: 1),
                actualRange: &actualRange
            )
        }
        return usableCaretRect(lineRect) ? lineRect : nil
    }

    private static func usableCaretRect(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.height > 1
    }

    /// Clears the concrete owner's draft. An acquired uninterrupted session
    /// permits unreadable text only while its observed range still matches.
    static func cancel(connection: UInt64) -> String {
        guard lockedConnection == connection else { return "err preview pass is not owned by this connection" }
        guard let policy = session, !policy.isRetired,
              case .ready(_, let client) = lockedClient(connection: connection),
              policy.canOperate(observe(client, expected: composition)) else {
            return "err unsafe preview session before cancellation"
        }
        let hadDraft = composition != nil
        switch clearComposition(reason: "cancel", sessionAuthorized: true) {
        case .nothingMarked:
            let client: IMKTextInput & NSObjectProtocol
            switch lockedClient(connection: connection) {
            case .refused(let reason): return "err unsafe \(reason)"
            case .ready(_, let resolved): client = resolved
            }
            let reply = policy.canOperate(observe(client, expected: nil))
                ? "ok cancelled nothing marked" : "err unsafe composition before cancellation"
            ProbeLog.write("cancel without composition reply=\(reply)")
            return reply
        case .cleared(let unmarked, let viaOwner):
            guard !policy.isRetired, !hadDraft || policy.didDiscard(observe(client, expected: nil)) else {
                return "err unsafe cancellation readback changed"
            }
            return "ok cancelled unmarkText=\(unmarked) viaOwner=\(viaOwner)"
        case .unreachable(let reason):
            return "err \(reason)"
        }
    }

    // MARK: - Composition teardown

    @discardableResult
    private static func clearComposition(reason: String, sessionAuthorized: Bool = false) -> ClearOutcome {
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
        case .unreadable:
            guard sessionAuthorized, target.client.markedRange() == current.range,
                  ProbeSessionOwnership.emptySelection(target.client.selectedRange()) else {
                return .unreachable("unsafe composition no longer matches the Epos preview")
            }
        case .foreign:
            return .unreachable("unsafe composition no longer matches the Epos preview")
        }
        composition = nil
        discarding = true
        defer { discarding = false }
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

    private static func interruptSession(_ reason: String, mayDiscard: Bool) {
        guard !discarding, let policy = session, policy.state != .finished else { return }
        let authorized = mayDiscard && composition.map { current in
            guard let client = current.client else { return false }
            let observation = observe(client, expected: current)
            return policy.canOperate(observation) || (nativeMarkInFlight
                && observation.marked == current.range
                && ProbeSessionOwnership.emptySelection(observation.selection)
                && (observation.composition == .owned || observation.composition == .unreadable))
        } == true
        policy.interrupt(reason) {
            if authorized { clearComposition(reason: reason, sessionAuthorized: true) }
        }
        if !nativeMarkInFlight { restoreKeyboardSource() }
    }

    private static func observe(_ client: IMKTextInput & NSObjectProtocol, expected: Composition?) -> ProbeSessionOwnership.Observation {
        let marked = client.markedRange()
        return .init(selection: client.selectedRange(), marked: marked,
                     composition: liveCompositionState(of: client, expected: expected, markedRange: marked))
    }

    private static func keyboardSource(identifier: String, layoutOnly: Bool = false) -> TISInputSource? {
        let properties = [kTISPropertyInputSourceID as String: identifier,
                          kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let sources = TISCreateInputSourceList(properties, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        if layoutOnly {
            guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
                  CFEqual(Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue(), kTISTypeKeyboardLayout) else { return nil }
        }
        return source
    }

    private static func restoreKeyboardSource() {
        guard let saved = savedKeyboardSource else { return }
        if !ProbeInputBarrier.eposIsSelected || TISSelectInputSource(saved) == noErr {
            savedKeyboardSource = nil
        } else { ProbeLog.write("saved keyboard source restoration failed") }
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
        expected current: Composition?,
        markedRange: NSRange? = nil
    ) -> ProbePreviewSafety.CompositionState {
        let range = markedRange ?? client.markedRange()
        if var current, current.client === client {
            let state = current.observe(markedRange: range) { client.attributedSubstring(from: $0)?.string }
            if composition?.client === client { composition?.textBeforeMark = current.textBeforeMark }
            return state
        }
        return ProbePreviewSafety.compositionState(markedRange: range, expected: nil) {
            client.attributedSubstring(from: $0)?.string
        }
    }

    private static func logMarkRefusal(
        client: IMKTextInput & NSObjectProtocol,
        selection: NSRange,
        marked: NSRange,
        state: ProbePreviewSafety.CompositionState
    ) {
        ProbeLog.write(
            "mark refused selection=\(selection.location),\(selection.length) "
                + "marked=\(marked.location),\(marked.length) state=\(state) "
                + "continuing=\(composition != nil) client=\(describe(client))"
        )
    }

    // MARK: - Helpers

#if EPOS_SESSION_PROTOTYPE
    static var sessionNormalIdle: Bool { lockedConnection == nil && composition == nil }

    static func sessionCandidates(_ bundle: String) -> [EposProbeInputController] {
        controllers.allObjects.filter { $0.client()?.bundleIdentifier() == bundle }
    }
#endif

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

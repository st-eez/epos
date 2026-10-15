#if EPOS_SESSION_PROTOTYPE
import AppKit
import ApplicationServices
import InputMethodKit

/// Explicit developer commands only. The default companion never compiles this
/// experiment. A synchronous event tap on main clears the draft before returning
/// an input event unchanged. Losing that barrier retires the entire pass.
enum ProbeSessionPrototype {
    private struct Pass {
        weak var controller: EposProbeInputController?
        weak var client: (IMKTextInput & NSObjectProtocol)?
        let connection: UInt64
        let pid: pid_t
        let window: CGWindowID
        let bundle: String
        let renderingNonce: String?
        let renderingBounds: CGRect?
        let policy: ProbeSessionOwnership
        var text = ""
    }

    private static let unavailable = NSRange(location: NSNotFound, length: NSNotFound)
    private static var pass: Pass?
    private static var snapshot: (connection: UInt64, bundle: String, controllers: Set<ObjectIdentifier>)?
    private static var tap: CFMachPort?
    private static var tapSource: CFRunLoopSource?
    private static var focusObserver: NSObjectProtocol?
    private static var previousFlags: CGEventFlags = []
    private static var eventCount = 0
    private static var callbackCount = 0
    private static var discardCount = 0
    private static var finalCount = 0
    private static var discarding = false
    private static var targetGate = "uninspected"
    private static var targetWindowCandidates = 0
    private static var barrierGate = "uninspected"

    static var hasPass: Bool { pass != nil }

    static func command(_ verb: String, argument: String, connection: UInt64) -> String? {
        precondition(Thread.isMainThread)
        switch verb {
        case "session-preflight":
            return "ok session preflight trusted=\(AXIsProcessTrusted())"
        case "session-snapshot":
            guard pass == nil, !argument.isEmpty else { return "err session snapshot requires idle prototype" }
            snapshot = (connection, argument, Set(EposProbeInputController.sessionCandidates(argument).map(ObjectIdentifier.init)))
            return "ok session snapshot"
        case "session-begin": return begin(argument, connection: connection)
        case "session-begin-background": return begin(argument, connection: connection, renderingOnly: true)
        case "session-mark": return mark(argument, connection: connection)
        case "session-cancel": return cancel(connection: connection)
        case "session-final": return final(argument, connection: connection)
        case "session-inspect": return inspect(connection: connection)
        case "session-end":
            guard pass?.connection == connection else { return "err session wrong connection" }
            interrupt("end", mayDiscard: true)
            stopBarrier()
            pass = nil
            return "ok session ended"
        default: return nil
        }
    }

    private static func begin(_ argument: String, connection: UInt64, renderingOnly: Bool = false) -> String {
        let parts = argument.split(separator: " ").map(String.init)
        guard parts.count == (renderingOnly ? 5 : 4), parts[3] == "controlled-empty-fixture",
              let pid = pid_t(parts[1]), pid > 0, let window = CGWindowID(parts[2]), window > 0,
              let saved = snapshot, saved.connection == connection, saved.bundle == parts[0],
              pass == nil, EposProbeInputController.sessionNormalIdle else {
            return "err session requires snapshot and controlled empty fixture"
        }
        let renderingNonce = renderingOnly ? parts[4] : nil
        if let renderingNonce {
            guard parts[0] == "com.mitchellh.ghostty",
                  renderingNonce.range(of: "^EPOS-SESSION-[A-Z0-9-]{1,64}$", options: .regularExpression) != nil else {
                return "err session rendering requires Ghostty fixture nonce"
            }
        }
        let fresh = EposProbeInputController.sessionCandidates(parts[0]).filter { !saved.controllers.contains(ObjectIdentifier($0)) }
        guard fresh.count == 1, let controller = fresh.first else {
            return "err session fresh-client-count fresh=\(fresh.count)"
        }
        guard let client = controller.client() else { return "err session fresh-client-unavailable fresh=1" }
        guard let bounds = targetBounds(pid: pid, window: window, bundle: parts[0], client: client,
                                        renderingNonce: renderingNonce) else {
            return "err session target gate=\(targetGate) windows=\(targetWindowCandidates) fresh=1"
        }
        guard let policy = ProbeSessionOwnership(controlledEmptyFixture: true, observation: observe(client, text: nil)) else {
            return "err session requires one fresh focused empty fixture client"
        }
        if renderingOnly {
            stopBarrier()
            barrierGate = "rendering-only"
        } else {
            guard startBarrier() else { return "err session event tap unavailable gate=\(barrierGate)" }
        }
        eventCount = 0
        callbackCount = 0
        discardCount = 0
        finalCount = 0
        previousFlags = CGEventSource.flagsState(.combinedSessionState)
        pass = Pass(controller: controller, client: client, connection: connection,
                    pid: pid, window: window, bundle: parts[0], renderingNonce: renderingNonce,
                    renderingBounds: renderingOnly ? bounds : nil, policy: policy)
        snapshot = nil
        return "ok session begun controlled-fixture=true rendering-only=\(renderingOnly)"
    }

    private static func mark(_ text: String, connection: UInt64) -> String {
        if pass?.renderingNonce != nil, text != "EPOS draft alpha", text != "EPOS draft beta" {
            return "err session rendering requires fixed draft"
        }
        guard !text.isEmpty, (text as NSString).length <= 256,
              !text.contains("\n"), !text.contains("\r") else { return "err session bounded single line required" }
        guard let current = operable(connection), let client = current.client,
              current.policy.canOperate(observe(client, text: current.text.isEmpty ? nil : current.text)) else {
            interrupt("mark-guard", mayDiscard: false)
            return "err session retired before mark"
        }
        client.setMarkedText(NSAttributedString(string: text, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            NSAttributedString.Key("NSMarkedClauseSegment"): 0,
        ]), selectionRange: NSRange(location: (text as NSString).length, length: 0), replacementRange: unavailable)
        // Native calls can reenter host callbacks. Never revive a retired pass.
        guard !current.policy.isRetired else { return "err session retired during mark" }
        if pass?.connection == connection { pass?.text = text }
        guard current.policy.didMark(observe(client, text: text), utf16Length: (text as NSString).length) else {
            return "err session retired after mark"
        }
        return "ok session marked"
    }

    private static func cancel(connection: UInt64) -> String {
        guard let current = operable(connection), let client = current.client,
              current.policy.canOperate(observe(client, text: current.text.isEmpty ? nil : current.text)) else {
            interrupt("cancel-guard", mayDiscard: false)
            return "err session retired before cancellation"
        }
        guard current.policy.isDraft else { return "ok session cancelled no draft" }
        discard(client)
        guard !current.policy.isRetired,
              current.policy.didDiscard(observe(client, text: nil)) else {
            return "err session retired after cancellation"
        }
        pass?.text = ""
        return "ok session cancelled controlled-baseline"
    }

    private static func final(_ text: String, connection: UInt64) -> String {
        if pass?.renderingNonce != nil, text != "EPOS final token" { return "err session rendering requires fixed final" }
        guard !text.isEmpty, (text as NSString).length <= 256,
              !text.contains("\n"), !text.contains("\r"),
              let current = operable(connection), let client = current.client,
              current.policy.permitsFinal,
              current.policy.canOperate(observe(client, text: nil)), current.policy.finish() else {
            return "err session final refused"
        }
        // Finished before insertText, so reentrancy cannot authorize another write.
        client.insertText(text, replacementRange: unavailable)
        finalCount += 1
        return "ok session final inserted"
    }

    private static func operable(_ connection: UInt64) -> Pass? {
        guard let current = pass, current.connection == connection,
              !current.policy.isRetired, current.policy.state != .finished,
              current.renderingNonce != nil || tap.map({ CGEvent.tapIsEnabled(tap: $0) }) == true,
              let controller = current.controller, let client = current.client,
              controller.client() === client,
              targetBounds(pid: current.pid, window: current.window, bundle: current.bundle, client: client,
                           renderingNonce: current.renderingNonce, expectedBounds: current.renderingBounds) != nil else {
            interrupt("target-or-barrier", mayDiscard: false)
            return nil
        }
        return current
    }

    private static func inspect(connection: UInt64) -> String {
        guard let current = pass, current.connection == connection else { return "err session wrong connection" }
        let selected = current.client?.selectedRange() ?? unavailable
        let marked = current.client?.markedRange() ?? unavailable
        let state: String
        switch current.policy.state {
        case .ready: state = "ready"
        case .committing: state = "committing"
        case .draft: state = "draft"
        case .retired(let reason): state = "retired-\(reason)"
        case .finished: state = "finished"
        }
        return "ok session state=\(state) selection=\(selected.location),\(selected.length) "
            + "marked=\(marked.location),\(marked.length) events=\(eventCount) callbacks=\(callbackCount) "
            + "discards=\(discardCount) finals=\(finalCount) tap=\(tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false) "
            + "rendering-only=\(current.renderingNonce != nil) "
            + "target=\(targetGate) windows=\(targetWindowCandidates) barrier=\(barrierGate)"
    }

    static func hostCallback(_ controller: EposProbeInputController, reason: String) {
        guard pass?.controller === controller else { return }
        callbackCount += 1
        if discarding { return }
        interrupt(reason, mayDiscard: true)
    }

    static func disconnect(_ connection: UInt64) {
        if snapshot?.connection == connection { snapshot = nil }
        guard pass?.connection == connection else { return }
        interrupt("disconnect", mayDiscard: true)
        stopBarrier()
        // Keep the retired metadata until explicit reset/new process, so another
        // peer cannot adopt a stale client as a new controlled empty fixture.
    }

    private static func interrupt(_ reason: String, mayDiscard: Bool) {
        guard let current = pass else { return }
        let canDiscard = mayDiscard && current.policy.isDraft && current.client.map {
            current.controller?.client() === $0 && $0.bundleIdentifier() == current.bundle
                && current.policy.canOperate(observe($0, text: current.text))
        } == true
        current.policy.interrupt(reason) {
            if canDiscard, let client = current.client { discard(client) }
        }
    }

    private static func discard(_ client: IMKTextInput & NSObjectProtocol) {
        discardCount += 1
        discarding = true
        defer { discarding = false }
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: unavailable)
        let selector = NSSelectorFromString("unmarkText")
        if client.responds(to: selector) { _ = client.perform(selector) }
    }

    private static func observe(_ client: IMKTextInput & NSObjectProtocol, text: String?) -> ProbeSessionOwnership.Observation {
        let marked = client.markedRange()
        let expected = text.map { (range: marked, text: $0) }
        return .init(selection: client.selectedRange(), marked: marked,
                     composition: ProbePreviewSafety.compositionState(markedRange: marked, expected: expected) {
                         client.attributedSubstring(from: $0)?.string
                     })
    }

    private static func targetBounds(pid: pid_t, window: CGWindowID, bundle: String, client: IMKTextInput,
                                     renderingNonce: String? = nil, expectedBounds: CGRect? = nil) -> CGRect? {
        targetWindowCandidates = 0
        targetGate = renderingNonce == nil ? "front-pid" : "rendering-target-frontmost"
        if renderingNonce == nil {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        } else {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return nil }
        }
        targetGate = "bundle"
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundle,
              client.bundleIdentifier() == bundle else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        targetGate = "focused-window-unavailable"
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        if let renderingNonce {
            var title: CFTypeRef?
            targetGate = "fixture-window-title"
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
                  title as? String == renderingNonce else { return nil }
        }
        targetGate = "focused-frame-unavailable"
        guard let focusedBounds = ProbeSessionWindow.focusedBounds(element, pid: pid) else { return nil }
        targetGate = "windows-unavailable"
        guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let match = ProbeSessionWindow.match(pid: pid, window: window, focusedBounds: focusedBounds, windows: windows,
                                             requireOnScreen: renderingNonce == nil, expectedBounds: expectedBounds)
        targetGate = match.gate
        targetWindowCandidates = match.candidates
        guard let rect = match.bounds else { return nil }
        var caret = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        targetGate = "caret-unavailable"
        guard caret.origin.x.isFinite, caret.origin.y.isFinite, caret.height > 1 else { return nil }
        // IMK rectangles use bottom-left coordinates; CGWindow bounds use the
        // main screen's top-left origin. Keep the known fixture inside its window.
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        let flipped = CGRect(x: caret.minX, y: screenHeight - caret.maxY, width: max(caret.width, 1), height: caret.height)
        if renderingNonce != nil {
            let bundlePIDs = Set(windows.compactMap { info -> pid_t? in
                guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                      NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == bundle else { return nil }
                return owner
            })
            targetGate = "rendering-caret-ambiguous"
            guard ProbeSessionWindow.exclusiveCaret(flipped, pid: pid, window: window, bundlePIDs: bundlePIDs,
                                                    windows: windows) else { return nil }
        }
        targetGate = rect.intersects(flipped) ? "ready" : "caret-outside-window"
        return targetGate == "ready" ? rect : nil
    }

    private static func startBarrier() -> Bool {
        stopBarrier()
        // CGEventTapCreate may silently remove keyboard mask bits when the
        // process lacks assistive access, while still creating a mouse tap.
        barrierGate = "ax-trust"
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown,
                                   .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        barrierGate = "tap-create"
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: { _, type, event, _ in
            ProbeSessionPrototype.received(type, event: event)
            return Unmanaged.passUnretained(event)
        }, userInfo: nil), let source = CFMachPortCreateRunLoopSource(nil, created, 0) else { return false }
        tap = created
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        barrierGate = "tap-mask"
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else {
            stopBarrier()
            return false
        }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success,
              taps.prefix(Int(count)).contains(where: {
                  $0.tappingProcess == getpid() && $0.enabled && $0.eventsOfInterest & mask == mask
              }) else {
            stopBarrier()
            return false
        }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            if let current = pass, NSWorkspace.shared.frontmostApplication?.processIdentifier != current.pid {
                interrupt("focus", mayDiscard: true)
            }
        }
        barrierGate = CGEvent.tapIsEnabled(tap: created) ? "ready" : "tap-disabled"
        return barrierGate == "ready"
    }

    private static func received(_ type: CGEventType, event: CGEvent) {
        precondition(Thread.isMainThread)
        guard pass != nil else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interrupt("tap-disabled", mayDiscard: false)
            return
        }
        eventCount += 1
        if type == .flagsChanged {
            let changed = event.flags.symmetricDifference(previousFlags)
            previousFlags = event.flags
            if ProbeSessionOwnership.ignoresFlagsChange(changed.rawValue, fnMask: CGEventFlags.maskSecondaryFn.rawValue) { return }
        }
        interrupt("input", mayDiscard: true)
    }

    private static func stopBarrier() {
        if let observer = focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        focusObserver = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tapSource = nil
        tap = nil
    }
}
#endif

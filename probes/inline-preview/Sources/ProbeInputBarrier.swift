import AppKit
import ApplicationServices
import Carbon

/// Clears preview synchronously before returning ordinary input to the host.
/// Host callbacks remain necessary because focus and source changes need no input.
final class ProbeInputBarrier {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var focusObserver: NSObjectProtocol?
    private var sourceObserver: NSObjectProtocol?
    private var previousFlags = CGEventSource.flagsState(.combinedSessionState)
    private let interrupt: (String, Bool) -> Void
    private var heldKey: UInt16?
    private let shortcut: DictationShortcut?

    init?(targetBundle: String, holdKey: UInt16? = nil, shortcut: DictationShortcut? = nil,
          interrupt: @escaping (String, Bool) -> Void) {
        self.interrupt = interrupt
        heldKey = holdKey
        self.shortcut = shortcut
        guard AXIsProcessTrusted() else { return nil }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown,
                                   .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                   .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let barrier = Unmanaged<ProbeInputBarrier>.fromOpaque(context).takeUnretainedValue()
                return barrier.receive(type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let runLoopSource = CFMachPortCreateRunLoopSource(nil, created, 0) else { return nil }
        tap = created
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        // Creation can succeed with keyboard mask bits silently removed.
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { stop(); return nil }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success,
              taps.prefix(Int(count)).contains(where: {
                  $0.tappingProcess == getpid() && $0.enabled && $0.eventsOfInterest & mask == mask
              }) else { stop(); return nil }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.bundleIdentifier == targetBundle else { return }
            self?.interrupt("focus", true)
        }
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in
            if !Self.eposIsSelected { self?.interrupt("input-source", true) }
        }
    }

    var enabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } == true }

    static var eposIsSelected: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
              let identifier = Bundle.main.bundleIdentifier else { return false }
        return (Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String) == identifier
    }

    private func receive(_ type: CGEventType, event: CGEvent) -> Bool {
        precondition(Thread.isMainThread)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interrupt("tap-disabled", false)
            return false
        }
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if Self.ignoresInput(type, flags: event.flags, previousFlags: &previousFlags,
                            heldKey: &heldKey, shortcut: shortcut,
                            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                            isRepeat: repeated) {
            // Consume held-key repeats here, before either the main tap or host.
            // A fresh matching shortcut must continue to the main deferred press.
            return type == .keyDown && repeated
        }
        interrupt("input", true)
        return false
    }

    static func holdKey(from token: String) -> UInt16? {
        guard token.hasPrefix("hold-key="), let code = UInt16(token.dropFirst("hold-key=".count)), code < 128 else { return nil }
        return code
    }

    static func holdShortcut(keyToken: String, flagsToken: String) -> DictationShortcut? {
        guard let key = holdKey(from: keyToken), flagsToken.hasPrefix("hold-flags="),
              let flags = UInt64(flagsToken.dropFirst("hold-flags=".count)) else { return nil }
        return DictationShortcut(modifierFlags: flags, keyCode: key)
    }

    static func ignoresInput(_ type: CGEventType, flags: CGEventFlags, previousFlags: inout CGEventFlags,
                             heldKey: inout UInt16?, shortcut: DictationShortcut? = nil,
                             keyCode: UInt16? = nil, isRepeat: Bool = false) -> Bool {
        if type == .keyDown, isRepeat, let heldKey, keyCode == heldKey { return true }
        if type == .keyDown, !isRepeat, let shortcut, let keyCode,
           shortcut.keyCode == keyCode,
           DictationShortcut.keyEventFlags(flags.rawValue, keyCode: keyCode,
                                           trackedModifiers: DictationShortcut.normalizedFlags(previousFlags.rawValue)) == shortcut.modifierFlags {
            heldKey = keyCode
            return true
        }
        // Releases cannot edit the target. This includes a configured hold key.
        if type == .keyUp {
            if keyCode == heldKey { heldKey = nil }
            return true
        }
        guard type == .flagsChanged else { return false }
        let changed = flags.symmetricDifference(previousFlags)
        previousFlags = flags
        // Modifier-only holds release during finalization. Other keyDown
        // events retire the pass unless they match the configured shortcut.
        return changed.subtracting([.maskSecondaryFn, .maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty
    }

    func stop() {
        if let observer = focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = sourceObserver { DistributedNotificationCenter.default().removeObserver(observer) }
        focusObserver = nil
        sourceObserver = nil
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    deinit { stop() }
}

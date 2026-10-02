import AppKit
import CoreGraphics
import Foundation

/// Push-to-talk edges and consumption of the configured shortcut's key.
@MainActor
public final class DictationHotkey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?
    public private(set) var shortcut: DictationShortcut
    public static let stuckKeyReconcileInterval: Duration = .milliseconds(500)

    private static let log = EposLogger(category: "coordinator")
    private static let processID = Int64(ProcessInfo.processInfo.processIdentifier)
    private var monitor: Any?
    private var isDown = false
    private var isRecordingShortcut = false
    private var trackedModifiers: UInt64 = 0
    private var consumedKeys: Set<UInt16> = []
    private var reconcileTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var pendingEdges: [Bool] = []
    private var deliveredPress = false
    private let hardwareStateReader: (@MainActor () -> Bool)?
    private let keyStateReader: @MainActor (UInt16) -> Bool
    private let reconcileInterval: Duration
    // Existing coordinator tests inject a lifecycle-only monitor and fn state.
    private let installMonitor: (@MainActor (@escaping @Sendable @MainActor (Bool) -> Void) -> Any?)?
    private let removeMonitor: @MainActor (Any) -> Void
    private let enableMonitor: @MainActor (Any) -> Void

    public var isShortcutHeld: Bool {
        guard !isRecordingShortcut else { return false }
        if let hardwareStateReader { return hardwareStateReader() }
        let flags = DictationShortcut.normalizedFlags(
            CGEventSource.flagsState(.hidSystemState).rawValue
        )
        guard flags & shortcut.modifierFlags == shortcut.modifierFlags else { return false }
        return shortcut.keyCode.map { CGEventSource.keyState(.hidSystemState, key: $0) } ?? true
    }

    public init(
        shortcut: DictationShortcut = .functionKey,
        hardwareStateReader: (@MainActor () -> Bool)? = nil,
        reconcileInterval: Duration = DictationHotkey.stuckKeyReconcileInterval,
        keyStateReader: (@MainActor (UInt16) -> Bool)? = nil,
        installMonitor: (@MainActor (@escaping @Sendable @MainActor (Bool) -> Void) -> Any?)? = nil,
        removeMonitor: (@MainActor (Any) -> Void)? = nil,
        enableMonitor: (@MainActor (Any) -> Void)? = nil
    ) {
        self.shortcut = shortcut
        self.hardwareStateReader = hardwareStateReader
        self.keyStateReader = keyStateReader ?? { CGEventSource.keyState(.hidSystemState, key: $0) }
        self.reconcileInterval = reconcileInterval
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor ?? { ($0 as? DictationEventTap)?.stop() }
        self.enableMonitor = enableMonitor ?? { ($0 as? DictationEventTap)?.enable() }
    }

    public func start() {
        guard monitor == nil else { return }
        if let installMonitor {
            monitor = installMonitor { [weak self] in self?.handleFlagsChanged(pressed: $0) }
        } else {
            monitor = DictationEventTap { [weak self] in self?.handleEvent($0) ?? false }
        }
    }

    public func stop() {
        if let monitor {
            removeMonitor(monitor)
            self.monitor = nil
        }
        stopReconciling()
        cancelPendingNotifications()
        isDown = false
        deliveredPress = false
        trackedModifiers = 0
        consumedKeys.removeAll()
    }

    public func setShortcut(_ shortcut: DictationShortcut) {
        guard self.shortcut != shortcut else { return }
        setHeld(false)
        self.shortcut = shortcut
    }

    public func setRecordingShortcut(_ recording: Bool) {
        guard isRecordingShortcut != recording else { return }
        isRecordingShortcut = recording
        if recording {
            isDown = false
            if consumedKeys.isEmpty { stopReconciling() }
            cancelPendingNotifications()
            if deliveredPress { enqueueEdge(false) }
        }
    }

    /// Returns synchronously whether the tap must delete this event. Coordinator
    /// callbacks run in a later task, so AX capture and microphone setup never
    /// execute inside the tap callback's timeout budget.
    @discardableResult
    func handleEvent(_ event: DictationKeyEvent) -> Bool {
        if event.kind == .tapDisabled {
            if let monitor { enableMonitor(monitor) }
            reconcileHardwareState()
            return false
        }
        // Final delivery posts Unicode keycode-zero events with cleared flags.
        // They must pass even when a physical A key is still consumed or another
        // dictation press has been deferred through finalization.
        guard event.sourceProcessID != Self.processID else { return false }
        if event.kind == .flagsChanged {
            trackedModifiers = DictationShortcut.normalizedFlags(event.modifierFlags)
        }
        if consumedKeys.contains(event.keyCode), event.kind == .keyDown || event.kind == .keyUp {
            if event.kind == .keyDown, !event.isRepeat {
                // A fresh press proves the previous keyUp was lost. Do not wait
                // for the 500 ms backstop and swallow the user's new key.
                consumedKeys.remove(event.keyCode)
                if event.keyCode == shortcut.keyCode { setHeld(false) }
                if consumedKeys.isEmpty, !isDown { stopReconciling() }
            } else {
                if event.kind == .keyUp {
                    consumedKeys.remove(event.keyCode)
                    if event.keyCode == shortcut.keyCode { setHeld(false) }
                    if consumedKeys.isEmpty, !isDown { stopReconciling() }
                }
                return true
            }
        }
        guard !isRecordingShortcut else { return false }

        let modifiers = event.kind == .flagsChanged ? trackedModifiers
            : DictationShortcut.keyEventFlags(
                event.modifierFlags, keyCode: event.keyCode, trackedModifiers: trackedModifiers
            )
        if isDown, event.kind == .flagsChanged,
           modifiers & shortcut.modifierFlags != shortcut.modifierFlags { setHeld(false) }

        if event.kind == .flagsChanged {
            if shortcut.keyCode == nil, !isDown, modifiers == shortcut.modifierFlags { setHeld(true) }
            return false
        }
        guard event.kind == .keyDown, !event.isRepeat,
              event.keyCode == shortcut.keyCode, modifiers == shortcut.modifierFlags else { return false }
        consumedKeys.insert(event.keyCode)
        setHeld(true)
        return true
    }

    // Lifecycle-only monitor seam retained for the coordinator's trust tests.
    func handleFlagsChanged(pressed: Bool) {
        handleEvent(DictationKeyEvent(
            kind: .flagsChanged, modifierFlags: pressed ? DictationShortcut.functionFlag : 0
        ))
    }

    func reconcileHardwareState() {
        consumedKeys = consumedKeys.filter { keyStateReader($0) }
        if isDown, !isShortcutHeld {
            Self.log.info("shortcut release reconciled: hardware reports the binding up, no release event arrived")
            setHeld(false)
        }
        if consumedKeys.isEmpty, !isDown { stopReconciling() }
    }

    private func setHeld(_ pressed: Bool) {
        guard pressed != isDown else { return }
        isDown = pressed
        if pressed { startReconciling() } else if consumedKeys.isEmpty { stopReconciling() }
        enqueueEdge(pressed)
    }

    private func enqueueEdge(_ pressed: Bool) {
        pendingEdges.append(pressed)
        guard notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let edges = self.pendingEdges
            self.pendingEdges.removeAll()
            self.notificationTask = nil
            for pressed in edges {
                self.deliveredPress = pressed
                if pressed { self.onPress?() } else { self.onRelease?() }
            }
        }
    }

    private func cancelPendingNotifications() {
        notificationTask?.cancel()
        notificationTask = nil
        pendingEdges.removeAll()
    }

    private func startReconciling() {
        stopReconciling()
        let interval = reconcileInterval
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.isDown || !self.consumedKeys.isEmpty else { return }
                self.reconcileHardwareState()
            }
        }
    }

    private func stopReconciling() {
        reconcileTask?.cancel()
        reconcileTask = nil
    }
}

/// The native adapter owns the tap, source, and callback lifetime together.
@MainActor
private final class DictationEventTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: @MainActor (DictationKeyEvent) -> Bool

    init?(handler: @escaping @MainActor (DictationKeyEvent) -> Bool) {
        self.handler = handler
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let kind: DictationKeyEvent.Kind
                switch type {
                case .flagsChanged: kind = .flagsChanged
                case .keyDown: kind = .keyDown
                case .keyUp: kind = .keyUp
                case .tapDisabledByTimeout, .tapDisabledByUserInput: kind = .tapDisabled
                default: return Unmanaged.passUnretained(event)
                }
                let input = DictationKeyEvent(
                    kind: kind, modifierFlags: event.flags.rawValue,
                    keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    sourceProcessID: event.getIntegerValueField(.eventSourceUnixProcessID)
                )
                let consumed = MainActor.assumeIsolated {
                    Unmanaged<DictationEventTap>.fromOpaque(context).takeUnretainedValue().handler(input)
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return nil }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func enable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    isolated deinit { stop() }
}

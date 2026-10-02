import AppKit
import SwiftUI

/// Opens a key window because the menu popover does not accept keyboard focus.
public struct ShortcutRecorderView: View {
    private let shortcut: DictationShortcut
    private let isEnabled: Bool
    private let onChange: (DictationShortcut) -> Void
    private let onRecordingChange: (Bool) -> Bool
    @State private var recorder: ShortcutRecorderController?

    public init(
        shortcut: DictationShortcut,
        isEnabled: Bool,
        onChange: @escaping (DictationShortcut) -> Void,
        onRecordingChange: @escaping (Bool) -> Bool
    ) {
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
    }

    public var body: some View {
        Button(shortcut.displayName) {
            let recorder = ShortcutRecorderController(
                onChange: onChange, onRecordingChange: onRecordingChange
            )
            self.recorder = recorder
            recorder.present()
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.78))
        .disabled(!isEnabled)
        .help("Change the hold-to-dictate shortcut")
    }
}

@MainActor
private final class ShortcutRecorderController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var message = ""
    private var recording = ShortcutRecording()
    private var panel: NSPanel?
    private var monitor: Any?
    private var completed = false
    private let onChange: (DictationShortcut) -> Void
    private let onRecordingChange: (Bool) -> Bool
    // The menu closes when this panel activates. Retain the recorder until close.
    private var lifetime: ShortcutRecorderController?

    init(
        onChange: @escaping (DictationShortcut) -> Void,
        onRecordingChange: @escaping (Bool) -> Bool
    ) {
        self.onChange = onChange
        self.onRecordingChange = onRecordingChange
    }

    func present() {
        guard onRecordingChange(true) else { return }
        lifetime = self
        recording = ShortcutRecording(initialModifierFlags: UInt64(NSEvent.modifierFlags.rawValue))
        message = recording.message
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 160),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        panel.title = "Dictation shortcut"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ShortcutRecorderPanel(controller: self))
        self.panel = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
            [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.handle(event)
            return nil
        }
        panel.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) {
        let kind: DictationKeyEvent.Kind
        switch event.type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return
        }
        let result = recording.handle(DictationKeyEvent(
            kind: kind, modifierFlags: UInt64(event.modifierFlags.rawValue),
            keyCode: event.keyCode, isRepeat: event.type == .keyDown && event.isARepeat
        ))
        message = recording.message
        if let result { finish(result) }
    }

    func reset() {
        let result = recording.resetToFunctionKey()
        message = recording.message
        if let result { finish(result) }
    }

    func cancel() { finish(.cancelled) }

    func windowWillClose(_ notification: Notification) { finish(.cancelled) }

    /// Closing or cancellation must also remove the suspension when focus leaves
    /// the recording panel, where release events would no longer reach it.
    func windowDidResignKey(_ notification: Notification) { finish(.cancelled) }

    private func finish(_ result: ShortcutRecording.Result) {
        guard !completed else { return }
        completed = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.close()
        panel = nil
        _ = onRecordingChange(false)
        if case .shortcut(let shortcut) = result { onChange(shortcut) }
        lifetime = nil
    }
}

private struct ShortcutRecorderPanel: View {
    @ObservedObject var controller: ShortcutRecorderController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(controller.message)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            HStack {
                Button("Use fn") { controller.reset() }
                Spacer()
                Button("Cancel") { controller.cancel() }
            }
        }
        .padding(20)
        .frame(width: 390, height: 160)
    }
}

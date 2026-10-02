import Carbon
import Foundation

/// Captures one chord and yields it only after every observed key is released.
struct ShortcutRecording {
    enum Result: Equatable {
        case shortcut(DictationShortcut)
        case cancelled
    }

    private(set) var message = "Hold modifiers, or modifiers and one key. Then release."
    private var modifiers: UInt64
    private var heldKeys: Set<UInt16> = []
    private var candidate: DictationShortcut?
    private var invalidChord = false
    private var candidateFrozen = false
    private var waitingForInitialRelease: Bool

    init(initialModifierFlags: UInt64 = 0) {
        modifiers = DictationShortcut.normalizedFlags(initialModifierFlags)
        waitingForInitialRelease = modifiers != 0
        if waitingForInitialRelease { message = "Release the held modifiers, then record a shortcut." }
    }

    mutating func handle(_ event: DictationKeyEvent) -> Result? {
        switch event.kind {
        case .flagsChanged:
            modifiers = DictationShortcut.normalizedFlags(event.modifierFlags)
            if !waitingForInitialRelease, !invalidChord, !candidateFrozen, heldKeys.isEmpty, modifiers != 0 {
                // Modifier releases must not overwrite the full combination.
                if modifiers.nonzeroBitCount >= (candidate?.modifierFlags.nonzeroBitCount ?? 0) {
                    candidate = DictationShortcut(modifierFlags: modifiers)
                    message = "\(candidate?.displayName ?? ""). Release to save."
                }
            }
        case .keyDown:
            guard !event.isRepeat else { return nil }
            let flags = DictationShortcut.keyEventFlags(
                event.modifierFlags, keyCode: event.keyCode, trackedModifiers: modifiers
            )
            if event.keyCode == UInt16(kVK_Escape), flags == 0 { return .cancelled }
            heldKeys.insert(event.keyCode)
            guard !waitingForInitialRelease else { return nil }
            if heldKeys.count > 1 {
                reject("Use one key with modifiers.")
            } else if let shortcut = DictationShortcut(modifierFlags: flags, keyCode: event.keyCode) {
                candidate = shortcut
                candidateFrozen = true
                message = "\(shortcut.displayName). Release all keys to save."
            } else {
                reject("Include Command, Control, Option, Shift, or fn.")
            }
        case .keyUp:
            heldKeys.remove(event.keyCode)
        case .tapDisabled:
            return nil
        }
        guard modifiers == 0, heldKeys.isEmpty else { return nil }
        if waitingForInitialRelease {
            waitingForInitialRelease = false
            message = "Hold modifiers, or modifiers and one key. Then release."
            return nil
        }
        if let candidate, !invalidChord { return .shortcut(candidate) }
        invalidChord = false
        candidateFrozen = false
        candidate = nil
        return nil
    }

    mutating func resetToFunctionKey() -> Result? {
        candidate = .functionKey
        candidateFrozen = true
        invalidChord = false
        waitingForInitialRelease = false
        if modifiers == 0, heldKeys.isEmpty { return .shortcut(.functionKey) }
        message = "Release all keys to use fn."
        return nil
    }

    private mutating func reject(_ message: String) {
        candidate = nil
        invalidChord = true
        self.message = message
    }
}

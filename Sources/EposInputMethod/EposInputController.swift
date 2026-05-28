import AppKit
import Carbon
import InputMethodKit

@objc(EposInputController)
final class EposInputController: IMKInputController {
    private static let diagnosticTriggerKey = "d"
    private static let diagnosticTriggerKeyCode = 2
    private static let diagnosticTriggerModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]
    private static let diagnosticText = "Epos input method diagnostic"
    private static let replacementRange = NSRange(location: NSNotFound, length: NSNotFound)
    private static let unmarkTextSelector = NSSelectorFromString("unmarkText")
    nonisolated(unsafe) private static weak var activeController: EposInputController?

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.activeController = self
        guard let keyboardLayout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return
        }
        _ = TISSetInputMethodKeyboardLayoutOverride(keyboardLayout)
    }

    override func deactivateServer(_ sender: Any!) {
        if Self.activeController === self {
            Self.activeController = nil
        }
        super.deactivateServer(sender)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        if Self.shouldCommitDiagnosticText(from: event) {
            return commitText(Self.diagnosticText, to: sender)
        }
        return commitPassthroughText(event.characters, flags: event.modifierFlags, to: sender)
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        commitPassthroughText(string, to: sender)
    }

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        if Self.shouldCommitDiagnosticText(keyCode: keyCode, modifiers: flags) {
            return commitText(Self.diagnosticText, to: sender)
        }
        return commitPassthroughText(string, modifiers: flags, to: sender)
    }

    override func commitComposition(_ sender: Any!) {
    }

    static func commitExternalText(_ text: String) -> Bool {
        guard let activeController else { return false }
        return activeController.commitText(text, to: activeController.client())
    }

    static func updateExternalMarkedText(_ text: String) -> Bool {
        guard let activeController else { return false }
        return activeController.updateMarkedText(text, to: activeController.client())
    }

    static func cancelExternalMarkedText() -> Bool {
        guard let activeController else { return false }
        return activeController.cancelMarkedText(to: activeController.client())
    }

    private static func shouldCommitDiagnosticText(from event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.charactersIgnoringModifiers?.lowercased() == diagnosticTriggerKey
            && flags.intersection(diagnosticTriggerModifiers) == diagnosticTriggerModifiers
            && !flags.contains(.command)
    }

    private static func shouldCommitDiagnosticText(keyCode: Int, modifiers rawFlags: Int) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(rawFlags)).intersection(.deviceIndependentFlagsMask)
        return keyCode == diagnosticTriggerKeyCode
            && flags.intersection(diagnosticTriggerModifiers) == diagnosticTriggerModifiers
            && !flags.contains(.command)
    }

    private static func passthroughText(_ string: String?, modifiers rawFlags: Int? = nil) -> String? {
        guard let string, !string.isEmpty else { return nil }
        if let rawFlags {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(rawFlags)).intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.control) {
                return nil
            }
        }
        guard string.unicodeScalars.allSatisfy({ scalar in !CharacterSet.controlCharacters.contains(scalar) }) else {
            return nil
        }
        return string
    }

    private static func passthroughText(_ string: String?, flags: NSEvent.ModifierFlags) -> String? {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) {
            return nil
        }
        return passthroughText(string)
    }

    private func commitText(_ text: String, to sender: Any?) -> Bool {
        guard !text.isEmpty else { return true }

        if let client = sender as? IMKTextInput {
            client.insertText(text, replacementRange: Self.replacementRange)
            return true
        }
        if let client = sender as? NSTextInputClient {
            client.insertText(text, replacementRange: Self.replacementRange)
            return true
        }
        if let client = self.client() {
            client.insertText(text, replacementRange: Self.replacementRange)
            return true
        }
        return false
    }

    private func commitPassthroughText(_ string: String?, modifiers rawFlags: Int? = nil, to sender: Any?) -> Bool {
        guard let text = Self.passthroughText(string, modifiers: rawFlags) else {
            return false
        }
        return commitText(text, to: sender)
    }

    private func commitPassthroughText(_ string: String?, flags: NSEvent.ModifierFlags, to sender: Any?) -> Bool {
        guard let text = Self.passthroughText(string, flags: flags) else {
            return false
        }
        return commitText(text, to: sender)
    }

    private func updateMarkedText(_ text: String, to sender: Any?) -> Bool {
        guard !text.isEmpty else { return cancelMarkedText(to: sender) }
        let selectionRange = NSRange(location: (text as NSString).length, length: 0)

        if let client = sender as? IMKTextInput {
            client.setMarkedText(text, selectionRange: selectionRange, replacementRange: Self.replacementRange)
            return true
        }
        if let client = sender as? NSTextInputClient {
            client.setMarkedText(text, selectedRange: selectionRange, replacementRange: Self.replacementRange)
            return true
        }
        if let client = self.client() {
            client.setMarkedText(text, selectionRange: selectionRange, replacementRange: Self.replacementRange)
            return true
        }
        return false
    }

    private func cancelMarkedText(to sender: Any?) -> Bool {
        if let client = sender as? NSTextInputClient {
            client.unmarkText()
            return true
        }
        if Self.performUnmarkText(on: sender) {
            return true
        }
        if let client = self.client() as? NSTextInputClient {
            client.unmarkText()
            return true
        }
        if Self.performUnmarkText(on: self.client()) {
            return true
        }
        return false
    }

    private static func performUnmarkText(on target: Any?) -> Bool {
        guard let object = target as? NSObjectProtocol,
              object.responds(to: unmarkTextSelector) else {
            return false
        }

        _ = object.perform(unmarkTextSelector)
        return true
    }
}

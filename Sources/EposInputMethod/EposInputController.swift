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

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        guard let keyboardLayout = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return
        }
        _ = TISSetInputMethodKeyboardLayoutOverride(keyboardLayout)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event,
              event.type == .keyDown,
              Self.shouldCommitDiagnosticText(from: event) else {
            return false
        }
        return commitDiagnosticText(to: sender)
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        false
    }

    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard Self.shouldCommitDiagnosticText(keyCode: keyCode, modifiers: flags) else { return false }
        return commitDiagnosticText(to: sender)
    }

    override func commitComposition(_ sender: Any!) {
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

    private func commitDiagnosticText(to sender: Any?) -> Bool {
        if let client = sender as? IMKTextInput {
            client.insertText(Self.diagnosticText, replacementRange: Self.replacementRange)
            return true
        }
        if let client = sender as? NSTextInputClient {
            client.insertText(Self.diagnosticText, replacementRange: Self.replacementRange)
            return true
        }
        if let client = self.client() {
            client.insertText(Self.diagnosticText, replacementRange: Self.replacementRange)
            return true
        }
        return false
    }
}

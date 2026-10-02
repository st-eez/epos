import Carbon
import CoreGraphics
import Foundation

/// One physical key, optionally, held with one or more supported modifiers.
public struct DictationShortcut: Codable, Equatable, Sendable {
    public let modifierFlags: UInt64
    public let keyCode: UInt16?

    static let functionFlag = CGEventFlags.maskSecondaryFn.rawValue
    static let supportedModifierFlags = CGEventFlags([
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn
    ]).rawValue

    public static let functionKey = DictationShortcut(validatedFlags: functionFlag, keyCode: nil)

    public init?(modifierFlags: UInt64, keyCode: UInt16? = nil) {
        guard modifierFlags != 0,
              modifierFlags & ~Self.supportedModifierFlags == 0,
              keyCode.map(Self.isRecordableKey) ?? true else { return nil }
        self.init(validatedFlags: modifierFlags, keyCode: keyCode)
    }

    private init(validatedFlags: UInt64, keyCode: UInt16?) {
        self.modifierFlags = validatedFlags
        self.keyCode = keyCode
    }

    private enum CodingKeys: String, CodingKey { case modifierFlags, keyCode }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let flags = try container.decode(UInt64.self, forKey: .modifierFlags)
        let keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        guard let shortcut = Self(modifierFlags: flags, keyCode: keyCode) else {
            throw DecodingError.dataCorruptedError(
                forKey: .modifierFlags, in: container, debugDescription: "Invalid dictation shortcut"
            )
        }
        self = shortcut
    }

    public var displayName: String {
        var name = ""
        for (flag, label) in [
            (CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"),
            (.maskShift, "⇧"), (.maskCommand, "⌘"), (.maskSecondaryFn, "fn")
        ] where modifierFlags & flag.rawValue != 0 {
            name += label
        }
        if let keyCode {
            if modifierFlags & Self.functionFlag != 0 { name += " " }
            name += Self.keyName(keyCode)
        }
        return name
    }

    static func normalizedFlags(_ flags: UInt64) -> UInt64 {
        flags & supportedModifierFlags
    }

    /// Navigation and function key events can carry fn without a physical fn
    /// press. Ordinary keys retain their event flags, including cleared flags on
    /// Epos's synthesized Unicode events.
    static func keyEventFlags(_ flags: UInt64, keyCode: UInt16, trackedModifiers: UInt64) -> UInt64 {
        let normalized = normalizedFlags(flags)
        guard implicitFunctionKeys.contains(keyCode) else { return normalized }
        return (normalized & ~functionFlag) | (trackedModifiers & functionFlag)
    }

    private static let implicitFunctionKeys = Set([
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
        kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
        kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ].map(UInt16.init))

    static func isRecordableKey(_ keyCode: UInt16) -> Bool {
        keyCode < 128 && ![
            kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift,
            kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
            kVK_Function, kVK_CapsLock
        ].contains(Int(keyCode))
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        let namedKeys: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Delete: "Delete", kVK_ForwardDelete: "Forward Delete", kVK_Escape: "Escape",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_ANSI_KeypadEnter: "Enter", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
            kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
            kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
        ]
        if let name = namedKeys[Int(keyCode)] { return name }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "Key \(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "Key \(keyCode)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
            characters.count, &length, &characters
        )
        guard status == noErr, length > 0 else { return "Key \(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

struct DictationKeyEvent: Equatable, Sendable {
    enum Kind: Sendable { case flagsChanged, keyDown, keyUp, tapDisabled }
    let kind: Kind
    var modifierFlags: UInt64 = 0
    var keyCode: UInt16 = 0
    var isRepeat = false
    var sourceProcessID: Int64 = 0
}

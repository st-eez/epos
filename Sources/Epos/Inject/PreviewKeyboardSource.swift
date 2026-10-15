import Carbon
import Foundation

enum PreviewKeyboardSourceStatus: String {
    case missing, disabled, available, selected

    var setupMessage: String? {
        switch self {
        case .missing:
            "The Epos input source is missing. Reinstall Epos with its signed installer."
        case .disabled:
            "Add EposProbe in Keyboard settings, Text Input, then select it in the input menu."
        case .available:
            "For live text in Ghostty, select EposProbe in the input menu."
        case .selected:
            nil
        }
    }
}

@MainActor
protocol PreviewKeyboardSourceAccess {
    func currentIdentifier() -> String?
    func currentIsLayout() -> Bool
    func layoutIdentifier() -> String?
    func companionIsAvailable() -> Bool
    func select(_ identifier: String) -> Bool
}

/// A recording adopts an already selected companion or borrows it temporarily.
/// Teardown preserves the user's selected source.
@MainActor
final class PreviewKeyboardSource {
    static let companionIdentifier = "com.steez.inputmethod.EposProbe"
    static var status: PreviewKeyboardSourceStatus { NativePreviewKeyboardSourceAccess().companionStatus() }
    let acquisitionArgument: String
    private let previousIdentifier: String?
    private let access: any PreviewKeyboardSourceAccess
    private var released = false

    init?(access: any PreviewKeyboardSourceAccess = NativePreviewKeyboardSourceAccess()) {
        guard access.companionIsAvailable(),
              let previous = access.currentIdentifier(),
              let layout = access.layoutIdentifier() else { return nil }
        if previous == Self.companionIdentifier {
            guard access.currentIdentifier() == previous else { return nil }
            self.access = access
            previousIdentifier = nil
            acquisitionArgument = "adopt-layout \(previous) \(layout)"
            return
        }
        let kind = access.currentIsLayout() ? "acquire-layout" : "acquire-method"
        guard access.select(Self.companionIdentifier),
              access.currentIdentifier() == Self.companionIdentifier else {
            // A successful select is not sufficient: activation is acknowledged
            // separately by the companion before any provisional write.
            if access.currentIdentifier() == Self.companionIdentifier {
                _ = access.select(previous)
            }
            return nil
        }
        self.access = access
        previousIdentifier = previous
        acquisitionArgument = "\(kind) \(previous) \(layout)"
    }

    func release() {
        guard !released else { return }
        released = true
        if let previousIdentifier, access.currentIdentifier() == Self.companionIdentifier {
            _ = access.select(previousIdentifier)
        }
    }
}

@MainActor
private struct NativePreviewKeyboardSourceAccess: PreviewKeyboardSourceAccess {
    func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }

    func currentIsLayout() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        return string(source, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String
    }

    func layoutIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }

    func companionIsAvailable() -> Bool {
        let status = companionStatus()
        return status == .available || status == .selected
    }

    func companionStatus() -> PreviewKeyboardSourceStatus {
        let filter = [kTISPropertyInputSourceID as String: PreviewKeyboardSource.companionIdentifier] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] ?? []
        let methods = sources.filter {
            string($0, kTISPropertyInputSourceType) == kTISTypeKeyboardInputMethodWithoutModes as String
        }
        guard !methods.isEmpty else { return .missing }
        guard methods.contains(where: {
            boolean($0, kTISPropertyInputSourceIsEnabled) && boolean($0, kTISPropertyInputSourceIsSelectCapable)
        }) else { return .disabled }
        return currentIdentifier() == PreviewKeyboardSource.companionIdentifier ? .selected : .available
    }

    func select(_ identifier: String) -> Bool {
        guard let source = find(identifier) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private func find(_ identifier: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }
        return sources.first
    }

    private func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    private func boolean(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let value = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }
}

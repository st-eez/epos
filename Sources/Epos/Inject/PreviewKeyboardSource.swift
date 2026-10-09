import Carbon
import Foundation

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
        guard let source = find(PreviewKeyboardSource.companionIdentifier),
              string(source, kTISPropertyInputSourceType) == kTISTypeKeyboardInputMethodWithoutModes as String,
              let enabled = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabled).takeUnretainedValue())
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
}

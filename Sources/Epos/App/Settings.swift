import Foundation

/// Persistent user-tunable settings, backed by `UserDefaults`.
public struct Settings: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var localeIdentifier: String
    public var saveAudioSamples: Bool
    public var saveCorrectionEvidence: Bool
    public var polishEnabled: Bool

    public init(
        launchAtLogin: Bool = false,
        localeIdentifier: String = "en-US",
        saveAudioSamples: Bool = false,
        saveCorrectionEvidence: Bool = false,
        polishEnabled: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.localeIdentifier = localeIdentifier
        self.saveAudioSamples = saveAudioSamples
        self.saveCorrectionEvidence = saveCorrectionEvidence
        self.polishEnabled = polishEnabled
    }

    private enum Key {
        static let launchAtLogin = "settings.launchAtLogin"
        static let localeIdentifier = "settings.localeIdentifier"
        static let saveAudioSamples = "settings.saveAudioSamples"
        static let saveCorrectionEvidence = "settings.saveCorrectionEvidence"
        static let polishEnabled = "settings.polishEnabled"
    }

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        Settings(
            launchAtLogin: defaults.bool(forKey: Key.launchAtLogin),
            localeIdentifier: defaults.string(forKey: Key.localeIdentifier) ?? "en-US",
            saveAudioSamples: defaults.bool(forKey: Key.saveAudioSamples),
            saveCorrectionEvidence: defaults.bool(forKey: Key.saveCorrectionEvidence),
            polishEnabled: defaults.bool(forKey: Key.polishEnabled)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(localeIdentifier, forKey: Key.localeIdentifier)
        defaults.set(saveAudioSamples, forKey: Key.saveAudioSamples)
        defaults.set(saveCorrectionEvidence, forKey: Key.saveCorrectionEvidence)
        defaults.set(polishEnabled, forKey: Key.polishEnabled)
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }
}

import Foundation

/// Persistent user-tunable settings, backed by `UserDefaults`.
/// Baseline surface: launch-at-login bool, install locale string. Anything beyond is post-baseline.
public struct Settings: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var localeIdentifier: String

    public init(launchAtLogin: Bool = false, localeIdentifier: String = "en-US") {
        self.launchAtLogin = launchAtLogin
        self.localeIdentifier = localeIdentifier
    }

    private enum Key {
        static let launchAtLogin = "settings.launchAtLogin"
        static let localeIdentifier = "settings.localeIdentifier"
    }

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        Settings(
            launchAtLogin: defaults.bool(forKey: Key.launchAtLogin),
            localeIdentifier: defaults.string(forKey: Key.localeIdentifier) ?? "en-US"
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(localeIdentifier, forKey: Key.localeIdentifier)
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }
}

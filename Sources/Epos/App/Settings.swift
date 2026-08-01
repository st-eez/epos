import Foundation

/// Named looks for the screen-edge recording glow.
public enum EdgeGlowTheme: String, Equatable, Sendable {
    /// The user's single color driving the derived gradient.
    case standard
    /// Red/black anime aura: fixed ember palette with smoke and electric
    /// flicker layers; the user color is ignored while active.
    case ember
}

/// User-tunable style for the screen-edge recording glow.
public struct EdgeGlowSettings: Equatable, Sendable {
    public var enabled: Bool
    public var theme: EdgeGlowTheme
    /// Brightness multiplier applied to every glow layer.
    public var intensity: Double
    /// Stroke-width multiplier (visual band thickness).
    public var thickness: Double
    /// Base color components (sRGB); the gradient's companion hues are
    /// derived from this one color.
    public var red: Double
    public var green: Double
    public var blue: Double

    public static let intensityRange: ClosedRange<Double> = 0.4...1.6
    public static let thicknessRange: ClosedRange<Double> = 0.6...1.6

    public init(
        enabled: Bool = true,
        theme: EdgeGlowTheme = .standard,
        // 0.85, not 1: the default indicator for an all-day utility should
        // sit just below conscious notice; the slider goes louder.
        intensity: Double = 0.85,
        thickness: Double = 1,
        red: Double = 0.22,
        green: Double = 0.78,
        blue: Double = 0.72
    ) {
        self.enabled = enabled
        self.theme = theme
        self.intensity = Self.intensityRange.clamping(intensity)
        self.thickness = Self.thicknessRange.clamping(thickness)
        self.red = (0.0...1.0).clamping(red)
        self.green = (0.0...1.0).clamping(green)
        self.blue = (0.0...1.0).clamping(blue)
    }
}

private extension ClosedRange<Double> {
    func clamping(_ value: Double) -> Double {
        guard value.isFinite else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

/// Persistent user-tunable settings, backed by `UserDefaults`.
public struct Settings: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var localeIdentifier: String
    public var saveAudioSamples: Bool
    public var saveCorrectionEvidence: Bool
    /// Runs the mic through Apple's voice-processing IO so audio the machine is
    /// playing out (music, a call, a video) is subtracted from what the recognizer
    /// hears.
    ///
    /// Default OFF. It works — three of four measured holds rejected the speaker
    /// audio completely — but macOS voice processing always ducks other audio while
    /// it runs, and the dip is audible at `.min`, the lowest level the platform
    /// offers. Quieting audio the user chose to play is a worse failure than
    /// occasionally transcribing it, so this stays opt-in until the cancellation can
    /// be done without touching the output.
    public var echoCancellation: Bool
    /// Streams volatile text into the fn-press field as marked text via the
    /// companion input method; falls back to the pill HUD when unavailable.
    public var inlinePreview: Bool
    public var edgeGlow: EdgeGlowSettings

    public init(
        launchAtLogin: Bool = false,
        localeIdentifier: String = "en-US",
        saveAudioSamples: Bool = false,
        saveCorrectionEvidence: Bool = false,
        echoCancellation: Bool = false,
        inlinePreview: Bool = true,
        edgeGlow: EdgeGlowSettings = EdgeGlowSettings()
    ) {
        self.launchAtLogin = launchAtLogin
        self.localeIdentifier = localeIdentifier
        self.saveAudioSamples = saveAudioSamples
        self.saveCorrectionEvidence = saveCorrectionEvidence
        self.echoCancellation = echoCancellation
        self.inlinePreview = inlinePreview
        self.edgeGlow = edgeGlow
    }

    private enum Key {
        static let launchAtLogin = "settings.launchAtLogin"
        static let localeIdentifier = "settings.localeIdentifier"
        static let saveAudioSamples = "settings.saveAudioSamples"
        static let saveCorrectionEvidence = "settings.saveCorrectionEvidence"
        static let echoCancellation = "settings.echoCancellation"
        static let inlinePreview = "settings.inlinePreview"
        static let edgeGlowEnabled = "settings.edgeGlow.enabled"
        static let edgeGlowTheme = "settings.edgeGlow.theme"
        static let edgeGlowIntensity = "settings.edgeGlow.intensity"
        static let edgeGlowThickness = "settings.edgeGlow.thickness"
        static let edgeGlowRed = "settings.edgeGlow.red"
        static let edgeGlowGreen = "settings.edgeGlow.green"
        static let edgeGlowBlue = "settings.edgeGlow.blue"
    }

    public static func load(from defaults: UserDefaults = .standard) -> Settings {
        let glowDefaults = EdgeGlowSettings()
        return Settings(
            launchAtLogin: defaults.bool(forKey: Key.launchAtLogin),
            localeIdentifier: defaults.string(forKey: Key.localeIdentifier) ?? "en-US",
            saveAudioSamples: defaults.bool(forKey: Key.saveAudioSamples),
            saveCorrectionEvidence: defaults.bool(forKey: Key.saveCorrectionEvidence),
            echoCancellation: defaults.object(forKey: Key.echoCancellation) as? Bool ?? false,
            inlinePreview: defaults.object(forKey: Key.inlinePreview) as? Bool ?? true,
            edgeGlow: EdgeGlowSettings(
                // `object(forKey:)` distinguishes "never set" (use defaults)
                // from a stored false/0.
                enabled: defaults.object(forKey: Key.edgeGlowEnabled) as? Bool
                    ?? glowDefaults.enabled,
                theme: (defaults.string(forKey: Key.edgeGlowTheme)
                    .flatMap(EdgeGlowTheme.init(rawValue:))) ?? glowDefaults.theme,
                intensity: defaults.object(forKey: Key.edgeGlowIntensity) as? Double
                    ?? glowDefaults.intensity,
                thickness: defaults.object(forKey: Key.edgeGlowThickness) as? Double
                    ?? glowDefaults.thickness,
                red: defaults.object(forKey: Key.edgeGlowRed) as? Double ?? glowDefaults.red,
                green: defaults.object(forKey: Key.edgeGlowGreen) as? Double ?? glowDefaults.green,
                blue: defaults.object(forKey: Key.edgeGlowBlue) as? Double ?? glowDefaults.blue
            )
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(localeIdentifier, forKey: Key.localeIdentifier)
        defaults.set(saveAudioSamples, forKey: Key.saveAudioSamples)
        defaults.set(saveCorrectionEvidence, forKey: Key.saveCorrectionEvidence)
        defaults.set(echoCancellation, forKey: Key.echoCancellation)
        defaults.set(inlinePreview, forKey: Key.inlinePreview)
        defaults.set(edgeGlow.enabled, forKey: Key.edgeGlowEnabled)
        defaults.set(edgeGlow.theme.rawValue, forKey: Key.edgeGlowTheme)
        defaults.set(edgeGlow.intensity, forKey: Key.edgeGlowIntensity)
        defaults.set(edgeGlow.thickness, forKey: Key.edgeGlowThickness)
        defaults.set(edgeGlow.red, forKey: Key.edgeGlowRed)
        defaults.set(edgeGlow.green, forKey: Key.edgeGlowGreen)
        defaults.set(edgeGlow.blue, forKey: Key.edgeGlowBlue)
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }
}

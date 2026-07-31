import Foundation

/// Why a fn press cannot open a dictation right now.
///
/// One value carries every face the app needs for the same fact — the pill's
/// two-word notice, the menu banner's sentence, and the diagnostic log's
/// detail — so the three surfaces cannot name different blockers for one cause.
public enum StartBlocker: Equatable, Sendable {
    /// The on-device speech model is still installing. Transient: this is the
    /// case that used to leave the pipeline dead until the next relaunch.
    case speechModelInstalling
    /// The model is not installed and this launch could not install it. The
    /// message is the underlying failure, for the log only.
    case speechModelUnavailable(String)
    /// Microphone access is denied, or the prompt was never answered.
    case microphoneDenied
    /// Speech recognition access is denied, or the prompt was never answered.
    case speechDenied
    /// Model installed and grants in place, and the analyzer still resolved no
    /// audio format.
    case speechEngineUnavailable

    /// The recording pill's notice. It has one short line inside a capsule, so
    /// these stay at two words.
    public var noticeLabel: String {
        switch self {
        case .speechModelInstalling: "Preparing"
        case .speechModelUnavailable: "No model"
        case .microphoneDenied: "Mic blocked"
        case .speechDenied: "Speech blocked"
        case .speechEngineUnavailable: "Not ready"
        }
    }

    /// The menu banner's subtitle: one sentence naming what to fix.
    public var bannerSubtitle: String {
        switch self {
        case .speechModelInstalling: "The speech model is still downloading"
        case .speechModelUnavailable: "The on-device speech model is not installed"
        case .microphoneDenied: "Allow Microphone in Privacy settings"
        case .speechDenied: "Allow Speech Recognition in Privacy settings"
        case .speechEngineUnavailable: "The speech engine resolved no audio format"
        }
    }

    /// Diagnostic-log detail.
    public var logDescription: String {
        switch self {
        case .speechModelInstalling: "speech model still downloading"
        case .speechModelUnavailable(let message): "speech model unavailable (\(message))"
        case .microphoneDenied: "microphone access not granted"
        case .speechDenied: "speech recognition access not granted"
        case .speechEngineUnavailable: "speech engine resolved no audio format"
        }
    }
}

/// Whether a fn press can open a dictation, as one value the HUD and the menu
/// both read. `preparing` is the launch window before bootstrap has resolved a
/// capture format; `blocked` is a resolved, named reason there is none.
public enum StartReadiness: Equatable, Sendable {
    case preparing
    case ready
    case blocked(StartBlocker)

    /// The recording pill's notice for a press that could not start. `ready`
    /// still has one: the format existed and the start failed later (the mic
    /// refused to open, the analyzer session failed).
    public var noticeLabel: String {
        switch self {
        case .preparing: "Preparing"
        case .ready: "Not ready"
        case .blocked(let blocker): blocker.noticeLabel
        }
    }
}

import Foundation
import OSLog
import Speech

public enum AssetStatus: Equatable {
    case missing
    case downloading(progress: Double)
    case ready
    case reserved
    case failed(message: String)
}

/// Wraps `AssetInventory` reservation + download for the install locale.
/// Reservation is process-scoped, so call `prepare()` on every app launch.
/// Thread-safe: implementations must protect any internal mutable state.
public final class AssetManager: @unchecked Sendable {
    public let locale: Locale

    private static let log = Logger(subsystem: "com.steez.SteezFlow", category: "assets")

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public func currentStatus() async -> AssetStatus {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let installed = await SpeechTranscriber.installedLocales
        let reserved = await AssetInventory.reservedLocales

        if contains(installed, locale) && contains(reserved, locale) {
            return .reserved
        }
        if contains(installed, locale) {
            return .ready
        }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .downloading:
            return .downloading(progress: 0)
        case .installed:
            return .ready
        case .supported, .unsupported:
            return .missing
        @unknown default:
            return .missing
        }
    }

    public func prepare() async -> AssetStatus {
        let status = await currentStatus()
        if case .reserved = status {
            Self.log.info("asset already reserved for locale \(self.locale.identifier, privacy: .public)")
            return status
        }

        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else {
            let message = "locale \(locale.identifier) not supported"
            Self.log.info("\(message, privacy: .public)")
            return .failed(message: message)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if case .missing = status {
                Self.log.info("downloading asset for locale \(self.locale.identifier, privacy: .public)")
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    // post-baseline: surface progress via request.progress (NSProgress)
                    try await request.downloadAndInstall()
                }
            }
            Self.log.info("reserving locale \(self.locale.identifier, privacy: .public)")
            try await AssetInventory.reserve(locale: locale)
            Self.log.info("asset reserved for locale \(self.locale.identifier, privacy: .public)")
            return .reserved
        } catch {
            let message = String(describing: error)
            Self.log.info("asset prepare failed: \(message, privacy: .public)")
            return .failed(message: message)
        }
    }

    private func contains(_ locales: [Locale], _ target: Locale) -> Bool {
        locales.contains { $0.identifier == target.identifier }
    }
}

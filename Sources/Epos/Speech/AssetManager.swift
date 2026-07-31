import Foundation
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
public struct AssetManager: Sendable {
    public let locale: Locale

    private static let log = EposLogger(category: "assets")

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public func currentStatus() async -> AssetStatus {
        guard let assetLocale = await resolvedLocale() else {
            return .missing
        }
        return await currentStatus(for: assetLocale)
    }

    private func currentStatus(for assetLocale: Locale) async -> AssetStatus {
        let transcriber = Transcriber.makeTranscriber(locale: assetLocale)
        let installed = await SpeechTranscriber.installedLocales
        let reserved = await AssetInventory.reservedLocales

        let isInstalled = installed.contains { $0.identifier == assetLocale.identifier }
        let isReserved = reserved.contains { $0.identifier == assetLocale.identifier }
        if isInstalled && isReserved {
            return .reserved
        }
        if isInstalled {
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
        guard let assetLocale = await resolvedLocale() else {
            let message = "locale \(locale.identifier) not supported"
            Self.log.info(message)
            return .failed(message: message)
        }

        let status = await currentStatus(for: assetLocale)
        if case .reserved = status {
            Self.log.info("asset already reserved for locale \(assetLocale.identifier)")
            return status
        }

        let transcriber = Transcriber.makeTranscriber(locale: assetLocale)
        do {
            switch status {
            case .missing, .downloading:
                // `.downloading` is a MobileAsset install still running from an
                // earlier launch. It used to fall straight through to `reserve`,
                // which reports a half-installed model as `.reserved`: bootstrap then
                // finds no audio format and misblames permissions, and the preset
                // eval host would benchmark an incomplete model.
                Self.log.info("installing asset for locale \(assetLocale.identifier)")
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    // post-baseline: surface progress via request.progress (NSProgress)
                    try await request.downloadAndInstall()
                }
                // A background download already in flight leaves no installation
                // request to await, so confirm the model actually landed rather than
                // inferring it from a request that was never returned.
                let installed = await currentStatus(for: assetLocale)
                switch installed {
                case .ready, .reserved:
                    break
                case .missing, .downloading, .failed:
                    Self.log.info(
                        "asset not installed after install attempt for locale \(assetLocale.identifier)"
                    )
                    return installed
                }
            case .ready, .reserved, .failed:
                break
            }
            Self.log.info("reserving locale \(assetLocale.identifier)")
            try await AssetInventory.reserve(locale: assetLocale)
            Self.log.info("asset reserved for locale \(assetLocale.identifier)")
            return .reserved
        } catch {
            let message = String(describing: error)
            Self.log.info("asset prepare failed: \(message)")
            return .failed(message: message)
        }
    }

    private func resolvedLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

}

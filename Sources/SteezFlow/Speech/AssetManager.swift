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
public final class AssetManager {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    public func currentStatus() async -> AssetStatus {
        // TODO: query AssetInventory.status(forModules:) for SpeechTranscriber locale
        .missing
    }

    public func prepare() async -> AssetStatus {
        // TODO: download via AssetInventory.assetInstallationRequest if missing,
        // then reserve via AssetInventory.reserve(locale:) for the current process.
        .reserved
    }
}

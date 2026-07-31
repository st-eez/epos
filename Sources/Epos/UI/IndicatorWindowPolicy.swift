import Foundation

/// Whether indicator windows (pill panel, edge glow) may actually be ordered
/// on screen. `swift test` drives the real coordinator, whose presentation
/// paths would otherwise flash real panels over whatever the developer is
/// doing; under XCTest every window-ordering call is a no-op while all
/// coordinator-side state (flags, callbacks, fades' bookkeeping) behaves
/// identically — that state is what the tests assert.
enum IndicatorWindowPolicy {
    nonisolated static let canPresentWindows =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
}

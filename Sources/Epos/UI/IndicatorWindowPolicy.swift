import Foundation

/// Whether side effects that escape the process (pill panel, edge glow,
/// recording bells, the Electron accessibility waker's AX writes) may actually
/// fire. `swift test` drives the real coordinator, whose presentation paths
/// would otherwise flash real panels and ping real bells over whatever the
/// developer is doing; in a test process every such call is a no-op while all
/// coordinator-side state (flags, callbacks, fades' bookkeeping) behaves
/// identically — that state is what the tests assert.
/// Both markers are checked because the toolchain's runner sets
/// `SWIFT_TESTING_ENABLED` for the whole `swift test` process while
/// `XCTestConfigurationFilePath` is only present under Xcode's runner — the
/// direct `xctest` runner may set neither marker, so also check whether XCTest
/// is loaded in the process.
enum IndicatorWindowPolicy {
    nonisolated static let canPresentWindows =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == nil
            && NSClassFromString("XCTestCase") == nil
}

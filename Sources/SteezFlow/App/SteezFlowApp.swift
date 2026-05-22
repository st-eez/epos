import SwiftUI

public struct SteezFlowApp: App {
    @StateObject private var coordinator = AppCoordinator()

    public init() {}

    public var body: some Scene {
        MenuBarExtra("SteezFlow", systemImage: "mic.fill") {
            MenuBarView(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)

        Window("Recording", id: RecordingIndicator.windowID) {
            RecordingIndicator(coordinator: coordinator)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

import SwiftUI

public struct SteezFlowApp: App {
    @StateObject private var coordinator = AppCoordinator()

    public init() {}

    public var body: some Scene {
        MenuBarExtra("SteezFlow", systemImage: "mic.fill") {
            MenuBarView(coordinator: coordinator)
                .task { await coordinator.bootstrap() }
        }
        .menuBarExtraStyle(.window)
        // The recording indicator is an NSPanel managed by the coordinator;
        // it intentionally is not a SwiftUI Scene.
    }
}

import SwiftUI

public struct EposApp: App {
    @StateObject private var coordinator = AppCoordinator()

    public init() {}

    public var body: some Scene {
        MenuBarExtra("Epos", image: "EposMenuBarIcon") {
            MenuBarView(coordinator: coordinator)
                .task { await coordinator.bootstrap() }
        }
        .menuBarExtraStyle(.window)

        Window("Corrections", id: CorrectionsEditorView.windowID) {
            CorrectionsEditorView(
                store: coordinator.corrections,
                evidenceStore: coordinator.correctionEvidence
            )
        }
        .defaultSize(width: 940, height: 560)
        .defaultLaunchBehavior(.suppressed)
        // The recording indicator is an NSPanel managed by the coordinator;
        // it intentionally is not a SwiftUI Scene.
    }
}

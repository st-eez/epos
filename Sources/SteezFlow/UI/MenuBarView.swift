import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(stateLabel, systemImage: stateIcon)
                .font(.headline)
            Divider()
            Button("Quit SteezFlow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 220)
    }

    private var stateLabel: String {
        switch coordinator.state {
        case .idle: "Idle — hold fn to record"
        case .recording: "Recording…"
        case .finalizing: "Finalizing…"
        }
    }

    private var stateIcon: String {
        switch coordinator.state {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .finalizing: "waveform"
        }
    }
}

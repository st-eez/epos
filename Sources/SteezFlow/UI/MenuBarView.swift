import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var permissions: PermissionsSnapshot?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(stateLabel, systemImage: stateIcon)
                .font(.headline)
            if let permissions, !allGranted(permissions) {
                Divider()
                permissionRow("Microphone", permissions.microphone)
                permissionRow("Speech Recognition", permissions.speech)
                permissionRow("Accessibility", permissions.accessibility)
                Button("Open System Settings → Privacy") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            Divider()
            Button("Quit SteezFlow") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { permissions = coordinator.snapshotPermissions() }
    }

    private func allGranted(_ snapshot: PermissionsSnapshot) -> Bool {
        snapshot.microphone == .granted
            && snapshot.speech == .granted
            && snapshot.accessibility == .granted
    }

    private func permissionRow(_ label: String, _ status: PermissionStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status == .granted ? .green : .orange)
            Text(label)
            Spacer()
            Text(statusLabel(status)).foregroundStyle(.secondary).font(.caption)
        }
    }

    private func statusLabel(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not set"
        }
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

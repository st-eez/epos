import ServiceManagement
import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var permissions: PermissionsSnapshot?
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    private static let log = SteezFlowLogger(category: "menubar")
    private let panelColor = Color(red: 0.11, green: 0.13, blue: 0.15)
    private let teal = Color(red: 0.22, green: 0.78, blue: 0.72)
    private let red = Color(red: 0.9, green: 0.28, blue: 0.3)
    private let amber = Color(red: 0.86, green: 0.55, blue: 0.18)

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readinessBanner
            permissionGrid
            metadataRows
            actionRow
        }
        .padding(14)
        .frame(width: 310)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(panelColor.opacity(0.94))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 12)
        .onAppear { permissions = coordinator.snapshotPermissions() }
    }

    private var readinessBanner: some View {
        HStack(spacing: 11) {
            Image(systemName: readinessIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(readinessColor)
                .frame(width: 34, height: 34)
                .background(readinessColor.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(readinessTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(readinessSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(readinessColor.opacity(0.22), lineWidth: 1))
    }

    private var permissionGrid: some View {
        HStack(spacing: 8) {
            permissionTile("Mic", permissions?.microphone)
            permissionTile("Speech", permissions?.speech)
            permissionTile("AX", permissions?.accessibility)
        }
    }

    private var metadataRows: some View {
        VStack(spacing: 0) {
            metaRow("Locale") {
                Text(coordinator.localeIdentifier)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
            Divider().overlay(.white.opacity(0.08))
            metaRow("Launch at login") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(teal)
                    .scaleEffect(0.74)
                    .frame(width: 42, height: 22)
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { openPrivacySettings() } label: { Label("Privacy", systemImage: "lock.shield") }
            .buttonStyle(QuietButtonStyle())

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer(minLength: 0)
                    Text("Q")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.46))
                }
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut("q")
        }
    }

    private func permissionTile(_ label: String, _ status: PermissionStatus?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(permissionColor(status))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
            Text(permissionLabel(status))
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(permissionColor(status).opacity(0.22), lineWidth: 1))
    }

    private func metaRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 12)
            content()
        }
        .frame(height: 34)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            var current = Settings.load()
            current.launchAtLogin = enabled
            current.save()
        } catch {
            Self.log.error("launch-at-login toggle failed: \(String(describing: error))")
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    private func allGranted(_ snapshot: PermissionsSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.microphone == .granted && snapshot.speech == .granted && snapshot.accessibility == .granted
    }

    private func permissionColor(_ status: PermissionStatus?) -> Color {
        return switch status {
        case .granted: teal
        case .denied: red
        case .notDetermined: amber
        case nil: .white.opacity(0.34)
        }
    }

    private func permissionLabel(_ status: PermissionStatus?) -> String {
        return switch status {
        case .granted: "OK"
        case .denied: "Blocked"
        case .notDetermined: "Needed"
        case nil: "..."
        }
    }

    private var readinessTitle: String {
        if !allGranted(permissions) {
            return permissions == nil ? "Checking access" : "Needs permission"
        }
        return switch coordinator.state {
        case .idle: "Ready to dictate"
        case .recording: "Recording"
        case .finalizing: "Finishing dictation"
        }
    }

    private var readinessSubtitle: String {
        if !allGranted(permissions) {
            return permissions == nil ? "Reading current grants" : "Open Privacy to finish setup"
        }
        return switch coordinator.state {
        case .idle: "Hold fn in any text field"
        case .recording: "Release fn to paste"
        case .finalizing: "Pasting into the frontmost app"
        }
    }

    private var readinessIcon: String {
        if !allGranted(permissions) {
            return permissions == nil ? "ellipsis" : "exclamationmark.triangle.fill"
        }
        return switch coordinator.state {
        case .idle: "mic"
        case .recording: "waveform"
        case .finalizing: "arrow.down.doc"
        }
    }

    private var readinessColor: Color {
        if !allGranted(permissions) {
            return permissions == nil ? .white.opacity(0.56) : amber
        }
        return switch coordinator.state {
        case .idle: teal
        case .recording: red
        case .finalizing: teal
        }
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.62 : 0.76))
            .frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.1 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

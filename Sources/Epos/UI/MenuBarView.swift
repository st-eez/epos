import SwiftUI

public struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: AppCoordinator
    @State private var permissions: PermissionsSnapshot?
    @State private var launchAtLogin = false
    @State private var saveAudioSamples = false
    @State private var polishEnabled = false

    private let panelColor = Color(red: 0.11, green: 0.13, blue: 0.15)
    private let teal = EposPalette.teal
    private let red = EposPalette.red
    private let amber = EposPalette.amber

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            readinessBanner
            permissionGrid
            metadataRows
            Button { openCorrectionsWindow() } label: {
                Label("Corrections", systemImage: "text.badge.checkmark")
            }
            .buttonStyle(QuietButtonStyle())
            actionRow
        }
        .padding(14)
        .frame(width: 330)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(panelColor.opacity(0.94))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 12)
        .onAppear {
            permissions = coordinator.snapshotPermissions()
            launchAtLogin = coordinator.launchAtLogin
            saveAudioSamples = coordinator.saveAudioSamples
            polishEnabled = coordinator.polishEnabled
        }
    }

    private var readinessBanner: some View {
        let readiness = self.readiness
        return HStack(spacing: 11) {
            Image(systemName: readiness.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(readiness.color)
                .frame(width: 34, height: 34)
                .background(readiness.color.opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(readiness.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(readiness.subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(readiness.color.opacity(0.22), lineWidth: 1))
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
                        coordinator.setLaunchAtLogin(newValue)
                    }
            }
            Divider().overlay(.white.opacity(0.08))
            metaRow("Save audio samples") {
                Toggle("", isOn: $saveAudioSamples)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(teal)
                    .scaleEffect(0.74)
                    .frame(width: 42, height: 22)
                    .onChange(of: saveAudioSamples) { _, newValue in
                        coordinator.setSaveAudioSamples(newValue)
                    }
            }
            Divider().overlay(.white.opacity(0.08))
            metaRow("Polish dictation (on-device AI)") {
                Toggle("", isOn: $polishEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(teal)
                    .scaleEffect(0.74)
                    .frame(width: 42, height: 22)
                    .onChange(of: polishEnabled) { _, newValue in
                        coordinator.setPolishEnabled(newValue)
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

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openCorrectionsWindow() {
        openWindow(id: CorrectionsEditorView.windowID)
        NSApplication.shared.activate(ignoringOtherApps: true)
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

    private struct Readiness {
        let icon: String
        let title: String
        let subtitle: String
        let color: Color
    }

    /// Single source for the banner's icon/title/subtitle/color. Permission state
    /// outranks recording state; these four facets were previously four parallel
    /// computed properties that each re-derived the same two-axis decision.
    private var readiness: Readiness {
        guard let permissions else {
            return Readiness(
                icon: "ellipsis",
                title: "Checking access",
                subtitle: "Reading current grants",
                color: .white.opacity(0.56)
            )
        }
        guard allGranted(permissions) else {
            return Readiness(
                icon: "exclamationmark.triangle.fill",
                title: "Needs permission",
                subtitle: "Open Privacy to finish setup",
                color: amber
            )
        }
        return switch coordinator.state {
        case .idle:
            Readiness(icon: "mic", title: "Ready to dictate", subtitle: "Hold fn in any text field", color: teal)
        case .recording:
            Readiness(icon: "waveform", title: "Recording", subtitle: "Release fn to finish", color: red)
        case .finalizing:
            finalizationReadiness
        }
    }

    private var finalizationReadiness: Readiness {
        switch coordinator.finalizationPhase {
        case .none, .finalizingSpeech:
            Readiness(
                icon: "waveform.badge.magnifyingglass",
                title: "Finishing speech",
                subtitle: "Waiting for the final transcript",
                color: amber
            )
        case .polishing:
            Readiness(
                icon: "sparkles",
                title: "Polishing dictation",
                subtitle: "Cleaning filler words",
                color: amber
            )
        case .inserting:
            Readiness(
                icon: "arrow.down.doc",
                title: "Updating text",
                subtitle: "Reconciling final output",
                color: teal
            )
        }
    }
}

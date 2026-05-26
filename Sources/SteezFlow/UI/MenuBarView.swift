import ServiceManagement
import SwiftUI

public struct MenuBarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var permissions: PermissionsSnapshot?
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var customRules: [TranscriptCanonicalizer.Rule] = TranscriptCanonicalizer.customRules()
    @State private var newAlias = ""
    @State private var newCanonical = ""

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
            correctionsPanel
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
            customRules = TranscriptCanonicalizer.customRules()
        }
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

    private var correctionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Corrections", systemImage: "text.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 8)
                Text("\(customRules.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
            }

            HStack(spacing: 6) {
                correctionField("Heard", text: $newAlias)
                correctionField("Use", text: $newCanonical)
                Button { addCorrection() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(PlainIconButtonStyle())
                .disabled(!canAddCorrection)
                .help("Add correction")
            }

            if !customRules.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(customRules.indices, id: \.self) { index in
                            correctionRow(index)
                        }
                    }
                }
                .frame(maxHeight: 92)
            }
        }
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private func correctionField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func correctionRow(_ index: Int) -> some View {
        let rule = customRules[index]
        return HStack(spacing: 6) {
            Text(rule.aliases.first ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.64))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.34))
            Text(rule.canonical)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { removeCorrection(at: index) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PlainIconButtonStyle())
            .help("Remove correction")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var canAddCorrection: Bool {
        !newAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !newCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addCorrection() {
        let alias = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical = newCanonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty, !canonical.isEmpty else { return }

        customRules.append(.init(canonical: canonical, aliases: [alias]))
        TranscriptCanonicalizer.saveCustomRules(customRules)
        newAlias = ""
        newCanonical = ""
    }

    private func removeCorrection(at index: Int) {
        guard customRules.indices.contains(index) else { return }
        customRules.remove(at: index)
        TranscriptCanonicalizer.saveCustomRules(customRules)
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

private struct PlainIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(!isEnabled ? 0.28 : configuration.isPressed ? 0.52 : 0.72))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.1 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

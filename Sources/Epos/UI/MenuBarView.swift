import SwiftUI

public struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: AppCoordinator
    @State private var permissions: PermissionsSnapshot?
    @State private var launchAtLogin = false
    @State private var saveAudioSamples = false
    @State private var saveCorrectionEvidence = false

    /// Curated glow palette. Swatches, not a SwiftUI ColorPicker: its well
    /// cannot present NSColorPanel from a non-activating menu-bar popover in
    /// a background app. Arbitrary colors go through the bridged panel button.
    private static let glowSwatches: [(red: Double, green: Double, blue: Double)] = [
        (0.22, 0.78, 0.72),  // teal (default)
        (0.30, 0.62, 0.95),  // sky
        (0.58, 0.45, 0.95),  // violet
        (0.92, 0.40, 0.70),  // pink
        (0.90, 0.20, 0.16),  // red
        (0.95, 0.70, 0.30),  // amber
        (0.45, 0.85, 0.50)   // green
    ]

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
            saveCorrectionEvidence = coordinator.saveCorrectionEvidence
        }
        .task {
            // Opening the menu is the other natural moment to re-check a launch
            // that came up without a capture format (a model that has finished
            // installing since, a grant made in System Settings). A no-op when the
            // pipeline is live; grants are re-read after it so the tiles and the
            // banner agree.
            await coordinator.refreshStartReadinessIfNeeded()?.value
            permissions = coordinator.snapshotPermissions()
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
                        // Snap back when the register/unregister failed: the
                        // coordinator reports the state that actually holds, and a
                        // toggle left showing the user's choice would claim a login
                        // item that does not exist.
                        let applied = coordinator.setLaunchAtLogin(newValue)
                        if applied != newValue { launchAtLogin = applied }
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
            metaRow("Learn corrections") {
                Toggle("", isOn: $saveCorrectionEvidence)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(teal)
                    .scaleEffect(0.74)
                    .frame(width: 42, height: 22)
                    .onChange(of: saveCorrectionEvidence) { _, newValue in
                        coordinator.setSaveCorrectionEvidence(newValue)
                    }
            }
            Divider().overlay(.white.opacity(0.08))
            metaRow("Stream into field") {
                Toggle("", isOn: Binding(
                    get: { coordinator.inlinePreviewSetting },
                    set: { coordinator.setInlinePreview($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(teal)
                .scaleEffect(0.74)
                .frame(width: 42, height: 22)
            }
            Divider().overlay(.white.opacity(0.08))
            metaRow("Edge glow") {
                Toggle("", isOn: glowBinding(\.enabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(teal)
                    .scaleEffect(0.74)
                    .frame(width: 42, height: 22)
            }
            if glow.enabled {
                metaRow("Glow intensity") {
                    Slider(value: glowBinding(\.intensity), in: EdgeGlowSettings.intensityRange)
                        .controlSize(.mini)
                        .tint(teal)
                        .frame(width: 110)
                }
                metaRow("Glow thickness") {
                    Slider(value: glowBinding(\.thickness), in: EdgeGlowSettings.thicknessRange)
                        .controlSize(.mini)
                        .tint(teal)
                        .frame(width: 110)
                }
                metaRow("Ember aura") {
                    Toggle("", isOn: Binding(
                        get: { glow.theme == .ember },
                        set: { on in setGlowTheme(on ? .ember : .standard) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(EposPalette.red)
                    .scaleEffect(0.74)
                    .frame(width: 42, height: 22)
                }
                if glow.theme == .standard {
                    metaRow("Glow color") {
                        HStack(spacing: 6) {
                            ForEach(Array(Self.glowSwatches.enumerated()), id: \.offset) { _, swatch in
                                let selected = abs(swatch.red - glow.red) < 0.01
                                    && abs(swatch.green - glow.green) < 0.01
                                    && abs(swatch.blue - glow.blue) < 0.01
                                Button {
                                    setGlowColor(
                                        red: swatch.red,
                                        green: swatch.green,
                                        blue: swatch.blue
                                    )
                                } label: {
                                    Circle()
                                        .fill(Color(red: swatch.red, green: swatch.green, blue: swatch.blue))
                                        .frame(width: 14, height: 14)
                                        .overlay(
                                            Circle().strokeBorder(
                                                .white.opacity(selected ? 0.95 : 0.25),
                                                lineWidth: selected ? 2 : 1
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            Button { openGlowColorPanel() } label: {
                                Image(systemName: "paintpalette")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .help("Custom color")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The glow controls read and write the coordinator's persisted settings
    /// directly — no mirrored view state, so a change made anywhere (swatch,
    /// slider, the color panel that outlives the popover) is immediately what
    /// every control shows.
    private var glow: EdgeGlowSettings { coordinator.edgeGlowStyle }

    private func glowBinding<Value>(
        _ keyPath: WritableKeyPath<EdgeGlowSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { glow[keyPath: keyPath] },
            set: { newValue in
                var style = glow
                style[keyPath: keyPath] = newValue
                coordinator.setEdgeGlowStyle(style)
            }
        )
    }

    private func setGlowTheme(_ theme: EdgeGlowTheme) {
        var style = glow
        style.theme = theme
        coordinator.setEdgeGlowStyle(style)
    }

    /// Picking a color implies the standard theme.
    private func setGlowColor(red: Double, green: Double, blue: Double) {
        var style = glow
        style.theme = .standard
        style.red = red
        style.green = green
        style.blue = blue
        coordinator.setEdgeGlowStyle(style)
    }

    /// Arbitrary colors via NSColorPanel, bridged manually: the app must be
    /// activated for the panel to come frontmost (the popover may close —
    /// the panel stays and applies continuously).
    private func openGlowColorPanel() {
        GlowColorPanelBridge.shared.present(
            red: glow.red, green: glow.green, blue: glow.blue
        ) { red, green, blue in
            setGlowColor(red: red, green: green, blue: blue)
        }
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

    /// The grants that are not in place, named as System Settings names them and
    /// ordered as the tiles show them. Both the banner's decision and its wording
    /// come from this one read: "Open Privacy to finish setup" left the user to
    /// work out which of the three tiles was the problem.
    static func missingPermissionNames(_ snapshot: PermissionsSnapshot) -> [String] {
        var missing: [String] = []
        if snapshot.microphone != .granted { missing.append("Microphone") }
        if snapshot.speech != .granted { missing.append("Speech Recognition") }
        if snapshot.accessibility != .granted { missing.append("Accessibility") }
        return missing
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

    /// Single source for the banner's icon/title/subtitle/color. Whether dictation
    /// can actually start outranks recording state; these four facets were
    /// previously four parallel computed properties that each re-derived the same
    /// two-axis decision.
    ///
    /// The pipeline's own readiness comes first and by name. Deriving the banner
    /// from grants alone let it read "Ready to dictate" over a coordinator with no
    /// capture format — every press flashing "Not ready" while the menu insisted
    /// everything was fine.
    private var readiness: Readiness {
        guard let permissions else {
            return Readiness(
                icon: "ellipsis",
                title: "Checking access",
                subtitle: "Reading current grants",
                color: .white.opacity(0.56)
            )
        }
        switch coordinator.startReadiness {
        case .preparing:
            return Readiness(
                icon: "ellipsis",
                title: "Starting up",
                subtitle: "Preparing the speech pipeline",
                color: amber
            )
        case .blocked(let blocker):
            return Readiness(
                icon: "exclamationmark.triangle.fill",
                title: "Not ready",
                subtitle: blocker.bannerSubtitle,
                color: amber
            )
        case .ready:
            break
        }
        let missingPermissions = Self.missingPermissionNames(permissions)
        guard missingPermissions.isEmpty else {
            return Readiness(
                icon: "exclamationmark.triangle.fill",
                title: "Needs permission",
                subtitle: "Allow \(missingPermissions.joined(separator: " and ")) in Privacy",
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
        case .finalizingSpeech:
            Readiness(
                icon: "waveform.badge.magnifyingglass",
                title: "Finishing speech",
                subtitle: "Waiting for the final transcript",
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

/// Target-action receiver for NSColorPanel, which a SwiftUI popover cannot
/// host directly (the ColorPicker well silently fails to present it from a
/// non-activating panel in a background app). Continuous: every change in
/// the panel lands in the callback immediately.
@MainActor
final class GlowColorPanelBridge: NSObject {
    static let shared = GlowColorPanelBridge()
    private var onPick: ((Double, Double, Double) -> Void)?

    func present(
        red: Double, green: Double, blue: Double,
        onPick: @escaping (Double, Double, Double) -> Void
    ) {
        self.onPick = onPick
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel,
              let rgb = panel.color.usingColorSpace(.sRGB) else { return }
        onPick?(Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
    }
}

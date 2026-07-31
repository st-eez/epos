import AppKit
import SwiftUI

/// Full-screen, click-through panel that glows softly along the screen edges
/// for the whole dictation — the Siri/Apple-Intelligence cue vocabulary, in
/// Epos's palette. Unlike the pill, it never hides while text streams: it is
/// peripheral, occludes nothing, and doubles as an honest "mic is hot" frame.
/// The glow brightens with the live mic level, so speaking visibly feeds it.
@MainActor
final class RecordingEdgeGlowController {
    private let model = RecordingEdgeGlowModel()
    private var panel: NSPanel?
    /// Bumped on every show/hide so a hide fade that finishes after a newer
    /// show can never order out the re-shown panel.
    private var visibilityGeneration = 0

    private static let showFadeDuration: TimeInterval = 0.15
    private static let hideFadeDuration: TimeInterval = 0.4

    /// Builds the panel ahead of the first recording so the first show pays
    /// no construction cost.
    func prewarm() {
        _ = ensurePanel()
    }

    func updateAmplitude(_ amplitude: Float) {
        model.amplitude = amplitude
    }

    /// Covers the active screen (the one with the focused window) and fades in.
    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        let panel = ensurePanel()
        visibilityGeneration += 1
        panel.setFrame(frame, display: false)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.showFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hideFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit invokes animation completions on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary
        ]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: RecordingEdgeGlowView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

/// Live mic level feeding the glow's brightness.
@MainActor
final class RecordingEdgeGlowModel: ObservableObject {
    @Published var amplitude: Float = 0
}

/// The glow itself: two blurred strokes centered on the screen boundary (only
/// their inner halves are visible). A slow calm breath carries the idle
/// brightness; the live mic level rides on top, so the edges answer your
/// voice. Timeline-driven, so rendering pauses whenever the panel is hidden.
struct RecordingEdgeGlowView: View {
    @ObservedObject var model: RecordingEdgeGlowModel

    /// One full breath — dimmest to brightest and back.
    private static let breathPeriod: TimeInterval = 3.4

    private static let gradient = AngularGradient(
        colors: [
            EposPalette.teal,
            Color(red: 0.25, green: 0.65, blue: 0.9),
            Color(red: 0.45, green: 0.85, blue: 0.7),
            EposPalette.teal
        ],
        center: .center
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                * 2 * .pi / Self.breathPeriod
            let breath = 0.5 + 0.16 * sin(phase)
            // Same perceptual mapping as the pill's meter bars.
            let level = pow(min(1, max(0, Double(model.amplitude) / 0.075)), 0.55)
            let intensity = min(1, breath + 0.5 * level)
            ZStack {
                glowStroke(lineWidth: 44, blur: 34, opacity: 0.45 * intensity)
                glowStroke(lineWidth: 16, blur: 10, opacity: 0.6 * intensity)
            }
            .animation(.easeOut(duration: 0.08), value: model.amplitude)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// A stroke straddling the screen edge: inset by half the width so the
    /// blur bleeds inward from the boundary instead of drawing a frame.
    private func glowStroke(
        lineWidth: CGFloat,
        blur: CGFloat,
        opacity: Double
    ) -> some View {
        Rectangle()
            .inset(by: -lineWidth / 2)
            .stroke(Self.gradient, lineWidth: lineWidth)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

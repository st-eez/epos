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
    private let log = EposLogger(category: "indicator")

    private static let showFadeDuration: TimeInterval = 0.15
    private static let hideFadeDuration: TimeInterval = 0.4

    /// Builds the panel ahead of the first recording AND forces its first
    /// render pass (order front at alpha 0, out on the next runloop turn), so
    /// the flattened glow layer is already rasterized when fn goes down —
    /// the first show pays only the fade.
    func prewarm() {
        let panel = ensurePanel()
        guard !panel.isVisible else { return }
        if let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame {
            panel.setFrame(frame, display: false)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let generation = visibilityGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            panel.orderOut(nil)
        }
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
        log.info("edge glow show")
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

/// The glow itself: blurred strokes centered on the screen boundary (only
/// their inner halves are visible), rendered ONCE into a flattened Metal
/// layer via `drawingGroup`. Everything that moves afterwards is pure layer
/// alpha — the calm breath is a Core Animation repeat-forever, and the live
/// mic level drives a second static copy — so no frame ever recomputes a
/// full-screen blur. (The previous TimelineView version re-evaluated two
/// 4K-wide Gaussian blurs 30×/s; its first frame alone read as start lag.)
struct RecordingEdgeGlowView: View {
    @ObservedObject var model: RecordingEdgeGlowModel
    @State private var breathingDim = false

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
        // Same perceptual mapping as the pill's meter bars.
        let level = pow(min(1, max(0, Double(model.amplitude) / 0.075)), 0.55)
        ZStack {
            // The calm breath: starts BRIGHT (the ignition) and eases into
            // the dim-bright cycle.
            glow.opacity(breathingDim ? 0.35 : 0.72)
            // The voice: brightens the same shape as you speak.
            glow.opacity(0.55 * level)
                .animation(.easeOut(duration: 0.08), value: model.amplitude)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                breathingDim = true
            }
        }
    }

    /// Static full-screen glow, flattened to one cached layer.
    private var glow: some View {
        ZStack {
            glowStroke(lineWidth: 36, blur: 26)
            glowStroke(lineWidth: 14, blur: 9)
        }
        .drawingGroup()
    }

    /// A stroke straddling the screen edge: inset by half the width so the
    /// blur bleeds inward from the boundary instead of drawing a frame.
    private func glowStroke(lineWidth: CGFloat, blur: CGFloat) -> some View {
        Rectangle()
            .inset(by: -lineWidth / 2)
            .stroke(Self.gradient, lineWidth: lineWidth)
            .blur(radius: blur)
    }
}

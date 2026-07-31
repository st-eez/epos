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

    /// Slow enough to read as a bloom, not a pop.
    private static let showFadeDuration: TimeInterval = 0.55
    private static let hideFadeDuration: TimeInterval = 0.5

    /// Builds the panel ahead of the first recording AND forces its first
    /// render pass (order front at alpha 0, out on the next runloop turn), so
    /// the flattened glow layer is already rasterized when fn goes down —
    /// the first show pays only the fade.
    func prewarm() {
        guard IndicatorWindowPolicy.canPresentWindows else { return }
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

    /// Covers the dictation screen and fades in.
    func show() {
        guard IndicatorWindowPolicy.canPresentWindows else { return }
        guard let frame = dictationScreen()?.frame else { return }
        let panel = ensurePanel()
        visibilityGeneration += 1
        log.info("edge glow show")
        model.isShown = true
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
        model.isShown = false
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

    /// The screen being dictated into. `NSScreen.main` is useless here: for a
    /// key-window-less menu-bar app it falls back to the primary display, so
    /// on a two-display setup the glow would frame the wrong screen whenever
    /// the focused field sits on the secondary. The frontmost application's
    /// frontmost normal window locates the real dictation screen; window
    /// BOUNDS need no screen-recording permission (only titles do).
    private func dictationScreen() -> NSScreen? {
        if let windowFrame = frontmostApplicationWindowFrame() {
            let best = NSScreen.screens.max { lhs, rhs in
                overlapArea(lhs.frame, windowFrame) < overlapArea(rhs.frame, windowFrame)
            }
            if let best, overlapArea(best.frame, windowFrame) > 0 {
                return best
            }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Cocoa-coordinate frame of the frontmost app's frontmost normal window
    /// (CGWindowList is ordered front-to-back; layer 0 excludes menus/docks).
    private func frontmostApplicationWindowFrame() -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let infos = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        let primaryTop = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.maxY ?? 0
        for info in infos {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 100, bounds.height >= 100 else {
                continue
            }
            // CG global coords are top-left-origin; flip about the primary top.
            return CGRect(
                x: bounds.minX,
                y: primaryTop - bounds.maxY,
                width: bounds.width,
                height: bounds.height
            )
        }
        return nil
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
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

/// Live mic level feeding the glow's brightness, and whether the glow is on
/// screen (the view runs its motion only while shown).
@MainActor
final class RecordingEdgeGlowModel: ObservableObject {
    @Published var amplitude: Float = 0
    @Published var isShown = false
}

/// The glow itself: blurred strokes centered on the screen boundary (only
/// their inner halves are visible), rendered ONCE per palette into flattened
/// Metal layers via `drawingGroup`. Everything that moves afterwards is pure
/// layer alpha: the calm breath animates one layer's opacity, the slow color
/// drift cross-fades a second pre-rendered palette (opacity-only — a
/// hueRotation here re-rasterized the full-screen layer every frame and
/// burned ~30% of a core, even hidden), and the mic level drives a third
/// copy. All motion stops while the panel is hidden.
struct RecordingEdgeGlowView: View {
    @ObservedObject var model: RecordingEdgeGlowModel
    @State private var breathingDim = false
    @State private var driftedIn = false

    private static let tealGradient = AngularGradient(
        colors: [
            EposPalette.teal,
            Color(red: 0.25, green: 0.65, blue: 0.9),
            Color(red: 0.45, green: 0.85, blue: 0.7),
            EposPalette.teal
        ],
        center: .center
    )

    /// The drift palette: the same hues shifted around the perimeter, so the
    /// cross-fade reads as color slowly wandering along the edges.
    private static let driftGradient = AngularGradient(
        colors: [
            Color(red: 0.25, green: 0.65, blue: 0.9),
            Color(red: 0.45, green: 0.85, blue: 0.7),
            EposPalette.teal,
            Color(red: 0.25, green: 0.65, blue: 0.9)
        ],
        center: .center
    )

    var body: some View {
        // Same perceptual mapping as the pill's meter bars.
        let level = pow(min(1, max(0, Double(model.amplitude) / 0.075)), 0.55)
        ZStack {
            // The calm breath and the color drift: non-harmonic cycles
            // (2.7s vs 6.8s), so the combined motion takes a long time to
            // visibly repeat.
            glow(Self.tealGradient).opacity(breathingDim ? 0.34 : 0.66)
            glow(Self.driftGradient).opacity(driftedIn ? 0.45 : 0)
            // The voice: brightens the same shape as you speak.
            glow(Self.tealGradient).opacity(0.55 * level)
                .animation(.easeOut(duration: 0.08), value: model.amplitude)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onChange(of: model.isShown, initial: true) { _, shown in
            if shown {
                withAnimation(.easeInOut(duration: 2.7).repeatForever(autoreverses: true)) {
                    breathingDim = true
                }
                withAnimation(.easeInOut(duration: 6.8).repeatForever(autoreverses: true)) {
                    driftedIn = true
                }
            } else {
                // Replacing the repeat-forever with a short one-shot ends it;
                // the panel is faded out by now, so the jump is invisible.
                withAnimation(.linear(duration: 0.05)) {
                    breathingDim = false
                    driftedIn = false
                }
            }
        }
    }

    /// Static full-screen glow, flattened to one cached layer per palette.
    private func glow(_ gradient: AngularGradient) -> some View {
        ZStack {
            glowStroke(gradient, lineWidth: 36, blur: 26)
            glowStroke(gradient, lineWidth: 14, blur: 9)
        }
        .drawingGroup()
    }

    /// A stroke straddling the screen edge: inset by half the width so the
    /// blur bleeds inward from the boundary instead of drawing a frame.
    private func glowStroke(
        _ gradient: AngularGradient,
        lineWidth: CGFloat,
        blur: CGFloat
    ) -> some View {
        Rectangle()
            .inset(by: -lineWidth / 2)
            .stroke(gradient, lineWidth: lineWidth)
            .blur(radius: blur)
    }
}

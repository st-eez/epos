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

    /// Pushes the user's style into the view; rasters rebuild once per change.
    func apply(_ style: EdgeGlowSettings) {
        model.style = style
    }

    /// Builds the panel ahead of the first recording AND forces its first
    /// render pass (order front at alpha 0, out on the next runloop turn), so
    /// the flattened glow layer is already rasterized when fn goes down —
    /// the first show pays only the fade. Prewarm uses the current main
    /// screen; a first show on a differently-sized display re-rasters once,
    /// which the quarter-resolution layers make cheap.
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
        // A fresh recording must not inherit the previous one's
        // voice-brightened layer while the mic warms up.
        model.amplitude = 0
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
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hideFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // AppKit invokes animation completions on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.visibilityGeneration == generation else { return }
                // Stop the motion only once fully faded: resetting it at fade
                // START snapped the palette while the panel was still near
                // full opacity. A show() during the fade bumps the generation
                // and keeps the motion running.
                self.model.isShown = false
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

/// Live mic level feeding the glow's brightness, whether the glow is on
/// screen (the view runs its motion only while shown), and the user's style.
@MainActor
final class RecordingEdgeGlowModel: ObservableObject {
    @Published var amplitude: Float = 0
    @Published var isShown = false
    @Published var style = EdgeGlowSettings()
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

    /// Rasters render at 1/4 linear resolution and scale up — the blur hides
    /// the upscale completely and the cached layers cost 1/16 the memory.
    private static let rasterScale: CGFloat = 4

    var body: some View {
        // Same perceptual mapping as the pill's meter bars.
        let level = pow(min(1, max(0, Double(model.amplitude) / 0.075)), 0.55)
        let style = model.style
        let base = Color(red: style.red, green: style.green, blue: style.blue)
        // The primary palette walks the base hue around the perimeter; the
        // drift palette is the same hues rotated one stop, so cross-fading
        // between them reads as color slowly wandering along the edges.
        let hues = [base, Self.hueShifted(base, degrees: 42), Self.hueShifted(base, degrees: -38)]
        let primary = AngularGradient(colors: [hues[0], hues[1], hues[2], hues[0]], center: .center)
        let drift = AngularGradient(colors: [hues[1], hues[2], hues[0], hues[1]], center: .center)
        ZStack {
            // The calm breath and the color drift: non-harmonic cycles
            // (2.7s vs 6.8s), so the combined motion takes a long time to
            // visibly repeat.
            glow(primary, style).opacity(min(1, (breathingDim ? 0.34 : 0.66) * style.intensity))
            glow(drift, style).opacity(min(1, (driftedIn ? 0.45 : 0) * style.intensity))
            // The voice: brightens the same shape as you speak.
            glow(primary, style).opacity(min(1, 0.55 * style.intensity * level))
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

    /// Static full-screen glow, flattened to one cached quarter-resolution
    /// layer per palette and scaled back up.
    private func glow(_ gradient: AngularGradient, _ style: EdgeGlowSettings) -> some View {
        GeometryReader { geo in
            let scale = Self.rasterScale
            let thickness = style.thickness
            ZStack {
                glowStroke(gradient, lineWidth: 36 * thickness / scale, blur: 26 / scale)
                glowStroke(gradient, lineWidth: 14 * thickness / scale, blur: 9 / scale)
            }
            .frame(width: geo.size.width / scale, height: geo.size.height / scale)
            .drawingGroup()
            .scaleEffect(scale, anchor: .topLeading)
        }
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

    /// The companion hues, derived from the user's base color so one color
    /// choice styles the whole gradient.
    private static func hueShifted(_ color: Color, degrees: Double) -> Color {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        var shifted = (hue + degrees / 360).truncatingRemainder(dividingBy: 1)
        if shifted < 0 { shifted += 1 }
        return Color(hue: shifted, saturation: saturation, brightness: brightness)
    }
}

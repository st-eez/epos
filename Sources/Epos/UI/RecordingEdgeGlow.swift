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
    /// Ember-only electric flicker phases: two fast non-harmonic opacity
    /// cycles (0.21s and 0.93s) multiply into an irregular crackle. Still
    /// pure layer alpha on cached rasters — no per-frame rendering.
    @State private var flickerHot = false
    @State private var flickerArc = false

    /// Rasters render at 1/4 linear resolution and scale up — the blur hides
    /// the upscale completely and the cached layers cost 1/16 the memory.
    private static let rasterScale: CGFloat = 4

    private static let emberRed = Color(red: 0.78, green: 0.07, blue: 0.05)
    private static let emberFire = Color(red: 1.0, green: 0.34, blue: 0.08)
    private static let emberDark = Color(red: 0.32, green: 0.02, blue: 0.03)
    private static let emberSmokeA = Color(red: 0.07, green: 0.005, blue: 0.015)
    private static let emberSmokeB = Color(red: 0.20, green: 0.02, blue: 0.04)
    private static let emberBoltCore = Color(red: 1.0, green: 0.55, blue: 0.3)

    /// Black-lightning surge state (ember only): a background task flashes one
    /// of the pre-rendered bolt rasters at random intervals. The task ticks
    /// once every couple of seconds — not per frame.
    @State private var boltIndex = 0
    @State private var boltVisible = false
    @State private var surgeTask: Task<Void, Never>?

    var body: some View {
        // Same perceptual mapping as the pill's meter bars.
        let level = pow(min(1, max(0, Double(model.amplitude) / 0.075)), 0.55)
        let style = model.style
        ZStack {
            if style.theme == .ember {
                emberLayers(style, level: level)
            } else {
                standardLayers(style, level: level)
            }
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
                withAnimation(.easeInOut(duration: 0.29).repeatForever(autoreverses: true)) {
                    flickerHot = true
                }
                withAnimation(.easeInOut(duration: 0.97).repeatForever(autoreverses: true)) {
                    flickerArc = true
                }
            } else {
                // Replacing the repeat-forever with a short one-shot ends it;
                // the panel is fully faded by the hide completion that flips
                // `isShown`, so the jump is invisible.
                withAnimation(.linear(duration: 0.05)) {
                    breathingDim = false
                    driftedIn = false
                    flickerHot = false
                    flickerArc = false
                }
            }
            syncSurgeTask()
        }
        .onChange(of: model.style.theme) { _, _ in
            syncSurgeTask()
        }
    }

    /// Runs while the ember aura is on screen; each tick waits a random beat,
    /// picks a bolt variant, and flashes it (sharp in, quick decay) — the
    /// irregularity that periodic autoreverse cycles cannot fake.
    private func syncSurgeTask() {
        let shouldRun = model.isShown && model.style.theme == .ember
        if shouldRun {
            guard surgeTask == nil else { return }
            surgeTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 800...2300)))
                    guard !Task.isCancelled else { return }
                    boltIndex = Int.random(in: 0..<EdgeBoltShape.variants.count)
                    withAnimation(.linear(duration: 0.04)) { boltVisible = true }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 80...170)))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.28)) { boltVisible = false }
                }
            }
        } else {
            surgeTask?.cancel()
            surgeTask = nil
            boltVisible = false
        }
    }

    /// The user-colored look: calm breath + slow palette drift + voice.
    @ViewBuilder
    private func standardLayers(_ style: EdgeGlowSettings, level: Double) -> some View {
        let base = Color(red: style.red, green: style.green, blue: style.blue)
        // The primary palette walks the base hue around the perimeter; the
        // drift palette is the same hues rotated one stop, so cross-fading
        // between them reads as color slowly wandering along the edges.
        // Non-harmonic cycles (2.7s vs 6.8s) take a long time to visibly
        // repeat.
        let hues = [base, Self.hueShifted(base, degrees: 42), Self.hueShifted(base, degrees: -38)]
        let primary = AngularGradient(colors: [hues[0], hues[1], hues[2], hues[0]], center: .center)
        let drift = AngularGradient(colors: [hues[1], hues[2], hues[0], hues[1]], center: .center)
        glow(primary, style).opacity(min(1, (breathingDim ? 0.34 : 0.66) * style.intensity))
        glow(drift, style).opacity(min(1, (driftedIn ? 0.45 : 0) * style.intensity))
        // The voice: brightens the same shape as you speak.
        glow(primary, style).opacity(min(1, 0.55 * style.intensity * level))
            .animation(.easeOut(duration: 0.08), value: model.amplitude)
    }

    /// The red/black aura. What sells "aura" over "glowing border" is the
    /// silhouette: every layer here is a FLAME-shaped raster (wavy tongues
    /// reaching inward), and billowing comes from cross-fading differently
    /// shaped bodies — a flip-book, not a re-render. Near-black smoke rolls
    /// ON TOP of the crimson, bright tips flicker fast, black lightning
    /// surges at random beats, and the voice stokes the whole fire.
    @ViewBuilder
    private func emberLayers(_ style: EdgeGlowSettings, level: Double) -> some View {
        let fire = AngularGradient(
            colors: [Self.emberRed, Self.emberFire, Self.emberDark, Self.emberRed],
            center: .center
        )
        let fireAlt = AngularGradient(
            colors: [Self.emberDark, Self.emberRed, Self.emberFire, Self.emberDark],
            center: .center
        )
        let tips = AngularGradient(
            colors: [Self.emberFire, Self.emberBoltCore, Self.emberRed, Self.emberFire],
            center: .center
        )
        let smoke = AngularGradient(
            colors: [Self.emberSmokeA, Self.emberSmokeB, Self.emberSmokeA, Self.emberSmokeB],
            center: .center
        )
        // Two flame bodies with different tongue shapes cross-fade in
        // counter-phase: the aura appears to roll and lick.
        flame(FlameEdgeShape.variants[0], fire, style, depth: 8.5, blur: 4)
            .opacity(min(1, (breathingDim ? 0.5 : 0.85) * style.intensity))
            .scaleEffect(breathingDim ? 1.0 : 1.006)
        flame(FlameEdgeShape.variants[1], fireAlt, style, depth: 9.5, blur: 4.5)
            .opacity(min(1, (driftedIn ? 0.75 : 0.15) * style.intensity))
            .scaleEffect(driftedIn ? 1.005 : 1.0)
        // Bright tips: thinner tongues, fast counter-cycled flicker.
        flame(FlameEdgeShape.variants[2], tips, style, depth: 5.5, blur: 2)
            .opacity(flickerHot ? 0.55 : 0.2)
            .opacity(flickerArc ? 1 : 0.5)
            .opacity(min(1, style.intensity))
        // The menace: dark smoke layered OVER the fire, occluding as it rolls.
        flame(FlameEdgeShape.variants[3], smoke, style, depth: 13, blur: 6)
            .opacity(min(1, (breathingDim ? 0.78 : 0.5) * style.intensity))
        // Black lightning: black-sheathed hot-core bolts, one random variant
        // at a time, flashed by the surge task.
        ForEach(0..<EdgeBoltShape.variants.count, id: \.self) { index in
            bolt(EdgeBoltShape.variants[index], style)
                .opacity(boltVisible && boltIndex == index ? min(1, style.intensity) : 0)
        }
        flame(FlameEdgeShape.variants[0], fire, style, depth: 8.5, blur: 4)
            .opacity(min(1, 0.7 * style.intensity * level))
            .animation(.easeOut(duration: 0.08), value: model.amplitude)
    }

    /// One cached quarter-res flame raster. Depth/blur are quarter-space.
    private func flame(
        _ waves: [FlameEdgeShape.Wave],
        _ gradient: AngularGradient,
        _ style: EdgeGlowSettings,
        depth: CGFloat,
        blur: CGFloat
    ) -> some View {
        GeometryReader { geo in
            let scale = Self.rasterScale
            FlameEdgeShape(
                waves: waves.map {
                    FlameEdgeShape.Wave(
                        frequency: $0.frequency,
                        amplitude: $0.amplitude * 0.6 * style.thickness,
                        phase: $0.phase
                    )
                },
                baseDepth: depth * style.thickness
            )
                .fill(gradient, style: FillStyle(eoFill: true))
                .blur(radius: blur)
                .frame(width: geo.size.width / scale, height: geo.size.height / scale)
                .drawingGroup()
                .scaleEffect(scale, anchor: .topLeading)
        }
    }

    /// One cached bolt raster: wide black sheath under a thin hot core, so
    /// the crackle reads as BLACK lightning against the red aura.
    private func bolt(_ points: [CGPoint], _ style: EdgeGlowSettings) -> some View {
        GeometryReader { geo in
            let scale = Self.rasterScale
            ZStack {
                EdgeBoltShape(points: points)
                    .stroke(Color.black, style: StrokeStyle(
                        lineWidth: 1.9, lineCap: .round, lineJoin: .miter
                    ))
                    .blur(radius: 0.7)
                EdgeBoltShape(points: points)
                    .stroke(Self.emberBoltCore, style: StrokeStyle(
                        lineWidth: 0.6, lineCap: .round, lineJoin: .miter
                    ))
            }
            .frame(width: geo.size.width / scale, height: geo.size.height / scale)
            .drawingGroup()
            .scaleEffect(scale, anchor: .topLeading)
        }
    }

    /// Static full-screen glow, flattened to one cached quarter-resolution
    /// layer per palette and scaled back up.
    private func glow(
        _ gradient: AngularGradient,
        _ style: EdgeGlowSettings,
        widthScale: CGFloat = 1
    ) -> some View {
        GeometryReader { geo in
            let scale = Self.rasterScale
            let thickness = style.thickness * widthScale
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

/// A band around the screen boundary whose INNER edge is a sum of sine waves
/// — flame tongues reaching inward. Integer frequencies keep the silhouette
/// seamless where the perimeter parameter wraps. Rendered once per variant
/// into a cached raster; the "billowing" is layers of different variants
/// cross-fading, never a live re-render.
struct FlameEdgeShape: Shape {
    struct Wave {
        let frequency: Double
        let amplitude: Double
        let phase: Double
    }

    /// Four hand-tuned tongue silhouettes (quarter-space amplitudes):
    /// two flame bodies, thin bright tips, wide rolling smoke.
    static let variants: [[Wave]] = [
        [Wave(frequency: 4, amplitude: 9, phase: 0.3),
         Wave(frequency: 9, amplitude: 5, phase: 2.1),
         Wave(frequency: 21, amplitude: 3, phase: 4.8)],
        [Wave(frequency: 5, amplitude: 8, phase: 1.2),
         Wave(frequency: 12, amplitude: 5, phase: 3.3),
         Wave(frequency: 19, amplitude: 3, phase: 0.7)],
        [Wave(frequency: 7, amplitude: 6, phase: 2.6),
         Wave(frequency: 15, amplitude: 4, phase: 5.0),
         Wave(frequency: 27, amplitude: 2.5, phase: 1.1)],
        [Wave(frequency: 3, amplitude: 11, phase: 0.9),
         Wave(frequency: 8, amplitude: 6, phase: 3.9),
         Wave(frequency: 13, amplitude: 4, phase: 5.5)]
    ]

    let waves: [Wave]
    let baseDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        let samples = 260
        let perimeter = 2 * (rect.width + rect.height)
        var inner: [CGPoint] = []
        inner.reserveCapacity(samples + 1)
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let (point, normal) = pointAndInwardNormal(
                at: CGFloat(t) * perimeter, in: rect
            )
            let wave = waves.reduce(0.0) {
                $0 + $1.amplitude * sin($1.frequency * t * 2 * .pi + $1.phase)
            }
            let depth = max(2, baseDepth + CGFloat(wave))
            inner.append(CGPoint(
                x: point.x + normal.dx * depth,
                y: point.y + normal.dy * depth
            ))
        }
        var path = Path()
        // Outer boundary past the screen edge; even-odd fill with the inner
        // wavy loop leaves the flame band.
        path.addRect(rect.insetBy(dx: -8, dy: -8))
        path.move(to: inner[0])
        path.addLines(inner)
        path.closeSubpath()
        return path
    }

    /// Walks the perimeter clockwise from the top-left corner; the normal
    /// always points into the screen.
    private func pointAndInwardNormal(
        at distance: CGFloat,
        in rect: CGRect
    ) -> (CGPoint, CGVector) {
        var d = distance
        if d <= rect.width {
            return (CGPoint(x: rect.minX + d, y: rect.minY), CGVector(dx: 0, dy: 1))
        }
        d -= rect.width
        if d <= rect.height {
            return (CGPoint(x: rect.maxX, y: rect.minY + d), CGVector(dx: -1, dy: 0))
        }
        d -= rect.height
        if d <= rect.width {
            return (CGPoint(x: rect.maxX - d, y: rect.maxY), CGVector(dx: 0, dy: -1))
        }
        d -= rect.width
        return (CGPoint(x: rect.minX, y: rect.maxY - min(d, rect.height)), CGVector(dx: 1, dy: 0))
    }
}

/// A jagged polyline hugging one screen edge — the black-lightning crackle.
/// Points are normalized to the rect; three hand-authored variants flash at
/// random via the surge task.
struct EdgeBoltShape: Shape {
    static let variants: [[CGPoint]] = [
        [CGPoint(x: 0.08, y: 0.010), CGPoint(x: 0.135, y: 0.045),
         CGPoint(x: 0.11, y: 0.085), CGPoint(x: 0.18, y: 0.060),
         CGPoint(x: 0.16, y: 0.130), CGPoint(x: 0.235, y: 0.100),
         CGPoint(x: 0.26, y: 0.160)],
        [CGPoint(x: 0.985, y: 0.30), CGPoint(x: 0.945, y: 0.36),
         CGPoint(x: 0.975, y: 0.415), CGPoint(x: 0.92, y: 0.47),
         CGPoint(x: 0.955, y: 0.52), CGPoint(x: 0.90, y: 0.585)],
        [CGPoint(x: 0.62, y: 0.985), CGPoint(x: 0.66, y: 0.930),
         CGPoint(x: 0.71, y: 0.965), CGPoint(x: 0.74, y: 0.895),
         CGPoint(x: 0.80, y: 0.940), CGPoint(x: 0.83, y: 0.870)]
    ]

    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x * rect.width, y: first.y * rect.height))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * rect.width, y: point.y * rect.height))
        }
        return path
    }
}

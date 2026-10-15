import AppKit
import SwiftUI

@MainActor
public final class RecordingIndicatorController {
    private var panel: NSPanel?
    private let log = EposLogger(category: "indicator")
    /// Bumped on every show/hide so a hide fade that finishes after a newer
    /// show can never order out the re-shown panel.
    private var visibilityGeneration = 0

    private var placementTask: Task<Void, Never>?
    private var showsNotice = false
    private(set) var targetPID: pid_t?
    private let frontmostProcessIdentifier: @MainActor () -> pid_t?
    private var targetScreen: NSScreen?
    private var nativeCaret: CGRect?
    private var nativeCaretWindow: CGRect?
    private var lastGeometry = RecordingCaretGeometry()
    private var placementMode: String?
    private static let panelSize = CGSize(width: 34, height: 34)
    private static let noticeSize = CGSize(width: 224, height: 40)
    private static let showFadeDuration: TimeInterval = 0.12
    private static let hideFadeDuration: TimeInterval = 0.18

    public init(frontmostProcessIdentifier: @escaping @MainActor () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }) {
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    /// Build the floating panel and host the supplied SwiftUI content. Idempotent —
    /// subsequent calls are no-ops; the first content sticks. Under XCTest no
    /// panel is ever built, so test runs cannot flash real windows.
    public func attach<Content: View>(content: Content) {
        guard IndicatorWindowPolicy.canPresentWindows else { return }
        guard panel == nil else { return }
        let frame = NSRect(origin: .zero, size: Self.panelSize)
        let panel = RecordingIndicatorPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Purely informational HUD — never intercept clicks meant for the app below.
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: content)
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
    }

    public func show(notice: Bool = false, newRecording: Bool = false) {
        if newRecording || targetPID == nil {
            placementTask?.cancel()
            placementTask = nil
            targetPID = frontmostProcessIdentifier()
            nativeCaret = nil
            lastGeometry = RecordingCaretGeometry()
            placementMode = nil
        }
        guard IndicatorWindowPolicy.canPresentWindows else { return }
        guard let panel else {
            log.error("show() called before attach(content:); ignoring")
            return
        }
        showsNotice = notice
        if placementTask == nil {
            targetScreen = NSScreen.main ?? NSScreen.screens.first
            updatePlacement(RecordingCaretGeometry())
            placementTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let pid = self?.targetPID else { return }
                    let geometry = await RecordingCaretReader.read(processIdentifier: pid)
                    guard !Task.isCancelled else { return }
                    self?.updatePlacement(geometry)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else {
            updatePlacement(RecordingCaretGeometry())
        }
        fadeIn(panel)
        log.info("cue show pid=\(targetPID ?? -1) notice=\(notice) window=\(panel.windowNumber) frame=\(panel.frame) visible=\(panel.isVisible) activeSpace=\(panel.isOnActiveSpace)")
    }

    public func updateNativeCaret(_ caret: CGRect?) {
        nativeCaret = caret.flatMap { RecordingIndicatorPlacementPolicy.isUsableCaret($0) ? $0 : nil }
        nativeCaretWindow = lastGeometry.window
        updatePlacement(lastGeometry)
    }

    private func fadeIn(_ panel: NSPanel) {
        visibilityGeneration += 1
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.showFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fade out, then order out — the pill yields to the text that just landed
    /// in the field instead of blinking off.
    public func hide() {
        placementTask?.cancel()
        placementTask = nil
        targetPID = nil
        nativeCaret = nil
        placementMode = nil
        guard let panel, panel.isVisible else { return }
        log.info("cue hide window=\(panel.windowNumber) frame=\(panel.frame) alpha=\(panel.alphaValue)")
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

    func resolveCaret(_ geometry: RecordingCaretGeometry, primaryScreenHeight: CGFloat) -> CGRect? {
        if let window = geometry.window {
            if let nativeCaretWindow, nativeCaretWindow != window { nativeCaret = nil }
            nativeCaretWindow = window
        }
        lastGeometry = geometry
        if let caret = geometry.caret {
            return RecordingIndicatorPlacementPolicy.appKitRect(fromAX: caret, primaryScreenHeight: primaryScreenHeight)
        }
        return nativeCaret
    }

    private func updatePlacement(_ geometry: RecordingCaretGeometry) {
        guard let panel else { return }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let caret = resolveCaret(geometry, primaryScreenHeight: primaryHeight)
        let window = geometry.window.map {
            RecordingIndicatorPlacementPolicy.appKitRect(fromAX: $0, primaryScreenHeight: primaryHeight)
        }
        if let caret, let screen = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY))
        }) {
            targetScreen = screen
        } else if let window, let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(window).area < $1.frame.intersection(window).area
        }), screen.frame.intersects(window) {
            targetScreen = screen
        }
        guard let visible = targetScreen?.visibleFrame else { return }
        let sameApplication = frontmostProcessIdentifier() == targetPID
        let placement = RecordingIndicatorPlacementPolicy.placement(
            caret: sameApplication && !showsNotice ? caret : nil,
            in: visible,
            indicatorSize: showsNotice ? Self.noticeSize : Self.panelSize
        )
        let frame = placement.frame
        panel.setFrame(frame, display: false)
        let mode: String
        if showsNotice { mode = "notice" }
        else if !sameApplication { mode = "edge-focus-moved" }
        else if placement.besideCaret {
            mode = geometry.caret == nil ? "caret-input-method" : "caret-accessibility"
        } else { mode = "edge-caret-unavailable" }
        if mode != placementMode {
            placementMode = mode
            log.info("cue placement mode=\(mode) pid=\(targetPID ?? -1) frame=\(frame) caret=\(String(describing: caret)) targetWindow=\(String(describing: window))")
        }
    }
}

private final class RecordingIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

struct RecordingIndicatorPlacementPolicy {
    nonisolated static func isUsableCaret(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width >= 0 && rect.width <= 32 && rect.height >= 4 && rect.height <= 120
    }

    // Accessibility uses a top-left origin on the primary display; AppKit uses bottom-left.
    nonisolated static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    nonisolated static func placement(
        caret: CGRect?, in visibleFrame: CGRect, indicatorSize: CGSize
    ) -> (frame: CGRect, besideCaret: Bool) {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        if let caret, isUsableCaret(caret), safe.contains(CGPoint(x: caret.midX, y: caret.midY)) {
            let x = min(max(caret.maxX + 6, safe.minX), safe.maxX - indicatorSize.width)
            for y in [caret.minY - 6 - indicatorSize.height, caret.maxY + 6] {
                let candidate = CGRect(origin: CGPoint(x: x, y: y), size: indicatorSize)
                if safe.contains(candidate) { return (candidate, true) }
            }
        }
        return (CGRect(
            x: safe.maxX - indicatorSize.width,
            y: safe.midY - indicatorSize.height / 2,
            width: indicatorSize.width,
            height: indicatorSize.height
        ), false)
    }
}

import Foundation
import SwiftUI

/// Owns which on-screen cue is showing for a dictation: the screen-edge glow, the
/// bottom-center pill, or neither.
///
/// The glow frames the WHOLE dictation — lit at fn press, brightening with the
/// voice, out at release — and unlike the pill it never hides while text streams,
/// because it is peripheral and occludes nothing. The pill is the fallback: it
/// shows whenever it is the only view of the volatile transcript.
///
/// Generic over the pill's content so the coordinator's own view type survives
/// intact and the panel is still built lazily, on first presentation.
@MainActor
final class RecordingCuePresenter<PillContent: View> {
    /// How long the preview channel may go unconfirmed before the pill presents
    /// and the glow retires (probe dead, connect failure, begin refused — paths
    /// that never activate mirroring). The healthy path activates within the begin
    /// round-trip, a few milliseconds.
    static var fallbackDelay: Duration { .milliseconds(200) }

    /// True while the screen-edge glow is on.
    private(set) var edgeGlowVisible = false
    /// True while the pill panel is presented. Window ordering is a no-op in
    /// test processes, so this flag is the pill's testable presentation state,
    /// like `edgeGlowVisible`.
    private(set) var pillVisible = false

    private let makePillContent: @MainActor () -> PillContent
    private lazy var pill: RecordingIndicatorController = {
        let controller = RecordingIndicatorController()
        controller.attach(content: makePillContent())
        return controller
    }()
    private lazy var edgeGlow = RecordingEdgeGlowController()

    init(makePillContent: @escaping @MainActor () -> PillContent) {
        self.makePillContent = makePillContent
    }

    // MARK: - Presentation

    /// The glow lights instantly at fn press — before the AX capture and (with the
    /// preview on) the probe handshake, so the prewarmed panel makes this a pure
    /// fade. With the glow turned off in settings the pill shows instead, exactly
    /// as it always has.
    ///
    /// With the preview on the glow doubles as the channel's cue: if the preview
    /// never confirms within the deadline (unidentifiable target, probe dead, begin
    /// refused), the glow retires and the pill takes over, so the user is never
    /// left with a glow advertising a channel that is not streaming.
    func presentForRecordingStart(
        glowEnabled: Bool,
        previewEnabled: Bool,
        previewStillUnconfirmed: @escaping @MainActor () -> Bool
    ) {
        guard glowEnabled else {
            showPill()
            return
        }
        showEdgeGlow()
        guard previewEnabled else {
            // No preview: the glow frames the recording, and the pill presents
            // alongside it because it is the only view of the volatile transcript.
            showPill()
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.fallbackDelay)
            guard let self, previewStillUnconfirmed() else { return }
            self.hideEdgeGlow()
            self.showPill()
        }
    }

    func showPill() {
        pillVisible = true
        pill.show()
    }

    func hidePill() {
        pillVisible = false
        pill.hide()
    }

    func showEdgeGlow() {
        guard !edgeGlowVisible else { return }
        edgeGlowVisible = true
        edgeGlow.show()
    }

    func hideEdgeGlow() {
        guard edgeGlowVisible else { return }
        edgeGlowVisible = false
        edgeGlow.hide()
    }

    // MARK: - Edge glow styling

    func applyEdgeGlowStyle(_ style: EdgeGlowSettings) {
        edgeGlow.apply(style)
    }

    func prewarmEdgeGlow() {
        edgeGlow.prewarm()
    }

    /// Only while the glow is actually up: a retired glow's hidden view has no
    /// business animating per buffer.
    func updateEdgeGlowAmplitude(_ amplitude: Float) {
        guard edgeGlowVisible else { return }
        edgeGlow.updateAmplitude(amplitude)
    }
}

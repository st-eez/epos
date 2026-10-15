import Foundation
import SwiftUI

@MainActor
final class RecordingCuePresenter<PillContent: View> {
    private(set) var edgeGlowVisible = false
    private(set) var pillVisible = false

    private let makePillContent: @MainActor () -> PillContent
    private lazy var pill: RecordingIndicatorController = { @MainActor in
        let controller = RecordingIndicatorController()
        controller.attach(content: makePillContent())
        return controller
    }()
    private lazy var edgeGlow = RecordingEdgeGlowController()

    init(makePillContent: @escaping @MainActor () -> PillContent) {
        self.makePillContent = makePillContent
    }

    func presentForRecordingStart(glowEnabled: Bool) {
        showPill(newRecording: true)
        if glowEnabled { showEdgeGlow() }
    }

    func showPill(notice: Bool = false, newRecording: Bool = false) {
        pillVisible = true
        pill.show(notice: notice, newRecording: newRecording)
    }

    func updateNativeCaret(_ caret: CGRect?) {
        guard pillVisible else { return }
        pill.updateNativeCaret(caret)
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

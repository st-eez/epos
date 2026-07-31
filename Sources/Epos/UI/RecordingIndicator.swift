import Foundation
import SwiftUI

public struct RecordingIndicator: View {
    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        if coordinator.indicatorBadge {
            RecordingCaretBadgeSurface(amplitude: coordinator.amplitude)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RecordingIndicatorSurface(
                state: coordinator.state,
                finalizationPhase: coordinator.finalizationPhase,
                amplitude: coordinator.amplitude,
                startUnavailable: coordinator.startUnavailable,
                insertionUnavailable: coordinator.insertionUnavailable,
                transcriptPreview: coordinator.hudTranscriptPreview
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 20)
        }
    }
}

/// The caret indicator shown while dictation is live but no text is streaming
/// (pre-first-word and during silences): a Liquid Glass orb holding a live
/// teal amplitude meter, so it reads "mic is hot and hearing you" in Epos's
/// own glass + teal language rather than native dictation's blue bubble.
struct RecordingCaretBadgeSurface: View {
    let amplitude: Float

    var body: some View {
        // Inverted from the pill's palette on purpose: a solid-teal glass orb
        // with grey-white bars is findable in peripheral vision, where a clear
        // orb with teal bars vanished unless you knew where to look.
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.black.opacity(
                        RecordingIndicatorSurface.barOpacity(index, amplitude: amplitude)
                    ))
                    .frame(
                        width: 2.5,
                        height: RecordingIndicatorSurface.barHeight(index, amplitude: amplitude) * 0.7
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fully opaque fill, not glass tint: Glass composites its tint against
        // the sampled backdrop (grey over dark windows), and partial opacity
        // read as washed out. The rim highlight alone carries the depth.
        .background(Circle().fill(EposPalette.teal))
        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(RecordingCaretBadgePolicy.badgeInset)
        .animation(.easeOut(duration: 0.08), value: amplitude)
    }
}

/// Compact, non-interactive recording pill. Liquid Glass, content-hugging:
/// a small capsule while it is only the "mic is hot" cue, widening to carry
/// the transcript line when the pill is the sole transcript surface (preview
/// disabled or degraded).
struct RecordingIndicatorSurface: View {
    let state: CoordinatorState
    let finalizationPhase: FinalizationPhase
    let amplitude: Float
    /// Flash a red "Not ready" notice: a held-fn dictation was dropped because
    /// bootstrap finished without a capture format.
    let startUnavailable: Bool
    let insertionUnavailable: Bool
    let transcriptPreview: String

    private let teal = EposPalette.teal
    private let amber = EposPalette.amber

    init(
        state: CoordinatorState,
        finalizationPhase: FinalizationPhase = .finalizingSpeech,
        amplitude: Float,
        startUnavailable: Bool = false,
        insertionUnavailable: Bool = false,
        transcriptPreview: String = ""
    ) {
        self.state = state
        self.finalizationPhase = finalizationPhase
        self.amplitude = amplitude
        self.startUnavailable = startUnavailable
        self.insertionUnavailable = insertionUnavailable
        self.transcriptPreview = transcriptPreview
    }

    var body: some View {
        content
            .animation(.easeOut(duration: 0.08), value: amplitude)
    }

    /// The wide form exists only while the pill carries the transcript line;
    /// its fixed width keeps the glass from resizing on every word.
    @ViewBuilder private var content: some View {
        if state == .recording, !transcriptPreview.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                statusRow
                Text(transcriptPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 304, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            // Clear glass, not regular: the cue capsule floats over arbitrary
            // app content, and regular glass over dark windows collapses into
            // a flat smoked pill with no visible refraction. While listening,
            // a specular sheen sweeps through the glass; notices stay still so
            // a red "Not inserted" reads as a warning, not a decoration.
            statusRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.clear, in: Capsule())
                .overlay {
                    if state == .recording, noticeText == nil {
                        GlassShimmer()
                            .clipShape(Capsule())
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// A diagonal specular band that sweeps across the capsule during the
    /// pre-text window (the only time the capsule is on screen), then rests
    /// off-glass for the remainder of each cycle so the pill breathes instead
    /// of strobing. Timeline-driven: no stored animation state, and rendering
    /// pauses whenever the panel is ordered out.
    private struct GlassShimmer: View {
        private static let period: TimeInterval = 2.6
        /// Fraction of each cycle spent traversing the glass.
        private static let sweepFraction = 0.45
        private static let bandWidth: CGFloat = 56

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                GeometryReader { geo in
                    let cycle = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.period) / Self.period
                    let sweep = min(cycle / Self.sweepFraction, 1)
                    let travel = (geo.size.width + Self.bandWidth * 2) * sweep
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: Self.bandWidth, height: geo.size.height * 2.4)
                    .rotationEffect(.degrees(16))
                    .offset(x: travel - Self.bandWidth * 2, y: -geo.size.height * 0.7)
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusDot
            if state == .recording {
                amplitudeMeter
            } else {
                activitySpinner
            }
            statusLabel
        }
    }

    private var statusLabel: some View {
        Text(noticeText ?? Self.statusText(state: state, finalizationPhase: finalizationPhase))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var noticeText: String? {
        if insertionUnavailable { return "Not inserted" }
        if startUnavailable { return "Not ready" }
        return nil
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
            .shadow(color: statusColor.opacity(0.34), radius: state == .recording ? 5 : 0)
    }

    private var amplitudeMeter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(teal.opacity(Self.barOpacity(index, amplitude: amplitude)))
                    .frame(width: 3, height: Self.barHeight(index, amplitude: amplitude))
            }
        }
        .frame(width: 24, height: 20)
    }

    private var activitySpinner: some View {
        ProgressView()
            .controlSize(.small)
            .tint(statusColor)
            .scaleEffect(0.58)
            .frame(width: 24, height: 20)
    }

    private var statusColor: Color {
        if startUnavailable || insertionUnavailable { return EposPalette.red }
        return switch state {
        case .recording: teal
        case .finalizing: amber
        case .idle: .secondary
        }
    }

    nonisolated static func statusText(
        state: CoordinatorState,
        finalizationPhase: FinalizationPhase
    ) -> String {
        switch state {
        case .idle:
            return "Ready"
        case .recording:
            return "Listening"
        case .finalizing:
            return switch finalizationPhase {
            case .finalizingSpeech:
                "Finishing"
            case .inserting:
                "Updating"
            }
        }
    }

    nonisolated static func barHeight(_ index: Int, amplitude: Float) -> CGFloat {
        let quiet: [CGFloat] = [4, 6, 5, 7, 5]
        let loud: [CGFloat] = [10, 17, 14, 19, 15]
        let level = visualLevel(amplitude)
        return quiet[index] + (loud[index] - quiet[index]) * level
    }

    nonisolated static func barOpacity(_ index: Int, amplitude: Float) -> Double {
        let quiet: [Double] = [0.32, 0.44, 0.38, 0.48, 0.4]
        let loud: [Double] = [0.72, 0.98, 0.86, 1, 0.88]
        let level = Double(visualLevel(amplitude))
        return quiet[index] + (loud[index] - quiet[index]) * level
    }

    nonisolated private static func visualLevel(_ amplitude: Float) -> CGFloat {
        let normalized = min(1, max(0, CGFloat(amplitude) / 0.075))
        return pow(normalized, 0.55)
    }
}

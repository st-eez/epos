import Foundation
import SwiftUI

public struct RecordingIndicator: View {
    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        RecordingIndicatorSurface(
            state: coordinator.state,
            finalizationPhase: coordinator.finalizationPhase,
            amplitude: coordinator.amplitude,
            startUnavailable: coordinator.startUnavailable,
            startNotice: coordinator.startNotice,
            insertionUnavailable: coordinator.insertionUnavailable,
            insertionNotice: coordinator.insertionNotice,
            microphoneUnavailable: coordinator.microphoneUnavailable,
            recognitionUnavailable: coordinator.recognitionUnavailable,
            transcriptPreview: coordinator.hudTranscriptPreview
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 20)
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
    /// Flash a red not-ready notice: a held-fn dictation was dropped because there
    /// was no capture format.
    let startUnavailable: Bool
    /// What that notice says — it names the blocker ("Preparing", "Mic blocked")
    /// rather than always reading "Not ready".
    let startNotice: String
    let insertionUnavailable: Bool
    /// What the refused-write notice says: "Not inserted", or "No access" when the
    /// refusal was Accessibility rather than a moved target.
    let insertionNotice: String
    /// Flash a red "Mic lost" notice: the microphone went away mid-hold, so the
    /// dictation stops where it stopped. Distinct from "Not ready" — this one has
    /// a partial transcript on its way to the field.
    let microphoneUnavailable: Bool
    /// Flash a red "Recognition lost" notice: the recognizer died while fn was still
    /// held. The mic is still open, but nothing said from here on is transcribed —
    /// what came before it is written at release.
    let recognitionUnavailable: Bool
    let transcriptPreview: String

    private let teal = EposPalette.teal
    private let amber = EposPalette.amber

    init(
        state: CoordinatorState,
        finalizationPhase: FinalizationPhase = .finalizingSpeech,
        amplitude: Float,
        startUnavailable: Bool = false,
        startNotice: String = "Not ready",
        insertionUnavailable: Bool = false,
        insertionNotice: String = AppCoordinator.defaultInsertionNotice,
        microphoneUnavailable: Bool = false,
        recognitionUnavailable: Bool = false,
        transcriptPreview: String = ""
    ) {
        self.state = state
        self.finalizationPhase = finalizationPhase
        self.amplitude = amplitude
        self.startUnavailable = startUnavailable
        self.startNotice = startNotice
        self.insertionUnavailable = insertionUnavailable
        self.insertionNotice = insertionNotice
        self.microphoneUnavailable = microphoneUnavailable
        self.recognitionUnavailable = recognitionUnavailable
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
        if insertionUnavailable { return insertionNotice }
        if microphoneUnavailable { return "Mic lost" }
        if recognitionUnavailable { return "Recognition lost" }
        if startUnavailable { return startNotice }
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
        if noticeText != nil { return EposPalette.red }
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

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
            insertionUnavailable: coordinator.insertionUnavailable,
            transcriptPreview: coordinator.hudTranscriptPreview
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 20)
    }
}

/// Compact, non-interactive recording pill with a volatile transcript preview.
struct RecordingIndicatorSurface: View {
    let state: CoordinatorState
    let finalizationPhase: FinalizationPhase
    let amplitude: Float
    /// Flash a red "Not ready" notice: a held-fn dictation was dropped because
    /// bootstrap finished without a capture format.
    let startUnavailable: Bool
    let insertionUnavailable: Bool
    let transcriptPreview: String

    private let panelColor = Color(red: 0.1, green: 0.12, blue: 0.14)
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
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(panelColor.opacity(0.9))
            )
            .overlay(surfaceStroke)
            .shadow(color: .black.opacity(0.17), radius: 12, x: 0, y: 6)
            .animation(.easeOut(duration: 0.08), value: amplitude)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusDot
                if state == .recording {
                    amplitudeMeter
                } else {
                    activitySpinner
                }
                statusLabel
            }
            if state == .recording, !transcriptPreview.isEmpty {
                Text(transcriptPreview)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 304, alignment: .leading)
        .frame(minHeight: 36, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var statusLabel: some View {
        Text(noticeText ?? Self.statusText(state: state, finalizationPhase: finalizationPhase))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
            .lineLimit(1)
    }

    private let cornerRadius: CGFloat = 18

    private var noticeText: String? {
        if insertionUnavailable { return "Not inserted" }
        if startUnavailable { return "Not ready" }
        return nil
    }

    private var surfaceStroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.18), .white.opacity(0.07), teal.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
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
        case .idle: .white.opacity(0.34)
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

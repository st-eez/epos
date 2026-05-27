import Foundation
import SwiftUI

enum RecordingIndicatorDisplayMode {
    case transcriptPreview
    case inlineStatus
}

public struct RecordingIndicator: View {
    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        RecordingIndicatorSurface(
            state: coordinator.state,
            transcript: coordinator.displayText,
            amplitude: coordinator.amplitude,
            displayMode: .transcriptPreview
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

struct RecordingIndicatorSurface: View {
    nonisolated private static let maxDisplayLines = 5
    nonisolated private static let maxDisplayCharacters = 240

    let state: CoordinatorState
    let transcript: String
    let amplitude: Float
    let displayMode: RecordingIndicatorDisplayMode

    private let panelColor = Color(red: 0.1, green: 0.12, blue: 0.14)
    private let teal = EposPalette.teal
    private let amber = EposPalette.amber

    init(
        state: CoordinatorState,
        transcript: String,
        amplitude: Float,
        displayMode: RecordingIndicatorDisplayMode = .transcriptPreview
    ) {
        self.state = state
        self.transcript = transcript
        self.amplitude = amplitude
        self.displayMode = displayMode
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            statusCluster
            if let transcriptText = presentation.transcriptText {
                self.transcriptText(transcriptText)
            }
        }
        .padding(.horizontal, presentation.horizontalPadding)
        .padding(.vertical, presentation.verticalPadding)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(panelColor.opacity(0.9))
        )
        .overlay(surfaceStroke)
        .shadow(color: .black.opacity(0.17), radius: 16, x: 0, y: 9)
        .frame(minWidth: presentation.minWidth, maxWidth: presentation.maxWidth, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: amplitude)
    }

    private var presentation: RecordingIndicatorPresentation {
        Self.presentation(mode: displayMode, transcript: transcript)
    }

    private var statusCluster: some View {
        HStack(spacing: 7) {
            statusDot
            amplitudeMeter
        }
        .frame(height: 24)
        .padding(.horizontal, 6)
        .background(.white.opacity(0.035), in: Capsule())
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

    private func transcriptText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: presentation.hasTranscript ? .semibold : .medium))
            .foregroundStyle(.white.opacity(presentation.hasTranscript ? 0.94 : 0.56))
            .lineLimit(Self.maxDisplayLines)
            .lineSpacing(1)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: presentation.maxTranscriptWidth, alignment: .leading)
            .frame(minHeight: 35, alignment: .leading)
            .transaction { transaction in
                transaction.animation = nil
            }
    }

    private var surfaceStroke: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.18), .white.opacity(0.07), teal.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var statusColor: Color {
        switch state {
        case .recording: teal
        case .finalizing: amber
        case .idle: .white.opacity(0.34)
        }
    }

    nonisolated static func presentation(
        mode: RecordingIndicatorDisplayMode,
        transcript: String
    ) -> RecordingIndicatorPresentation {
        switch mode {
        case .transcriptPreview:
            let transcriptText = recentDisplayText(transcript)
            return RecordingIndicatorPresentation(
                transcriptText: transcriptText,
                hasTranscript: !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                minWidth: 260,
                maxWidth: 500,
                maxTranscriptWidth: 410,
                horizontalPadding: 10,
                verticalPadding: 7
            )
        case .inlineStatus:
            return RecordingIndicatorPresentation(
                transcriptText: nil,
                hasTranscript: false,
                minWidth: 96,
                maxWidth: 144,
                maxTranscriptWidth: 0,
                horizontalPadding: 8,
                verticalPadding: 6
            )
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

    nonisolated static func recentDisplayText(
        _ text: String,
        maxCharacters: Int = maxDisplayCharacters
    ) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Listening..." }
        guard cleaned.count > maxCharacters else { return cleaned }

        let suffixStart = cleaned.index(cleaned.endIndex, offsetBy: -maxCharacters)
        let suffix = cleaned[suffixStart...]
        let boundary = suffix.firstIndex(where: { $0.isWhitespace }) ?? suffix.startIndex
        let recent = suffix[boundary...].trimmingCharacters(in: .whitespacesAndNewlines)
        return recent.isEmpty ? String(suffix) : "... \(recent)"
    }

    nonisolated private static func visualLevel(_ amplitude: Float) -> CGFloat {
        let normalized = min(1, max(0, CGFloat(amplitude) / 0.075))
        return pow(normalized, 0.55)
    }
}

struct RecordingIndicatorPresentation {
    let transcriptText: String?
    let hasTranscript: Bool
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let maxTranscriptWidth: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
}

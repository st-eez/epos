import Foundation
import SwiftUI

public struct RecordingIndicator: View {
    public static let windowID = "recording-indicator"

    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        RecordingIndicatorSurface(
            state: coordinator.state,
            transcript: coordinator.displayText,
            amplitude: coordinator.amplitude
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    nonisolated static func barHeight(_ index: Int, amplitude: Float) -> CGFloat {
        RecordingIndicatorSurface.barHeight(index, amplitude: amplitude)
    }

    nonisolated static func barOpacity(_ index: Int, amplitude: Float) -> Double {
        RecordingIndicatorSurface.barOpacity(index, amplitude: amplitude)
    }
}

struct RecordingIndicatorSurface: View {
    let state: CoordinatorState
    let transcript: String
    let amplitude: Float

    private let panelColor = Color(red: 0.1, green: 0.12, blue: 0.14)
    private let teal = Color(red: 0.22, green: 0.78, blue: 0.72)
    private let amber = Color(red: 0.86, green: 0.55, blue: 0.18)
    private let maxTranscriptWidth: CGFloat = 430

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            statusCluster
            transcriptText
            keyCap
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(panelColor.opacity(0.9))
        )
        .overlay(surfaceStroke)
        .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 11)
        .frame(minWidth: 300, maxWidth: 560, alignment: .center)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: displayText)
        .animation(.easeOut(duration: 0.08), value: amplitude)
    }

    private var displayText: String {
        transcript.isEmpty ? "Listening..." : transcript
    }

    private var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusCluster: some View {
        HStack(spacing: 9) {
            statusDot
            amplitudeMeter
        }
        .frame(height: 28)
        .padding(.horizontal, 8)
        .background(.white.opacity(0.055), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .shadow(color: statusColor.opacity(0.38), radius: state == .recording ? 6 : 0)
    }

    private var amplitudeMeter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(teal.opacity(Self.barOpacity(index, amplitude: amplitude)))
                    .frame(width: 3, height: Self.barHeight(index, amplitude: amplitude))
            }
        }
        .frame(width: 26, height: 22)
    }

    private var transcriptText: some View {
        Text(displayText)
            .font(.system(size: 14, weight: hasTranscript ? .semibold : .medium))
            .foregroundStyle(.white.opacity(hasTranscript ? 0.94 : 0.56))
            .lineLimit(2)
            .lineSpacing(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 155, maxWidth: maxTranscriptWidth, alignment: .leading)
    }

    private var keyCap: some View {
        Text("fn")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 29, height: 22)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
    }

    private var surfaceStroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
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

    nonisolated static func barHeight(_ index: Int, amplitude: Float) -> CGFloat {
        let quiet: [CGFloat] = [5, 7, 6, 8, 6]
        let loud: [CGFloat] = [12, 20, 16, 22, 18]
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

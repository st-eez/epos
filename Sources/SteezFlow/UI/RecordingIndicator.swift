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
    private let maxTranscriptWidth: CGFloat = 500

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            statusCluster
            transcriptText
            keyCap
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(panelColor.opacity(0.9))
        )
        .overlay(surfaceStroke)
        .shadow(color: .black.opacity(0.22), radius: 28, x: 0, y: 16)
        .frame(minWidth: 360, maxWidth: 660, alignment: .center)
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
        .frame(height: 36)
        .padding(.horizontal, 10)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 9, height: 9)
            .shadow(color: statusColor.opacity(0.42), radius: state == .recording ? 8 : 0)
    }

    private var amplitudeMeter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(teal.opacity(Self.barOpacity(index, amplitude: amplitude)))
                    .frame(width: 4, height: Self.barHeight(index, amplitude: amplitude))
            }
        }
        .frame(width: 32, height: 28)
    }

    private var transcriptText: some View {
        Text(displayText)
            .font(.system(size: 15, weight: hasTranscript ? .semibold : .medium))
            .foregroundStyle(.white.opacity(hasTranscript ? 0.94 : 0.56))
            .lineLimit(2)
            .lineSpacing(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 180, maxWidth: maxTranscriptWidth, alignment: .leading)
    }

    private var keyCap: some View {
        Text("fn")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 34, height: 26)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
    }

    private var surfaceStroke: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
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
        let quiet: [CGFloat] = [6, 9, 7, 11, 8]
        let loud: [CGFloat] = [16, 26, 21, 29, 23]
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

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

    nonisolated static func recentDisplayText(_ text: String, maxCharacters: Int = 160) -> String {
        RecordingIndicatorSurface.recentDisplayText(text, maxCharacters: maxCharacters)
    }
}

struct RecordingIndicatorSurface: View {
    let state: CoordinatorState
    let transcript: String
    let amplitude: Float

    private let panelColor = Color(red: 0.1, green: 0.12, blue: 0.14)
    private let teal = Color(red: 0.22, green: 0.78, blue: 0.72)
    private let amber = Color(red: 0.86, green: 0.55, blue: 0.18)
    private let maxTranscriptWidth: CGFloat = 370

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            statusCluster
            transcriptText
            keyCap
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(panelColor.opacity(0.9))
        )
        .overlay(surfaceStroke)
        .shadow(color: .black.opacity(0.17), radius: 16, x: 0, y: 9)
        .frame(minWidth: 260, maxWidth: 500, alignment: .center)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: displayText)
        .animation(.easeOut(duration: 0.08), value: amplitude)
    }

    private var displayText: String {
        Self.recentDisplayText(transcript)
    }

    private var hasTranscript: Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var transcriptText: some View {
        Text(displayText)
            .font(.system(size: 14, weight: hasTranscript ? .semibold : .medium))
            .foregroundStyle(.white.opacity(hasTranscript ? 0.94 : 0.56))
            .lineLimit(2)
            .lineSpacing(1)
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 135, maxWidth: maxTranscriptWidth, alignment: .leading)
    }

    private var keyCap: some View {
        Text("fn")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 27, height: 20)
            .background(.white.opacity(0.085), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
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

    nonisolated static func recentDisplayText(_ text: String, maxCharacters: Int = 160) -> String {
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

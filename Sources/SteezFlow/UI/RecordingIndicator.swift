import SwiftUI

public struct RecordingIndicator: View {
    public static let windowID = "recording-indicator"

    @ObservedObject var coordinator: AppCoordinator
    private let maxTranscriptWidth: CGFloat = 460

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusDot
                .padding(.top, 9)
            amplitudeMeter
                .padding(.top, 5)
            Text(displayText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 170, maxWidth: maxTranscriptWidth, alignment: .leading)
            Text("fn")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.76))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.12), in: Capsule())
                .padding(.top, 7)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(red: 0.11, green: 0.13, blue: 0.15).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 24, x: 0, y: 14)
        .frame(minWidth: 340, maxWidth: 620, alignment: .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var displayText: String {
        coordinator.displayText.isEmpty ? "Listening..." : coordinator.displayText
    }

    private var statusDot: some View {
        Circle()
            .fill(coordinator.state == .recording ? Color(red: 0.9, green: 0.28, blue: 0.3) : .secondary)
            .frame(width: 10, height: 10)
            .shadow(
                color: coordinator.state == .recording ? Color(red: 0.9, green: 0.28, blue: 0.3).opacity(0.34) : .clear,
                radius: 6
            )
    }

    private var amplitudeMeter: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color(red: 0.22, green: 0.78, blue: 0.72).opacity(Self.barOpacity(index, amplitude: coordinator.amplitude)))
                    .frame(width: 4, height: Self.barHeight(index, amplitude: coordinator.amplitude))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: coordinator.amplitude)
    }

    nonisolated static func barHeight(_ index: Int, amplitude: Float) -> CGFloat {
        let quiet: [CGFloat] = [5, 7, 6, 8, 6]
        let loud: [CGFloat] = [14, 23, 18, 26, 20]
        let level = visualLevel(amplitude)
        return quiet[index] + (loud[index] - quiet[index]) * level
    }

    nonisolated static func barOpacity(_ index: Int, amplitude: Float) -> Double {
        let quiet: [Double] = [0.38, 0.5, 0.44, 0.54, 0.46]
        let loud: [Double] = [0.76, 0.98, 0.88, 1, 0.9]
        let level = Double(visualLevel(amplitude))
        return quiet[index] + (loud[index] - quiet[index]) * level
    }

    nonisolated private static func visualLevel(_ amplitude: Float) -> CGFloat {
        let normalized = min(1, max(0, CGFloat(amplitude) / 0.09))
        return pow(normalized, 0.55)
    }
}

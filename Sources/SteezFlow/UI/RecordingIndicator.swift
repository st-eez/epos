import SwiftUI

public struct RecordingIndicator: View {
    public static let windowID = "recording-indicator"

    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(coordinator.state == .recording ? .red : .secondary)
                .frame(width: 10, height: 10)
            Capsule()
                .fill(.tint)
                .frame(width: max(4, CGFloat(coordinator.amplitude) * 120), height: 4)
            Text(coordinator.partialTranscript.isEmpty ? "Listening…" : coordinator.partialTranscript)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 280, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .frame(minWidth: 360)
    }
}

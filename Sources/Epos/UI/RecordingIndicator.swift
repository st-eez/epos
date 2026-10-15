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
            recognitionUnavailable: coordinator.recognitionUnavailable
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

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
    /// Names a refused write or asks the user to check an unconfirmed delivery.
    let insertionNotice: String
    /// Flash a red "Mic lost" notice: the microphone went away mid-hold, so the
    /// dictation stops where it stopped. Distinct from "Not ready" — this one has
    /// a partial transcript on its way to the field.
    let microphoneUnavailable: Bool
    /// Flash a red "Recognition lost" notice: the recognizer died while fn was still
    /// held. The mic is still open, but nothing said from here on is transcribed —
    /// what came before it is written at release.
    let recognitionUnavailable: Bool

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
        recognitionUnavailable: Bool = false
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
    }

    var body: some View {
        Group {
            if let noticeText {
                Label(noticeText, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(EposPalette.red)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Group {
                    if state == .finalizing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(amber)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(teal.opacity(Self.microphoneOpacity(amplitude)))
                    }
                }
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: Circle())
            }
        }
        .animation(.easeOut(duration: 0.08), value: amplitude)
        .accessibilityLabel(noticeText ?? Self.statusText(state: state, finalizationPhase: finalizationPhase))
    }

    private var noticeText: String? {
        if insertionUnavailable { return insertionNotice }
        if microphoneUnavailable { return "Mic lost" }
        if recognitionUnavailable { return "Recognition lost" }
        if startUnavailable { return startNotice }
        return nil
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

    nonisolated static func microphoneOpacity(_ amplitude: Float) -> Double {
        let level = min(1, max(0, Double(amplitude) / 0.075))
        return 0.55 + 0.45 * pow(level, 0.55)
    }
}

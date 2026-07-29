import Foundation

public enum ReliabilityOutcome: String, Sendable {
    case setupFailed = "setup-failed"
    case noInput = "no-input"
    case recognizerFailed = "recognizer-failed"
    case emptyTranscript = "empty-transcript"
    case targetRefused = "target-refused"
    case backendRefused = "backend-refused"
    case deliveryVerified = "delivery-verified"
    case deliveryMismatch = "delivery-mismatch"
    case writeAcceptedUnverified = "write-accepted-unverified"
    case cancelledBeforeAudio = "cancelled-before-audio"

}

/// Per-recording, privacy-safe operational evidence. The terminal emitter is
/// idempotent so overlapping teardown paths cannot create two outcomes.
public final class ReliabilityRecording: @unchecked Sendable {
    private struct State {
        var audioBuffers = 0
        var audioFrames = 0
        var releasedAt: ContinuousClock.Instant?
        var didEmit = false
    }

    private let recordingID: String
    private let log: EposLogger
    private let clock = ContinuousClock()
    private let lock = NSLock()
    private var state = State()

    public init(recordingID: String, diagnostics: DiagnosticLogSink = .shared) {
        self.recordingID = recordingID
        self.log = EposLogger(category: "reliability", diagnostics: diagnostics)
        self.log.info("reliability start schema=1", recordingID: recordingID)
    }

    public func recordAudioBuffer(frameCount: Int) {
        lock.withLock {
            state.audioBuffers += 1
            state.audioFrames += max(0, frameCount)
        }
    }

    public func markReleased() {
        lock.withLock {
            if state.releasedAt == nil {
                state.releasedAt = clock.now
            }
        }
    }

    public var hasAudioInput: Bool {
        lock.withLock { state.audioBuffers > 0 && state.audioFrames > 0 }
    }

    public func emit(
        _ outcome: ReliabilityOutcome,
        transcriptUTF16: Int = 0,
        writeAttempted: Bool = false,
        writeAccepted: Bool = false,
        readbackAvailable: Bool = false,
        readbackMatched: Bool = false
    ) {
        let snapshot: (audioBuffers: Int, audioFrames: Int, latencyMs: Int)? = lock.withLock {
            guard !state.didEmit else { return nil }
            state.didEmit = true
            let latencyMs: Int
            if let releasedAt = state.releasedAt {
                let elapsed = releasedAt.duration(to: clock.now)
                let components = elapsed.components
                latencyMs = max(0, Int(components.seconds * 1_000) +
                    Int(components.attoseconds / 1_000_000_000_000_000))
            } else {
                latencyMs = -1
            }
            return (state.audioBuffers, state.audioFrames, latencyMs)
        }
        guard let snapshot else { return }

        log.info(
            "reliability outcome " +
                "schema=1 " +
                "outcome=\(outcome.rawValue) " +
                "audioBuffers=\(snapshot.audioBuffers) " +
                "audioFrames=\(snapshot.audioFrames) " +
                "transcriptUTF16=\(max(0, transcriptUTF16)) " +
                "writeAttempted=\(writeAttempted) " +
                "writeAccepted=\(writeAccepted) " +
                "readbackAvailable=\(readbackAvailable) " +
                "readbackMatched=\(readbackMatched) " +
                "latencyMs=\(snapshot.latencyMs)",
            recordingID: recordingID
        )
    }

    /// Collapse final insertion and readback evidence into one terminal outcome.
    /// A recognizer failure remains authoritative even when a trailing partial
    /// was successfully delivered; the write fields preserve that secondary fact.
    public func emitFinal(
        recognizerFailed: Bool,
        insertionResult: FinalInsertionResult,
        delivery: FinalInsertionDeliveryVerification,
        transcriptUTF16: Int
    ) {
        let evidence: (
            outcome: ReliabilityOutcome,
            writeAttempted: Bool,
            writeAccepted: Bool,
            readbackAvailable: Bool,
            readbackMatched: Bool
        )
        switch insertionResult {
        case .targetRefused:
            evidence = (.targetRefused, false, false, false, false)
        case .backendRefused:
            evidence = (.backendRefused, true, false, false, false)
        case .accepted:
            switch delivery {
            case .matched:
                evidence = (.deliveryVerified, true, true, true, true)
            case .mismatched:
                evidence = (.deliveryMismatch, true, true, true, false)
            case .unavailable:
                evidence = (.writeAcceptedUnverified, true, true, false, false)
            }
        }
        emit(
            recognizerFailed ? .recognizerFailed : evidence.outcome,
            transcriptUTF16: transcriptUTF16,
            writeAttempted: evidence.writeAttempted,
            writeAccepted: evidence.writeAccepted,
            readbackAvailable: evidence.readbackAvailable,
            readbackMatched: evidence.readbackMatched
        )
    }
}

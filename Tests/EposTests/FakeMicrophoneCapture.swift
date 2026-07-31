import AVFoundation
@testable import Epos

/// Ordered log of the things `startRecording` does, so a test can assert what
/// happened before what.
final class RecordingStartEventLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

/// Stands in for the real microphone. `startRecording` opens the mic
/// synchronously at fn press, so every test that drives it needs this — otherwise
/// `swift test` would open the machine's actual input device.
final class FakeMicrophoneCapture: MicrophoneCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onAmplitude: ((Float) -> Void)?
    var onCaptureFailure: ((Error) -> Void)?

    /// Set to model a mic that refuses to open.
    var startError: (any Error)?
    var events: RecordingStartEventLog?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isCapturing = false

    func start(targetFormat: AVAudioFormat) throws {
        if let startError {
            throw startError
        }
        startCount += 1
        isCapturing = true
        events?.append("mic-open")
    }

    func stop() {
        if isCapturing {
            stopCount += 1
        }
        isCapturing = false
    }
}

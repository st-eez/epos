import AppKit

/// Audible "mic is hot" cue at recording start, like native dictation's pop.
/// During the recognizer's warm-up nothing moves on screen near the caret, so
/// the cue confirms the press registered without looking anywhere. Fire and
/// forget: a missing system sound just means silence, never a failed start.
@MainActor
enum RecordingStartCue {
    /// Quiet relative to alerts: a confirmation, not a notification.
    private static let volume: Float = 0.35

    private static let sound: NSSound? = {
        let sound = NSSound(named: "Pop")
        sound?.volume = volume
        return sound
    }()

    static func play() {
        guard let sound else { return }
        // A restart beats a dropped cue when recordings come back-to-back.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}

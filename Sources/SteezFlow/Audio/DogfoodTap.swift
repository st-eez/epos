import AVFoundation
import Foundation
import OSLog

/// Per-recording `.wav` capture in the mic's native format. Lives in
/// `~/Library/Caches/SteezFlow/recordings/` as future eval material for the
/// dogfood session that started 2026-05-22. **Temporary — delete this file and
/// the `onRawBuffer` hook on `AudioCapture` when the dogfood review is done.**
final class DogfoodTap: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.steez.SteezFlow", category: "dogfood")

    private let lock = NSLock()
    private var file: AVAudioFile?

    /// Append `buffer` to the current recording. Opens a new file on the first call
    /// after construction or after `stop()`. Thread-safe; called from the audio thread.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if file == nil {
                file = Self.openFile(format: buffer.format)
            }
            try? file?.write(from: buffer)
        }
    }

    /// Close the current recording. Next `write` opens a fresh file.
    func stop() {
        lock.withLock { file = nil }
    }

    private static func openFile(format: AVAudioFormat) -> AVAudioFile? {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = cachesDir.appendingPathComponent("SteezFlow/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            log.info("recording to \(url.lastPathComponent, privacy: .public)")
            return file
        } catch {
            log.error("audio file open failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

import AVFoundation
import Foundation

/// Per-recording `.wav` capture in the mic's native format. Lives in the app's
/// cache directory as opt-in eval material; disabled by default through `Settings`.
final class DogfoodTap: @unchecked Sendable {
    private static let log = EposLogger(category: "dogfood")

    /// Serial queue that owns `file`. All disk I/O happens here, never on the
    /// audio thread.
    private let queue = DispatchQueue(label: "com.steez.Epos.dogfood-write", qos: .utility)
    private let recordingsDirectory: URL?
    private var file: AVAudioFile?
    private var fileURL: URL?

    init(recordingsDirectory: URL? = nil) {
        self.recordingsDirectory = recordingsDirectory
    }

    /// Append `buffer` to the current recording. Called from the audio thread, so
    /// it does only a cheap deep-copy of the samples here (the engine reuses
    /// `buffer` after the callback returns) and hands the copy to the write queue.
    /// Opens a new file on the first write after construction or after `stop()`.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard let copy = Self.copy(buffer) else { return }
        // `copy` is freshly allocated and handed off exclusively to the write queue —
        // the audio thread never touches it again — so the transfer is safe.
        // `AVAudioPCMBuffer` is not `Sendable`, hence the explicit opt-out.
        nonisolated(unsafe) let sendableCopy = copy
        queue.async {
            if self.file == nil {
                guard let opened = Self.openFile(
                    format: sendableCopy.format,
                    recordingsDirectory: self.recordingsDirectory
                ) else { return }
                self.file = opened.file
                self.fileURL = opened.url
            }
            do {
                try self.file?.write(from: sendableCopy)
            } catch {
                Self.log.error("audio file write failed: \(String(describing: error))")
            }
        }
    }

    /// Close the current recording. Routed through the write queue so any
    /// already-enqueued writes flush first (serial FIFO). Next `write` opens a
    /// fresh file.
    func stop(keeping shouldKeep: Bool = true) {
        queue.async {
            let url = self.fileURL
            self.file = nil
            self.fileURL = nil
            if !shouldKeep, let url {
                do {
                    try FileManager.default.removeItem(at: url)
                    Self.log.info("discarded recording \(url.lastPathComponent)")
                } catch {
                    Self.log.error("recording discard failed: \(String(describing: error))")
                }
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    /// Deep-copy a buffer's samples so it survives past the audio callback. Returns
    /// nil if the sample format isn't one we know how to copy.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)

        // The channelData accessors are non-nil for BOTH layouts. Interleaved
        // formats keep every channel in one shared block (pointer [0], samples
        // strided by channelCount); deinterleaved formats give one block per
        // channel. Copy whole blocks accordingly so interleaved data isn't
        // scrambled by a per-channel stride-1 assumption.
        let interleaved = buffer.format.isInterleaved
        let blockCount = interleaved ? 1 : channelCount
        let samplesPerBlock = interleaved ? frameLength * channelCount : frameLength

        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            let bytes = samplesPerBlock * MemoryLayout<Float>.size
            for block in 0..<blockCount {
                memcpy(dst[block], src[block], bytes)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            let bytes = samplesPerBlock * MemoryLayout<Int16>.size
            for block in 0..<blockCount {
                memcpy(dst[block], src[block], bytes)
            }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            let bytes = samplesPerBlock * MemoryLayout<Int32>.size
            for block in 0..<blockCount {
                memcpy(dst[block], src[block], bytes)
            }
        } else {
            return nil
        }
        return copy
    }

    private static func openFile(
        format: AVAudioFormat,
        recordingsDirectory: URL?
    ) -> (file: AVAudioFile, url: URL)? {
        guard let dir = recordingsDirectory ?? defaultRecordingsDirectory() else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            log.info("recording to \(url.lastPathComponent)")
            return (file, url)
        } catch {
            log.error("audio file open failed: \(String(describing: error))")
            return nil
        }
    }

    private static func defaultRecordingsDirectory() -> URL? {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return cachesDir.appendingPathComponent("Epos/recordings", isDirectory: true)
    }
}

import AVFoundation
import Foundation
import Epos

enum SavedRecordingEvalSupport {
    struct Transcription {
        let text: String
        let failureMessages: [String]
    }

    static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    static func recordingsDirectory(environment: [String: String]) -> URL {
        fileURL(
            path: environment["EPOS_EVAL_RECORDINGS_DIR"]
                ?? "\(NSHomeDirectory())/Library/Caches/Epos/recordings",
            isDirectory: true
        )
    }

    static func outputURL(environment: [String: String], defaultPath: String) -> URL {
        fileURL(path: environment["EPOS_EVAL_OUTPUT"] ?? defaultPath, isDirectory: false)
    }

    static func selectedRecordings(
        in recordingsDirectory: URL,
        limit: Int?,
        latest: Bool
    ) throws -> [URL] {
        let recordings = try FileManager.default
            .contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ordered = latest ? Array(recordings.reversed()) : recordings
        let selectedCount = limit.map { max(0, $0) } ?? ordered.count
        return Array(ordered.prefix(selectedCount))
    }

    static func prepareOutput(_ outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: outputURL, atomically: true, encoding: .utf8)
    }

    static func appendJSONL<Row: Encodable>(_ row: Row, to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(row)
        guard let line = String(data: data, encoding: .utf8) else {
            throw SavedRecordingEvalError.encodingFailed
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    static func durationSeconds(recording: URL) throws -> Double {
        let file = try AVAudioFile(forReading: recording)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func transcribe(
        recording: URL,
        locale: Locale,
        contextualStrings: [String] = []
    ) async throws -> Transcription {
        let transcriber = Transcriber(locale: locale)
        guard let targetFormat = await transcriber.bestAudioFormat() else {
            throw SavedRecordingEvalError.noCompatibleFormat
        }

        let events = try await transcriber.start(contextualStrings: contextualStrings)
        let collector = Task {
            var finalText = ""
            var failures: [String] = []
            for await event in events {
                switch event {
                case .partial:
                    break
                case .final(let text):
                    finalText += text
                case .failed(let message):
                    failures.append(message)
                }
            }
            return Transcription(
                text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
                failureMessages: failures
            )
        }

        do {
            try feed(recording: recording, targetFormat: targetFormat, into: transcriber)
            await transcriber.finish()
        } catch {
            await transcriber.finish()
            throw error
        }

        let transcription = await collector.value
        if let failure = transcription.failureMessages.first {
            throw SavedRecordingEvalError.transcriptionFailed(recording.lastPathComponent, failure)
        }
        return transcription
    }

    private static func feed(
        recording: URL,
        targetFormat: AVAudioFormat,
        into transcriber: Transcriber
    ) throws {
        let file = try AVAudioFile(forReading: recording)
        let inputFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw SavedRecordingEvalError.converterUnavailable
        }
        converter.primeMethod = .none

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frameCapacity = AVAudioFrameCount(min(remaining, 4_096))
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
                throw SavedRecordingEvalError.bufferUnavailable
            }
            try file.read(into: inputBuffer, frameCount: frameCapacity)
            guard inputBuffer.frameLength > 0 else { continue }

            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw SavedRecordingEvalError.bufferUnavailable
            }

            let pending = SavedRecordingEvalInputBox(inputBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard let next = pending.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return next
            }

            if status == .error {
                throw conversionError ?? SavedRecordingEvalError.conversionFailed
            }
            guard outputBuffer.frameLength > 0 else { continue }
            transcriber.accept(outputBuffer)
        }
    }

    private static func fileURL(path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: isDirectory)
    }
}

enum PolishEvalScoring {
    static func retainsFiller(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return !PolishVocabulary.singleFillers.isDisjoint(with: Set(words))
    }
}

private final class SavedRecordingEvalInputBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

enum SavedRecordingEvalError: Error, CustomStringConvertible {
    case bufferUnavailable
    case converterUnavailable
    case conversionFailed
    case encodingFailed
    case noCompatibleFormat
    case transcriptionFailed(String, String)

    var description: String {
        switch self {
        case .bufferUnavailable:
            return "audio buffer unavailable"
        case .converterUnavailable:
            return "audio converter unavailable"
        case .conversionFailed:
            return "audio conversion failed"
        case .encodingFailed:
            return "JSONL encoding failed"
        case .noCompatibleFormat:
            return "SpeechTranscriber has no compatible audio format"
        case .transcriptionFailed(let file, let message):
            return "transcription failed for \(file): \(message)"
        }
    }
}

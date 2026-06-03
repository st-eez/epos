import AVFoundation
import Foundation
@testable import Epos

enum SavedRecordingEvalSupport {
    struct Transcription {
        let text: String
        let failureMessages: [String]
        let alternatives: [String]
        let alternativeTranscripts: [String]
        let alternativeTranscriptCandidates: [AlternativeTranscriptCandidate]
        let confidenceMean: Double?
        let confidenceMinimum: Double?
        let contextReadback: [String]

        init(
            text: String,
            failureMessages: [String],
            alternatives: [String] = [],
            alternativeTranscripts: [String] = [],
            alternativeTranscriptCandidates: [AlternativeTranscriptCandidate] = [],
            confidenceMean: Double? = nil,
            confidenceMinimum: Double? = nil,
            contextReadback: [String] = []
        ) {
            self.text = text
            self.failureMessages = failureMessages
            self.alternatives = alternatives
            self.alternativeTranscripts = alternativeTranscripts
            self.alternativeTranscriptCandidates = alternativeTranscriptCandidates
            self.confidenceMean = confidenceMean
            self.confidenceMinimum = confidenceMinimum
            self.contextReadback = contextReadback
        }
    }

    struct AlternativeTranscriptCandidate: Codable {
        let text: String
        let confidenceMean: Double?
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

    static func groundTruthManifest(
        in recordingsDirectory: URL,
        environment: [String: String]
    ) throws -> HumanIntendedTranscriptManifest {
        if let configured = environment["EPOS_EVAL_GROUND_TRUTH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let url = fileURL(path: configured, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SavedRecordingEvalError.groundTruthManifestNotFound(url.path)
            }
            return try HumanIntendedTranscriptManifest.load(from: url)
        }

        let defaultURL = recordingsDirectory.appendingPathComponent("ground-truth.jsonl")
        guard FileManager.default.fileExists(atPath: defaultURL.path) else {
            return HumanIntendedTranscriptManifest(sourceURL: nil, transcriptsByFile: [:])
        }
        return try HumanIntendedTranscriptManifest.load(from: defaultURL)
    }

    static func selectedRecordings(
        in recordingsDirectory: URL,
        limit: Int?,
        latest: Bool,
        environment: [String: String] = [:]
    ) throws -> [URL] {
        if let explicitRecordings = try explicitlySelectedRecordings(
            in: recordingsDirectory,
            environment: environment
        ) {
            return explicitRecordings
        }

        let recordings = try FileManager.default
            .contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ordered = latest ? Array(recordings.reversed()) : recordings
        let selectedCount = limit.map { max(0, $0) } ?? ordered.count
        return Array(ordered.prefix(selectedCount))
    }

    private static func explicitlySelectedRecordings(
        in recordingsDirectory: URL,
        environment: [String: String]
    ) throws -> [URL]? {
        guard let configured = environment["EPOS_EVAL_RECORDING_FILES"] else { return nil }
        let entries = configured
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return nil }

        return try entries.map { entry in
            let url = recordingRelativeURL(path: entry, recordingsDirectory: recordingsDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SavedRecordingEvalError.recordingNotFound(url.path)
            }
            return url
        }
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

    static func polishPrewarmSettleNanoseconds(environment: [String: String]) -> UInt64 {
        let milliseconds = environment["EPOS_POLISH_EVAL_PREWARM_MS"].flatMap(UInt64.init) ?? 1_500
        return milliseconds * 1_000_000
    }

    @discardableResult
    static func waitForPolishPrewarmSettle(
        delayNanoseconds: UInt64,
        alreadyElapsedSeconds: Double = 0
    ) async -> Double {
        let requestedSeconds = Double(delayNanoseconds) / 1_000_000_000
        let remainingSeconds = max(0, requestedSeconds - alreadyElapsedSeconds)
        let remainingNanoseconds = UInt64(remainingSeconds * 1_000_000_000)
        if remainingNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: remainingNanoseconds)
        }
        return remainingSeconds
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
        try feed(recording: recording, targetFormat: targetFormat) { buffer in
            transcriber.accept(buffer)
        }
    }

    static func feed(
        recording: URL,
        targetFormat: AVAudioFormat,
        accept: (AVAudioPCMBuffer) -> Void
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
            accept(outputBuffer)
        }
    }

    private static func fileURL(path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: isDirectory)
    }

    private static func recordingRelativeURL(path: String, recordingsDirectory: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : recordingsDirectory.appendingPathComponent(expanded)
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
    case duplicateGroundTruthTranscript(String)
    case groundTruthManifestDecodeFailed(String, Int, String)
    case groundTruthManifestNotFound(String)
    case noCompatibleFormat
    case recordingNotFound(String)
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
        case .duplicateGroundTruthTranscript(let file):
            return "duplicate ground-truth transcript for \(file)"
        case .groundTruthManifestDecodeFailed(let path, let line, let message):
            return "ground-truth manifest decode failed at \(path):\(line): \(message)"
        case .groundTruthManifestNotFound(let path):
            return "ground-truth manifest not found: \(path)"
        case .noCompatibleFormat:
            return "SpeechTranscriber has no compatible audio format"
        case .recordingNotFound(let path):
            return "recording not found: \(path)"
        case .transcriptionFailed(let file, let message):
            return "transcription failed for \(file): \(message)"
        }
    }
}

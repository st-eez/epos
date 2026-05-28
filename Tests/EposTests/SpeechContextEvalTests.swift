import AVFoundation
import XCTest
@testable import Epos

/// Offline validation for recognition bias via `AnalysisContext.contextualStrings`,
/// before wiring it into the live recording path. Replays saved `.wav` captures
/// (from `DogfoodTap`, i.e. `Settings.saveAudioSamples` on) through the transcriber
/// twice — once unbiased, once with the canonicalizer's `speechContextualStrings` —
/// and reports how often the bias changed the raw transcript, the canonicalized
/// transcript, and the count of vocabulary terms that surfaced.
///
/// Skipped unless `EPOS_RUN_CONTEXT_EVAL=1`, since it needs the locale asset, real
/// recordings, and runs the model. Capture samples first: enable audio-sample
/// capture in Settings, dictate a handful of utterances that exercise your
/// vocabulary, then:
///
///   EPOS_RUN_CONTEXT_EVAL=1 swift test --filter SpeechContextEvalTests
///
/// Read `.build/evals/speech-context-eval.jsonl` (one row per recording) plus the
/// printed summary. If `with context` rarely changes anything and vocabulary hits
/// don't rise, biasing on canonical *written* forms isn't paying off — try feeding
/// spoken/alias forms instead before committing to the live wiring.
final class SpeechContextEvalTests: XCTestCase {
    func testSavedRecordingsWithAndWithoutSpeechContext() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_CONTEXT_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_CONTEXT_EVAL=1 to replay saved recordings")
        }

        let recordingsDirectory = URL(
            fileURLWithPath: environment["EPOS_EVAL_RECORDINGS_DIR"]
                ?? "\(NSHomeDirectory())/Library/Caches/Epos/recordings",
            isDirectory: true
        )
        let limit = environment["EPOS_EVAL_LIMIT"].flatMap(Int.init)
        let outputURL = URL(
            fileURLWithPath: environment["EPOS_EVAL_OUTPUT"]
                ?? ".build/evals/speech-context-eval.jsonl"
        )

        let fileManager = FileManager.default
        let recordings = try fileManager
            .contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let selectedRecordings = Array(recordings.prefix(limit ?? recordings.count))
        try XCTSkipIf(selectedRecordings.isEmpty, "No .wav recordings found at \(recordingsDirectory.path)")

        let canonicalizer = TranscriptCanonicalizer.load()
        let contextualStrings = canonicalizer.speechContextualStrings
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "".write(to: outputURL, atomically: true, encoding: .utf8)

        var summary = SpeechContextEvalSummary()
        for recording in selectedRecordings {
            let noContext = try await Self.transcribe(recording: recording, contextualStrings: [])
            let withContext = try await Self.transcribe(recording: recording, contextualStrings: contextualStrings)
            let row = SpeechContextEvalRow(
                file: recording.lastPathComponent,
                noContext: noContext,
                withContext: withContext,
                noContextCanonicalized: canonicalizer.canonicalize(noContext),
                withContextCanonicalized: canonicalizer.canonicalize(withContext),
                noContextVocabularyHits: Self.vocabularyHits(in: noContext, terms: contextualStrings),
                withContextVocabularyHits: Self.vocabularyHits(in: withContext, terms: contextualStrings)
            )
            summary.add(row)
            try Self.append(row, to: outputURL)
        }

        print(summary.report(
            recordingCount: selectedRecordings.count,
            contextTermCount: contextualStrings.count,
            outputURL: outputURL
        ))
    }

    private static func transcribe(recording: URL, contextualStrings: [String]) async throws -> String {
        let transcriber = Transcriber(locale: Locale(identifier: "en-US"))
        guard let targetFormat = await transcriber.bestAudioFormat() else {
            throw SpeechContextEvalError.noCompatibleFormat
        }

        let events = try await transcriber.start(contextualStrings: contextualStrings)
        let collector = Task {
            var finalText = ""
            for await event in events {
                switch event {
                case .partial:
                    break
                case .final(let text):
                    finalText += text
                case .failed(let message):
                    XCTFail("Transcription failed for \(recording.lastPathComponent): \(message)")
                }
            }
            return finalText
        }

        try feed(recording: recording, targetFormat: targetFormat, into: transcriber)
        await transcriber.finish()
        return await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func feed(
        recording: URL,
        targetFormat: AVAudioFormat,
        into transcriber: Transcriber
    ) throws {
        let file = try AVAudioFile(forReading: recording)
        let inputFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw SpeechContextEvalError.converterUnavailable
        }
        converter.primeMethod = .none

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let frameCapacity = AVAudioFrameCount(min(remaining, 4_096))
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
                throw SpeechContextEvalError.bufferUnavailable
            }
            try file.read(into: inputBuffer, frameCount: frameCapacity)
            guard inputBuffer.frameLength > 0 else { continue }

            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 1
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw SpeechContextEvalError.bufferUnavailable
            }

            let pending = EvalInputBox(inputBuffer)
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
                throw conversionError ?? SpeechContextEvalError.conversionFailed
            }
            guard outputBuffer.frameLength > 0 else { continue }
            transcriber.accept(outputBuffer)
        }
    }

    private static func vocabularyHits(in text: String, terms: [String]) -> [String] {
        let lowercasedText = text.lowercased()
        return terms.filter { lowercasedText.contains($0.lowercased()) }
    }

    private static func append(_ row: SpeechContextEvalRow, to outputURL: URL) throws {
        let data = try JSONEncoder().encode(row)
        guard let line = String(data: data, encoding: .utf8) else {
            throw SpeechContextEvalError.encodingFailed
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

private struct SpeechContextEvalRow: Codable {
    let file: String
    let noContext: String
    let withContext: String
    let noContextCanonicalized: String
    let withContextCanonicalized: String
    let noContextVocabularyHits: [String]
    let withContextVocabularyHits: [String]

    var rawChanged: Bool { noContext != withContext }
    var canonicalizedChanged: Bool { noContextCanonicalized != withContextCanonicalized }
    var vocabularyHitDelta: Int { withContextVocabularyHits.count - noContextVocabularyHits.count }
}

private struct SpeechContextEvalSummary {
    private var rawChanged = 0
    private var canonicalizedChanged = 0
    private var vocabularyHitGains = 0
    private var vocabularyHitLosses = 0

    mutating func add(_ row: SpeechContextEvalRow) {
        if row.rawChanged {
            rawChanged += 1
        }
        if row.canonicalizedChanged {
            canonicalizedChanged += 1
        }
        if row.vocabularyHitDelta > 0 {
            vocabularyHitGains += 1
        }
        if row.vocabularyHitDelta < 0 {
            vocabularyHitLosses += 1
        }
    }

    func report(recordingCount: Int, contextTermCount: Int, outputURL: URL) -> String {
        """

        Speech context eval summary
        recordings: \(recordingCount)
        context terms: \(contextTermCount)
        raw changed: \(rawChanged)
        canonicalized changed: \(canonicalizedChanged)
        vocabulary hit gains: \(vocabularyHitGains)
        vocabulary hit losses: \(vocabularyHitLosses)
        output: \(outputURL.path)
        """
    }
}

private final class EvalInputBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

private enum SpeechContextEvalError: Error {
    case bufferUnavailable
    case converterUnavailable
    case conversionFailed
    case encodingFailed
    case noCompatibleFormat
}

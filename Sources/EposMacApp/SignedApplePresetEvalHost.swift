#if DEBUG
import AVFoundation
import CryptoKit
import Darwin
import Epos
import Foundation
import Speech

enum SignedApplePresetEvalHost {
    static let environmentKey = "EPOS_RUN_SIGNED_APPLE_PRESET_EVAL"

    static var isRequested: Bool {
        Self.isTruthy(ProcessInfo.processInfo.environment[environmentKey])
    }

    static func runAndExit() async -> Never {
        do {
            let result = try await run(environment: ProcessInfo.processInfo.environment)
            FileHandle.standardOutput.write(Data((result.summary + "\n").utf8))
            Darwin.exit(result.hasFailures ? EXIT_FAILURE : EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data(("signed Apple preset eval failed: \(error)\n").utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run(environment: [String: String]) async throws -> EvalResult {
        let locale = Settings.load().locale
        let recordingsDirectory = fileURL(
            environment["EPOS_EVAL_RECORDINGS_DIR"]
                ?? "\(NSHomeDirectory())/Library/Caches/Epos/recordings",
            isDirectory: true
        )
        let manifestURL = fileURL(
            environment["EPOS_EVAL_GROUND_TRUTH"]
                ?? recordingsDirectory.appendingPathComponent("ground-truth.jsonl").path,
            isDirectory: false
        )
        let manifest = try GroundTruthManifest.load(from: manifestURL)
        let recordings = try selectedRecordings(
            in: recordingsDirectory,
            manifest: manifest,
            environment: environment
        )
        guard !recordings.isEmpty else {
            throw EvalError.noRecordings(recordingsDirectory.path)
        }

        let outputURL = fileURL(
            environment["EPOS_EVAL_OUTPUT"]
                ?? FileManager.default.currentDirectoryPath
                    + "/.build/evals/apple-transcriber-presets-signed.jsonl",
            isDirectory: false
        )
        let summaryURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("summary.txt")
        try prepareOutput(outputURL)

        let assetStatus = await AssetManager(locale: locale).prepare()
        guard assetStatus == .reserved else {
            throw EvalError.assetPreparationFailed(String(describing: assetStatus))
        }
        let availability = await ApplePresetAvailability.resolve(locale: locale)
        guard availability.available[.speechProgressiveFast] != nil else {
            throw EvalError.baselineUnavailable(
                availability.unavailable[.speechProgressiveFast] ?? "unknown reason"
            )
        }

        let enabledArms = ApplePresetArm.allCases.filter {
            availability.available[$0] != nil
        }
        let canonicalizer = TranscriptCanonicalizer.load()
        var rows: [ApplePresetEvalRow] = []
        for (recordingIndex, recording) in recordings.enumerated() {
            let duration = try durationSeconds(recording)
            let audioDigest = try audioSHA256(recording)
            for arm in rotated(enabledArms, by: recordingIndex) {
                let armLocale = availability.available[arm]!
                let started = ContinuousClock.now
                let transcript: String
                let error: String?
                do {
                    transcript = try await ApplePresetTranscriber.transcribe(
                        recording: recording,
                        locale: armLocale,
                        arm: arm
                    )
                    error = nil
                } catch let caught {
                    transcript = ""
                    error = String(describing: caught)
                }
                let elapsed = seconds(from: started.duration(to: .now))
                let intended = manifest.transcript(for: recording)!
                let productionOutput = TranscriptDeterministicCleaner.streamClean(
                    canonicalizer.canonicalize(transcript)
                )
                let row = ApplePresetEvalRow(
                    arm: arm,
                    configuration: arm.configuration,
                    locale: armLocale.identifier,
                    file: recording.lastPathComponent,
                    audioSHA256: audioDigest,
                    audioDurationSeconds: duration,
                    humanIntendedTranscript: intended,
                    transcript: transcript,
                    transcriptScore: WordErrorScoring.score(reference: intended, hypothesis: transcript),
                    productionOutput: productionOutput,
                    productionOutputTranscriptScore: WordErrorScoring.score(
                        reference: intended,
                        hypothesis: productionOutput
                    ),
                    elapsedSeconds: elapsed,
                    rtfX: elapsed > 0 ? duration / elapsed : nil,
                    error: error
                )
                rows.append(row)
                try appendJSONL(row, to: outputURL)
            }
        }

        let summary = ApplePresetEvalReport.render(
            rows: rows,
            enabledArms: enabledArms,
            unavailable: availability.unavailable,
            expectedRowsPerArm: recordings.count,
            outputURL: outputURL,
            summaryURL: summaryURL
        )
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        return EvalResult(
            summary: summary,
            hasFailures: rows.contains { $0.error != nil || $0.isEmpty }
        )
    }

    private static func selectedRecordings(
        in directory: URL,
        manifest: GroundTruthManifest,
        environment: [String: String]
    ) throws -> [URL] {
        let recordings = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" && manifest.transcript(for: $0) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let limit = environment["EPOS_EVAL_LIMIT"].flatMap(Int.init).map { max(0, $0) }
        return Array(recordings.prefix(limit ?? recordings.count))
    }

    private static func prepareOutput(_ outputURL: URL) throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: outputURL, options: .atomic)
    }

    private static func appendJSONL<Row: Encodable>(_ row: Row, to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(row)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
    }

    private static func audioSHA256(_ recording: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: recording)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func durationSeconds(_ recording: URL) throws -> Double {
        let file = try AVAudioFile(forReading: recording)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private static func fileURL(_ path: String, isDirectory: Bool) -> URL {
        URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath,
            isDirectory: isDirectory
        )
    }

    private static func rotated<Element>(_ values: [Element], by offset: Int) -> [Element] {
        guard !values.isEmpty else { return [] }
        let split = offset % values.count
        return Array(values[split...] + values[..<split])
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }
}

private struct EvalResult {
    let summary: String
    let hasFailures: Bool
}

private enum EvalError: Error, CustomStringConvertible {
    case assetPreparationFailed(String)
    case baselineUnavailable(String)
    case noRecordings(String)

    var description: String {
        switch self {
        case .assetPreparationFailed(let reason):
            "asset preparation failed: \(reason)"
        case .baselineUnavailable(let reason):
            "current production arm unavailable: \(reason)"
        case .noRecordings(let path):
            "no labeled WAV recordings found at \(path)"
        }
    }
}
#endif

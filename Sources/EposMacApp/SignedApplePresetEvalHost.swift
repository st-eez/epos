#if DEBUG
import AVFoundation
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
                ?? "\(NSHomeDirectory())/Library/Application Support/Epos/recordings",
            isDirectory: true
        )
        let corpusURL = fileURL(
            environment["EPOS_EVAL_CORPUS"]
                ?? FileManager.default.currentDirectoryPath
                    + "/.build/evals/evaluation-corpus-v2.jsonl",
            isDirectory: false
        )
        let corpus = try ConfirmedEvalCorpus.load(from: corpusURL)
        let provenance = try ApplePresetEvalProvenance(corpusURL: corpusURL)
        let entries = selectedEntries(corpus, environment: environment)
        guard !entries.isEmpty else {
            throw EvalError.noRecordings(recordingsDirectory.path)
        }
        try verifyAudio(of: entries, in: recordingsDirectory)

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
        let snapshot = try ApplePresetEvalSnapshot(dictionary: CorrectionDictionary.load())
        var rows: [ApplePresetEvalRow] = []
        for (recordingIndex, entry) in entries.enumerated() {
            let recording = recordingsDirectory.appendingPathComponent(entry.file)
            let duration = try durationSeconds(recording)
            for arm in rotated(enabledArms, by: recordingIndex) {
                let armLocale = availability.available[arm]!
                let started = ContinuousClock.now
                let transcript: String
                let contextReadback: [String]?
                let error: String?
                do {
                    let transcription = try await snapshot.transcribe(
                        recording: recording,
                        locale: armLocale,
                        arm: arm
                    )
                    transcript = transcription.text
                    contextReadback = transcription.contextReadback
                    error = nil
                } catch let caught {
                    transcript = ""
                    contextReadback = nil
                    error = String(describing: caught)
                }
                let elapsed = seconds(from: started.duration(to: .now))
                let intended = entry.reference
                let productionOutput = TranscriptDeterministicCleaner.streamClean(
                    snapshot.canonicalizer.canonicalize(transcript)
                )
                let row = ApplePresetEvalRow(
                    arm: arm,
                    configuration: arm.configuration,
                    locale: armLocale.identifier,
                    file: entry.file,
                    audioSHA256: entry.audioSHA256,
                    audioDurationSeconds: duration,
                    humanIntendedTranscript: intended,
                    referenceDesignation: entry.designation,
                    transcript: transcript,
                    transcriptScore: WordErrorScoring.score(reference: intended, hypothesis: transcript),
                    productionOutput: productionOutput,
                    productionOutputTranscriptScore: WordErrorScoring.score(
                        reference: intended,
                        hypothesis: productionOutput
                    ),
                    elapsedSeconds: elapsed,
                    rtfX: elapsed > 0 ? duration / elapsed : nil,
                    error: error,
                    correctionDictionaryFingerprint: snapshot.dictionaryFingerprint,
                    correctionDictionaryRecords: snapshot.dictionaryRecords,
                    contextualStrings: snapshot.context(for: arm),
                    contextReadback: contextReadback,
                    evalProvenance: provenance
                )
                rows.append(row)
                try appendJSONL(row, to: outputURL)
            }
        }

        let summary = ApplePresetEvalReport.render(
            rows: rows,
            enabledArms: enabledArms,
            unavailable: availability.unavailable,
            expectedRowsPerArm: entries.count,
            outputURL: outputURL,
            summaryURL: summaryURL
        )
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        return EvalResult(
            summary: summary,
            hasFailures: rows.contains { $0.error != nil || $0.isEmpty }
        )
    }

    private static func selectedEntries(
        _ corpus: ConfirmedEvalCorpus,
        environment: [String: String]
    ) -> [ConfirmedEvalCorpus.Entry] {
        let limit = environment["EPOS_EVAL_LIMIT"].flatMap(Int.init).map { max(0, $0) }
        return Array(corpus.entries.prefix(limit ?? corpus.entries.count))
    }

    /// Scoring against drifted audio would be silently wrong, so the whole run
    /// aborts before the first transcription when any recording disagrees with
    /// the ledger it was confirmed under.
    private static func verifyAudio(
        of entries: [ConfirmedEvalCorpus.Entry],
        in directory: URL
    ) throws {
        for entry in entries {
            let recording = directory.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: recording.path) else {
                throw EvalError.recordingMissing(recording.path)
            }
            let digest = try ApplePresetEvalProvenance.fileSHA256(recording)
            guard digest == entry.audioSHA256 else {
                throw EvalError.audioDigestMismatch(
                    file: entry.file,
                    expected: entry.audioSHA256,
                    actual: digest
                )
            }
        }
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
    case audioDigestMismatch(file: String, expected: String, actual: String)
    case baselineUnavailable(String)
    case noRecordings(String)
    case recordingMissing(String)

    var description: String {
        switch self {
        case .assetPreparationFailed(let reason):
            "asset preparation failed: \(reason)"
        case .audioDigestMismatch(let file, let expected, let actual):
            "audio changed since confirmation: \(file) expected \(expected), found \(actual)"
        case .baselineUnavailable(let reason):
            "current production arm unavailable: \(reason)"
        case .noRecordings(let path):
            "no confirmed WAV recordings selected from \(path)"
        case .recordingMissing(let path):
            "confirmed recording missing: \(path)"
        }
    }
}
#endif

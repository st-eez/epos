#if DEBUG
import Darwin
import Epos
import Foundation

enum SignedAnalyzerPreparationEvalHost {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["EPOS_RUN_ANALYZER_PREPARATION_EVAL"] == "1"
    }

    static func runAndExit() async -> Never {
        do {
            let rows = try await run(environment: ProcessInfo.processInfo.environment)
            Darwin.exit(rows.contains { $0.error != nil || $0.transcript.isEmpty } ? EXIT_FAILURE : EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data(("analyzer preparation eval failed: \(error)\n").utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run(environment: [String: String]) async throws -> [AnalyzerPreparationEvalRow] {
        let corpusURL = fileURL(environment["EPOS_EVAL_CORPUS"] ?? ".build/evals/evaluation-corpus-v2.jsonl")
        let recordings = fileURL(environment["EPOS_EVAL_RECORDINGS_DIR"]
            ?? "\(NSHomeDirectory())/Library/Application Support/Epos/recordings")
        let output = fileURL(environment["EPOS_EVAL_OUTPUT"] ?? ".build/evals/analyzer-preparation.jsonl")
        let limit = try positiveInteger(environment["EPOS_EVAL_LIMIT"], defaultValue: 6)
        let repeats = try positiveInteger(environment["EPOS_PREPARE_REPEATS"], defaultValue: 2)
        let idleSeconds = Double(environment["EPOS_PREPARE_IDLE_SECONDS"] ?? "2") ?? -1
        guard idleSeconds.isFinite, (0...300).contains(idleSeconds) else {
            throw PreparationEvalError.invalidConfiguration("idle seconds must be between 0 and 300")
        }
        let firstArm = AnalyzerPreparationArm(rawValue: environment["EPOS_PREPARE_FIRST_ARM"] ?? "unprepared")
        guard let firstArm else { throw PreparationEvalError.invalidConfiguration("unknown first arm") }
        let corpus = try ConfirmedEvalCorpus.load(from: corpusURL)
        let entries = Array(corpus.entries.prefix(limit))
        for entry in entries {
            let digest = try ApplePresetEvalProvenance.fileSHA256(recordings.appendingPathComponent(entry.file))
            guard digest == entry.audioSHA256 else {
                throw PreparationEvalError.audioDigestMismatch(entry.file)
            }
        }
        let locale = Settings.load().locale
        let status = await AssetManager(locale: locale).prepare()
        guard status == .reserved else { throw PreparationEvalError.assetsUnavailable(String(describing: status)) }
        let snapshot = try ApplePresetEvalSnapshot(dictionary: CorrectionDictionary.load())
        let provenance = try ApplePresetEvalProvenance(corpusURL: corpusURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let context = snapshot.context(for: .baseline)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: output, options: .atomic)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var rows: [AnalyzerPreparationEvalRow] = []
        let firstOffset = AnalyzerPreparationArm.allCases.firstIndex(of: firstArm) ?? 0
        for repeatIndex in 0..<repeats {
            for (entryIndex, entry) in entries.enumerated() {
                let audio = try await AnalyzerPreparationAudio.load(
                    recording: recordings.appendingPathComponent(entry.file), locale: locale
                )
                for arm in rotatedArms(by: firstOffset + repeatIndex + entryIndex) {
                    let watchdog = Task {
                        try? await Task.sleep(for: .seconds(audio.durationSeconds + idleSeconds + 30))
                        guard !Task.isCancelled else { return }
                        FileHandle.standardError.write(Data(("preparation trial timed out: \(entry.file) \(arm.rawValue)\n").utf8))
                        Darwin.exit(EXIT_FAILURE)
                    }
                    defer { watchdog.cancel() }
                    let result: AnalyzerPreparationResult?
                    let error: String?
                    do {
                        result = try await SignedAnalyzerPreparationTranscriber.transcribe(
                            audio: audio, locale: locale, arm: arm,
                            contextualStrings: context, idleSeconds: idleSeconds
                        )
                        error = nil
                    } catch let caught {
                        result = nil
                        error = String(describing: caught)
                    }
                    let transcript = result?.transcript ?? ""
                    let cleaned = TranscriptDeterministicCleaner.streamClean(snapshot.canonicalizer.canonicalize(transcript))
                    let row = AnalyzerPreparationEvalRow(
                        trialOrdinal: rows.count + 1, repeatIndex: repeatIndex, arm: arm,
                        file: entry.file, audioSHA256: entry.audioSHA256,
                        referenceDesignation: entry.designation, reference: entry.reference,
                        correctionDictionaryFingerprint: snapshot.dictionaryFingerprint,
                        correctionDictionaryRecords: snapshot.dictionaryRecords,
                        contextualStrings: context, contextReadback: result?.contextReadback,
                        evalProvenance: provenance,
                        locale: locale.identifier, audioDurationSeconds: audio.durationSeconds,
                        metrics: result?.metrics,
                        rssAfterCleanupBytes: SignedAnalyzerPreparationTranscriber.residentMemoryBytes(),
                        transcript: transcript, productionOutput: cleaned,
                        transcriptScore: WordErrorScoring.score(reference: entry.reference, hypothesis: transcript),
                        productionOutputScore: WordErrorScoring.score(reference: entry.reference, hypothesis: cleaned),
                        error: error
                    )
                    rows.append(row)
                    try handle.write(contentsOf: encoder.encode(row))
                    try handle.write(contentsOf: Data("\n".utf8))
                }
            }
        }
        let summary = AnalyzerPreparationEvalReport.render(rows: rows, output: output)
        try summary.write(to: output.deletingPathExtension().appendingPathExtension("summary.txt"),
                          atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data((summary + "\n").utf8))
        return rows
    }

    private static func positiveInteger(_ value: String?, defaultValue: Int) throws -> Int {
        guard let value else { return defaultValue }
        guard let count = Int(value), count > 0 else {
            throw PreparationEvalError.invalidConfiguration("counts must be positive integers")
        }
        return count
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func rotatedArms(by offset: Int) -> [AnalyzerPreparationArm] {
        let arms = AnalyzerPreparationArm.allCases
        let split = offset % arms.count
        return Array(arms[split...] + arms[..<split])
    }
}

struct AnalyzerPreparationEvalRow: Codable {
    let trialOrdinal: Int
    let repeatIndex: Int
    let arm: AnalyzerPreparationArm
    let file: String
    let audioSHA256: String
    let referenceDesignation: ReferenceDesignation
    let reference: String
    let correctionDictionaryFingerprint: String
    let correctionDictionaryRecords: [CorrectionRecord]
    let contextualStrings: [String]
    let contextReadback: [String]?
    let evalProvenance: ApplePresetEvalProvenance?
    let locale: String
    let audioDurationSeconds: Double
    let metrics: AnalyzerPreparationMetrics?
    let rssAfterCleanupBytes: UInt64?
    let transcript: String
    let productionOutput: String
    let transcriptScore: WordErrorScore
    let productionOutputScore: WordErrorScore
    let error: String?
}
#endif

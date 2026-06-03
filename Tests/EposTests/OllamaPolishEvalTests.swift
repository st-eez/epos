import XCTest
@testable import Epos

/// Local Ollama polish bakeoff for small models. The first target is
/// `qwen3:1.7b`: low memory footprint, local-only, and unloaded after each real
/// polish call via `keep_alive: 0`.
///
/// Skipped unless explicitly enabled and the model is already installed:
///
///   ollama pull qwen3:1.7b
///   EPOS_RUN_OLLAMA_POLISH_EVAL=1 swift test --filter OllamaPolishEvalTests
///
/// Optional knobs:
/// - `EPOS_OLLAMA_MODEL`: defaults to `qwen3:1.7b`
/// - `EPOS_EVAL_LIMIT`: number of transcripts to replay
/// - `EPOS_EVAL_OUTPUT`: defaults to `.build/evals/ollama-polish-eval.jsonl`
/// - `EPOS_POLISH_EVAL_PREWARM_MS`: defaults to 1500, use 0 for cold-start stress
final class OllamaPolishEvalTests: XCTestCase {
    private static let transcripts = [
        "It seems like you're saying that the polish is not working.",
        "Can we take a look at the details of this and break it down some more?",
        "What should we test 1st to ensure that it's still working properly?",
        "Also, I noticed that the text is no longer streaming in like it used to be.",
        "um so like we should uh ship it you know",
        "so I was thinking like we could just um refactor the parser",
        "send the report to dana comma then ping the team",
        "kill the process and then nuke the build directory",
        "Tuesday no wait Wednesday works better for the demo",
        "the damn thing crashed again so basically we lost the data",
    ]

    func testQwenPolishOverCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_OLLAMA_POLISH_EVAL"]) else {
            throw XCTSkip("Set EPOS_RUN_OLLAMA_POLISH_EVAL=1 to run the Ollama polish eval")
        }

        let model = environment["EPOS_OLLAMA_MODEL"] ?? OllamaPolishEngine.defaultModel
        let availabilityEngine = OllamaPolishEngine(model: model, prewarmEnabled: false)
        guard await availabilityEngine.isModelInstalled() else {
            throw XCTSkip("Ollama model \(model) unavailable; run `ollama pull \(model)`")
        }

        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/ollama-polish-eval.jsonl"
        )
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let limit = environment["EPOS_EVAL_LIMIT"].flatMap(Int.init)
        let transcripts = Array(Self.transcripts.prefix(limit ?? Self.transcripts.count))
        let prewarmDelay = SavedRecordingEvalSupport.polishPrewarmSettleNanoseconds(environment: environment)

        let variants = [
            OllamaPolishEvalVariant(name: "\(model)-cold", prewarmEnabled: false, prewarmWait: 0),
            OllamaPolishEvalVariant(name: "\(model)-prewarm", prewarmEnabled: true, prewarmWait: prewarmDelay),
        ]

        var rows: [OllamaPolishEvalRow] = []
        for variant in variants {
            for raw in transcripts {
                let engine = OllamaPolishEngine(model: model, prewarmEnabled: variant.prewarmEnabled)
                let canonicalizedRaw = canonicalizer.canonicalize(raw)
                let deterministicOutput = TranscriptDeterministicCleaner.clean(canonicalizedRaw)
                let polisher = TranscriptPolisher(
                    enabled: true,
                    engine: engine,
                    knownTerms: knownTerms,
                    canonicalize: { canonicalizer.canonicalize($0) }
                )
                polisher.prewarm()
                let prewarmWaitSeconds = await SavedRecordingEvalSupport.waitForPolishPrewarmSettle(
                    delayNanoseconds: variant.prewarmWait
                )

                let started = Date()
                let result = await polisher.polish(raw)
                let elapsedSeconds = Date().timeIntervalSince(started)
                let row = OllamaPolishEvalRow(
                    variant: variant.name,
                    model: model,
                    prewarmEnabled: variant.prewarmEnabled,
                    raw: raw,
                    canonicalizedRaw: canonicalizedRaw,
                    deterministicOutput: deterministicOutput,
                    output: result.text,
                    outcome: String(describing: result.outcome),
                    engineOutcome: result.engineOutcome?.rawValue,
                    prewarmWaitSeconds: prewarmWaitSeconds,
                    elapsedSeconds: elapsedSeconds,
                    rawCharacterCount: result.rawCharacterCount,
                    outputCharacterCount: result.text.count,
                    outputChangedFromCanonicalizedRaw: result.text != canonicalizedRaw,
                    outputChangedFromDeterministic: result.text != deterministicOutput,
                    retainedFillerInRaw: PolishEvalScoring.retainsFiller(raw),
                    retainedFillerInOutput: PolishEvalScoring.retainsFiller(result.text),
                    guardRejectionReason: result.guardRejection?.reason.rawValue,
                    guardRejectionCandidate: result.guardRejection?.candidateText,
                    guardRejectionDiff: result.guardRejection?.diff
                )
                rows.append(row)
                try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
            }
        }

        print(Self.report(rows: rows, outputURL: outputURL))
    }

    private static func report(rows: [OllamaPolishEvalRow], outputURL: URL) -> String {
        var lines = ["", "Ollama polish eval"]
        for variant in stableUnique(rows.map(\.variant)) {
            let variantRows = rows.filter { $0.variant == variant }
            lines.append("")
            lines.append("[\(variant)] rows=\(variantRows.count)")
            lines.append("  outcomes: \(Self.countSummary(variantRows.map(\.outcome)))")
            lines.append("  engine outcomes: \(Self.countSummary(variantRows.map { $0.engineOutcome ?? "not-attempted" }))")
            lines.append("  guard rejections: \(Self.countSummary(variantRows.compactMap(\.guardRejectionReason)))")
            lines.append("  retained filler raw/output: \(variantRows.filter(\.retainedFillerInRaw).count)/\(variantRows.filter(\.retainedFillerInOutput).count)")
            lines.append("  changed from deterministic: \(variantRows.filter(\.outputChangedFromDeterministic).count)")
            lines.append("  mean elapsed: \(Self.formatSeconds(Self.meanElapsed(variantRows)))s")
            for row in variantRows {
                let engineOutcome = row.engineOutcome ?? "not-attempted"
                lines.append("  - <\(row.outcome)> engine=<\(engineOutcome)> elapsed=\(Self.formatSeconds(row.elapsedSeconds))s raw: \(row.raw)")
                lines.append("    out: \(row.output)")
                if let candidate = row.guardRejectionCandidate {
                    lines.append("    candidate: \(candidate)")
                }
            }
        }
        lines.append("")
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func countSummary(_ values: [String]) -> String {
        guard !values.isEmpty else { return "none" }
        return values
            .reduce(into: [String: Int]()) { counts, value in counts[value, default: 0] += 1 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func meanElapsed(_ rows: [OllamaPolishEvalRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.elapsedSeconds } / Double(rows.count)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}

private struct OllamaPolishEvalVariant {
    let name: String
    let prewarmEnabled: Bool
    let prewarmWait: UInt64
}

private struct OllamaPolishEvalRow: Codable {
    let variant: String
    let model: String
    let prewarmEnabled: Bool
    let raw: String
    let canonicalizedRaw: String
    let deterministicOutput: String
    let output: String
    let outcome: String
    let engineOutcome: String?
    let prewarmWaitSeconds: Double
    let elapsedSeconds: Double
    let rawCharacterCount: Int
    let outputCharacterCount: Int
    let outputChangedFromCanonicalizedRaw: Bool
    let outputChangedFromDeterministic: Bool
    let retainedFillerInRaw: Bool
    let retainedFillerInOutput: Bool
    let guardRejectionReason: String?
    let guardRejectionCandidate: String?
    let guardRejectionDiff: String?
}

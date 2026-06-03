import Foundation
import XCTest
@testable import Epos

/// Phase-1 FoundationModels bakeoff for deciding whether the current model can be
/// salvaged before trying local open-source engines. It runs prompt variants through
/// the real `TranscriptPolisher` guard/fallback path and writes JSONL diagnostics.
///
/// Skipped unless explicitly enabled:
///
///   EPOS_RUN_FM_POLISH_BAKEOFF=1 swift test --filter FoundationModelsPolishBakeoffEvalTests
///
/// By default each row waits 1.5s after `prewarm()` before `polish()`, matching
/// production's "prewarm during recording" shape better than a cold immediate call.
/// Use `EPOS_POLISH_EVAL_PREWARM_MS=0` to intentionally stress cold-start behavior.
final class FoundationModelsPolishBakeoffEvalTests: XCTestCase {
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

    func testFoundationModelsPromptVariants() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_FM_POLISH_BAKEOFF"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_FM_POLISH_BAKEOFF=1 to run the FoundationModels bakeoff")
        }

        let availabilityEngine = FoundationModelsPolishEngine(promptStyle: .production)
        try XCTSkipUnless(availabilityEngine.isAvailable, "FoundationModels model unavailable in this context")

        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/foundation-models-polish-bakeoff.jsonl"
        )
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let limit = environment["EPOS_EVAL_LIMIT"].flatMap(Int.init)
        let transcripts = Array(Self.transcripts.prefix(limit ?? Self.transcripts.count))
        let prewarmDelay = SavedRecordingEvalSupport.polishPrewarmSettleNanoseconds(environment: environment)
        let variants = [
            FoundationModelsPolishBakeoffVariant(
                name: "production-known-terms",
                promptStyle: .production,
                knownTerms: knownTerms
            ),
            FoundationModelsPolishBakeoffVariant(
                name: "example-free-known-terms",
                promptStyle: .exampleFreeStrict,
                knownTerms: knownTerms
            ),
            FoundationModelsPolishBakeoffVariant(
                name: "example-free-no-known-terms",
                promptStyle: .exampleFreeStrict,
                knownTerms: []
            ),
        ]

        var rows: [FoundationModelsPolishBakeoffRow] = []
        for variant in variants {
            let engine = FoundationModelsPolishEngine(promptStyle: variant.promptStyle)
            for raw in transcripts {
                let canonicalizedRaw = canonicalizer.canonicalize(raw)
                let deterministicOutput = TranscriptDeterministicCleaner.clean(canonicalizedRaw)
                let polisher = TranscriptPolisher(
                    enabled: true,
                    engine: engine,
                    knownTerms: variant.knownTerms,
                    canonicalize: { canonicalizer.canonicalize($0) }
                )
                polisher.prewarm()
                let prewarmWaitSeconds = await SavedRecordingEvalSupport.waitForPolishPrewarmSettle(
                    delayNanoseconds: prewarmDelay
                )

                let started = Date()
                let result = await polisher.polish(raw)
                let elapsedSeconds = Date().timeIntervalSince(started)
                let row = FoundationModelsPolishBakeoffRow(
                    variant: variant.name,
                    promptStyle: variant.promptStyle.rawValue,
                    knownTermCount: variant.knownTerms.count,
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

    private static func report(rows: [FoundationModelsPolishBakeoffRow], outputURL: URL) -> String {
        var lines = ["", "FoundationModels polish bakeoff"]
        for variant in rows.map(\.variant).stableUnique() {
            let variantRows = rows.filter { $0.variant == variant }
            lines.append("")
            lines.append("[\(variant)] rows=\(variantRows.count)")
            lines.append("  outcomes: \(Self.countSummary(variantRows.map(\.outcome)))")
            lines.append("  engine outcomes: \(Self.countSummary(variantRows.map { $0.engineOutcome ?? "not-attempted" }))")
            lines.append("  guard rejections: \(Self.countSummary(variantRows.compactMap(\.guardRejectionReason)))")
            lines.append("  retained filler raw/output: \(variantRows.filter(\.retainedFillerInRaw).count)/\(variantRows.filter(\.retainedFillerInOutput).count)")
            lines.append("  changed from deterministic: \(variantRows.filter(\.outputChangedFromDeterministic).count)")
            lines.append("  prewarm wait total: \(String(format: "%.3f", variantRows.reduce(0) { $0 + $1.prewarmWaitSeconds }))s")
            for row in variantRows {
                let engineOutcome = row.engineOutcome ?? "not-attempted"
                lines.append("  - <\(row.outcome)> engine=<\(engineOutcome)> raw: \(row.raw)")
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
}

private struct FoundationModelsPolishBakeoffVariant {
    let name: String
    let promptStyle: FoundationModelsPolishPromptStyle
    let knownTerms: [String]
}

private struct FoundationModelsPolishBakeoffRow: Codable {
    let variant: String
    let promptStyle: String
    let knownTermCount: Int
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

private extension Array where Element: Hashable {
    func stableUnique() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

import Foundation

struct CorrectionRuleMatchSpec: Sendable {
    let recordID: String?
    let canonical: String
    let regex: NSRegularExpression
    let contexts: [String]
    let matchStrategy: TranscriptCanonicalizer.Rule.MatchStrategy
    let attachesFlagArgument: Bool
}

struct CorrectionRuleMatchResult {
    let output: String
    let appliedRecordIDs: [String]
}

enum CorrectionRuleMatcher {
    static func isFlagPrefixRule(canonical: String, aliasRegex: NSRegularExpression) -> Bool {
        guard canonical == "--" else { return false }
        let sample = "dash dash"
        let range = NSRange(location: 0, length: (sample as NSString).length)
        return aliasRegex.firstMatch(in: sample, range: range)?.range == range
    }

    static func apply(_ specs: [CorrectionRuleMatchSpec], to text: String) -> CorrectionRuleMatchResult {
        guard !text.isEmpty else {
            return CorrectionRuleMatchResult(output: text, appliedRecordIDs: [])
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var replacements: [Replacement] = []
        var appliedRecordIDs: [String] = []
        var seenRecordIDs: Set<String> = []

        for spec in specs {
            let candidates = flagCandidates(for: spec, in: text, range: fullRange)
                + spec.regex.matches(in: text, range: fullRange).map {
                    Candidate(range: $0.range, flagArgument: nil)
                }
            var specApplied = false

            for candidate in candidates {
                guard !replacements.contains(where: { rangesOverlap($0.range, candidate.range) }) else {
                    continue
                }
                guard CorrectionMatchContext.allows(
                    matchStrategy: spec.matchStrategy,
                    contexts: spec.contexts,
                    before: candidate.range,
                    in: nsText
                ) else {
                    continue
                }

                let canonical = CorrectionMatchContext.sentenceCasedCanonical(
                    spec.canonical,
                    forMatch: candidate.range,
                    in: nsText
                )
                replacements.append(
                    Replacement(
                        range: candidate.range,
                        text: canonical + (candidate.flagArgument ?? "")
                    )
                )
                specApplied = true
            }

            if specApplied,
               let recordID = spec.recordID,
               seenRecordIDs.insert(recordID).inserted {
                appliedRecordIDs.append(recordID)
            }
        }

        guard !replacements.isEmpty else {
            return CorrectionRuleMatchResult(output: text, appliedRecordIDs: [])
        }

        var output = ""
        var cursor = 0
        for replacement in replacements.sorted(by: { $0.range.location < $1.range.location }) {
            output += nsText.substring(
                with: NSRange(location: cursor, length: replacement.range.location - cursor)
            )
            output += replacement.text
            cursor = replacement.range.location + replacement.range.length
        }
        output += nsText.substring(from: cursor)

        return CorrectionRuleMatchResult(output: output, appliedRecordIDs: appliedRecordIDs)
    }
}

private extension CorrectionRuleMatcher {
    struct Candidate {
        let range: NSRange
        let flagArgument: String?
    }

    struct Replacement {
        let range: NSRange
        let text: String
    }

    static func flagCandidates(
        for spec: CorrectionRuleMatchSpec,
        in text: String,
        range: NSRange
    ) -> [Candidate] {
        guard spec.attachesFlagArgument, let regex = flagPrefixRegex else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges == 2 else { return nil }
            return Candidate(
                range: match.range,
                flagArgument: nsText.substring(with: match.range(at: 1))
            )
        }
    }

    static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    static let flagPrefixRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])dash[\s,]+dash[\s,]+([A-Za-z][A-Za-z0-9_-]*)"#,
        options: [.caseInsensitive]
    )
}

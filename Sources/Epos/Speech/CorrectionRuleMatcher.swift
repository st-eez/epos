import Foundation

struct CorrectionRuleMatchSpec: Sendable {
    let recordID: String?
    let canonical: String
    let regex: NSRegularExpression
    let contexts: [String]
    let matchStrategy: TranscriptCanonicalizer.Rule.MatchStrategy
}

struct CorrectionRuleMatchResult {
    let output: String
    let appliedRecordIDs: [String]
}

enum CorrectionRuleMatcher {
    static func apply(_ specs: [CorrectionRuleMatchSpec], to text: String) -> CorrectionRuleMatchResult {
        let text = attachingFlagPrefix(in: text)
        guard !text.isEmpty else {
            return CorrectionRuleMatchResult(output: text, appliedRecordIDs: [])
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var replacements: [Replacement] = []
        var appliedRecordIDs: [String] = []
        var seenRecordIDs: Set<String> = []

        for spec in specs {
            var specApplied = false

            for match in spec.regex.matches(in: text, range: fullRange) {
                guard !replacements.contains(where: { rangesOverlap($0.range, match.range) }) else {
                    continue
                }
                guard CorrectionMatchContext.allows(
                    matchStrategy: spec.matchStrategy,
                    contexts: spec.contexts,
                    before: match.range,
                    in: nsText
                ) else {
                    continue
                }

                replacements.append(
                    Replacement(
                        range: match.range,
                        text: CorrectionMatchContext.sentenceCasedCanonical(
                            spec.canonical,
                            forMatch: match.range,
                            in: nsText
                        )
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

    /// `dash dash <flag>` -> `--<flag>`: the one spoken shorthand the alias->canonical
    /// engine cannot express, because it prepends `--` to a *captured* following word
    /// instead of replacing a fixed phrase. It runs ahead of the alias rules and belongs
    /// to no correction record, so editing or deleting the `dash dash` -> `--` row cannot
    /// silently take the flag form away with it. That row still owns bare `dash dash`.
    static func attachingFlagPrefix(in text: String) -> String {
        guard let regex = flagPrefixRegex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: #"--$1"#)
    }
}

private extension CorrectionRuleMatcher {
    struct Replacement {
        let range: NSRange
        let text: String
    }

    static func rangesOverlap(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
        NSIntersectionRange(lhs, rhs).length > 0
    }

    /// The recognizer punctuates the spoken command "dash dash fix" as "Dash, dash, fix."
    /// — a comma after each token. Tolerating commas (and whitespace) between the tokens
    /// keeps this consuming the whole run and yielding "--fix"; without it the bare
    /// `dash dash` alias matched only "Dash, dash" and stranded the comma as "--, fix".
    static let flagPrefixRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])dash[\s,]+dash[\s,]+([A-Za-z][A-Za-z0-9_-]*)"#,
        options: [.caseInsensitive]
    )
}

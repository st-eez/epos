import Foundation

struct CorrectionPhraseBoundary: Sendable {
    private let prefixes: Set<String>
    private let maximumTokens: Int

    init(rules: [TranscriptCanonicalizer.Rule]) {
        var prefixes: Set<String> = ["dash"]
        var maximumTokens = 1
        for rule in rules {
            for alias in rule.aliases {
                let tokens = CorrectionMatchContext.normalizedPhrase(alias).split(separator: " ")
                let count = rule.matchStrategy == .personNameSlot ? tokens.count : tokens.count - 1
                guard count > 0 else { continue }
                maximumTokens = max(maximumTokens, count)
                for length in 1...count {
                    prefixes.insert(tokens.prefix(length).joined(separator: " "))
                }
            }
        }
        self.prefixes = prefixes
        self.maximumTokens = maximumTokens
    }

    func needsContinuation(_ text: String) -> Bool {
        let tokens = CorrectionMatchContext.normalizedPhrase(text).split(separator: " ")
        let count = min(tokens.count, maximumTokens)
        guard count > 0 else { return false }
        return (1...count).contains { prefixes.contains(tokens.suffix($0).joined(separator: " ")) }
    }
}

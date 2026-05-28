import Foundation

public final class ProgressiveTranscriptInsertionSession {
    private let insertionSession: any TextInsertionSession
    private let canonicalize: (String) -> String
    private let log = EposLogger(category: "inject")

    private var committedText = ""
    private var previousStableCandidate = ""
    private var didFinish = false

    public init(
        insertionSession: any TextInsertionSession,
        canonicalize: @escaping (String) -> String
    ) {
        self.insertionSession = insertionSession
        self.canonicalize = canonicalize
    }

    public func acceptPartialTranscript(_ text: String) {
        guard !didFinish else { return }
        let canonicalText = canonicalize(text)
        let stableCandidate = Self.stablePrefixCandidate(in: canonicalText)
        let confirmedPrefix = Self.commonPrefixAtWordBoundary(previousStableCandidate, stableCandidate)
        previousStableCandidate = stableCandidate
        commitPrefix(confirmedPrefix)
    }

    public func acceptFinalTranscript(_ text: String) {
        guard !didFinish else { return }
        previousStableCandidate = ""
        commitPrefix(canonicalize(text))
    }

    public func finish() {
        guard !didFinish else { return }
        didFinish = true
        insertionSession.finish()
    }

    public func cancel() {
        guard !didFinish else { return }
        didFinish = true
        insertionSession.cancel()
    }

    private func commitPrefix(_ targetPrefix: String) {
        guard targetPrefix.hasPrefix(committedText) else {
            log.info("progressive insert paused reason=prefix-revision committedChars=\(committedText.utf16.count) targetChars=\(targetPrefix.utf16.count)")
            return
        }

        let delta = String(targetPrefix.dropFirst(committedText.count))
        guard !delta.isEmpty else { return }

        insertionSession.insert(delta)
        committedText = targetPrefix
        log.info("progressive insert committed deltaChars=\(delta.utf16.count) totalChars=\(committedText.utf16.count)")
    }

    static func stablePrefixCandidate(in text: String) -> String {
        guard !text.isEmpty else { return "" }

        let wordRanges = text.wordRanges
        guard wordRanges.count > 1 else { return "" }

        return String(text[..<wordRanges[wordRanges.count - 1].lowerBound])
    }

    static func commonPrefixAtWordBoundary(_ lhs: String, _ rhs: String) -> String {
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        var commonEnd = lhs.startIndex

        while lhsIndex < lhs.endIndex, rhsIndex < rhs.endIndex, lhs[lhsIndex] == rhs[rhsIndex] {
            lhs.formIndex(after: &lhsIndex)
            rhs.formIndex(after: &rhsIndex)
            commonEnd = lhsIndex
        }

        let common = String(lhs[..<commonEnd])
        return common.prefixThroughLastWordBoundary()
    }
}

private extension String {
    var wordRanges: [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = startIndex

        while index < endIndex {
            while index < endIndex, !self[index].isWordCharacter {
                formIndex(after: &index)
            }
            guard index < endIndex else { break }

            let start = index
            while index < endIndex, self[index].isWordCharacter {
                formIndex(after: &index)
            }
            ranges.append(start..<index)
        }

        return ranges
    }

    func prefixThroughLastWordBoundary() -> String {
        guard !isEmpty else { return "" }
        var index = endIndex

        while index > startIndex {
            let previous = self.index(before: index)
            if !self[previous].isWordCharacter {
                return String(self[..<index])
            }
            index = previous
        }

        return ""
    }
}

private extension Character {
    var isWordCharacter: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0.value == 95 }
    }
}

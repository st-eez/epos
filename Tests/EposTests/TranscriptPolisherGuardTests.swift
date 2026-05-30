import XCTest
@testable import Epos

/// The content-retention guard is a pure string→bool decision (no I/O), so it is
/// exercised directly with a table of cases. It must keep legitimate
/// filler-removal and spoken-symbol conversion while rejecting clause drops,
/// additions, and reordering.
final class TranscriptPolisherGuardTests: XCTestCase {
    func testGuardPreservesExactContentSequenceAfterAllowedCleanup() {
        let cases: [(raw: String, polished: String, expected: Bool)] = [
            // Clause-drop: the polished output lost the command's verb and most
            // of its content, retaining only the trailing fragment. Reject.
            (
                "run the script with dash dash verbose and point it at dollar home slash bin",
                "dollar home slash bin",
                false
            ),
            // Filler-removal: um/uh/so/like/you-know stripped, the content words
            // remain exactly in order. Keep.
            (
                "um so like we should uh ship it you know",
                "we should ship it",
                true
            ),
            // Ambiguous filler words are only droppable when needed for
            // alignment. The final "like" is semantic and must be allowed to
            // survive while the filler "like"s are removed.
            (
                "Uh, like, I'm trying to see the, uh, filler words would, like, uh, " +
                    "get removed, but it doesn't seem like it.",
                "I'm trying to see the filler words would get removed, but it " +
                    "doesn't seem like it.",
                true
            ),
            (
                "Uh, like, I'm trying to see the, uh, filler words would, like, uh, " +
                    "get removed, but it doesn't seem like it.",
                "I'm trying to see the filler words would get removed, but it " +
                    "doesn't seem it.",
                false
            ),
            // "I think" is meaningful per the prompt. Dropping it is content loss.
            (
                "um so like i think we should uh ship it you know",
                "we should ship it",
                false
            ),
            // Spoken punctuation/symbol words can disappear when converted to
            // punctuation, as long as the surrounding content remains.
            (
                "run dash dash verbose from dollar home slash bin",
                "run --verbose from $HOME/bin",
                true
            ),
            // Near-identical cleanup (just casing/punctuation) retains everything.
            (
                "the quick brown fox jumps over the lazy dog",
                "The quick brown fox jumps over the lazy dog.",
                true
            ),
            // Additions and reordering are not cleanup.
            (
                "ship the feature",
                "ship the feature tomorrow",
                false
            ),
            (
                "ship the feature",
                "basically ship the feature",
                false
            ),
            (
                "ship the feature today",
                "today ship the feature",
                false
            ),
            // Empty polished can never retain content.
            ("hello there world", "", false),
            ("hello there world", "   ", false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                TranscriptPolisher.polishRetainsContent(raw: testCase.raw, polished: testCase.polished),
                testCase.expected,
                "raw=\(testCase.raw) | polished=\(testCase.polished)"
            )
        }
    }
}

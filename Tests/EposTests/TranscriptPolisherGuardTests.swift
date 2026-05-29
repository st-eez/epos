import XCTest
@testable import Epos

/// The content-retention guard is a pure string→bool decision (no I/O), so it is
/// exercised directly with a table of cases. It must keep legitimate
/// filler-removal while rejecting clause-drop over-compression — the main
/// today's-model risk the design defends against.
final class TranscriptPolisherGuardTests: XCTestCase {
    func testGuardRejectsClauseDropAndKeepsFillerRemoval() {
        let cases: [(raw: String, polished: String, expected: Bool)] = [
            // Clause-drop: the polished output lost the command's verb and most
            // of its content, retaining only the trailing fragment. Reject.
            (
                "run the script with dash dash verbose and point it at dollar home slash bin",
                "dollar home slash bin",
                false
            ),
            // Filler-removal: um/uh/so/like/you-know stripped, the substantive
            // words ("should", "ship") survive above threshold. Keep.
            (
                "um so like i think we should uh ship it you know",
                "we should ship it",
                true
            ),
            // Near-identical cleanup (just casing/punctuation) retains everything.
            (
                "the quick brown fox jumps over the lazy dog",
                "The quick brown fox jumps over the lazy dog.",
                true
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

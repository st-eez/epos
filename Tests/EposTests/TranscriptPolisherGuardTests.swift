import XCTest
@testable import Epos

/// The content-retention guard is a pure string→bool decision (no I/O), so it is
/// exercised directly with a table of cases. The guard receives ALREADY-
/// canonicalized text (canonicalization happens in `TranscriptPolisher.polish`
/// before the guard), so these cases use the post-canonicalize strings directly.
/// It must keep filler removal and the hyphen-merge of an already-spoken compound
/// while rejecting content-word drops, additions, reordering, word substitution,
/// spoken-symbol conversion, contraction collapse, added `,`/`?`/`!`, and
/// collapsed sentence boundaries.
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
            ("um so like we should uh ship it you know", "we should ship it", true),
            // Ambiguous filler words are only droppable when needed for alignment.
            // The final "like" is semantic and must survive while the fillers go.
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
            (
                "Uh, like, I'm trying to see the filler words like uh get removed " +
                    "but it doesn't seem like it.",
                "I'm trying to see the filler words get removed but it doesn't " +
                    "seem like it.",
                true
            ),
            (
                "Uh, like, I'm trying to see the filler words like uh get removed " +
                    "but it doesn't seem like it.",
                "I'm trying to see the filler words like get removed but it " +
                    "doesn't seem like it.",
                false
            ),
            ("I like uh tacos.", "I like tacos.", true),
            // "I think" is meaningful per the prompt. Dropping it is content loss.
            ("um so like i think we should uh ship it you know", "we should ship it", false),
            // Near-identical cleanup (just casing/punctuation) retains everything.
            (
                "the quick brown fox jumps over the lazy dog",
                "The quick brown fox jumps over the lazy dog.",
                true
            ),
            // Existing sentence boundaries from the recognizer are content
            // structure. The model may add punctuation, but it must not collapse
            // a raw period between retained words.
            (
                "I'm not sure. There must be a better way to determine what's " +
                    "the best way to do this. You have any suggestions in mind?",
                "I'm not sure There must be a better way to determine what's " +
                    "the best way to do this. You have any suggestions in mind?",
                false
            ),
            (
                "I'm not sure. There must be a better way to determine what's " +
                    "the best way to do this. You have any suggestions in mind?",
                "I'm not sure. There must be a better way to determine what's " +
                    "the best way to do this. You have any suggestions in mind?",
                true
            ),
            (
                "I'm not sure. There must be a better way to determine what's " +
                    "the best way to do this. You have any suggestions in mind?",
                "I'm not sure. There must be a better way to determine what's " +
                    "the best way to do this.You have any suggestions in mind?",
                false
            ),
            // Additions and reordering are not cleanup.
            ("ship the feature", "ship the feature tomorrow", false),
            ("ship the feature", "basically ship the feature", false),
            ("ship the feature today", "today ship the feature", false),
            // Empty polished can never retain content.
            ("hello there world", "", false),
            ("hello there world", "   ", false),

            // A meaningful leading "so" the model kept matches as content.
            ("so it failed", "so it failed", true),
            // The model left a hard filler in: content is a superset, preserved. Keep.
            ("basically ship the feature", "Basically ship the feature.", true),
            // Possessive/hyphen normalization of the same words. Keep.
            ("the well known issue", "the well-known issue", true),
            // Abbreviation/version dot removed (next token not capitalized, so it
            // was never a sentence boundary). Keep.
            ("see fig. 3 now", "see fig 3 now", true),
            // A restored trailing period does not change meaning. Keep.
            ("ship it", "ship it.", true),
            // Zero-content: a conversion introducing no new characters is fine; an
            // unrelated symbol rewrite is not.
            ("...", ".", true),
            ("...", "???", false),

            // MARK: - rejected meaning changes (every word kept, meaning altered)

            // Added punctuation the user did not dictate.
            ("we should ship it", "we should ship it?", false),
            ("the build passed run it", "the build passed? run it", false),
            ("stop the build", "stop the build!", false),
            ("lets eat grandma", "lets eat, grandma", false),
            ("call me john", "call me, john", false),

            // MARK: - rejected: word substitution and symbol/contraction collapse

            // The guard does not do fuzzy word substitution; a misrecognition fix
            // the canonicalizer does not cover is kept raw (known-term correction
            // is the canonicalizer's job, applied on both sides before the guard).
            ("open ethos cluster", "open Epos cluster", false),
            ("evil ego", "Epos ego", false),
            // A spoken symbol WORD is content here; dropping it (even with the glyph
            // present) is a content change the guard rejects.
            ("i need the period key", "i need the key", false),
            ("i need the period key", "i need the . key", false),
            ("press the dollar key", "press the key", false),
            ("the trial period ended", "the trial. ended", false),
            ("list one comma two", "list one, two", false),
            ("are you sure question mark", "are you sure?", false),
            // A spoken symbol word the model correctly left as content. Keep.
            ("i need the comma key", "I need the comma key.", true),
            // Contraction collapse drops the elided word — a meaning change. Reject.
            // (The token normalizer must NOT strip a trailing "'s".)
            ("let's go now", "let go now", false),
            ("it's broken", "it broken", false),
            ("that's fine with me", "that fine with me", false),
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

import XCTest
@testable import Epos

/// The content-retention guard is a pure string→bool decision (no I/O), so it is
/// exercised directly with a table of cases. The guard receives ALREADY-
/// canonicalized text (canonicalization happens in `TranscriptPolisher.polish`
/// before the guard), so these cases use the post-canonicalize strings directly.
/// It must keep filler removal and the hyphen-merge of an already-spoken compound
/// while rejecting content-word drops, additions, reordering, word substitution,
/// spoken-symbol conversion, contraction collapse, dropped or added content
/// symbols, added meaning-bearing punctuation, and collapsed or invented sentence
/// boundaries.
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
            // Filler-removal: hard single-token fillers stripped, the content words
            // remain exactly in order. "you know" is NOT a droppable
            // phrase (it has content uses the guard can't distinguish), so the model
            // keeping it is fine — every content word survives. Keep.
            ("um we should uh ship it you know", "we should ship it you know", true),
            // Explicit comma-delimited opening disfluencies are droppable.
            ("um, so, like, we should uh ship it", "we should ship it", true),
            // A "like" between content words is treated as a comparator the guard
            // cannot distinguish from a verbal tic, so the model may not DROP it —
            // not even when a filler sits beside it (a filler neighbor does not make
            // "like" itself filler). It MAY keep it: keeping a possible filler never
            // changes meaning. Sentence-initial and semantically-anchored "like"s
            // behave as before. The four cases below share two raw inputs and differ
            // only in what the model did to the mid-sentence "like".
            //
            // Model dropped the mid "like" (between "would" and the filler "uh"): a
            // content-word neighbor means the guard can't safely drop it → reject.
            (
                "Uh, like, I'm trying to see the, uh, filler words would, like, uh, " +
                    "get removed, but it doesn't seem like it.",
                "I'm trying to see the filler words would get removed, but it " +
                    "doesn't seem like it.",
                false
            ),
            // Same input, model also dropped the trailing semantic "like" ("seem like
            // it" → "seem it"): a clear meaning change → reject.
            (
                "Uh, like, I'm trying to see the, uh, filler words would, like, uh, " +
                    "get removed, but it doesn't seem like it.",
                "I'm trying to see the filler words would get removed, but it " +
                    "doesn't seem it.",
                false
            ),
            // Model dropped the mid "like" ("words like uh get" → "words get"):
            // reject for the same reason (the guard keeps the raw words instead).
            (
                "Uh, like, I'm trying to see the filler words like uh get removed " +
                    "but it doesn't seem like it.",
                "I'm trying to see the filler words get removed but it doesn't " +
                    "seem like it.",
                false
            ),
            // Same input, but the model KEPT the mid "like" and removed only the
            // adjacent "uh" ("words like uh get" → "words like get"): every content
            // word survives and a possible filler is merely retained → accept. (The
            // old reject here was an artifact of the force-drop, not a safety bar.)
            (
                "Uh, like, I'm trying to see the filler words like uh get removed " +
                    "but it doesn't seem like it.",
                "I'm trying to see the filler words like get removed but it " +
                    "doesn't seem like it.",
                true
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

            // MARK: - rank 1: a dropped standalone symbol token (invisible to the
            // content-token sequence) is still caught by the symbol-count check.
            ("run -- verbose now", "run verbose now", false),
            ("use / as root", "use as root", false),
            ("cd / etc / hosts", "cd etc hosts", false),
            // Control: the `--` survives on both sides while a filler is removed. Keep.
            ("run -- verbose um now", "run -- verbose now", true),

            // MARK: - rank 2: a comparator "like" beside a filler is not itself
            // filler; dropping it inverts meaning. Reject. (A semantic anchor still
            // protects it even when the model also strips an adjacent filler.)
            ("it tastes like um chicken", "it tastes chicken", false),
            ("it works like uh magic", "it works magic", false),
            ("looks like um rain", "looks rain", false),

            // MARK: - rank 3: meaning-bearing punctuation beyond `, ? !` — a colon,
            // semicolon, or dash the user did not dictate — also changes meaning.
            ("the error is timeout", "the error is: timeout", false),
            ("done now go home", "done; now go home", false),
            ("we win lose it", "we win — lose it", false),

            // MARK: - a dictated `?`/`!` may not be dropped or swapped for the exempt
            // `.` — that inverts a question/command into a statement (every word kept).
            ("is it broken?", "is it broken.", false),
            ("stop it!", "stop it.", false),
            ("do it? stop it", "do it. Stop it", false),
            ("is it broken? really", "is it broken really", false),
            // Control: the `?` is preserved, only casing changes. Keep.
            ("is it broken?", "Is it broken?", true),
            // A count-balanced `?`↔`!` swap between clauses still flips a question and
            // a command, even though every glyph count is preserved. Reject.
            ("do it? stop it!", "do it! stop it?", false),
            ("go now? wait here!", "go now! wait here?", false),
            // Control: both mood marks keep their type across clauses. Keep.
            ("do it? stop it!", "Do it? Stop it!", true),

            // MARK: - rank 4: an invented period+capital splits one dictated sentence
            // into two. Reject (a restored trailing period is still fine, above).
            ("ship it now", "ship it. Now", false),
            ("i ran it again", "i ran it. Again", false),

            // MARK: - rank 5: a hyphen-merge must not fuse across a dictated sentence
            // boundary into a nonsense compound.
            ("we are done. Ship now", "we are done-ship now", false),
            // Control: the same words without the boundary merge legitimately. Keep.
            ("we are done ship now", "we are done-ship now", true),

            // MARK: - finding 1: a comma may DROP only when stranded beside a removed
            // filler — never beside a kept content word, and never be added. Policy is
            // positional and per-gap: a comma is never added to a gap, and a gap may
            // drop at most one comma per dropped filler it contains (one disfluency is
            // delimited by at most one comma).
            //
            // Comma beside two KEPT content words: dropping it changes meaning
            // ("let's eat, grandma" → "let's eat grandma"). Unlicensed → reject.
            ("let's eat, grandma", "let's eat grandma", false),
            // Comma stranded by a dropped filler ("um,") → licensed to drop. Keep.
            ("um, hello", "hello", true),
            // The "a, b" comma sits in a gap with no dropped filler, so it cannot drop
            // even though "um" is removed two gaps over → reject.
            ("a, b, um, c", "a b c", false),
            // One filler licenses one comma drop: "um,, hello" has two commas in the
            // leading gap but only one dropped filler, so dropping both over-drops a
            // comma the disfluency never stranded → reject.
            ("um,, hello", "hello", false),
            // An added comma is always rejected (covered above by "lets eat grandma"
            // → "lets eat, grandma"); here a filler is removed AND a comma added —
            // the addition still rejects even though a drop would have been licensed.
            ("um hello there", "hello, there", false),
            // Count-neutral RELOCATION: the comma moves from the kept-word boundary
            // "eat,grandma" to "let's,eat". Totals match (1→1), so a count-based check
            // waves it through; the per-gap check sees a comma appear in a gap that had
            // none → reject.
            ("let's eat, grandma", "let's, eat grandma", false),
            // Filler-budget MASKING: "um" is dropped (licensing its "um, c" comma), but
            // the unlicensed "a, b" comma is dropped while a NEW comma appears at the
            // kept-word "b c" boundary. A net count compares 2→1 and could pass; the
            // per-gap check rejects the dropped "a,b" and the added "b,c" independently.
            ("a, b um, c", "a b, c", false),
            // Within-gap content comma: "buy milk, um, eggs" surrounds the filler "um"
            // with the list separator on one side. One filler licenses dropping ONE
            // comma, not both — so collapsing the list to "buy milk eggs" over-drops
            // the content comma → reject, while the correct "buy milk, eggs" is kept.
            ("buy milk, um, eggs", "buy milk eggs", false),
            ("buy milk, um, eggs", "buy milk, eggs", true),

            // MARK: - finding 5: an all-caps acronym must not silently fold to/from a
            // lowercase homograph, in EITHER direction (the fold changes meaning).
            // Model lowercased an acronym ("IT" → "it"). Reject.
            ("escalate to IT now", "escalate to it now", false),
            // Model uppercased a word into an acronym ("us" → "US"). Symmetric. Reject.
            ("log in to us", "log in to US", false),
            // Control: a single letter is not an acronym, so ordinary sentence-initial
            // case folding ("I" → "i") still matches. Keep.
            ("I think", "i think", true),

            // MARK: - finding 10: a leading "like" the model KEPT matches as content
            // (keeping a possible filler never changes meaning); if the model DROPS
            // an ambiguous leading "like" or "so" with no comma-delimited
            // disfluency marker, reject and keep the raw words.
            ("Like button is broken", "Like button is broken", true),
            ("Like button is broken", "button is broken", false),
            ("Like we should ship", "we should ship", false),
            ("so that it works", "that it works", false),

            // MARK: - an all-caps acronym must not be droppable just because its
            // normalized lowercase form is a filler token.
            ("go to the ER now", "go to the now", false),

            // MARK: - regression: a dropped negation inverts meaning. Reject.
            ("do not ship it", "do ship it", false),
            ("it isn't ready", "it is ready", false),
            ("we never agreed", "we agreed", false),
            // Regression: a number change is a content change. Reject.
            ("retry after 15 seconds", "retry after 50 seconds", false),
        ]

        for testCase in cases {
            XCTAssertEqual(
                TranscriptPolisher.polishRetainsContent(raw: testCase.raw, polished: testCase.polished),
                testCase.expected,
                "raw=\(testCase.raw) | polished=\(testCase.polished)"
            )
        }
    }

    func testRetentionEvaluationReportsFailureStageAndDiff() throws {
        let evaluation = TranscriptPolisher.polishRetentionEvaluation(
            raw: "test 1st thing",
            polished: "Test first thing."
        )

        XCTAssertFalse(evaluation.retainsContent)
        let rejection = try XCTUnwrap(evaluation.rejection)
        XCTAssertEqual(rejection.reason, .contentTokensChanged)
        XCTAssertTrue(rejection.diff.contains("kind=raw-token-changed"))
        XCTAssertTrue(rejection.diff.contains("rawIndex=1"))
        XCTAssertTrue(rejection.diff.contains("polishedIndex=1"))
        XCTAssertTrue(rejection.diff.contains("hint=ordinal-normalization"))
    }
}

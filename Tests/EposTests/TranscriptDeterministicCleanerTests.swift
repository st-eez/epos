import XCTest
@testable import Epos

final class TranscriptDeterministicCleanerTests: XCTestCase {
    func testRemovesOnlyHardFillersFromAmbiguousSpeech() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("um so like we should uh ship it you know"),
            "so like we should ship it you know"
        )
    }

    func testKeepsBareSoAndLikeBecauseTheyAreAmbiguous() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean(
                "so I was thinking like we could just um refactor the parser"
            ),
            "so I was thinking like we could just refactor the parser"
        )
    }

    func testKeepsCommaDelimitedOpeningDiscourseMarkers() {
        // Dropping a comma-delimited opening "so"/"like" was measured against LLM polish
        // and removed with it: the opener is ambiguous content, so it must survive.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("um, so, like, we should uh ship it"),
            "so, like, we should ship it"
        )
    }

    func testKeepsAcronymsThatNormalizeToFillers() {
        let raw = "go to the ER now"

        XCTAssertEqual(TranscriptDeterministicCleaner.streamClean(raw), raw)
    }

    func testStripStandaloneFillersRemovesHardFillersOnly() {
        let raw = "I think uh we should um ship it"

        let stripped = TranscriptDeterministicCleaner.stripStandaloneFillers(raw)

        XCTAssertEqual(stripped, "I think we should ship it")
    }

    func testStripStandaloneFillersLeavesOrdinalsAndOpenersUntouched() {
        // The filler pass is one stage of `streamClean`: the "so"/"like" opener and the
        // "1st" ordinal are none of its business, only the hard filler "uh" goes.
        let raw = "so, like, the 1st thing uh matters"

        let stripped = TranscriptDeterministicCleaner.stripStandaloneFillers(raw)

        XCTAssertEqual(stripped, "so, like, the 1st thing matters")
    }

    func testStripStandaloneFillersKeepsAcronymsAndDropsTrailingComma() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.stripStandaloneFillers("go to the ER uh now"),
            "go to the ER now"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.stripStandaloneFillers("let's eat um, grandma"),
            "let's eat grandma"
        )
    }

    func testStripStandaloneFillersReturnsInputWhenNoFiller() {
        let raw = "ship the build today"

        XCTAssertEqual(TranscriptDeterministicCleaner.stripStandaloneFillers(raw), raw)
    }

    func testPreservesOneContentCommaAroundRemovedFiller() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("buy milk, um, eggs"),
            "buy milk, eggs"
        )
    }

    func testDropsCommaTrailingARemovedFillerInsteadOfTransplantingIt() {
        // The comma after "um" punctuated the disfluency. Whitespace normalization
        // used to snap it onto the kept word ("let's eat, grandma"), inventing a
        // vocative; it must die with the filler instead.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("let's eat um, grandma"),
            "let's eat grandma"
        )
    }

    func testKeepsCommaOwnedByTheKeptWordWhenALaterFillerDrops() {
        // The comma before "um" belongs to "want"; only the disfluency's own
        // trailing comma is dropped.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("I want, um apples"),
            "I want, apples"
        )
    }

    func testConvertsStandaloneNumericOrdinals() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean(
                "What should we test 1st to ensure that it's still working properly?"
            ),
            "What should we test first to ensure that it's still working properly?"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("ship the 21st build after the 3rd smoke test"),
            "ship the twenty-first build after the third smoke test"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("test 1st, 2nd, 3rd, and 21st"),
            "test first, second, third, and twenty-first"
        )
    }

    func testDoesNotConvertMalformedOrEmbeddedNumericOrdinals() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("test 11st thing and ship the 22th build"),
            "test 11st thing and ship the 22th build"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("open EPOS-1st and version1st before the release"),
            "open EPOS-1st and version1st before the release"
        )
    }

    func testDoesNotReflowGrammar() {
        // Grammar repair ("seems to getting" -> "seems to be getting") was an opt-in
        // polish-path transform, removed with that stack: the always-on pass never
        // rewrites words the user actually said.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("It seems to getting batched."),
            "It seems to getting batched."
        )
    }

    func testCollapseAdjacentDuplicatesRemovesStutteredFunctionWords() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the the build and and ship it"),
            "the build and ship it"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("we we need to fix the the flaky test"),
            "we need to fix the flaky test"
        )
    }

    func testCollapseAdjacentDuplicatesPreservesCopulaCleftConstructions() {
        // The copulas are excluded: "[what X is] is Y" is a real double-copula, not a stutter.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("what it is is important"),
            "what it is is important"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("all it was was luck"),
            "all it was was luck"
        )
    }

    func testCollapseAdjacentDuplicatesCollapsesTriplesToOne() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the the the parser"),
            "the parser"
        )
    }

    func testCollapseAdjacentDuplicatesIsCaseInsensitiveAndKeepsFirstCasing() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("The the report"),
            "The report"
        )
    }

    func testCollapseAdjacentDuplicatesProtectsValidGrammaticalDoublings() {
        // "had had" (past perfect) and "that that" are real English, not stutters.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("I had had enough"),
            "I had had enough"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the fact that that happened"),
            "the fact that that happened"
        )
    }

    func testCollapseAdjacentDuplicatesProtectsEmphasisAndContentWords() {
        // Emphatic reduplication and content-word repeats are NOT in the allow-list,
        // because a deterministic pass can't tell a stutter from intended emphasis.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("it was very very slow"),
            "it was very very slow"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("rebuild rebuild the project"),
            "rebuild rebuild the project"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the food was so so"),
            "the food was so so"
        )
    }

    func testCollapseAdjacentDuplicatesIgnoresCommaSeparatedRepeats() {
        // A comma between the repeats means it is not a single stuttered run.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the, the report"),
            "the, the report"
        )
    }

    func testCollapseAdjacentDuplicatesKeepsCommaTrailingTheCollapsedStutter() {
        // The removed copy is the SECOND "the"; the comma after it is the user's
        // punctuation on the kept word, not filler punctuation — collapse but keep it.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the the, report"),
            "the, report"
        )
    }

    func testCollapseAdjacentDuplicatesPreservesAcronymBesideLowercaseHomonym() {
        // "OR" (operating room) is a distinct token from the conjunction "or"; their
        // lowercase forms collide, but the acronym guard keeps both. Same for "IT"/"it".
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the OR or the ICU"),
            "the OR or the ICU"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("the IT it manages"),
            "the IT it manages"
        )
    }

    func testCollapseAdjacentDuplicatesPreservesDoubledPhrasalParticles() {
        // "in"/"on" double legitimately at a particle+preposition juncture, not a stutter.
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("log in in the morning"),
            "log in in the morning"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.collapseAdjacentDuplicates("turn it on on Monday"),
            "turn it on on Monday"
        )
    }

    func testCollapseAdjacentDuplicatesReturnsInputWhenNoDuplicate() {
        let raw = "send it to the whole team"
        XCTAssertEqual(TranscriptDeterministicCleaner.collapseAdjacentDuplicates(raw), raw)
    }

    func testLiveFillerStripAndDedupCompose() {
        // The live insertion path runs both passes: hard fillers go, then the stutter the
        // filler removal exposed collapses — exactly the AppCoordinator canonicalize closure.
        let raw = "I think uh the the build um is broken"
        let cleaned = TranscriptDeterministicCleaner.collapseAdjacentDuplicates(
            TranscriptDeterministicCleaner.stripStandaloneFillers(raw)
        )
        XCTAssertEqual(cleaned, "I think the build is broken")
    }
}

import XCTest
@testable import Epos

final class TranscriptDeterministicCleanerTests: XCTestCase {
    func testRemovesOnlyHardFillersFromAmbiguousSpeech() {
        let raw = "um so like we should uh ship it you know"

        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "so like we should ship it you know")
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(raw: raw, polished: cleaned))
    }

    func testRemovesCommaDelimitedOpeningDiscourseMarkers() {
        let raw = "um, so, like, we should uh ship it"

        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "we should ship it")
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(raw: raw, polished: cleaned))
    }

    func testKeepsBareSoAndLikeBecauseTheyAreAmbiguous() {
        let raw = "so I was thinking like we could just um refactor the parser"

        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "so I was thinking like we could just refactor the parser")
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(raw: raw, polished: cleaned))
    }

    func testKeepsAcronymsThatNormalizeToFillers() {
        let raw = "go to the ER now"

        XCTAssertEqual(TranscriptDeterministicCleaner.clean(raw), raw)
    }

    func testStripStandaloneFillersRemovesHardFillersOnly() {
        let raw = "I think uh we should um ship it"

        let stripped = TranscriptDeterministicCleaner.stripStandaloneFillers(raw)

        XCTAssertEqual(stripped, "I think we should ship it")
    }

    func testStripStandaloneFillersLeavesOrdinalsAndOpenersUntouched() {
        // The live strip must NOT do the full `clean` transforms (they act on
        // not-yet-stable partials): the "so"/"like" opener and "1st" ordinal stay,
        // only the hard filler "uh" goes.
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
        let raw = "buy milk, um, eggs"

        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "buy milk, eggs")
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(raw: raw, polished: cleaned))
    }

    func testDropsCommaTrailingARemovedFillerInsteadOfTransplantingIt() {
        // The comma after "um" punctuated the disfluency. Whitespace normalization
        // used to snap it onto the kept word ("let's eat, grandma"), inventing a
        // vocative; it must die with the filler instead.
        let raw = "let's eat um, grandma"

        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "let's eat grandma")
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(raw: raw, polished: cleaned))
    }

    func testKeepsCommaOwnedByTheKeptWordWhenALaterFillerDrops() {
        // The comma before "um" belongs to "want"; only the disfluency's own
        // trailing comma is dropped.
        let raw = "I want, um apples"

        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "I want, apples")
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(raw: raw, polished: cleaned))
    }

    func testConvertsStandaloneNumericOrdinals() {
        let first = "What should we test 1st to ensure that it's still working properly?"
        let twentyFirst = "ship the 21st build after the 3rd smoke test"

        XCTAssertEqual(
            TranscriptDeterministicCleaner.clean(first),
            "What should we test first to ensure that it's still working properly?"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.clean(twentyFirst),
            "ship the twenty-first build after the third smoke test"
        )
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(
            raw: first,
            polished: TranscriptDeterministicCleaner.clean(first)
        ))
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(
            raw: twentyFirst,
            polished: TranscriptDeterministicCleaner.clean(twentyFirst)
        ))
    }

    func testStreamCleanConvertsStandaloneNumericOrdinals() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("test 1st, 2nd, 3rd, and 21st"),
            "test first, second, third, and twenty-first"
        )
    }

    func testDoesNotConvertMalformedOrEmbeddedNumericOrdinals() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.clean("test 11st thing and ship the 22th build"),
            "test 11st thing and ship the 22th build"
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.clean("open EPOS-1st and version1st before the release"),
            "open EPOS-1st and version1st before the release"
        )
    }

    func testInsertsMissingBeOnlyForMeasuredSeemsToGettingPattern() {
        let raw = "It seems to getting batched."
        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "It seems to be getting batched.")
        XCTAssertTrue(TranscriptPolisher.polishRetainsContent(raw: raw, polished: cleaned))
    }

    func testStreamCleanInsertsMissingBeOnlyForMeasuredSeemsToGettingPattern() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.streamClean("It seems to getting batched."),
            "It seems to be getting batched."
        )
    }

    func testDoesNotInsertMissingBeForOtherIngOrPunctuatedShapes() {
        let unchanged = [
            "It seems to bring the wrong file.",
            "It seems, to getting batched.",
            "I want to getting started.",
        ]
        for transcript in unchanged {
            XCTAssertEqual(TranscriptDeterministicCleaner.clean(transcript), transcript)
            XCTAssertEqual(TranscriptDeterministicCleaner.streamClean(transcript), transcript)
        }
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

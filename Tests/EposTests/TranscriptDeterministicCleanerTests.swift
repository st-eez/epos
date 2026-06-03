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

    func testPreservesOneContentCommaAroundRemovedFiller() {
        let raw = "buy milk, um, eggs"

        let cleaned = TranscriptDeterministicCleaner.clean(raw)

        XCTAssertEqual(cleaned, "buy milk, eggs")
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

    func testDoesNotInsertMissingBeForOtherIngOrPunctuatedShapes() {
        XCTAssertEqual(
            TranscriptDeterministicCleaner.clean("It seems to bring the wrong file."),
            "It seems to bring the wrong file."
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.clean("It seems, to getting batched."),
            "It seems, to getting batched."
        )
        XCTAssertEqual(
            TranscriptDeterministicCleaner.clean("I want to getting started."),
            "I want to getting started."
        )
    }
}

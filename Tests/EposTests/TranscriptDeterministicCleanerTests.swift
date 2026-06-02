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
}

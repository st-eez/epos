import XCTest
@testable import Epos

/// `PolishVocabulary.singleFillers` is the single source of the filler words the
/// content-retention guard accepts dropping and the engine prompt tells the model
/// to remove. The guard consumes it directly (a code reference, so it cannot
/// drift). This test pins the prompt to it: if a filler is added to or removed from
/// the set, the prompt's interpolated enumeration must follow, or the model and the
/// guard would disagree about what may be removed (a mismatch makes the guard
/// reject the whole polish). (`fillerPhrases` is deliberately NOT asserted: the
/// guard no longer drops those and the prompt no longer names them — see
/// `PolishVocabulary`. Spoken-symbol conversion is owned by
/// `TranscriptCanonicalizer`, not the polish stage, so it is absent here too.)
final class PolishVocabularyTests: XCTestCase {
    func testPromptNamesEveryFillerSoItCannotDriftFromTheGuard() {
        let prompt = FoundationModelsPolishEngine.makeInstructions(knownTerms: []).lowercased()

        for filler in PolishVocabulary.singleFillers {
            XCTAssertTrue(prompt.contains(filler), "prompt should name filler '\(filler)'")
        }
    }

    func testPromptDoesNotLicenseAmbiguousDeletionBeyondTheGuard() {
        let prompt = FoundationModelsPolishEngine.makeInstructions(knownTerms: []).lowercased()

        XCTAssertTrue(prompt.contains("do not remove meaningful words"))
        XCTAssertTrue(prompt.contains("bare \"so\" or \"like\" without a comma must stay"))
        XCTAssertTrue(prompt.contains("the only words you may remove are the exact"))
        XCTAssertTrue(prompt.contains("\"you know\""))
        XCTAssertTrue(prompt.contains("\"i mean\""))
    }

    func testKnownTermsLineIsAppendedOnlyWhenTermsExist() {
        XCTAssertFalse(FoundationModelsPolishEngine.makeInstructions(knownTerms: []).contains("Known project terms"))
        XCTAssertTrue(
            FoundationModelsPolishEngine.makeInstructions(knownTerms: ["Epos"]).contains("Known project terms")
        )
    }
}

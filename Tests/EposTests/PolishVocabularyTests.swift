import XCTest
@testable import Epos

/// `PolishVocabulary` is the single source of the filler vocabulary the content-
/// retention guard and the engine prompt both reason about. The guard consumes it
/// directly (a code reference, so it cannot drift). These tests pin the prompt to
/// it: if a filler is added to the vocabulary, the prompt must name it too, or the
/// model and the guard would disagree about what may be removed. (Spoken-symbol
/// conversion is owned by `TranscriptCanonicalizer`, not the polish stage, so it
/// is intentionally absent here.)
final class PolishVocabularyTests: XCTestCase {
    func testPromptNamesEveryFillerSoItCannotDriftFromTheGuard() {
        let prompt = FoundationModelsPolishEngine.makeInstructions(knownTerms: []).lowercased()

        for filler in PolishVocabulary.singleFillers {
            XCTAssertTrue(prompt.contains(filler), "prompt should name filler '\(filler)'")
        }
        for phrase in PolishVocabulary.fillerPhrases {
            let joined = phrase.joined(separator: " ")
            XCTAssertTrue(prompt.contains(joined), "prompt should name filler phrase '\(joined)'")
        }
    }

    func testKnownTermsLineIsAppendedOnlyWhenTermsExist() {
        XCTAssertFalse(FoundationModelsPolishEngine.makeInstructions(knownTerms: []).contains("Known project terms"))
        XCTAssertTrue(
            FoundationModelsPolishEngine.makeInstructions(knownTerms: ["Epos"]).contains("Known project terms")
        )
    }
}

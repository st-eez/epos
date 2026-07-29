import XCTest
@testable import Epos

/// The live insertion closure cleans every streamed partial/final
/// (`streamClean(canonicalize(...))`), and the authoritative FINAL text is typed
/// verbatim from `makeFinalTranscriptCleaner()` (no second canonicalize). If the two
/// diverge, finalization re-types the raw, filler/stutter-laden tail and reverts the
/// on-screen cleaning on every deletable target. This pins that parity.
@MainActor
final class CoordinatorFinalCleaningTests: XCTestCase {
    private static let disfluentRaw = "the the uh build is broken"
    private static let cleaned = "the build is broken"

    func testFinalTranscriptMatchesLiveStreamCleaning() {
        let coordinator = AppCoordinator(autoStart: false)

        let finalText = coordinator.makeFinalTranscriptCleaner()(Self.disfluentRaw)

        // The final typed text must equal what the live closure streamed on screen:
        // the same `streamClean` over the same canonicalization.
        let liveStreamed = TranscriptDeterministicCleaner.streamClean(
            coordinator.corrections.canonicalize(Self.disfluentRaw)
        )
        XCTAssertEqual(finalText, liveStreamed)
        XCTAssertEqual(finalText, Self.cleaned)
        // Guard against a silent no-op: corrections-only (the pre-fix baseline) leaves the
        // fillers and stutters, so the cleaned final must differ from it.
        XCTAssertNotEqual(finalText, coordinator.corrections.canonicalize(Self.disfluentRaw))
    }
}

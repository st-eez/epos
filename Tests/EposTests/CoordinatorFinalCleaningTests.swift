import XCTest
@testable import Epos

/// The live insertion closure cleans every streamed partial/final
/// (`streamClean(canonicalize(...))`), but the authoritative FINAL text is produced by
/// the per-recording polisher and typed verbatim by `acceptFinalPolishedTranscript`
/// (no second canonicalize). If `makePolisher` does not apply the same `streamClean`,
/// the polish-off default (and the polish-on deterministic baseline for stutters)
/// re-types the raw, filler/stutter-laden tail at finalization and reverts the
/// on-screen cleaning on every deletable target. These pin the parity: the polisher's
/// final text must equal the live closure's transform in both polish modes.
@MainActor
final class CoordinatorFinalCleaningTests: XCTestCase {
    private static let disfluentRaw = "the the uh build is broken"
    private static let cleaned = "the build is broken"

    func testPolishOffFinalBaselineMatchesLiveStreamCleaning() async {
        let coordinator = AppCoordinator(
            settings: Settings(polishEnabled: false),
            autoStart: false
        )
        let polisher = coordinator.makePolisher()

        let result = await polisher.polish(Self.disfluentRaw)

        // The final typed text must equal what the live closure streamed on screen:
        // the same `streamClean` over the same canonicalization.
        let liveStreamed = TranscriptDeterministicCleaner.streamClean(
            coordinator.corrections.canonicalize(Self.disfluentRaw)
        )
        XCTAssertEqual(result.text, liveStreamed)
        XCTAssertEqual(result.text, Self.cleaned)
        // Guard against a silent no-op: corrections-only (the pre-fix baseline) leaves the
        // fillers and stutters, so the cleaned final must differ from it.
        XCTAssertNotEqual(result.text, coordinator.corrections.canonicalize(Self.disfluentRaw))
    }

    func testPolishOnFinalBaselineMatchesLiveStreamCleaning() async {
        // Engine unavailable → polish falls through to the deterministic baseline
        // (`canonicalRaw`/`clean`), exercising the polish-ON wiring without a real model.
        // `clean()` alone strips fillers but never collapses stutters, so this also pins
        // that the stutter collapse reaches the final text only via the shared seam.
        let coordinator = AppCoordinator(
            settings: Settings(polishEnabled: true),
            polishEngine: FakePolishEngine(isAvailable: false),
            autoStart: false
        )
        let polisher = coordinator.makePolisher()

        let result = await polisher.polish(Self.disfluentRaw)

        XCTAssertEqual(result.text, Self.cleaned)
        XCTAssertNotEqual(result.text, coordinator.corrections.canonicalize(Self.disfluentRaw))
    }
}

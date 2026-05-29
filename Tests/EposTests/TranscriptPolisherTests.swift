import XCTest
@testable import Epos

/// Policy tests for `TranscriptPolisher.polish`, driven by a fake engine so the
/// six decision paths (disabled / unavailable / throws / guard-fail / success /
/// empty) are exercised hermetically — no FoundationModels, no network. The real
/// model call and the live insertion it feeds are not unit-testable (they need
/// the installed signed app), so only the policy around the engine is covered.
final class TranscriptPolisherTests: XCTestCase {
    func testPolishReturnsRawAndSkipsEngineWhenDisabled() async {
        let engine = FakePolishEngine(result: "polished output")
        let polisher = TranscriptPolisher(enabled: false, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result, "raw transcript")
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testPolishReturnsRawWhenEngineUnavailable() async {
        let engine = FakePolishEngine(isAvailable: false, result: "polished output")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result, "raw transcript")
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testPolishReturnsRawWhenEngineThrows() async {
        let engine = FakePolishEngine(throwError: FakePolishError())
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result, "raw transcript")
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsRawWhenOutputFailsRetentionGuard() async {
        // The engine over-compressed a multi-clause command to a trailing
        // fragment; the retention guard must reject it and keep the raw words.
        let raw = "run the script with dash dash verbose and point it at dollar home slash bin"
        let engine = FakePolishEngine(result: "dollar home slash bin")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish(raw)

        XCTAssertEqual(result, raw)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsPolishedWhenAvailableAndGuardPasses() async {
        // Legit cleanup: fillers removed, every substantive word retained — the
        // guard passes and the polished text is used.
        let raw = "um so i think we should uh ship the feature you know"
        let engine = FakePolishEngine(result: "I think we should ship the feature.")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish(raw)

        XCTAssertEqual(result, "I think we should ship the feature.")
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsRawForEmptyInputWithoutCallingEngine() async {
        let engine = FakePolishEngine(result: "polished output")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("   ")

        XCTAssertEqual(result, "   ")
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testPrewarmDelegatesToEngineOnlyWhenEnabledAndAvailable() {
        let enabledAvailable = FakePolishEngine(isAvailable: true)
        TranscriptPolisher(enabled: true, engine: enabledAvailable).prewarm()
        XCTAssertEqual(enabledAvailable.prewarmCallCount, 1)

        let disabled = FakePolishEngine(isAvailable: true)
        TranscriptPolisher(enabled: false, engine: disabled).prewarm()
        XCTAssertEqual(disabled.prewarmCallCount, 0)

        let unavailable = FakePolishEngine(isAvailable: false)
        TranscriptPolisher(enabled: true, engine: unavailable).prewarm()
        XCTAssertEqual(unavailable.prewarmCallCount, 0)
    }
}

/// Configurable test double for `PolishEngine`. `@unchecked Sendable` is safe
/// here: each test awaits `polish` to completion before reading the counters, so
/// there is no concurrent access.
final class FakePolishEngine: PolishEngine, @unchecked Sendable {
    var isAvailable: Bool
    var result: String
    var throwError: Error?
    private(set) var polishCallCount = 0
    private(set) var prewarmCallCount = 0

    init(isAvailable: Bool = true, result: String = "", throwError: Error? = nil) {
        self.isAvailable = isAvailable
        self.result = result
        self.throwError = throwError
    }

    func prewarm() { prewarmCallCount += 1 }

    func polish(_ raw: String) async throws -> String {
        polishCallCount += 1
        if let throwError { throw throwError }
        return result
    }
}

struct FakePolishError: Error {}

import XCTest
@testable import Epos

/// Policy tests for `TranscriptPolisher.polish`, driven by a fake engine so the
/// seven decision paths (disabled / unavailable / throws / timeout / guard-fail
/// / success / empty) are exercised hermetically — no FoundationModels, no network. The real
/// model call and the live insertion it feeds are not unit-testable (they need
/// the installed signed app), so only the policy around the engine is covered.
final class TranscriptPolisherTests: XCTestCase {
    func testPolishReturnsRawAndSkipsEngineWhenDisabled() async {
        let engine = FakePolishEngine(result: "polished output")
        let polisher = TranscriptPolisher(enabled: false, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.outcome, .disabled)
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testPolishReturnsRawWhenEngineUnavailable() async {
        let engine = FakePolishEngine(isAvailable: false, result: "polished output")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.outcome, .unavailable)
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testPolishReturnsRawWhenEngineThrows() async {
        let engine = FakePolishEngine(throwError: FakePolishError())
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsRawWhenEngineTimesOut() async {
        let engine = FakePolishEngine(result: "polished output", delayNanoseconds: 1_000_000_000)
        let polisher = TranscriptPolisher(
            enabled: true,
            engine: engine,
            timeoutNanoseconds: 50_000_000
        )

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsRawWhenOutputFailsRetentionGuard() async {
        // The engine over-compressed a multi-clause command to a trailing
        // fragment; the retention guard must reject it and keep the raw words.
        let raw = "run the script with dash dash verbose and point it at dollar home slash bin"
        let engine = FakePolishEngine(result: "dollar home slash bin")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish(raw)

        XCTAssertEqual(result.text, raw)
        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsPolishedWhenAvailableAndGuardPasses() async {
        // Legit cleanup: fillers removed, every substantive word retained — the
        // guard passes and the polished text is used.
        let raw = "um so i think we should uh ship the feature you know"
        let engine = FakePolishEngine(result: "I think we should ship the feature.")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish(raw)

        XCTAssertEqual(result.text, "I think we should ship the feature.")
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsRawForEmptyInputWithoutCallingEngine() async {
        let engine = FakePolishEngine(result: "polished output")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("   ")

        XCTAssertEqual(result.text, "   ")
        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testPrewarmDelegatesToEngineOnlyWhenEnabledAndAvailable() {
        let enabledAvailable = FakePolishEngine(isAvailable: true)
        TranscriptPolisher(enabled: true, engine: enabledAvailable, knownTerms: ["CMUX"]).prewarm()
        XCTAssertEqual(enabledAvailable.prewarmCallCount, 1)
        XCTAssertEqual(enabledAvailable.prewarmKnownTerms, [["CMUX"]])

        let disabled = FakePolishEngine(isAvailable: true)
        TranscriptPolisher(enabled: false, engine: disabled).prewarm()
        XCTAssertEqual(disabled.prewarmCallCount, 0)

        let unavailable = FakePolishEngine(isAvailable: false)
        TranscriptPolisher(enabled: true, engine: unavailable).prewarm()
        XCTAssertEqual(unavailable.prewarmCallCount, 0)
    }

    func testKnownTermsArePassedToEngine() async {
        let engine = FakePolishEngine(result: "Open CMUX.")
        let polisher = TranscriptPolisher(enabled: true, engine: engine, knownTerms: ["Epos", "CMUX"])

        let result = await polisher.polish("open CMUX")

        XCTAssertEqual(result.text, "Open CMUX.")
        XCTAssertEqual(engine.polishKnownTerms, [["Epos", "CMUX"]])
    }
}

/// Configurable test double for `PolishEngine`. `@unchecked Sendable` is safe
/// here: each test awaits `polish` to completion before reading the counters, so
/// there is no concurrent access.
final class FakePolishEngine: PolishEngine, @unchecked Sendable {
    var isAvailable: Bool
    var result: String
    var throwError: Error?
    var delayNanoseconds: UInt64?
    private(set) var polishCallCount = 0
    private(set) var prewarmCallCount = 0
    private(set) var polishKnownTerms: [[String]] = []
    private(set) var prewarmKnownTerms: [[String]] = []

    init(
        isAvailable: Bool = true,
        result: String = "",
        throwError: Error? = nil,
        delayNanoseconds: UInt64? = nil
    ) {
        self.isAvailable = isAvailable
        self.result = result
        self.throwError = throwError
        self.delayNanoseconds = delayNanoseconds
    }

    func prewarm(knownTerms: [String]) {
        prewarmCallCount += 1
        prewarmKnownTerms.append(knownTerms)
    }

    func polish(_ raw: String, knownTerms: [String]) async throws -> String {
        polishCallCount += 1
        polishKnownTerms.append(knownTerms)
        if let delayNanoseconds {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let throwError { throw throwError }
        return result
    }
}

struct FakePolishError: Error {}

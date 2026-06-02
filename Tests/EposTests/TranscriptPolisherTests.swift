import XCTest
@testable import Epos

/// Policy tests for `TranscriptPolisher.polish`, driven by a fake engine so the
/// decision paths (disabled / unavailable / throws / timeout / guard-fail /
/// success / empty) are exercised hermetically — no FoundationModels, no network. The real
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
        XCTAssertEqual(result.outcome, .engineFailed)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testPolishReturnsRawWhenEngineReturnsSameText() async {
        let engine = FakePolishEngine(result: "raw transcript")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.outcome, .sameText)
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

    func testAbandonInFlightPolishReturnsRawPromptlyWithoutWaitingForTheDecode() async {
        // A slow decode under a long timeout: without abandon, polish() would block on
        // the ~2s decode. An abandon (a re-press during the finalize window) makes it
        // give up immediately with the raw text — the decode is orphaned, not awaited.
        let engine = FakePolishEngine(result: "polished output", delayNanoseconds: 2_000_000_000)
        let polisher = TranscriptPolisher(
            enabled: true,
            engine: engine,
            timeoutNanoseconds: 10_000_000_000
        )
        let startedAt = Date()
        async let pending = polisher.polish("raw transcript")
        try? await Task.sleep(nanoseconds: 200_000_000) // let the decode get in-flight
        polisher.abandonInFlightPolish()
        let result = await pending

        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.outcome, .abandoned)
        XCTAssertEqual(engine.polishCallCount, 1)
        // Returned on abandon, far short of the 2s decode (and the 10s timeout).
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testAbandonWithNoPolishRunningIsANoOp() {
        // Triggering an abandon when nothing is in flight must not crash.
        let engine = FakePolishEngine(result: "polished output")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)
        polisher.abandonInFlightPolish()
    }

    func testAbandonRequestedBeforePolishStartsStillReturnsRawPromptly() async {
        // The re-press can land while the recognizer is still draining, before the polish
        // arms its abandon handle. The request must stick so the polish that starts a
        // moment later gives up immediately rather than blocking on the decode.
        let engine = FakePolishEngine(result: "polished output", delayNanoseconds: 2_000_000_000)
        let polisher = TranscriptPolisher(
            enabled: true,
            engine: engine,
            timeoutNanoseconds: 10_000_000_000
        )
        polisher.abandonInFlightPolish() // before polish() is even called
        let startedAt = Date()
        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result.text, "raw transcript")
        XCTAssertEqual(result.outcome, .abandoned)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
    }

    func testPolishReturnsRawWhenOutputFailsRetentionGuard() async {
        // The engine over-compressed a multi-clause command to a trailing
        // fragment; the retention guard must reject it and keep the raw words.
        let raw = "run the script with dash dash verbose and point it at dollar home slash bin"
        let engine = FakePolishEngine(result: "dollar home slash bin")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish(raw)

        XCTAssertEqual(result.text, raw)
        XCTAssertEqual(result.outcome, .guardRejected)
        XCTAssertEqual(result.guardRejection?.reason, .contentTokensChanged)
        XCTAssertEqual(result.guardRejection?.candidateCharacterCount, engine.result.count)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testGuardRejectedOutcomeIncludesCandidateTextAndOrdinalDiagnostics() async throws {
        let engine = FakePolishEngine(result: "Test first thing.")
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("test 1st thing")

        XCTAssertEqual(result.text, "test 1st thing")
        XCTAssertEqual(result.outcome, .guardRejected)
        let rejection = try XCTUnwrap(result.guardRejection)
        XCTAssertEqual(rejection.reason, .contentTokensChanged)
        XCTAssertEqual(rejection.candidateText, "Test first thing.")
        XCTAssertEqual(rejection.candidateCharacterCount, "Test first thing.".count)
        XCTAssertTrue(rejection.diff.contains("rawTokenShape=numeric-ordinal"))
        XCTAssertTrue(rejection.diff.contains("polishedTokenShape=ordinal-word"))
        XCTAssertTrue(rejection.diff.contains("hint=ordinal-normalization"))
        XCTAssertTrue(rejection.logDescription.contains(#"candidateText="Test first thing.""#))
    }

    func testPolishReturnsPolishedWhenAvailableAndGuardPasses() async {
        // Legit cleanup: only droppable fillers removed (um, comma-delimited
        // sentence-initial so, uh), every substantive word retained — the guard
        // passes and the polished text is used. (Ambiguous fillers like "you know"
        // are no longer droppable: the guard would reject their removal, so they are
        // deliberately absent here.)
        let raw = "um, so, i think we should uh ship the feature"
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
        XCTAssertEqual(result.outcome, .sameText)
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testPrewarmDelegatesToEngineOnlyWhenEnabledAndAvailable() {
        let enabledAvailable = FakePolishEngine(isAvailable: true)
        TranscriptPolisher(enabled: true, engine: enabledAvailable, knownTerms: ["CMUX"]).prewarm()
        XCTAssertEqual(enabledAvailable.sessionCount, 1)
        XCTAssertEqual(enabledAvailable.sessionKnownTerms, [["CMUX"]])

        let disabled = FakePolishEngine(isAvailable: true)
        TranscriptPolisher(enabled: false, engine: disabled).prewarm()
        XCTAssertEqual(disabled.sessionCount, 0)

        let unavailable = FakePolishEngine(isAvailable: false)
        TranscriptPolisher(enabled: true, engine: unavailable).prewarm()
        XCTAssertEqual(unavailable.sessionCount, 0)
    }

    func testPrewarmedSessionIsReusedForPolish() async {
        // The latency fix: prewarm() builds the session at recording start and polish()
        // reuses THAT session — one session per recording, not a prewarmed one discarded
        // plus a fresh one built at finish (the prior design, measured to cost ~750ms).
        let engine = FakePolishEngine(result: "Polished.")
        let polisher = TranscriptPolisher(enabled: true, engine: engine, knownTerms: ["Epos"])

        polisher.prewarm()
        let result = await polisher.polish("polished")

        XCTAssertEqual(engine.sessionCount, 1)
        XCTAssertEqual(engine.polishCallCount, 1)
        XCTAssertEqual(result.text, "Polished.")
    }

    func testKnownTermsArePassedToEngine() async {
        let engine = FakePolishEngine(result: "Open CMUX.")
        let polisher = TranscriptPolisher(enabled: true, engine: engine, knownTerms: ["Epos", "CMUX"])

        let result = await polisher.polish("open CMUX")

        XCTAssertEqual(result.text, "Open CMUX.")
        XCTAssertEqual(engine.polishKnownTerms, [["Epos", "CMUX"]])
    }

    func testPolishSurfacesTooLongWhenEngineReportsContextOverflow() async {
        // A context-window overflow is a distinct outcome, not a silent no-op, so
        // an over-long dictation is observably skipped.
        let engine = FakePolishEngine(throwError: PolishInputTooLargeError())
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("a very long raw transcript")

        XCTAssertEqual(result.text, "a very long raw transcript")
        XCTAssertEqual(result.outcome, .tooLong)
        XCTAssertEqual(engine.polishCallCount, 1)
    }

    func testGenericEngineThrowStaysUnchangedNotTooLong() async {
        // Guards the `catch is PolishInputTooLargeError` boundary: any other throw
        // is an ordinary fallback, not `.tooLong`.
        let engine = FakePolishEngine(throwError: FakePolishError())
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("raw transcript")

        XCTAssertEqual(result.outcome, .engineFailed)
    }

    func testPolishRejectsModelWordSubstitutionAndKeepsRaw() async {
        // The model "fixed" a misrecognition to a known term the canonicalizer does
        // not rule. The guard cannot tell a real correction from a corruption (e.g.
        // "epic" -> "Epos"), so it rejects the substitution and keeps the raw words.
        // Known-term correction is the canonicalizer's job, applied on both sides.
        let engine = FakePolishEngine(result: "open Epos cluster")
        let polisher = TranscriptPolisher(enabled: true, engine: engine, knownTerms: ["Epos"])

        let result = await polisher.polish("open ethos cluster")

        XCTAssertEqual(result.text, "open ethos cluster")
        XCTAssertEqual(result.outcome, .guardRejected)
    }

    func testGuardComparesCanonicalizedRawSoOneSidedCanonicalizationAccepts() async {
        // Raw "see mux is down" and engine "CMUX is down." differ as raw strings,
        // but canonicalize maps "see mux" -> "CMUX" on BOTH sides, so the guard
        // compares "CMUX is down" vs "CMUX is down." and accepts the cleanup.
        let engine = FakePolishEngine(result: "CMUX is down.")
        let canonicalize: @Sendable (String) -> String = {
            $0.replacingOccurrences(of: "see mux", with: "CMUX")
        }
        let polisher = TranscriptPolisher(enabled: true, engine: engine, canonicalize: canonicalize)

        let result = await polisher.polish("see mux is down")

        XCTAssertEqual(result.text, "CMUX is down.")
        XCTAssertEqual(result.outcome, .applied)
        // The log reads `rawCharacterCount` instead of re-canonicalizing the raw
        // transcript: on `.applied` it is the canonicalized-RAW baseline, distinct
        // from the polished `result.text.count`, so rawChars − polishedChars stays
        // the filler-removal delta on a single normalization.
        XCTAssertEqual(result.rawCharacterCount, canonicalize("see mux is down").count)
        XCTAssertNotEqual(result.rawCharacterCount, result.text.count)
    }

    func testFallbackOutcomesReturnCanonicalizedRaw() async {
        // When polish is disabled the returned text is the canonicalized raw, so
        // the field target is consistent whether or not polish runs.
        let engine = FakePolishEngine(result: "ignored")
        let canonicalize: @Sendable (String) -> String = { $0.uppercased() }
        let polisher = TranscriptPolisher(enabled: false, engine: engine, canonicalize: canonicalize)

        let result = await polisher.polish("hello world")

        XCTAssertEqual(result.text, "HELLO WORLD")
        XCTAssertEqual(result.outcome, .disabled)
        XCTAssertEqual(engine.polishCallCount, 0)
    }

    func testEffectivePolishOutcomeDowngradesAppliedWhenNothingTyped() {
        let applied = PolishResult(text: "polished", outcome: .applied, rawCharacterCount: 8)
        XCTAssertEqual(TranscriptPolisher.effectivePolishOutcome(applied, applied: false), .suppressedByInsertion)
        XCTAssertEqual(TranscriptPolisher.effectivePolishOutcome(applied, applied: true), .applied)

        let timedOut = PolishResult(text: "raw", outcome: .timedOut, rawCharacterCount: 3)
        XCTAssertEqual(TranscriptPolisher.effectivePolishOutcome(timedOut, applied: false), .timedOut)

        let tooLong = PolishResult(text: "raw", outcome: .tooLong, rawCharacterCount: 3)
        XCTAssertEqual(TranscriptPolisher.effectivePolishOutcome(tooLong, applied: false), .tooLong)
    }
}

/// Configurable test double for `PolishEngine` + `PolishSession`. `@unchecked Sendable`:
/// the polish counters are lock-guarded because, since the policy now runs the decode in
/// an UNSTRUCTURED task, a timed-out or abandoned `polish()` returns while the fake's
/// `polish` is still in-flight on a background task — so a test reading the counters can
/// race that orphaned call. `sessionCount`/`sessionKnownTerms` track `makeSession` (called
/// synchronously before the decode task spawns, so they need no lock); `polishCallCount`/
/// `polishKnownTerms` track the polish calls made on the sessions it produced.
final class FakePolishEngine: PolishEngine, @unchecked Sendable {
    var isAvailable: Bool
    var result: String
    var throwError: Error?
    var delayNanoseconds: UInt64?
    private(set) var sessionCount = 0
    private(set) var sessionKnownTerms: [[String]] = []

    private let lock = NSLock()
    private var _polishCallCount = 0
    private var _polishKnownTerms: [[String]] = []
    var polishCallCount: Int { lock.withLock { _polishCallCount } }
    var polishKnownTerms: [[String]] { lock.withLock { _polishKnownTerms } }

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

    func makeSession(knownTerms: [String]) -> any PolishSession {
        sessionCount += 1
        sessionKnownTerms.append(knownTerms)
        return FakePolishSession(engine: self, knownTerms: knownTerms)
    }

    fileprivate func recordPolish(knownTerms: [String]) {
        lock.withLock {
            _polishCallCount += 1
            _polishKnownTerms.append(knownTerms)
        }
    }
}

/// A session produced by `FakePolishEngine`, carrying the `knownTerms` it was built with
/// and reading its result/error/delay from the engine so the existing test configuration
/// keeps working through the new seam.
final class FakePolishSession: PolishSession, @unchecked Sendable {
    private let engine: FakePolishEngine
    private let knownTerms: [String]

    init(engine: FakePolishEngine, knownTerms: [String]) {
        self.engine = engine
        self.knownTerms = knownTerms
    }

    func polish(_ raw: String) async throws -> String {
        engine.recordPolish(knownTerms: knownTerms)
        if let delayNanoseconds = engine.delayNanoseconds {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let throwError = engine.throwError { throw throwError }
        return engine.result
    }
}

struct FakePolishError: Error {}

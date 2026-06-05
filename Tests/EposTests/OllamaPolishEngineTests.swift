import XCTest
@testable import Epos

final class OllamaPolishEngineTests: XCTestCase {
    func testUsesQwen17BAndConservativePromptByDefaultAndUnloadsAfterPolish() async throws {
        let client = FakeOllamaPolishClient(cleaned: "Hello world.")
        let engine = OllamaPolishEngine(client: client, prewarmEnabled: false)
        let session = engine.makeSession(knownTerms: ["CMUX"])

        let output = try await session.polish("um hello world")

        XCTAssertEqual(output, "Hello world.")
        let requests = client.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].model, "qwen3:1.7b")
        XCTAssertEqual(requests[0].raw, "um hello world")
        XCTAssertEqual(requests[0].keepAlive, "0")
        XCTAssertEqual(requests[0].options.contextTokenLimit, 2_048)
        XCTAssertTrue(requests[0].instructions.contains("Known project terms"))
        XCTAssertTrue(requests[0].instructions.contains("CMUX"))
        XCTAssertTrue(requests[0].instructions.contains("Preserve existing sentence-ending punctuation exactly"))
        XCTAssertTrue(requests[0].instructions.contains("Do not fix suspected speech-recognition mistakes"))
    }

    func testStrictPromptStyleRemainsSelectableForEvalComparisons() async throws {
        let client = FakeOllamaPolishClient(cleaned: "Hello world.")
        let engine = OllamaPolishEngine(
            client: client,
            promptStyle: .strict,
            prewarmEnabled: false
        )
        let session = engine.makeSession(knownTerms: [])

        _ = try await session.polish("hello world")

        let instructions = try XCTUnwrap(client.requests.first?.instructions)
        XCTAssertTrue(instructions.contains("Do not fix suspected recognition errors"))
        XCTAssertFalse(instructions.contains("Preserve existing sentence-ending punctuation exactly"))
    }

    func testPrewarmUsesShortKeepAliveThenPolishUnloads() async throws {
        let client = FakeOllamaPolishClient(cleaned: "Ship it.")
        let engine = OllamaPolishEngine(client: client, prewarmKeepAlive: "30s", polishKeepAlive: "0")
        let session = engine.makeSession(knownTerms: [])
        guard let prewarmRequest = await client.waitForRequest(raw: "prewarm") else {
            XCTFail("Expected prewarm request")
            return
        }

        let output = try await session.polish("ship it")

        XCTAssertEqual(output, "Ship it.")
        let requests = client.requests
        let polishRequest = try XCTUnwrap(requests.first { $0.raw == "ship it" })
        XCTAssertEqual(prewarmRequest.keepAlive, "30s")
        XCTAssertEqual(polishRequest.keepAlive, "0")
    }

    func testSlowPrewarmDoesNotConsumeFinalPolishTimeout() async throws {
        let client = FakeOllamaPolishClient(cleaned: "Ship it.", prewarmDelayNanoseconds: 1_000_000_000)
        let engine = OllamaPolishEngine(client: client, prewarmKeepAlive: "30s", polishKeepAlive: "0")
        let session = engine.makeSession(knownTerms: [])

        let output = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await session.polish("ship it")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 200_000_000)
                throw FakeTimeoutError()
            }

            guard let firstResult = try await group.next() else {
                throw FakeTimeoutError()
            }
            group.cancelAll()
            return firstResult
        }

        XCTAssertEqual(output, "Ship it.")
        XCTAssertTrue(client.requests.contains { $0.raw == "ship it" && $0.keepAlive == "0" })
    }

    func testTranscriptPolisherFallsBackSafelyWhenOllamaFails() async {
        let engine = OllamaPolishEngine(
            client: FakeOllamaPolishClient(error: FakeOllamaError()),
            prewarmEnabled: false
        )
        let polisher = TranscriptPolisher(enabled: true, engine: engine)

        let result = await polisher.polish("um ship it")

        XCTAssertEqual(result.text, "ship it")
        XCTAssertEqual(result.outcome, .deterministicCleanup)
        XCTAssertEqual(result.engineOutcome, .failed)
    }

    func testRelaxedPromptStyleAllowsShadowCandidatesBeyondStrictGuard() async throws {
        let client = FakeOllamaPolishClient(cleaned: "Can we review cmux?")
        let engine = OllamaPolishEngine(
            client: client,
            promptStyle: .relaxed,
            prewarmEnabled: false
        )
        let session = engine.makeSession(knownTerms: ["cmux"])

        _ = try await session.polish("can we review see mux question mark")

        let instructions = try XCTUnwrap(client.requests.first?.instructions)
        XCTAssertTrue(instructions.contains("Fix obvious speech-recognition mistakes"))
        XCTAssertTrue(instructions.contains("Convert clearly dictated punctuation and symbols"))
        XCTAssertTrue(instructions.contains("you know"))
        XCTAssertTrue(instructions.contains("cmux"))
        XCTAssertFalse(instructions.contains("Do not fix suspected recognition errors"))
    }

    func testConservativePromptStylePreservesPunctuationAndInitialCase() async throws {
        let client = FakeOllamaPolishClient(cleaned: "Follow up what the territory is.")
        let engine = OllamaPolishEngine(
            client: client,
            promptStyle: .conservative,
            prewarmEnabled: false
        )
        let session = engine.makeSession(knownTerms: ["CMUX"])

        _ = try await session.polish("Follow up what the territory is.")

        let instructions = try XCTUnwrap(client.requests.first?.instructions)
        XCTAssertTrue(instructions.contains("Preserve existing sentence-ending punctuation exactly"))
        XCTAssertTrue(instructions.contains("the cleaned field must end with that same character"))
        XCTAssertTrue(instructions.contains("Do not lowercase the first word of the transcript"))
        XCTAssertTrue(instructions.contains("Do not fix suspected speech-recognition mistakes"))
        XCTAssertTrue(instructions.contains("CMUX"))
        XCTAssertFalse(instructions.contains("Fix obvious speech-recognition mistakes"))
    }

    func testRawCandidateEvalBypassesPolisherButReportsStrictGuardDecision() async {
        let raw = "send the report to dana comma then ping the team"
        let canonicalizedRaw = raw
        let deterministicOutput = TranscriptDeterministicCleaner.clean(canonicalizedRaw)
        let result = await OllamaRawCandidateEvalSupport.evaluate(
            raw: raw,
            canonicalizedRaw: canonicalizedRaw,
            deterministicOutput: deterministicOutput,
            session: RawCandidateFakePolishSession(candidate: "send the report to dana, then ping the team"),
            canonicalize: { $0 }
        )

        XCTAssertEqual(result.candidateOutcome, "success")
        XCTAssertEqual(result.candidate, "send the report to dana, then ping the team")
        XCTAssertEqual(result.canonicalizedCandidate, "send the report to dana, then ping the team")
        XCTAssertEqual(result.strictGuardRetainsContent, false)
        XCTAssertEqual(result.strictGateOutcome, "guardRejected")
        XCTAssertEqual(result.strictGateOutput, raw)
        XCTAssertEqual(result.strictGuardRejectionReason, PolishGuardRejectionReason.contentTokensChanged.rawValue)
    }
}

private struct FakeOllamaError: Error {}
private struct FakeTimeoutError: Error {}

private struct RawCandidateFakePolishSession: PolishSession {
    let candidate: String

    func polish(_ raw: String) async throws -> String {
        candidate
    }
}

private final class FakeOllamaPolishClient: OllamaPolishClient, @unchecked Sendable {
    private let lock = NSLock()
    private let cleaned: String
    private let error: Error?
    private let prewarmDelayNanoseconds: UInt64
    private var storedRequests: [OllamaPolishRequest] = []

    init(cleaned: String = "", error: Error? = nil, prewarmDelayNanoseconds: UInt64 = 0) {
        self.cleaned = cleaned
        self.error = error
        self.prewarmDelayNanoseconds = prewarmDelayNanoseconds
    }

    var requests: [OllamaPolishRequest] {
        lock.withLock { storedRequests }
    }

    func waitForRequest(raw: String) async -> OllamaPolishRequest? {
        for _ in 0..<50 {
            if let request = requests.first(where: { $0.raw == raw }) {
                return request
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }

    func polish(_ request: OllamaPolishRequest) async throws -> OllamaPolishResponse {
        lock.withLock { storedRequests.append(request) }
        if request.raw == "prewarm", prewarmDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: prewarmDelayNanoseconds)
        }
        if let error { throw error }
        return OllamaPolishResponse(cleaned: cleaned)
    }

    func modelIsInstalled(_ model: String) async -> Bool {
        true
    }
}

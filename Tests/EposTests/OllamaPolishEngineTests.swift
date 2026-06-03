import XCTest
@testable import Epos

final class OllamaPolishEngineTests: XCTestCase {
    func testUsesQwen17BByDefaultAndUnloadsAfterPolish() async throws {
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
    }

    func testPrewarmUsesShortKeepAliveThenPolishUnloads() async throws {
        let client = FakeOllamaPolishClient(cleaned: "Ship it.")
        let engine = OllamaPolishEngine(client: client, prewarmKeepAlive: "30s", polishKeepAlive: "0")
        let session = engine.makeSession(knownTerms: [])

        let output = try await session.polish("ship it")

        XCTAssertEqual(output, "Ship it.")
        let requests = client.requests
        XCTAssertEqual(requests.map(\.raw), ["prewarm", "ship it"])
        XCTAssertEqual(requests.map(\.keepAlive), ["30s", "0"])
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
}

private struct FakeOllamaError: Error {}

private final class FakeOllamaPolishClient: OllamaPolishClient, @unchecked Sendable {
    private let lock = NSLock()
    private let cleaned: String
    private let error: Error?
    private var storedRequests: [OllamaPolishRequest] = []

    init(cleaned: String = "", error: Error? = nil) {
        self.cleaned = cleaned
        self.error = error
    }

    var requests: [OllamaPolishRequest] {
        lock.withLock { storedRequests }
    }

    func polish(_ request: OllamaPolishRequest) async throws -> OllamaPolishResponse {
        lock.withLock { storedRequests.append(request) }
        if let error { throw error }
        return OllamaPolishResponse(cleaned: cleaned)
    }

    func modelIsInstalled(_ model: String) async -> Bool {
        true
    }
}

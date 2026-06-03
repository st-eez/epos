import XCTest
@testable import Epos

final class PolishEngineFactoryTests: XCTestCase {
    func testDefaultsToFoundationModelsEngine() {
        let configured = PolishEngineFactory.configuredEngine(environment: [:])

        XCTAssertEqual(configured, .foundationModels)
        XCTAssertTrue(PolishEngineFactory.makeDefault(environment: [:]) is FoundationModelsPolishEngine)
    }

    func testCanSelectDefaultOllamaEngineFromEnvironment() {
        let environment = [
            PolishEngineFactory.engineEnvironmentKey: " ollama ",
        ]

        let configured = PolishEngineFactory.configuredEngine(environment: environment)
        let engine = PolishEngineFactory.makeDefault(environment: environment)

        XCTAssertEqual(configured, .ollama(model: "qwen3:1.7b"))
        XCTAssertEqual((engine as? OllamaPolishEngine)?.model, "qwen3:1.7b")
    }

    func testCanOverrideOllamaModelFromEnvironment() {
        let environment = [
            PolishEngineFactory.engineEnvironmentKey: "ollama",
            PolishEngineFactory.ollamaModelEnvironmentKey: " llama3.2:1b ",
        ]

        let configured = PolishEngineFactory.configuredEngine(environment: environment)
        let engine = PolishEngineFactory.makeDefault(environment: environment)

        XCTAssertEqual(configured, .ollama(model: "llama3.2:1b"))
        XCTAssertEqual((engine as? OllamaPolishEngine)?.model, "llama3.2:1b")
    }
}

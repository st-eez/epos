import Foundation

enum PolishEngineFactory {
    static let engineEnvironmentKey = "EPOS_POLISH_ENGINE"
    static let ollamaModelEnvironmentKey = "EPOS_OLLAMA_MODEL"

    static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any PolishEngine {
        switch configuredEngine(environment: environment) {
        case .foundationModels:
            return FoundationModelsPolishEngine()
        case .ollama(let model):
            return OllamaPolishEngine(model: model)
        }
    }

    static func configuredEngine(
        environment: [String: String]
    ) -> ConfiguredPolishEngine {
        switch normalized(environment[engineEnvironmentKey]) {
        case "ollama":
            return .ollama(model: configuredOllamaModel(environment: environment))
        default:
            return .foundationModels
        }
    }

    private static func configuredOllamaModel(environment: [String: String]) -> String {
        guard let configured = environment[ollamaModelEnvironmentKey] else {
            return OllamaPolishEngine.defaultModel
        }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? OllamaPolishEngine.defaultModel : trimmed
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum ConfiguredPolishEngine: Equatable {
    case foundationModels
    case ollama(model: String)
}

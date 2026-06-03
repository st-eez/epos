import Foundation

/// Local Ollama-backed polish engine. This is intentionally a peer of
/// `FoundationModelsPolishEngine`, not a dependency of it: Epos can try a small
/// local open-source model through the same `TranscriptPolisher` guard/fallback
/// policy without changing insertion behavior.
public struct OllamaPolishEngine: PolishEngine {
    public static let defaultModel = "qwen3:1.7b"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:11434")!

    let model: String
    private let client: any OllamaPolishClient
    private let promptStyle: FoundationModelsPolishPromptStyle
    private let options: OllamaPolishOptions
    private let prewarmEnabled: Bool
    private let prewarmKeepAlive: String
    private let polishKeepAlive: String

    public init(
        model: String = Self.defaultModel,
        baseURL: URL = Self.defaultBaseURL,
        options: OllamaPolishOptions = .default,
        prewarmEnabled: Bool = true,
        prewarmKeepAlive: String = "30s",
        polishKeepAlive: String = "0"
    ) {
        self.init(
            model: model,
            client: OllamaHTTPPolishClient(baseURL: baseURL),
            promptStyle: .exampleFreeStrict,
            options: options,
            prewarmEnabled: prewarmEnabled,
            prewarmKeepAlive: prewarmKeepAlive,
            polishKeepAlive: polishKeepAlive
        )
    }

    init(
        model: String = Self.defaultModel,
        client: any OllamaPolishClient,
        promptStyle: FoundationModelsPolishPromptStyle = .exampleFreeStrict,
        options: OllamaPolishOptions = .default,
        prewarmEnabled: Bool = true,
        prewarmKeepAlive: String = "30s",
        polishKeepAlive: String = "0"
    ) {
        self.model = model
        self.client = client
        self.promptStyle = promptStyle
        self.options = options
        self.prewarmEnabled = prewarmEnabled
        self.prewarmKeepAlive = prewarmKeepAlive
        self.polishKeepAlive = polishKeepAlive
    }

    /// Availability is ultimately an external local process check. Keep this true so
    /// a configured Ollama engine attempts the call and falls through the existing
    /// safe `.engineFailed` policy if the server or model is absent.
    public var isAvailable: Bool { true }

    public func makeSession(knownTerms: [String]) -> any PolishSession {
        let instructions = FoundationModelsPolishEngine.makeInstructions(
            knownTerms: knownTerms,
            promptStyle: promptStyle
        )
        let prewarmTask = prewarmEnabled ? Task {
            _ = try? await client.polish(OllamaPolishRequest(
                model: model,
                instructions: instructions,
                raw: "prewarm",
                options: options,
                keepAlive: prewarmKeepAlive
            ))
        } : nil
        return Session(
            model: model,
            client: client,
            instructions: instructions,
            options: options,
            keepAlive: polishKeepAlive,
            prewarmTask: prewarmTask
        )
    }

    public func isModelInstalled() async -> Bool {
        await client.modelIsInstalled(model)
    }

    private final class Session: PolishSession, @unchecked Sendable {
        private let model: String
        private let client: any OllamaPolishClient
        private let instructions: String
        private let options: OllamaPolishOptions
        private let keepAlive: String
        private let prewarmTask: Task<Void, Never>?

        init(
            model: String,
            client: any OllamaPolishClient,
            instructions: String,
            options: OllamaPolishOptions,
            keepAlive: String,
            prewarmTask: Task<Void, Never>?
        ) {
            self.model = model
            self.client = client
            self.instructions = instructions
            self.options = options
            self.keepAlive = keepAlive
            self.prewarmTask = prewarmTask
        }

        func polish(_ raw: String) async throws -> String {
            await prewarmTask?.value
            let result = try await client.polish(OllamaPolishRequest(
                model: model,
                instructions: instructions,
                raw: raw,
                options: options,
                keepAlive: keepAlive
            ))
            return result.cleaned
        }
    }
}

public struct OllamaPolishOptions: Sendable, Equatable {
    public static let `default` = OllamaPolishOptions()

    public let temperature: Double
    public let contextTokenLimit: Int

    public init(temperature: Double = 0, contextTokenLimit: Int = 2_048) {
        self.temperature = temperature
        self.contextTokenLimit = contextTokenLimit
    }
}

struct OllamaPolishRequest: Sendable, Equatable {
    let model: String
    let instructions: String
    let raw: String
    let options: OllamaPolishOptions
    let keepAlive: String
}

struct OllamaPolishResponse: Sendable, Equatable {
    let cleaned: String
}

protocol OllamaPolishClient: Sendable {
    func polish(_ request: OllamaPolishRequest) async throws -> OllamaPolishResponse
    func modelIsInstalled(_ model: String) async -> Bool
}

import Foundation

final class OllamaHTTPPolishClient: OllamaPolishClient, @unchecked Sendable {
    private let baseURL: URL
    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    func polish(_ request: OllamaPolishRequest) async throws -> OllamaPolishResponse {
        var urlRequest = URLRequest(url: baseURL.appending(path: "api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try encoder.encode(OllamaChatRequest(polishRequest: request))

        let (data, response) = try await urlSession.data(for: urlRequest)
        try Self.validateHTTPResponse(response, data: data)
        let chatResponse = try decoder.decode(OllamaChatResponse.self, from: data)
        let content = chatResponse.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = try decoder.decode(OllamaCleanedTranscript.self, from: Data(content.utf8)).cleaned
        return OllamaPolishResponse(cleaned: cleaned)
    }

    func modelIsInstalled(_ model: String) async -> Bool {
        do {
            var urlRequest = URLRequest(url: baseURL.appending(path: "api/tags"))
            urlRequest.httpMethod = "GET"
            let (data, response) = try await urlSession.data(for: urlRequest)
            try Self.validateHTTPResponse(response, data: data)
            let tags = try decoder.decode(OllamaTagsResponse.self, from: data)
            return tags.models.contains { installed in
                installed.name == model || installed.model == model
            }
        } catch {
            return false
        }
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 400,
               String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("context") {
                throw PolishInputTooLargeError()
            }
            throw OllamaPolishError.httpStatus(httpResponse.statusCode)
        }
    }
}

enum OllamaPolishError: Error, Sendable, Equatable {
    case httpStatus(Int)
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let format = OllamaCleanedTranscriptSchema()
    let options: Options
    let stream = false
    let think = false
    let keepAlive: String

    init(polishRequest: OllamaPolishRequest) {
        model = polishRequest.model
        messages = [
            Message(role: "system", content: polishRequest.instructions),
            Message(role: "user", content: polishRequest.raw),
        ]
        options = Options(polishOptions: polishRequest.options)
        keepAlive = polishRequest.keepAlive
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case format
        case options
        case stream
        case think
        case keepAlive = "keep_alive"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct Options: Encodable {
        let temperature: Double
        let numCtx: Int

        init(polishOptions: OllamaPolishOptions) {
            temperature = polishOptions.temperature
            numCtx = polishOptions.contextTokenLimit
        }

        private enum CodingKeys: String, CodingKey {
            case temperature
            case numCtx = "num_ctx"
        }
    }
}

private struct OllamaCleanedTranscriptSchema: Encodable {
    let type = "object"
    let properties = Properties()
    let required = ["cleaned"]
    let additionalProperties = false

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case additionalProperties = "additionalProperties"
    }

    struct Properties: Encodable {
        let cleaned = StringProperty()
    }

    struct StringProperty: Encodable {
        let type = "string"
        let description = "The cleaned transcript only."
    }
}

private struct OllamaChatResponse: Decodable {
    let message: Message

    struct Message: Decodable {
        let content: String
    }
}

private struct OllamaCleanedTranscript: Decodable {
    let cleaned: String
}

private struct OllamaTagsResponse: Decodable {
    let models: [Model]

    struct Model: Decodable {
        let name: String
        let model: String?
    }
}

import Foundation

public struct LLMRequest: Sendable {
    public var system: String
    public var messages: [AgentMessage]
    public var tools: [AgentToolDefinition]

    public init(system: String, messages: [AgentMessage], tools: [AgentToolDefinition]) {
        self.system = system
        self.messages = messages
        self.tools = tools
    }
}

public enum LLMStopReason: String, Sendable, Equatable {
    case endTurn, toolUse, maxTokens, refusal, pauseTurn, other
}

public struct LLMUsage: Sendable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }
}

public struct LLMResponse: Sendable, Equatable {
    public var message: AgentMessage
    public var stopReason: LLMStopReason
    public var model: String?
    public var usage: LLMUsage
    /// Set when `stopReason == .refusal` and the API said why.
    public var refusalCategory: String?
    /// True when a fallback model served the turn after a policy decline.
    public var servedByFallback: Bool

    public init(message: AgentMessage, stopReason: LLMStopReason, model: String?, usage: LLMUsage, refusalCategory: String? = nil, servedByFallback: Bool = false) {
        self.message = message
        self.stopReason = stopReason
        self.model = model
        self.usage = usage
        self.refusalCategory = refusalCategory
        self.servedByFallback = servedByFallback
    }
}

public enum LLMStreamEvent: Sendable {
    case started(model: String?)
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseStarted(name: String)
    case done(LLMResponse)
}

public enum LLMError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case api(type: String, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No API key is set. Add one in Settings → Claude."
        case .invalidBaseURL(let url): "The endpoint URL is not valid: \(url)"
        case .httpStatus(let code, let body): "The API returned HTTP \(code). \(body)".trimmingCharacters(in: .whitespaces)
        case .api(let type, let message): "\(message) (\(type))"
        case .invalidResponse(let detail): "Unexpected response from the API: \(detail)"
        }
    }
}

/// A model endpoint the agent can talk to.
public protocol LLMProvider: Sendable {
    var displayName: String { get }
    var modelName: String { get }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

/// Which API the agent uses, as saved in settings. The key itself lives in the Keychain.
public struct LLMProviderConfiguration: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case anthropic
        case openAICompatible = "openai-compatible"

        public var displayName: String {
            switch self {
            case .anthropic: "Anthropic (Claude)"
            case .openAICompatible: "OpenAI-compatible endpoint"
            }
        }
    }

    public var kind: Kind
    public var model: String
    /// Only for OpenAI-compatible endpoints, e.g. http://localhost:11434/v1.
    public var baseURL: String
    /// Anthropic `output_config.effort`; nil leaves the model's default.
    public var effort: String?

    public static let defaultAnthropicModel = "claude-opus-5-5"
    public static let anthropicModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    public init(kind: Kind = .anthropic, model: String = LLMProviderConfiguration.defaultAnthropicModel, baseURL: String = "", effort: String? = nil) {
        self.kind = kind
        self.model = model
        self.baseURL = baseURL
        self.effort = effort
    }

    /// Builds the provider. Throws when the configuration is incomplete.
    public func makeProvider(apiKey: String?) throws -> any LLMProvider {
        switch kind {
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey }
            return AnthropicProvider(apiKey: apiKey, model: model, effort: effort)
        case .openAICompatible:
            guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil, url.host != nil else {
                throw LLMError.invalidBaseURL(baseURL)
            }
            return OpenAICompatibleProvider(baseURL: url, apiKey: apiKey ?? "", model: model)
        }
    }
}

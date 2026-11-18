import Foundation
import TepfaCore

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

    /// OpenAI-shaped gateways report `{"error": {"type": …, "message": …}}`; fall back to the raw body.
    static func fromHTTP(status: Int, body: Data) -> LLMError {
        if let json = try? JSONValue.parse(body), let error = json["error"], let message = error["message"]?.stringValue {
            return .api(type: error["type"]?.stringValue ?? "http_\(status)", message: message)
        }
        return .httpStatus(status, String(decoding: body.prefix(300), as: UTF8.self))
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
        case caimex
        case openAICompatible = "openai-compatible"

        public var displayName: String {
            switch self {
            case .anthropic: "Anthropic (Claude)"
            case .caimex: "Caimex"
            case .openAICompatible: "OpenAI-compatible endpoint"
            }
        }

        /// The name the agent gives itself in the system prompt. Anthropic keeps "Claude".
        public var agentName: String {
            switch self {
            case .anthropic: "Claude"
            case .caimex: "Caimex"
            case .openAICompatible: "AI"
            }
        }
    }

    public var kind: Kind
    /// One model per kind, so switching kind gives each one back. Read `model` for the current kind.
    public private(set) var models: [Kind: String]
    /// Only for OpenAI-compatible endpoints, e.g. http://localhost:11434/v1.
    public var baseURL: String
    /// Anthropic `output_config.effort`; nil leaves the model's default.
    public var effort: String?

    /// The fixed Caimex gateway. Nothing the user types can change it.
    public static let caimexBaseURL = URL(string: "https://api.caimex.ai/v1")!

    public static let defaultAnthropicModel = "claude-opus-5-5"
    public static let defaultCaimexModel = "deepseek-v4-flash"
    public static let anthropicModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]

    public static func defaultModel(for kind: Kind) -> String {
        switch kind {
        case .anthropic: defaultAnthropicModel
        case .caimex: defaultCaimexModel
        case .openAICompatible: ""
        }
    }

    /// The model of the current kind; setting it leaves the other kinds alone.
    public var model: String {
        get { models[kind] ?? Self.defaultModel(for: kind) }
        set { models[kind] = newValue }
    }

    public init(kind: Kind = .anthropic, model: String? = nil, baseURL: String = "", effort: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL
        self.effort = effort
        var models = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, Self.defaultModel(for: $0)) })
        models[kind] = model ?? Self.defaultModel(for: kind)
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case kind, model, models, baseURL, effort
    }

    /// Reads 0.3.8 files (one `model` for the saved kind) and the per-kind map this version writes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .anthropic
        self.kind = kind
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        self.effort = try container.decodeIfPresent(String.self, forKey: .effort)

        var models = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, Self.defaultModel(for: $0)) })
        let stored = try container.decodeIfPresent([String: String].self, forKey: .models)
        if let stored {
            for (raw, value) in stored {
                if let key = Kind(rawValue: raw) { models[key] = value }
            }
        }
        // 0.3.8 had no per-kind map: its one model belonged to the saved kind.
        if let legacy = try container.decodeIfPresent(String.self, forKey: .model), stored?[kind.rawValue] == nil {
            models[kind] = legacy
        }
        self.models = models
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }), forKey: .models)
        // Keep the single `model` key so readers that predate the per-kind map see the current model.
        try container.encode(model, forKey: .model)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(effort, forKey: .effort)
    }

    /// Builds the provider. Throws when the configuration is incomplete.
    public func makeProvider(apiKey: String?) throws -> any LLMProvider {
        switch kind {
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey }
            return AnthropicProvider(apiKey: apiKey, model: model, effort: effort)
        case .caimex:
            guard let apiKey, !apiKey.isEmpty else { throw LLMError.missingAPIKey }
            return OpenAICompatibleProvider(baseURL: Self.caimexBaseURL, apiKey: apiKey, model: model, name: Kind.caimex.displayName)
        case .openAICompatible:
            guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil, url.host != nil else {
                throw LLMError.invalidBaseURL(baseURL)
            }
            return OpenAICompatibleProvider(baseURL: url, apiKey: apiKey ?? "", model: model)
        }
    }
}

extension LLMProviderConfiguration.Kind {
    /// The Keychain account holding this kind's key. Each kind has its own, so one provider's key is never
    /// sent to another; `agent.apiKey` stays the Anthropic account and the one 0.3.8 wrote to.
    public var keychainAccount: String {
        switch self {
        case .anthropic: SecretAccount.agentAPIKey
        case .caimex: SecretAccount.caimexAPIKey
        case .openAICompatible: SecretAccount.openAICompatibleAPIKey
        }
    }
}

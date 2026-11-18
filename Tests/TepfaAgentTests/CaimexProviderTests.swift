import Foundation
import Testing
import TepfaCore
@testable import TepfaAgent

@Suite("Caimex provider")
struct CaimexProviderTests {
    private func decode(_ json: String) throws -> LLMProviderConfiguration {
        try JSONDecoder().decode(LLMProviderConfiguration.self, from: Data(json.utf8))
    }

    // MARK: Configuration

    @Test func version038ConfigurationStillDecodes() throws {
        let anthropic = try decode(#"{"kind":"anthropic","model":"claude-opus-5-5","baseURL":"","effort":"high"}"#)
        #expect(anthropic.kind == .anthropic)
        #expect(anthropic.model == "claude-opus-5-5")
        #expect(anthropic.baseURL == "")
        #expect(anthropic.effort == "high")

        let compatible = try decode(#"{"kind":"openai-compatible","model":"llama3.3","baseURL":"http://localhost:11434/v1","effort":null}"#)
        #expect(compatible.kind == .openAICompatible)
        #expect(compatible.model == "llama3.3")
        #expect(compatible.baseURL == "http://localhost:11434/v1")
        #expect(compatible.effort == nil)

        let minimal = try decode(#"{"kind":"anthropic","model":"claude-sonnet-5-5","baseURL":""}"#)
        #expect(minimal.model == "claude-sonnet-5-5")
        #expect(minimal.effort == nil)
    }

    @Test func newConfigurationRoundTrips() throws {
        var configuration = LLMProviderConfiguration(kind: .caimex)
        configuration.model = "caimex/auto"
        configuration.baseURL = "http://localhost:11434/v1"
        configuration.effort = "max"

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(LLMProviderConfiguration.self, from: data)
        #expect(decoded == configuration)
        #expect(decoded.model == "caimex/auto")
        #expect(decoded.models[.anthropic] == LLMProviderConfiguration.defaultAnthropicModel)
    }

    @Test func eachKindKeepsItsOwnModel() {
        var configuration = LLMProviderConfiguration()
        #expect(configuration.model == "claude-opus-5-5")

        configuration.kind = .caimex
        #expect(configuration.model == "deepseek-v4-flash")
        configuration.model = "qwen3.5-122b"

        configuration.kind = .anthropic
        #expect(configuration.model == "claude-opus-5-5")
        configuration.model = "claude-sonnet-5-5"

        configuration.kind = .caimex
        #expect(configuration.model == "qwen3.5-122b")
        configuration.kind = .anthropic
        #expect(configuration.model == "claude-sonnet-5-5")
    }

    @Test func openAICompatibleBaseURLSurvivesSwitchingKind() {
        var configuration = LLMProviderConfiguration(kind: .openAICompatible, model: "llama3.3", baseURL: "http://localhost:11434/v1")
        configuration.kind = .caimex
        #expect(configuration.model == "deepseek-v4-flash")
        #expect(configuration.baseURL == "http://localhost:11434/v1")

        configuration.kind = .anthropic
        configuration.kind = .openAICompatible
        #expect(configuration.model == "llama3.3")
        #expect(configuration.baseURL == "http://localhost:11434/v1")
    }

    // MARK: Provider

    @Test func caimexProviderUsesTheGateway() throws {
        let provider = try LLMProviderConfiguration(kind: .caimex).makeProvider(apiKey: "test-key")
        #expect(provider.displayName == "Caimex")
        #expect(provider.modelName == "deepseek-v4-flash")

        let compatible = try #require(provider as? OpenAICompatibleProvider)
        #expect(compatible.baseURL == LLMProviderConfiguration.caimexBaseURL)
    }

    @Test func caimexNeedsAKey() {
        let configuration = LLMProviderConfiguration(kind: .caimex)
        #expect(throws: LLMError.missingAPIKey) { try configuration.makeProvider(apiKey: nil) }
        #expect(throws: LLMError.missingAPIKey) { try configuration.makeProvider(apiKey: "") }
    }

    @Test func caimexRequestKeepsItsURLHeaderAndModel() throws {
        let configuration = LLMProviderConfiguration(kind: .caimex, model: "ollama/qwen3-vl:8b")
        let provider = try #require(try configuration.makeProvider(apiKey: "test-key") as? OpenAICompatibleProvider)
        let request = provider.urlRequest(for: LLMRequest(system: "sys", messages: [.user("hi")], tools: []))

        #expect(request.url?.absoluteString == "https://api.caimex.ai/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let body = try JSONValue.parse(try #require(request.httpBody))
        #expect(body["model"]?.stringValue == "ollama/qwen3-vl:8b", "the id is sent unchanged")
        #expect(body["stream"]?.boolValue == true)
    }

    @Test func caimexIgnoresATypedBaseURL() throws {
        var configuration = LLMProviderConfiguration(kind: .caimex)
        configuration.baseURL = "https://example.test/v1"
        let provider = try #require(try configuration.makeProvider(apiKey: "test-key") as? OpenAICompatibleProvider)

        #expect(provider.baseURL.host == "api.caimex.ai")
        #expect(provider.urlRequest(for: LLMRequest(system: "", messages: [], tools: [])).url?.host == "api.caimex.ai")
    }

    @Test func eachKindSendsOnlyItsOwnKeyToItsOwnHost() throws {
        let anthropic = try #require(try LLMProviderConfiguration(kind: .anthropic).makeProvider(apiKey: "anthropic-test-key") as? AnthropicProvider)
        #expect(anthropic.apiKey == "anthropic-test-key")
        #expect(anthropic.baseURL.host == "api.anthropic.com")

        var caimexConfiguration = LLMProviderConfiguration(kind: .caimex)
        caimexConfiguration.baseURL = "https://typed.example/v1"
        let caimex = try #require(try caimexConfiguration.makeProvider(apiKey: "caimex-test-key") as? OpenAICompatibleProvider)
        let caimexRequest = caimex.urlRequest(for: LLMRequest(system: "", messages: [], tools: []))
        #expect(caimexRequest.url?.host == "api.caimex.ai")
        #expect(caimexRequest.value(forHTTPHeaderField: "Authorization") == "Bearer caimex-test-key")

        let compatibleConfiguration = LLMProviderConfiguration(kind: .openAICompatible, model: "llama3.3", baseURL: "http://localhost:11434/v1")
        let compatible = try #require(try compatibleConfiguration.makeProvider(apiKey: "openai-test-key") as? OpenAICompatibleProvider)
        let compatibleRequest = compatible.urlRequest(for: LLMRequest(system: "", messages: [], tools: []))
        #expect(compatibleRequest.url?.host == "localhost")
        #expect(compatibleRequest.value(forHTTPHeaderField: "Authorization") == "Bearer openai-test-key")
        #expect(compatibleRequest.url?.host != caimexRequest.url?.host)
    }

    @Test func eachKindHasItsOwnKeychainAccount() {
        #expect(LLMProviderConfiguration.Kind.anthropic.keychainAccount == SecretAccount.agentAPIKey)
        #expect(LLMProviderConfiguration.Kind.openAICompatible.keychainAccount == SecretAccount.openAICompatibleAPIKey)
        #expect(LLMProviderConfiguration.Kind.caimex.keychainAccount == SecretAccount.caimexAPIKey)
        #expect(SecretAccount.agentAPIKey == "agent.apiKey", "0.3.8's account keeps its name and its Anthropic key")
        #expect(SecretAccount.openAICompatibleAPIKey != SecretAccount.agentAPIKey)
        #expect(SecretAccount.caimexAPIKey != SecretAccount.agentAPIKey)
        #expect(SecretAccount.caimexAPIKey != SecretAccount.openAICompatibleAPIKey)
    }

    // MARK: Names and the system prompt

    @Test func kindNamesAndDefaults() {
        #expect(LLMProviderConfiguration.Kind.caimex.rawValue == "caimex")
        #expect(LLMProviderConfiguration.Kind.caimex.displayName == "Caimex")
        #expect(LLMProviderConfiguration.Kind.caimex.agentName == "Caimex")
        #expect(LLMProviderConfiguration.Kind.anthropic.agentName == "Claude")
        #expect(LLMProviderConfiguration.Kind.openAICompatible.agentName == "AI")
        #expect(LLMProviderConfiguration.defaultModel(for: .caimex) == "deepseek-v4-flash")
        #expect(LLMProviderConfiguration.defaultModel(for: .anthropic) == "claude-opus-5-5")
    }

    @Test func systemPromptNamesTheProvider() {
        let claude = AgentSystemPrompt.build(hosts: [], focus: nil)
        #expect(claude.hasPrefix("You are the Claude agent built into Tepfasonic, a macOS SSH client."))

        let caimex = AgentSystemPrompt.build(hosts: [], focus: nil, providerName: LLMProviderConfiguration.Kind.caimex.agentName)
        #expect(caimex.hasPrefix("You are the Caimex agent built into Tepfasonic, a macOS SSH client."))
        #expect(!caimex.contains("Claude agent"))

        let ai = AgentSystemPrompt.build(hosts: [], focus: nil, providerName: LLMProviderConfiguration.Kind.openAICompatible.agentName)
        #expect(ai.hasPrefix("You are the AI agent built into Tepfasonic, a macOS SSH client."))
        #expect(!ai.contains("Claude agent"))

        #expect(claude.contains("Claude agent"))
    }

    @Test func anEmptyModelFallsBackToTheKindDefault() {
        var configuration = LLMProviderConfiguration(kind: .caimex)
        configuration.model = ""
        #expect(configuration.model == LLMProviderConfiguration.defaultCaimexModel)

        configuration.model = "   "
        #expect(configuration.model == LLMProviderConfiguration.defaultCaimexModel)

        configuration.model = "ollama/qwen3-vl:8b"
        #expect(configuration.model == "ollama/qwen3-vl:8b")

        configuration.model = " spaced/id "
        #expect(configuration.model == " spaced/id ", "a real id is returned exactly as stored")
    }
}

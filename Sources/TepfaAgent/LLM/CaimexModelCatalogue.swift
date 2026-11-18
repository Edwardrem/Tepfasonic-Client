import Foundation

/// One model the Caimex gateway can serve to the agent.
public struct CaimexModel: Sendable, Equatable, Identifiable {
    /// The gateway id, sent unchanged: some contain `/` or `:`.
    public let id: String
    public let featured: Bool

    public init(id: String, featured: Bool = false) {
        self.id = id
        self.featured = featured
    }
}

/// Loads the Caimex model list. The gateway answers without a key, so the picker
/// can fill before one is saved.
public struct CaimexModelCatalogue: Sendable {
    /// Today's list is about 174 KB; refuse anything an order of magnitude larger.
    public static let maximumBodyBytes = 4 * 1024 * 1024
    public static let timeout: TimeInterval = 30

    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static var modelsURL: URL {
        LLMProviderConfiguration.caimexBaseURL.appending(path: "models")
    }

    /// Chat-capable, unlocked models: featured first, then by id.
    public func models(apiKey: String? = nil) async throws -> [CaimexModel] {
        var request = URLRequest(url: Self.modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = Self.timeout

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw LLMError.invalidResponse("The model list could not be loaded. \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = try await Self.readBody(from: bytes, limit: 64_000, overflow: "The gateway's error response is too large.")
            throw LLMError.fromHTTP(status: http.statusCode, body: body)
        }

        let body = try await Self.readBody(from: bytes, limit: Self.maximumBodyBytes, overflow: "The model list is too large to read.")
        guard let list = try? JSONDecoder().decode(ModelList.self, from: body) else {
            throw LLMError.invalidResponse("The model list could not be read.")
        }
        return list.data
            .filter { !$0.id.isEmpty && ($0.capabilities?.contains("chat") ?? false) && $0.locked != true }
            .map { CaimexModel(id: $0.id, featured: $0.featured == true) }
            .sorted { lhs, rhs in
                guard lhs.featured == rhs.featured else { return lhs.featured }
                return lhs.id < rhs.id
            }
    }

    /// Reads at most `limit` bytes; a longer body is an error, never a partial list.
    private static func readBody(from bytes: URLSession.AsyncBytes, limit: Int, overflow: String) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            if body.count >= limit { throw LLMError.invalidResponse(overflow) }
            body.append(byte)
        }
        return body
    }

    private struct ModelList: Decodable {
        let data: [Entry]
    }

    /// Only the fields the picker needs; unknown keys and `null` values are fine.
    private struct Entry: Decodable {
        let id: String
        let featured: Bool?
        let locked: Bool?
        let capabilities: [String]?
    }
}

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

/// The ids a Caimex model picker offers: the gateway's order, with the model the user already has kept
/// first when the list no longer carries it. Ids stay opaque and are never trimmed or split.
public struct CaimexModelChoices: Sendable, Equatable {
    public let ids: [String]

    public init(models: [CaimexModel], current: String) {
        var ids = models.map(\.id)
        if !current.isEmpty, !ids.contains(current) {
            ids.insert(current, at: 0)
        }
        self.ids = ids
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

        // Transport errors and cancellation keep their own type; the view decides whether to show them.
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("not an HTTP response")
        }
        guard http.statusCode == 200 else {
            let body = await Self.readAtMost(from: bytes, limit: 64_000)
            throw LLMError.fromHTTP(status: http.statusCode, body: body)
        }

        let body = try await Self.readBody(from: bytes, limit: Self.maximumBodyBytes, overflow: "The model list is too large to read.")
        guard let list = try? JSONDecoder().decode(ModelList.self, from: body) else {
            throw LLMError.invalidResponse("The model list could not be read.")
        }
        return list.data
            .compactMap(\.entry)
            .filter { entry in
                guard !entry.id.isEmpty, !entry.locked else { return false }
                // Known capabilities must include chat; unknown (absent or null) keeps the model.
                guard let capabilities = entry.capabilities else { return true }
                return capabilities.contains("chat")
            }
            .map { CaimexModel(id: $0.id, featured: $0.featured) }
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

    /// Reads at most `limit` bytes and stops, so an oversized error page keeps its status.
    private static func readAtMost(from bytes: URLSession.AsyncBytes, limit: Int) async -> Data {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= limit { break }
            }
        } catch {
            // A broken error body still leaves the status to report.
        }
        return body
    }

    private struct ModelList: Decodable {
        let data: [LossyEntry]
    }

    /// One array element. An entry that cannot be read is skipped instead of failing the whole list.
    private struct LossyEntry: Decodable {
        let entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    /// Only the fields the picker needs; unknown keys and `null` values are fine. A `featured` or `locked`
    /// that is not a Bool counts as false; absent or null capabilities mean "unknown", not "no chat".
    private struct Entry: Decodable {
        let id: String
        let featured: Bool
        let locked: Bool
        let capabilities: [String]?

        private enum CodingKeys: String, CodingKey {
            case id, featured, locked, capabilities
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            featured = (try? container.decode(Bool.self, forKey: .featured)) ?? false
            locked = (try? container.decode(Bool.self, forKey: .locked)) ?? false
            if container.contains(.capabilities) {
                let isNull = (try? container.decodeNil(forKey: .capabilities)) ?? false
                // Absent or null is unknown; a present value that is not a string array cannot support chat.
                capabilities = isNull ? nil : ((try? container.decode([String].self, forKey: .capabilities)) ?? [])
            } else {
                capabilities = nil
            }
        }
    }
}

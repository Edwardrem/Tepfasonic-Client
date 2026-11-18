import Foundation
import Testing
@testable import TepfaAgent

/// Answers every request with one scripted response and records what was sent.
private final class StubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stub = Stub()
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func install(_ stub: Stub) {
        lock.lock()
        defer { lock.unlock() }
        Self.stub = stub
        seen = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.seen.append(request)
        let stub = Self.stub
        Self.lock.unlock()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.caimex.ai/v1/models")!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Caimex model catalogue", .serialized)
struct CaimexModelCatalogueTests {
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func load(_ body: String, status: Int = 200, apiKey: String? = nil) async throws -> [CaimexModel] {
        StubURLProtocol.install(.init(status: status, body: Data(body.utf8), headers: ["Content-Type": "application/json"]))
        return try await CaimexModelCatalogue(session: Self.session()).models(apiKey: apiKey)
    }

    @Test func keepsChatModelsFeaturedFirstThenByID() async throws {
        let body = """
        {"object":"list","data":[
          {"id":"zeta","object":"model","featured":false,"locked":null,"capabilities":["chat"],"pricing":{"input":1},"zdr":true},
          {"id":"alpha","featured":true,"locked":null,"capabilities":["chat"],"kind":"chat"},
          {"id":"beta","featured":true,"capabilities":["embeddings"]},
          {"id":"gamma","featured":null,"locked":null,"capabilities":["chat"],"context_length":null},
          {"id":"delta","featured":false,"locked":true,"capabilities":["chat"]},
          {"id":"epsilon","featured":false,"locked":null,"capabilities":null},
          {"id":"caimex/auto","featured":false,"locked":null,"capabilities":["chat"],"description":"x"},
          {"id":"","featured":false,"locked":null,"capabilities":["chat"]}
        ]}
        """
        let models = try await load(body)
        // A null capabilities value means "unknown", so epsilon is kept; present capabilities without
        // "chat" (beta) and a locked model (delta) are still excluded.
        #expect(models.map(\.id) == ["alpha", "caimex/auto", "epsilon", "gamma", "zeta"])
        #expect(models.first?.featured == true)
        #expect(models.dropFirst().allSatisfy { !$0.featured })
    }

    @Test func requestIsAKeylessGETWithATimeout() async throws {
        _ = try await load(#"{"object":"list","data":[]}"#)

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.caimex.ai/v1/models")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "the list loads before a key is saved")
        #expect(request.timeoutInterval == CaimexModelCatalogue.timeout)
    }

    @Test func sendsTheKeyWhenThereIsOne() async throws {
        _ = try await load(#"{"data":[]}"#, apiKey: "test-key")
        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test func gatewayErrorBodyBecomesAnAPIError() async {
        StubURLProtocol.install(.init(
            status: 401,
            body: Data(#"{"error":{"message":"Invalid authorization header","type":"authentication_error","code":"authentication_error","param":null}}"#.utf8),
            headers: ["Content-Type": "application/json"]
        ))
        do {
            _ = try await CaimexModelCatalogue(session: Self.session()).models(apiKey: "test-key")
            Issue.record("a 401 should throw")
        } catch let error as LLMError {
            #expect(error == .api(type: "authentication_error", message: "Invalid authorization header"))
        } catch {
            Issue.record("expected LLMError, got \(error)")
        }
    }

    @Test func transportErrorReachesTheCallerUnchanged() async {
        StubURLProtocol.install(.init(error: URLError(.notConnectedToInternet)))
        do {
            _ = try await CaimexModelCatalogue(session: Self.session()).models()
            Issue.record("an offline Mac should throw")
        } catch {
            #expect((error as? URLError)?.code == .notConnectedToInternet)
            #expect(!(error is LLMError), "transport errors keep their type for the view")
        }
    }

    @Test func cancellationIsNotTurnedIntoAnLLMError() async {
        StubURLProtocol.install(.init(error: URLError(.cancelled)))
        do {
            _ = try await CaimexModelCatalogue(session: Self.session()).models()
            Issue.record("a cancelled load should throw")
        } catch {
            #expect((error as? URLError)?.code == .cancelled)
            #expect(!(error is LLMError), "cancellation is not a gateway error")
        }
    }

    @Test func oversizedErrorPageStillReportsTheStatus() async {
        StubURLProtocol.install(.init(status: 500, body: Data(repeating: 0x78, count: 100_000)))
        do {
            _ = try await CaimexModelCatalogue(session: Self.session()).models()
            Issue.record("a 500 should throw")
        } catch let error as LLMError {
            guard case .httpStatus(let status, let body) = error else {
                Issue.record("expected httpStatus, got \(error)")
                return
            }
            #expect(status == 500)
            #expect(body == String(repeating: "x", count: 300), "only the bounded body head is quoted")
        } catch {
            Issue.record("expected LLMError, got \(error)")
        }
    }

    @Test func unreadableBodyIsAnInvalidResponse() async {
        StubURLProtocol.install(.init(body: Data("not json".utf8)))
        do {
            _ = try await CaimexModelCatalogue(session: Self.session()).models()
            Issue.record("unreadable JSON should throw")
        } catch let error as LLMError {
            guard case .invalidResponse = error else {
                Issue.record("expected invalidResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("expected LLMError, got \(error)")
        }
    }

    @Test func skipsAnEntryItCannotRead() async throws {
        let body = """
        {"data":[
          {"id":"ok","capabilities":["chat"]},
          {"featured":true},
          {"id":null,"capabilities":["chat"]},
          {"id":42},
          "not an object",
          null,
          {"id":"also-ok","capabilities":["chat"]}
        ]}
        """
        let models = try await load(body)
        #expect(models.map(\.id) == ["also-ok", "ok"])
    }

    @Test func aNonBoolFeaturedOrLockedCountsAsFalse() async throws {
        let body = """
        {"data":[
          {"id":"featured-text","featured":"yes","capabilities":["chat"]},
          {"id":"locked-number","locked":1,"capabilities":["chat"]}
        ]}
        """
        let models = try await load(body)
        #expect(models.map(\.id) == ["featured-text", "locked-number"])
        #expect(models.allSatisfy { !$0.featured })
    }

    @Test func capabilitiesAbsentOrNullKeepsTheModel() async throws {
        let body = """
        {"data":[
          {"id":"absent"},
          {"id":"null","capabilities":null},
          {"id":"embeddings","capabilities":["embeddings"]},
          {"id":"chat","capabilities":["chat"]},
          {"id":"wrong-type","capabilities":"chat"}
        ]}
        """
        let models = try await load(body)
        #expect(models.map(\.id) == ["absent", "chat", "null"])
    }

    @Test func aMissingOrUnreadableDataArrayIsAnError() async {
        for body in [#"{"object":"list"}"#, #"{"data":"nope"}"#] {
            do {
                _ = try await load(body)
                Issue.record("an unreadable list should throw: \(body)")
            } catch let error as LLMError {
                guard case .invalidResponse = error else {
                    Issue.record("expected invalidResponse, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected LLMError, got \(error)")
            }
        }
    }
}

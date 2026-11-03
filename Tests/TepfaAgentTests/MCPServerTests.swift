import Foundation
import Testing
import TepfaCore
@testable import TepfaAgent

@Suite("MCP server")
struct MCPServerTests {
    private struct Client {
        let port: Int
        var token: String
        var extraHeaders: [String: String] = [:]

        func post(_ body: String) async throws -> (Int, JSONValue?, [String: String]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as! HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
            return (http.statusCode, data.isEmpty ? nil : try? JSONValue.parse(data), headers)
        }

        func call(_ id: Int, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue? {
            let body = JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).text
            let (status, json, _) = try await post(body)
            #expect(status == 200)
            return json
        }
    }

    @MainActor
    private func startServer() async throws -> (MCPServer, FakeToolHost, Client) {
        let host = FakeToolHost(hosts: [FakeToolHost.web, FakeToolHost.db])
        let server = MCPServer(toolHost: host, token: "secret-token", serverVersion: "test")
        let port = try await server.start(port: 0)
        return (server, host, Client(port: port, token: "secret-token"))
    }

    @Test func handshakeListAndCall() async throws {
        let (server, host, client) = try await startServer()
        defer { Task { await server.stop() } }

        let (status, initialize, headers) = try await client.post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(status == 200)
        #expect(initialize?["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(initialize?["result"]?["serverInfo"]?["name"]?.stringValue == "Tepfasonic")
        #expect(initialize?["result"]?["capabilities"]?["tools"] != nil)
        #expect(headers["mcp-session-id"] != nil)

        let (notificationStatus, body, _) = try await client.post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notificationStatus == 202)
        #expect(body == nil)

        let tools = try await client.call(2, "tools/list")
        let names = tools?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names == AgentToolName.allCases.map(\.rawValue))
        #expect(tools?["result"]?["tools"]?.arrayValue?.first?["inputSchema"]?["type"]?.stringValue == "object")

        let list = try await client.call(3, "tools/call", ["name": "list_hosts", "arguments": [:]])
        let text = list?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("web-01"))
        #expect(list?["result"]?["isError"]?.boolValue == false)

        let run = try await client.call(4, "tools/call", ["name": "run_command", "arguments": ["host": "db-01", "command": "uptime", "reason": "load"]])
        #expect(run?["result"]?["isError"]?.boolValue == false)
        await MainActor.run {
            #expect(host.executed.map(\.command) == ["uptime"])
            #expect(host.auditRecords.first?.source == .mcp)
            #expect(host.auditRecords.first?.decision == .autoAllowed)
        }

        let blocked = try await client.call(5, "tools/call", ["name": "run_command", "arguments": ["host": "db-01", "command": "reboot", "reason": "r"]])
        #expect(blocked?["result"]?["isError"]?.boolValue == true)

        let unknown = try await client.call(6, "no/such")
        #expect(unknown?["error"]?["code"]?.intValue == -32601)
        let ping = try await client.call(7, "ping")
        #expect(ping?["result"]?.objectValue?.isEmpty == true)
    }

    @Test func batchesAuthAndOrigin() async throws {
        let (server, _, client) = try await startServer()
        defer { Task { await server.stop() } }

        let (batchStatus, batch, _) = try await client.post(#"[{"jsonrpc":"2.0","id":"a","method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":"b","method":"tools/list"}]"#)
        #expect(batchStatus == 200)
        #expect(batch?.arrayValue?.count == 2)
        #expect(batch?.arrayValue?.first?["id"]?.stringValue == "a")

        var wrongToken = client
        wrongToken.token = "nope"
        let (unauthorized, _, _) = try await wrongToken.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(unauthorized == 401)

        var remoteOrigin = client
        remoteOrigin.extraHeaders["Origin"] = "https://evil.example"
        let (forbidden, _, _) = try await remoteOrigin.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(forbidden == 403)

        var localOrigin = client
        localOrigin.extraHeaders["Origin"] = "http://localhost:3000"
        let (ok, _, _) = try await localOrigin.post(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(ok == 200)

        let (bad, parse, _) = try await client.post("{not json")
        #expect(bad == 400)
        #expect(parse?["error"]?["code"]?.intValue == -32700)

        var get = URLRequest(url: URL(string: "http://127.0.0.1:\(client.port)/mcp")!)
        get.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: get)
        #expect((response as? HTTPURLResponse)?.statusCode == 405)
    }
}

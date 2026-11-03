// tepfasonic-mcp: stdio bridge for the Model Context Protocol.
//
// Claude Desktop, Claude Code and other MCP clients launch this tool and talk
// JSON-RPC over stdin/stdout. It forwards every message to the Tepfasonic
// app's local HTTP MCP server (port and token from mcp.json in Application
// Support), launching the app first when it is not running.
import Foundation

let standardError = FileHandle.standardError

func log(_ message: String) {
    standardError.write(Data("[tepfasonic-mcp] \(message)\n".utf8))
}

struct BridgeConfig {
    var port: Int
    var token: String

    static var url: URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["TEPFA_DATA_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Tepfasonic", directoryHint: .isDirectory)
        }
        return base.appending(path: "mcp.json")
    }

    static func load() -> BridgeConfig? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = object["port"] as? Int, let token = object["token"] as? String else { return nil }
        return BridgeConfig(port: port, token: token)
    }
}

/// The app bundle this tool was copied into, when it was.
func appBundleURL() -> URL? {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // Tepfasonic.app/Contents/MacOS/tepfasonic-mcp
    let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return bundle.pathExtension == "app" ? bundle : nil
}

func launchApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let bundle = appBundleURL() {
        process.arguments = ["-g", bundle.path]
    } else {
        process.arguments = ["-g", "-b", "com.tepfasonic.client"]
    }
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        log("could not launch Tepfasonic: \(error.localizedDescription)")
    }
}

let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 900
    configuration.timeoutIntervalForResource = 900
    return URLSession(configuration: configuration)
}()

enum PostResult {
    case response(Data)
    case accepted
    case unreachable(String)
    case failed(Int, Data)
}

func post(_ body: Data, config: BridgeConfig) -> PostResult {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.port)/mcp")!)
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: PostResult = .unreachable("no response")
    session.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result = .unreachable(error.localizedDescription)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            result = .unreachable("not an HTTP response")
            return
        }
        switch http.statusCode {
        case 200: result = .response(data ?? Data())
        case 202, 204: result = .accepted
        default: result = .failed(http.statusCode, data ?? Data())
        }
    }.resume()
    semaphore.wait()
    return result
}

/// Waits for the app's server, launching the app once if needed.
func waitForServer() -> BridgeConfig? {
    var launched = false
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
        if let config = BridgeConfig.load() {
            let ping = Data(#"{"jsonrpc":"2.0","id":"bridge-ping","method":"ping"}"#.utf8)
            if case .response = post(ping, config: config) { return config }
            if case .failed(let status, _) = post(ping, config: config), status == 401 {
                log("the token in mcp.json was rejected; turn the MCP server off and on in Tepfasonic → Settings → Claude")
                return nil
            }
        }
        if !launched {
            log("Tepfasonic is not running; launching it")
            launchApp()
            launched = true
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    log("Tepfasonic's MCP server did not answer. Enable it in Tepfasonic → Settings → Claude.")
    return nil
}

func writeOut(_ data: Data) {
    var line = data
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

func errorResponse(id: Any?, code: Int, message: String) -> Data {
    let object: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

guard var config = waitForServer() else { exit(1) }

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    let body = Data(trimmed.utf8)
    let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"]
    var result = post(body, config: config)
    if case .unreachable = result {
        // The app may have restarted with a new port or token.
        if let fresh = waitForServer() {
            config = fresh
            result = post(body, config: config)
        }
    }
    switch result {
    case .response(let data):
        writeOut(data)
    case .accepted:
        break
    case .unreachable(let detail):
        if id != nil { writeOut(errorResponse(id: id, code: -32000, message: "Tepfasonic is not reachable: \(detail)")) }
    case .failed(let status, let data):
        if id != nil { writeOut(errorResponse(id: id, code: -32000, message: "Tepfasonic answered HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")) }
    }
}

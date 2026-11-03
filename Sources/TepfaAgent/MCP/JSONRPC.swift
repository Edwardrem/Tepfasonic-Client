import Foundation

/// JSON-RPC 2.0 messages as used by the Model Context Protocol.
public enum JSONRPC {
    public struct Request: Sendable, Equatable {
        public var id: JSONValue?
        public var method: String
        public var params: JSONValue?

        public var isNotification: Bool { id == nil }

        public init(id: JSONValue?, method: String, params: JSONValue?) {
            self.id = id
            self.method = method
            self.params = params
        }

        public init?(_ json: JSONValue) {
            guard let method = json["method"]?.stringValue else { return nil }
            var id = json["id"]
            if id?.isNull == true { id = nil }
            self.init(id: id, method: method, params: json["params"])
        }
    }

    public struct ErrorObject: Error, Sendable, Equatable {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603

        public var code: Int
        public var message: String
        public var data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        public var json: JSONValue {
            var object: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
            if let data { object["data"] = data }
            return .object(object)
        }
    }

    public static func response(id: JSONValue?, result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id ?? .null, "result": result]
    }

    public static func response(id: JSONValue?, error: ErrorObject) -> JSONValue {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": error.json]
    }
}

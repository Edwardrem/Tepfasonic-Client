import Foundation

/// The streamed arguments of a tool call and the fallback used when they do not
/// parse. The key and both directions of the conversion live here so a provider
/// and the session can never disagree about the shape.
enum ToolCallInput {
    /// The key that holds the raw text of arguments the model sent as bad JSON.
    static let rawArgumentsKey = "_invalid_json"

    /// The input for a call: the parsed arguments, or a fallback object holding
    /// the raw text when they do not parse (a truncated stream, for example).
    static func decoded(_ arguments: String) -> JSONValue {
        (try? JSONValue.parse(arguments.isEmpty ? "{}" : arguments)) ?? .object([rawArgumentsKey: .string(arguments)])
    }

    /// The raw arguments of a fallback input, or nil when the input parsed.
    static func rawArguments(in input: JSONValue) -> String? {
        guard let object = input.objectValue, object.count == 1 else { return nil }
        return object[rawArgumentsKey]?.stringValue
    }
}

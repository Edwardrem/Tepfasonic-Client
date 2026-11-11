import Foundation

/// Checks the host editor's fields and says what still needs attention, so the
/// Save button is never disabled without the reason on screen.
public struct HostFormValidation: Sendable, Equatable {
    public struct Input: Sendable, Equatable {
        public var hostname: String
        public var username: String
        public var port: String
        public var authMethod: AuthMethod
        /// An identity chosen on the host, or inherited from its group.
        public var hasIdentity: Bool
        public var proxyEnabled: Bool
        public var proxyHost: String
        public var proxyPort: String
        public var jumpHostID: UUID?
        /// The host being edited; nil while creating one.
        public var editedHostID: UUID?

        public init(
            hostname: String,
            username: String,
            port: String,
            authMethod: AuthMethod,
            hasIdentity: Bool,
            proxyEnabled: Bool = false,
            proxyHost: String = "",
            proxyPort: String = "",
            jumpHostID: UUID? = nil,
            editedHostID: UUID? = nil
        ) {
            self.hostname = hostname
            self.username = username
            self.port = port
            self.authMethod = authMethod
            self.hasIdentity = hasIdentity
            self.proxyEnabled = proxyEnabled
            self.proxyHost = proxyHost
            self.proxyPort = proxyPort
            self.jumpHostID = jumpHostID
            self.editedHostID = editedHostID
        }
    }

    /// What stops the host from being saved, in the order the form shows the fields.
    public let problems: [String]

    public var isValid: Bool { problems.isEmpty }

    public init(_ input: Input) {
        var problems: [String] = []
        if input.hostname.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Enter a hostname or IP address.")
        }
        if Self.port(input.port) == nil {
            problems.append("The port must be a number from 1 to 65535.")
        }
        if input.username.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("Enter a username.")
        }
        if input.authMethod == .privateKey, !input.hasIdentity {
            problems.append("Choose an identity, or switch the method to “Ask for a password”.")
        }
        if let jumpHostID = input.jumpHostID, jumpHostID == input.editedHostID {
            problems.append("A host cannot be its own jump host.")
        }
        if input.proxyEnabled {
            if input.proxyHost.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("Enter the proxy host.")
            }
            if Self.port(input.proxyPort) == nil {
                problems.append("The proxy port must be a number from 1 to 65535.")
            }
        }
        self.problems = problems
    }

    /// A TCP port typed into a text field, or nil when it is not one.
    public static func port(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }
}

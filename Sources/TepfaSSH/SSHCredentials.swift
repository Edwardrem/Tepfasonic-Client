import Foundation

public struct SSHCredentials: Sendable {
    public enum Secret: Sendable {
        case password(String)
        case privateKey(SSHPrivateKey)
    }

    public var username: String
    public var secret: Secret

    public init(username: String, secret: Secret) {
        self.username = username
        self.secret = secret
    }
}

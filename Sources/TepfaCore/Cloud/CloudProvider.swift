import Foundation

/// A virtual machine found at a cloud provider, ready to become a host.
public struct CloudInstance: Sendable, Hashable, Identifiable, Codable {
    public var provider: CloudProviderKind
    /// The provider's own id (`i-0abc…`, droplet id, Azure resource id).
    public var instanceID: String
    public var name: String
    public var region: String
    public var publicIP: String?
    public var privateIP: String?
    public var state: String
    public var tags: [String: String]
    /// Image or OS hint, used to guess the login user.
    public var image: String?

    public var id: String { "\(provider.rawValue):\(instanceID)" }

    public init(provider: CloudProviderKind, instanceID: String, name: String, region: String, publicIP: String? = nil, privateIP: String? = nil, state: String, tags: [String: String] = [:], image: String? = nil) {
        self.provider = provider
        self.instanceID = instanceID
        self.name = name
        self.region = region
        self.publicIP = publicIP
        self.privateIP = privateIP
        self.state = state
        self.tags = tags
        self.image = image
    }

    public var isRunning: Bool {
        ["running", "active", "VM running", "PowerState/running"].contains(state) || state.lowercased().hasSuffix("running")
    }

    /// The best guess at the login user from the image name.
    public var suggestedUsername: String {
        if let admin = tags["adminUsername"], !admin.isEmpty { return admin }
        let hint = ((image ?? "") + " " + (tags["Name"] ?? "")).lowercased()
        if hint.contains("ubuntu") { return "ubuntu" }
        if hint.contains("amzn") || hint.contains("amazon") || hint.contains("al2023") { return "ec2-user" }
        if hint.contains("debian") { return "admin" }
        if hint.contains("centos") { return "centos" }
        if hint.contains("fedora") { return "fedora" }
        if hint.contains("rocky") { return "rocky" }
        if hint.contains("alma") { return "almalinux" }
        switch provider {
        case .aws: return "ec2-user"
        case .digitalOcean: return "root"
        case .azure: return "azureuser"
        }
    }

    /// A stable UUID so re-importing the same instance updates the host instead of duplicating it.
    public var stableHostID: UUID {
        UUID.stable("cloud:\(id)")
    }

    /// Converts instances into hosts for the reviewed import. `group` names the
    /// group they land in; `preferPrivateIP` uses the private address when both exist.
    public static func document(from instances: [CloudInstance], groupName: String?, preferPrivateIP: Bool, usernameOverride: String? = nil) -> TepfaDocument {
        var document = TepfaDocument()
        var groupID: UUID?
        if let groupName, !groupName.isEmpty {
            let id = UUID.stable("cloud-group:\(groupName)")
            groupID = id
            document.groups = [.init(id: id, name: groupName)]
        }
        for (index, instance) in instances.enumerated() {
            let address = preferPrivateIP ? (instance.privateIP ?? instance.publicIP) : (instance.publicIP ?? instance.privateIP)
            guard let hostname = address, !hostname.isEmpty else { continue }
            var tags = [instance.provider.displayName.lowercased().replacingOccurrences(of: " ", with: "-"), instance.region]
            for (key, value) in instance.tags.sorted(by: { $0.key < $1.key }) where key != "Name" && !value.isEmpty {
                tags.append("\(key):\(value)")
            }
            var notes = "\(instance.provider.displayName) \(instance.instanceID) in \(instance.region), \(instance.state)."
            if let publicIP = instance.publicIP { notes += " Public IP \(publicIP)." }
            if let privateIP = instance.privateIP { notes += " Private IP \(privateIP)." }
            document.hosts.append(.init(
                id: instance.stableHostID,
                name: instance.name.isEmpty ? instance.instanceID : instance.name,
                hostname: hostname,
                port: 22,
                username: usernameOverride?.isEmpty == false ? usernameOverride! : instance.suggestedUsername,
                authMethod: AuthMethod.privateKey.rawValue,
                tags: tags,
                notes: notes,
                sortOrder: index,
                groupID: groupID))
        }
        return document
    }
}

public enum CloudProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case aws
    case digitalOcean = "digitalocean"
    case azure

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aws: "Amazon EC2"
        case .digitalOcean: "DigitalOcean"
        case .azure: "Microsoft Azure"
        }
    }

    public var credentialHint: String {
        switch self {
        case .aws: "An access key id and secret for an IAM user or role with ec2:DescribeInstances (read-only)."
        case .digitalOcean: "A personal access token with read scope."
        case .azure: "A service principal (tenant id, client id, client secret) with the Reader role on the subscription."
        }
    }

    public var keychainAccount: String { SecretAccount.cloudCredential(rawValue) }
}

/// Credentials as stored (JSON) in the Keychain, one item per provider.
public struct CloudCredentials: Codable, Sendable, Equatable {
    public var provider: CloudProviderKind
    /// AWS access key id, DigitalOcean token, or Azure client id.
    public var keyID: String
    /// AWS secret key or Azure client secret.
    public var secret: String
    /// Azure tenant id.
    public var tenantID: String
    /// Azure subscription id.
    public var subscriptionID: String
    /// AWS regions to list (empty means the common ones).
    public var regions: [String]

    public init(provider: CloudProviderKind, keyID: String = "", secret: String = "", tenantID: String = "", subscriptionID: String = "", regions: [String] = []) {
        self.provider = provider
        self.keyID = keyID
        self.secret = secret
        self.tenantID = tenantID
        self.subscriptionID = subscriptionID
        self.regions = regions
    }

    public var isComplete: Bool {
        switch provider {
        case .aws: !keyID.isEmpty && !secret.isEmpty
        case .digitalOcean: !keyID.isEmpty
        case .azure: !keyID.isEmpty && !secret.isEmpty && !tenantID.isEmpty && !subscriptionID.isEmpty
        }
    }

    public static func load(_ provider: CloudProviderKind, store: SecretStore = .shared) -> CloudCredentials? {
        guard let data = try? store.data(account: provider.keychainAccount) else { return nil }
        return try? JSONDecoder().decode(CloudCredentials.self, from: data)
    }

    public func save(store: SecretStore = .shared) throws {
        try store.set(try JSONEncoder().encode(self), account: provider.keychainAccount, label: "Tepfasonic \(provider.displayName) credentials")
    }

    public static func remove(_ provider: CloudProviderKind, store: SecretStore = .shared) {
        try? store.delete(account: provider.keychainAccount)
    }
}

public enum CloudError: Error, LocalizedError, Sendable, Equatable {
    case missingCredentials(CloudProviderKind)
    case http(Int, String)
    case malformed(String)
    case authentication(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let provider): "No \(provider.displayName) credentials are saved. Add them in Settings → Cloud."
        case .http(let status, let detail): "The provider answered HTTP \(status): \(detail)"
        case .malformed(let detail): "The provider's answer could not be read: \(detail)"
        case .authentication(let detail): "Authentication failed: \(detail)"
        }
    }
}

/// Performs HTTP requests; replaced in tests.
public protocol CloudHTTPClient: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionCloudHTTPClient: CloudHTTPClient {
    public init() {}

    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.malformed("not an HTTP response") }
        return (data, http)
    }
}

/// Lists instances at one provider.
public protocol CloudProvider: Sendable {
    var kind: CloudProviderKind { get }
    func listInstances(credentials: CloudCredentials) async throws -> [CloudInstance]
}

public enum CloudProviders {
    public static func provider(for kind: CloudProviderKind, http: any CloudHTTPClient = URLSessionCloudHTTPClient()) -> any CloudProvider {
        switch kind {
        case .aws: AWSEC2Provider(http: http)
        case .digitalOcean: DigitalOceanProvider(http: http)
        case .azure: AzureProvider(http: http)
        }
    }

    static func errorText(_ data: Data) -> String {
        String(decoding: data.prefix(300), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
    }
}

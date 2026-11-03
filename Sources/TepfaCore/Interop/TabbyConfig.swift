import Foundation

/// SSH profiles from Tabby's `config.yaml`.
public enum TabbyConfig {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/tabby/config.yaml")
    }

    public struct Profile: Equatable, Sendable {
        public var name: String
        public var host: String
        public var port: Int
        public var user: String?
        public var privateKeys: [String]
        public var group: String?

        public init(name: String, host: String, port: Int = 22, user: String? = nil, privateKeys: [String] = [], group: String? = nil) {
            self.name = name
            self.host = host
            self.port = port
            self.user = user
            self.privateKeys = privateKeys
            self.group = group
        }
    }

    public static func profiles(from yaml: String) throws -> [Profile] {
        let root = try MiniYAML.parse(yaml)
        var groupNames: [String: String] = [:]
        for group in root["groups"]?.array ?? [] {
            if let id = group["id"]?.string, let name = group["name"]?.string { groupNames[id] = name }
        }
        var profiles: [Profile] = []
        for profile in root["profiles"]?.array ?? [] {
            guard profile["type"]?.string == "ssh", let options = profile["options"], let host = options["host"]?.string, !host.isEmpty else { continue }
            let name = profile["name"]?.string ?? host
            let groupValue = profile["group"]?.string
            let group = groupValue.flatMap { groupNames[$0] ?? ($0.isEmpty ? nil : $0) }
            profiles.append(Profile(
                name: name,
                host: host,
                port: options["port"]?.int ?? 22,
                user: options["user"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                privateKeys: (options["privateKeys"]?.array ?? []).compactMap(\.string),
                group: group))
        }
        return profiles
    }

    public static func document(from profiles: [Profile], tag: String = "tabby") -> TepfaDocument {
        var document = TepfaDocument()
        var groups: [String: UUID] = [:]
        var identityByPath: [String: UUID] = [:]
        for profile in profiles {
            var groupID: UUID?
            if let group = profile.group, !group.isEmpty {
                if let existing = groups[group] {
                    groupID = existing
                } else {
                    let id = UUID.stable("tabby-group:\(group)")
                    groups[group] = id
                    document.groups.append(.init(id: id, name: group, sortOrder: document.groups.count))
                    groupID = id
                }
            }
            var identityID: UUID?
            if let key = profile.privateKeys.first, !key.isEmpty {
                if let existing = identityByPath[key] {
                    identityID = existing
                } else {
                    let id = UUID.stable("tabby-key:\(key)")
                    identityByPath[key] = id
                    document.identities.append(.init(id: id, name: (key as NSString).lastPathComponent, credentialKind: CredentialKind.keyFile.rawValue, privateKeyPath: key))
                    identityID = id
                }
            }
            document.hosts.append(.init(
                id: UUID.stable("\(tag):\(profile.name)@\(profile.host):\(profile.port)"),
                name: profile.name,
                hostname: profile.host,
                port: profile.port,
                username: profile.user ?? NSUserName(),
                authMethod: identityID == nil ? AuthMethod.password.rawValue : AuthMethod.privateKey.rawValue,
                tags: [tag],
                sortOrder: document.hosts.count,
                groupID: groupID,
                identityID: identityID))
        }
        return document
    }
}

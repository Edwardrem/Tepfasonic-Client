import Foundation

/// One `Host` block from an OpenSSH client config.
public struct SSHConfigHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var port: Int?
    public var user: String?
    public var identityFiles: [String] = []
    public var proxyJump: String?

    public init(alias: String, hostName: String? = nil, port: Int? = nil, user: String? = nil, identityFiles: [String] = [], proxyJump: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.port = port
        self.user = user
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
    }

    /// True for `Host *`, `Host *.example.com`, negations and the like.
    public var isPattern: Bool {
        alias.contains("*") || alias.contains("?") || alias.hasPrefix("!")
    }
}

/// Reads and writes `~/.ssh/config`.
public enum SSHConfigFile {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")
    }

    public static let beginMarker = "# BEGIN Tepfasonic hosts (managed by Tepfasonic; edits inside this block are overwritten)"
    public static let endMarker = "# END Tepfasonic hosts"

    /// Parses `Host` blocks. `Match` blocks are skipped. `Include` lines are
    /// expanded through `include`, which returns the text for a path (relative
    /// paths resolve against `~/.ssh`), to a depth of 8.
    public static func parse(_ text: String, include: ((String) -> String?)? = nil, depth: Int = 0) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [SSHConfigHost] = []
        var skipping = false

        func flush() {
            hosts.append(contentsOf: current)
            current = []
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#"), !line.contains("\"") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (keyword, value) = splitKeyword(line)
            switch keyword {
            case "host":
                flush()
                skipping = false
                current = splitArguments(value).map { SSHConfigHost(alias: $0) }
            case "match":
                flush()
                skipping = true
            case "include":
                guard let include, depth < 8 else { continue }
                flush()
                for path in splitArguments(value) {
                    if let included = include(path) {
                        hosts.append(contentsOf: parse(included, include: include, depth: depth + 1))
                    }
                }
            default:
                guard !skipping, !current.isEmpty else { continue }
                for index in current.indices {
                    apply(keyword: keyword, value: value, to: &current[index])
                }
            }
        }
        flush()
        return hosts
    }

    /// Resolves `Include` paths the way ssh does (relative to `~/.ssh`), with `~` and simple `*` globs.
    public static func defaultIncludeResolver(sshDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")) -> (String) -> String? {
        { path in
            var expanded = (path as NSString).expandingTildeInPath
            if !expanded.hasPrefix("/") { expanded = sshDirectory.appending(path: expanded).path }
            var files: [String] = []
            if expanded.contains("*") {
                let directory = (expanded as NSString).deletingLastPathComponent
                let pattern = (expanded as NSString).lastPathComponent
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                for name in names.sorted() where globMatches(pattern, name) {
                    files.append((directory as NSString).appendingPathComponent(name))
                }
            } else {
                files = [expanded]
            }
            let texts = files.compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
    }

    static func globMatches(_ pattern: String, _ name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == name }
        var remainder = Substring(name)
        for (index, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if index == 0 {
                guard remainder.hasPrefix(part) else { return false }
                remainder = remainder.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return remainder.hasSuffix(part)
            } else {
                guard let range = remainder.range(of: part) else { return false }
                remainder = remainder[range.upperBound...]
            }
        }
        return true
    }

    private static func splitKeyword(_ line: String) -> (String, String) {
        var keyword = ""
        var rest = Substring(line)
        if let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) {
            keyword = String(line[..<separator])
            rest = line[separator...].drop { $0 == " " || $0 == "\t" || $0 == "=" }
        } else {
            keyword = line
            rest = ""
        }
        return (keyword.lowercased(), String(rest))
    }

    /// Splits a value on whitespace, honouring double quotes.
    static func splitArguments(_ value: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func apply(keyword: String, value: String, to host: inout SSHConfigHost) {
        let arguments = splitArguments(value)
        switch keyword {
        case "hostname": host.hostName = host.hostName ?? arguments.first
        case "port": host.port = host.port ?? arguments.first.flatMap { Int($0) }
        case "user": host.user = host.user ?? arguments.first
        case "identityfile": host.identityFiles.append(contentsOf: arguments)
        case "proxyjump": host.proxyJump = host.proxyJump ?? arguments.first
        default: break
        }
    }

    // MARK: - Import

    /// Hosts and key-file identities for a document. Identities are shared per
    /// key path; `existingIdentityIDs` maps paths the app already knows.
    public static func document(from configHosts: [SSHConfigHost], existingIdentityIDs: [String: UUID] = [:], tag: String = "ssh-config") -> TepfaDocument {
        var document = TepfaDocument()
        var identityByPath: [String: UUID] = existingIdentityIDs
        for config in configHosts where !config.isPattern {
            let hostname = config.hostName ?? config.alias
            var identityID: UUID?
            if let keyPath = config.identityFiles.first {
                let normalized = keyPath.hasPrefix("~") || keyPath.hasPrefix("/") ? keyPath : "~/.ssh/" + keyPath
                if let existing = identityByPath[normalized] {
                    identityID = existing
                } else {
                    let id = UUID.stable("ssh-config-key:\(normalized)")
                    identityByPath[normalized] = id
                    document.identities.append(.init(id: id, name: (normalized as NSString).lastPathComponent, credentialKind: CredentialKind.keyFile.rawValue, privateKeyPath: normalized))
                    identityID = id
                }
            }
            var notes = ""
            if let jump = config.proxyJump { notes = "ProxyJump \(jump)" }
            document.hosts.append(.init(
                id: UUID.stable("ssh-config:\(config.alias)"),
                name: config.alias,
                hostname: hostname,
                port: config.port ?? 22,
                username: config.user ?? NSUserName(),
                authMethod: identityID == nil ? AuthMethod.password.rawValue : AuthMethod.privateKey.rawValue,
                tags: [tag],
                notes: notes,
                sortOrder: document.hosts.count,
                identityID: identityID))
        }
        return document
    }

    // MARK: - Export

    public struct ExportableHost: Equatable, Sendable {
        public var alias: String
        public var hostname: String
        public var port: Int
        public var user: String
        public var identityFile: String?

        public init(alias: String, hostname: String, port: Int = 22, user: String, identityFile: String? = nil) {
            self.alias = alias
            self.hostname = hostname
            self.port = port
            self.user = user
            self.identityFile = identityFile
        }
    }

    /// A `Host` alias ssh accepts: no whitespace, unique within `taken`.
    public static func alias(for name: String, taken: Set<String>) -> String {
        var base = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" ? $0 : "-" }.map(String.init).joined()
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "host" }
        var candidate = base
        var counter = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    public static func managedBlock(for hosts: [ExportableHost]) -> String {
        var lines = [beginMarker]
        for host in hosts {
            lines.append("Host \(host.alias)")
            lines.append("    HostName \(host.hostname)")
            if host.port != 22 { lines.append("    Port \(host.port)") }
            lines.append("    User \(host.user)")
            if let file = host.identityFile {
                lines.append("    IdentityFile \(file.contains(" ") ? "\"\(file)\"" : file)")
                lines.append("    IdentitiesOnly yes")
            }
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Replaces (or appends) the managed block in an existing config, leaving everything else untouched.
    public static func replacingManagedBlock(in text: String, with block: String) -> String {
        if let begin = text.range(of: beginMarker), let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) {
            var endIndex = end.upperBound
            if endIndex < text.endIndex, text[endIndex] == "\n" { endIndex = text.index(after: endIndex) }
            return String(text[..<begin.lowerBound]) + block + String(text[endIndex...])
        }
        if text.isEmpty { return block }
        return text.hasSuffix("\n") ? text + "\n" + block : text + "\n\n" + block
    }
}

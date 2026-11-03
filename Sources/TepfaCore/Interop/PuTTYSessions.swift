import Foundation

/// Saved PuTTY sessions: a Windows `.reg` export of
/// `HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions`, or the per-session
/// files in `~/.putty/sessions/` on macOS and Linux.
public enum PuTTYSessions {
    public struct Session: Equatable, Sendable {
        public var name: String
        public var hostName: String
        public var port: Int
        public var userName: String?
        public var publicKeyFile: String?
        public var proto: String?

        public init(name: String, hostName: String, port: Int = 22, userName: String? = nil, publicKeyFile: String? = nil, proto: String? = nil) {
            self.name = name
            self.hostName = hostName
            self.port = port
            self.userName = userName
            self.publicKeyFile = publicKeyFile
            self.proto = proto
        }
    }

    /// Decodes a `.reg` file (regedit writes UTF-16 LE with a BOM; older tools write ANSI/UTF-8).
    public static func decodeRegistryExport(_ data: Data) -> String? {
        if data.count >= 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    public static func parseRegistryExport(_ text: String) -> [Session] {
        var sessions: [Session] = []
        var current: (name: String, values: [String: String])?

        func flush() {
            if let current, let session = session(named: current.name, values: current.values) {
                sessions.append(session)
            }
            current = nil
        }

        var continuation = ""
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if !continuation.isEmpty {
                line = continuation + line
                continuation = ""
            }
            if line.hasSuffix("\\") {
                continuation = String(line.dropLast())
                continue
            }
            if line.hasPrefix("[") {
                flush()
                let path = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let components = path.split(separator: "\\")
                if let sessionsIndex = components.firstIndex(where: { $0.caseInsensitiveCompare("Sessions") == .orderedSame }),
                   sessionsIndex + 1 < components.count, path.range(of: "PuTTY", options: .caseInsensitive) != nil {
                    current = (name: decodeName(String(components[(sessionsIndex + 1)...].joined(separator: "\\"))), values: [:])
                }
                continue
            }
            guard current != nil, line.hasPrefix("\"") else { continue }
            guard let closing = line.dropFirst().firstIndex(of: "\""), line.index(after: closing) < line.endIndex else { continue }
            let key = String(line[line.index(after: line.startIndex)..<closing])
            let rest = line[line.index(after: closing)...].drop { $0 == "=" || $0 == " " }
            if rest.hasPrefix("\"") {
                let inner = rest.dropFirst().dropLast(rest.hasSuffix("\"") ? 1 : 0)
                current?.values[key] = inner.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\\"", with: "\"")
            } else if rest.lowercased().hasPrefix("dword:") {
                let hex = rest.dropFirst("dword:".count)
                current?.values[key] = Int(hex, radix: 16).map(String.init) ?? ""
            }
        }
        flush()
        return sessions
    }

    /// Parses one `~/.putty/sessions/<name>` file.
    public static func parseSessionFile(named fileName: String, contents: String) -> Session? {
        var values: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return session(named: decodeName(fileName), values: values)
    }

    /// Parses every file in a sessions directory.
    public static func parseSessionDirectory(_ url: URL) -> [Session] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.sorted().compactMap { name in
            guard name != "Default%20Settings", let contents = try? String(contentsOf: url.appending(path: name), encoding: .utf8) else { return nil }
            return parseSessionFile(named: name, contents: contents)
        }
    }

    private static func session(named name: String, values: [String: String]) -> Session? {
        guard let hostName = values["HostName"]?.trimmingCharacters(in: .whitespaces), !hostName.isEmpty else { return nil }
        guard name != "Default Settings" else { return nil }
        var host = hostName
        var user = values["UserName"].flatMap { $0.isEmpty ? nil : $0 }
        if let at = host.lastIndex(of: "@") {
            user = user ?? String(host[..<at])
            host = String(host[host.index(after: at)...])
        }
        return Session(
            name: name,
            hostName: host,
            port: values["PortNumber"].flatMap { Int($0) } ?? 22,
            userName: user,
            publicKeyFile: values["PublicKeyFile"].flatMap { $0.isEmpty ? nil : $0 },
            proto: values["Protocol"])
    }

    /// PuTTY percent-encodes session names (`My%20Server`).
    static func decodeName(_ name: String) -> String {
        name.removingPercentEncoding ?? name
    }

    public static func document(from sessions: [Session], tag: String = "putty") -> TepfaDocument {
        var document = TepfaDocument()
        var identityByPath: [String: UUID] = [:]
        for session in sessions where (session.proto ?? "ssh").lowercased() == "ssh" {
            var identityID: UUID?
            var notes = ""
            if let keyFile = session.publicKeyFile {
                let isWindowsPath = keyFile.count > 1 && keyFile[keyFile.index(after: keyFile.startIndex)] == ":"
                if isWindowsPath || !FileManager.default.fileExists(atPath: (keyFile as NSString).expandingTildeInPath) {
                    notes = "PuTTY key file: \(keyFile)"
                } else if let existing = identityByPath[keyFile] {
                    identityID = existing
                } else {
                    let id = UUID.stable("putty-key:\(keyFile)")
                    identityByPath[keyFile] = id
                    document.identities.append(.init(id: id, name: (keyFile as NSString).lastPathComponent, credentialKind: CredentialKind.keyFile.rawValue, privateKeyPath: keyFile))
                    identityID = id
                }
            }
            document.hosts.append(.init(
                id: UUID.stable("\(tag):\(session.name)"),
                name: session.name,
                hostname: session.hostName,
                port: session.port,
                username: session.userName ?? NSUserName(),
                authMethod: identityID == nil ? AuthMethod.password.rawValue : AuthMethod.privateKey.rawValue,
                tags: [tag],
                notes: notes,
                sortOrder: document.hosts.count,
                identityID: identityID))
        }
        return document
    }
}

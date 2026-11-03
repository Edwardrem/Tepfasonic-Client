import AppKit
import SwiftData
import TepfaCore
import UniformTypeIdentifiers

/// What the File menu asked for; `ContentView` carries it out with its model context.
enum ImportRequest: Equatable, Identifiable {
    case chooseFile
    case file(URL)
    case sshConfig
    case termius
    case putty
    case tabby
    /// A terminal colour scheme in any supported format (chosen with a panel).
    case themeFile
    case themeFileAt(URL)

    var id: String {
        switch self {
        case .chooseFile: "chooseFile"
        case .file(let url): "file:\(url.path)"
        case .sshConfig: "sshConfig"
        case .termius: "termius"
        case .putty: "putty"
        case .tabby: "tabby"
        case .themeFile: "themeFile"
        case .themeFileAt(let url): "theme:\(url.path)"
        }
    }
}

/// Builds import flows from other programs' configuration.
@MainActor
enum InteropImport {
    enum Failure: LocalizedError {
        case nothingFound(String)
        case missingFile(String)

        var errorDescription: String? {
            switch self {
            case .nothingFound(let what): "No \(what) were found."
            case .missingFile(let path): "\(path) does not exist."
            }
        }
    }

    /// Returns nil when the user cancelled a panel.
    static func flow(for request: ImportRequest, context: ModelContext) async -> ImportFlow? {
        switch request {
        case .chooseFile:
            guard let url = choose(title: "Import Tepfasonic data", types: [.tepfa, .json], directories: false) else { return nil }
            return await ImportFlow.open(url: url, context: context)
        case .file(let url):
            return await ImportFlow.open(url: url, context: context)
        case .sshConfig:
            return await documentFlow(source: "~/.ssh/config", context: context) {
                let url = SSHConfigFile.defaultURL
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.missingFile("~/.ssh/config") }
                let hosts = SSHConfigFile.parse(text, include: SSHConfigFile.defaultIncludeResolver()).filter { !$0.isPattern }
                guard !hosts.isEmpty else { throw Failure.nothingFound("Host entries") }
                return SSHConfigFile.document(from: hosts, existingIdentityIDs: existingKeyFileIdentities(context))
            }
        case .termius:
            guard let url = choose(title: "Import a Termius CSV export", types: [.commaSeparatedText, .plainText], directories: false) else { return nil }
            return await documentFlow(source: url.lastPathComponent, context: context) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let document = try TermiusCSV.document(from: text)
                guard !document.hosts.isEmpty else { throw Failure.nothingFound("hosts") }
                return document
            }
        case .putty:
            let sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".putty/sessions")
            guard let url = choose(title: "Import PuTTY sessions (a .reg export or the sessions folder)", types: nil, directories: true,
                                   startingAt: FileManager.default.fileExists(atPath: sessionsDirectory.path) ? sessionsDirectory : nil) else { return nil }
            return await documentFlow(source: url.lastPathComponent, context: context) {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let sessions: [PuTTYSessions.Session]
                if isDirectory.boolValue {
                    sessions = PuTTYSessions.parseSessionDirectory(url)
                } else {
                    let data = try Data(contentsOf: url)
                    guard let text = PuTTYSessions.decodeRegistryExport(data) else { throw Failure.nothingFound("sessions") }
                    sessions = text.contains("[HKEY") ? PuTTYSessions.parseRegistryExport(text) : [PuTTYSessions.parseSessionFile(named: url.lastPathComponent, contents: text)].compactMap { $0 }
                }
                guard !sessions.isEmpty else { throw Failure.nothingFound("PuTTY sessions") }
                return PuTTYSessions.document(from: sessions)
            }
        case .themeFile:
            guard let url = choose(title: "Import a terminal colour scheme (iTerm2, Windows Terminal, VS Code, Alacritty, Ghostty or Tepfasonic JSON)", types: nil, directories: false) else { return nil }
            return await themeFlow(url: url, context: context)
        case .themeFileAt(let url):
            return await themeFlow(url: url, context: context)
        case .tabby:
            var url = TabbyConfig.defaultURL
            if !FileManager.default.fileExists(atPath: url.path) {
                guard let chosen = choose(title: "Import Tabby's config.yaml", types: [.yaml, .plainText], directories: false) else { return nil }
                url = chosen
            }
            return await documentFlow(source: "Tabby", context: context) {
                let text = try String(contentsOf: url, encoding: .utf8)
                let profiles = try TabbyConfig.profiles(from: text)
                guard !profiles.isEmpty else { throw Failure.nothingFound("SSH profiles") }
                return TabbyConfig.document(from: profiles)
            }
        }
    }

    /// A theme file becomes a one-record document so it goes through the same review.
    private static func themeFlow(url: URL, context: ModelContext) async -> ImportFlow {
        await documentFlow(source: url.lastPathComponent, context: context) {
            let data = try Data(contentsOf: url)
            let theme = try ThemeImporter.theme(from: data, fileName: url.lastPathComponent)
            var document = TepfaDocument()
            let id = UUID(uuidString: theme.id) ?? UUID()
            document.themes = [.init(id: id, name: theme.name, source: ThemeImporter.sourceName(for: url.lastPathComponent), scheme: theme)]
            return document
        }
    }

    private static func documentFlow(source: String, context: ModelContext, build: () throws -> TepfaDocument) async -> ImportFlow {
        do {
            return await ImportFlow.open(document: try build(), source: source, context: context)
        } catch {
            let flow = await ImportFlow.open(document: TepfaDocument(), source: source, context: context)
            flow.fail(error.localizedDescription)
            return flow
        }
    }

    /// Key-file identities already known, by normalised path, so imports reuse them.
    static func existingKeyFileIdentities(_ context: ModelContext) -> [String: UUID] {
        let identities = (try? context.fetch(FetchDescriptor<Identity>())) ?? []
        var out: [String: UUID] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for identity in identities where identity.credentialKind == .keyFile && !identity.privateKeyPath.isEmpty {
            let path = identity.privateKeyPath
            out[path] = identity.uuid
            let expanded = (path as NSString).expandingTildeInPath
            out[expanded] = identity.uuid
            if expanded.hasPrefix(home + "/") { out["~" + expanded.dropFirst(home.count)] = identity.uuid }
        }
        return out
    }

    private static func choose(title: String, types: [UTType]?, directories: Bool, startingAt: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let types { panel.allowedContentTypes = types }
        if let startingAt { panel.directoryURL = startingAt }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

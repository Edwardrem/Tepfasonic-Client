import Foundation

/// Trust-on-first-use store of host keys, persisted as JSON.
///
/// Kept separate from SwiftData because it is consulted from the SSH transport
/// off the main actor, and because it is exported as part of a `.tepfa` file.
public actor KnownHostsStore {
    public static let shared = KnownHostsStore(url: AppPaths.knownHostsURL)

    private let url: URL
    private var entries: [String: KnownHostEntry] = [:]
    private var loaded = false

    public init(url: URL) {
        self.url = url
    }

    public func allEntries() -> [KnownHostEntry] {
        loadIfNeeded()
        return entries.values.sorted { ($0.host, $0.port, $0.keyType) < ($1.host, $1.port, $1.keyType) }
    }

    public func verdict(host: String, port: Int, keyType: String, publicKey: String) -> HostKeyVerdict {
        loadIfNeeded()
        let normalized = HostKeyFingerprint.normalize(openSSHPublicKey: publicKey) ?? publicKey
        guard let existing = entries[KnownHostEntry.key(host: host, port: port, keyType: keyType)] else {
            return .unknown
        }
        return existing.publicKey == normalized ? .known : .changed(previous: existing)
    }

    @discardableResult
    public func remember(host: String, port: Int, keyType: String, publicKey: String, fingerprintSHA256: String) throws -> KnownHostEntry {
        loadIfNeeded()
        let normalized = HostKeyFingerprint.normalize(openSSHPublicKey: publicKey) ?? publicKey
        let entry = KnownHostEntry(host: host, port: port, keyType: keyType, publicKey: normalized, fingerprintSHA256: fingerprintSHA256)
        entries[entry.id] = entry
        try save()
        return entry
    }

    /// Forget every key type saved for this host and port.
    public func forget(host: String, port: Int) throws {
        loadIfNeeded()
        let prefix = "\(host.lowercased()):\(port):"
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        try save()
    }

    public func forget(host: String, port: Int, keyType: String) throws {
        loadIfNeeded()
        entries[KnownHostEntry.key(host: host, port: port, keyType: keyType)] = nil
        try save()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([KnownHostEntry].self, from: data) else { return }
        entries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(allEntries())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

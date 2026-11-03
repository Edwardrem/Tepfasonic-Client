import Foundation

/// Keeps the last few exports and pre-import snapshots in Application Support
/// so a bad import can be undone by importing the backup.
public enum Backups {
    public static let keep = 10

    public static var directory: URL { AppPaths.backupsDirectory }

    /// Copies `data` into the backups folder under a timestamped name and prunes old ones.
    @discardableResult
    public static func store(_ data: Data, label: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: .now)
        let safeLabel = label.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let url = directory.appending(path: "\(stamp)-\(String(safeLabel)).\(TepfaFile.fileExtension)")
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        prune()
        return url
    }

    /// Backup files, newest first.
    public static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls
            .filter { $0.pathExtension == TepfaFile.fileExtension }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
    }

    public static func prune() {
        for url in list().dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

import Foundation

/// Well-known on-disk locations. Everything the app stores lives under
/// `~/Library/Application Support/Tepfasonic/`.
public enum AppPaths {
    public static let appName = "Tepfasonic"

    /// Set `TEPFA_DATA_DIR` to run against a scratch copy of everything (QA, screenshots).
    public static let dataDirectoryOverride = ProcessInfo.processInfo.environment["TEPFA_DATA_DIR"]

    /// `~/Library/Application Support/Tepfasonic/`, created on first access.
    public static var applicationSupport: URL {
        let directory: URL
        if let dataDirectoryOverride, !dataDirectoryOverride.isEmpty {
            directory = URL(fileURLWithPath: dataDirectoryOverride, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            directory = base.appending(path: appName, directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// SwiftData store holding hosts, groups and identities.
    public static var databaseURL: URL {
        applicationSupport.appending(path: "Tepfasonic.store")
    }

    /// JSON file of trusted host-key fingerprints (see `KnownHostsStore`).
    public static var knownHostsURL: URL {
        applicationSupport.appending(path: "known_hosts.json")
    }

    /// Automatic `.tepfa` backups kept before an import (build step 6).
    public static var backupsDirectory: URL {
        applicationSupport.appending(path: "backups", directoryHint: .isDirectory)
    }
}

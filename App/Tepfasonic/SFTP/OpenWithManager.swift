import AppKit
import Foundation
import Observation
import TepfaSSH

/// "Open with" for remote files: downloads to a scratch folder, opens the
/// file in an app, watches it, and uploads it again whenever it is saved.
@MainActor
@Observable
final class OpenWithManager {
    final class Watch {
        let hostID: UUID
        let remotePath: String
        let localURL: URL
        var source: DispatchSourceFileSystemObject?
        var descriptor: Int32 = -1
        var uploadTask: Task<Void, Never>?
        var lastUpload = Date.distantPast

        init(hostID: UUID, remotePath: String, localURL: URL) {
            self.hostID = hostID
            self.remotePath = remotePath
            self.localURL = localURL
        }
    }

    private let connections: RemoteConnections
    private(set) var watches: [URL: Watch] = [:]
    private(set) var message: String?

    init(connections: RemoteConnections) {
        self.connections = connections
    }

    private var scratchDirectory: URL {
        AppPathsBridge.openWithDirectory
    }

    /// Downloads the file and opens it, with the default app or one the user picks.
    func open(hostID: UUID, remotePath: String, chooseApplication: Bool) async {
        let hostName = connections.hostName(hostID)
        let localURL = scratchDirectory
            .appending(path: hostID.uuidString)
            .appending(path: remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        do {
            let client = try await connections.client(for: hostID)
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await client.download(remotePath, to: localURL)
            message = "Opened \(SFTP.baseName(remotePath)) from \(hostName); changes are uploaded when you save."
        } catch {
            message = "Could not open \(remotePath): \(error.localizedDescription)"
            return
        }
        startWatching(hostID: hostID, remotePath: remotePath, localURL: localURL)
        if chooseApplication {
            let panel = NSOpenPanel()
            panel.title = "Open \(SFTP.baseName(remotePath)) with"
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let app = panel.url else { return }
            NSWorkspace.shared.open([localURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.open(localURL)
        }
    }

    private func startWatching(hostID: UUID, remotePath: String, localURL: URL) {
        if let existing = watches[localURL] {
            existing.source?.cancel()
        }
        let watch = Watch(hostID: hostID, remotePath: remotePath, localURL: localURL)
        watches[localURL] = watch
        arm(watch)
    }

    /// Editors replace files on save, so the descriptor is re-opened after each event.
    private func arm(_ watch: Watch) {
        let descriptor = Darwin.open(watch.localURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watch.descriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
        source.setEventHandler { [weak self, weak watch] in
            MainActor.assumeIsolated {
                guard let self, let watch else { return }
                let flags = source.data
                source.cancel()
                if flags.contains(.delete) || flags.contains(.rename) {
                    // Atomic save: the file was replaced. Watch the new one after a short delay.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak watch] in
                        MainActor.assumeIsolated {
                            guard let self, let watch, FileManager.default.fileExists(atPath: watch.localURL.path) else { return }
                            self.arm(watch)
                            self.scheduleUpload(watch)
                        }
                    }
                } else {
                    self.arm(watch)
                    self.scheduleUpload(watch)
                }
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        watch.source = source
        source.resume()
    }

    private func scheduleUpload(_ watch: Watch) {
        watch.uploadTask?.cancel()
        watch.uploadTask = Task { [weak self, weak watch] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, let watch else { return }
            await upload(watch)
        }
    }

    private func upload(_ watch: Watch) async {
        do {
            let client = try await connections.client(for: watch.hostID)
            try await client.upload(watch.localURL, to: watch.remotePath)
            watch.lastUpload = .now
            message = "Uploaded \(SFTP.baseName(watch.remotePath)) to \(connections.hostName(watch.hostID)) at \(Date.now.formatted(date: .omitted, time: .shortened))."
        } catch {
            message = "Could not upload \(SFTP.baseName(watch.remotePath)): \(error.localizedDescription)"
        }
    }

    func stopAll() {
        for watch in watches.values {
            watch.source?.cancel()
            watch.uploadTask?.cancel()
        }
        watches.removeAll()
    }
}

/// Scratch folder for open-with copies (outside `TepfaCore` so it can stay app-specific).
enum AppPathsBridge {
    static var openWithDirectory: URL {
        let url = TepfaCore.AppPaths.applicationSupport.appending(path: "OpenWith", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

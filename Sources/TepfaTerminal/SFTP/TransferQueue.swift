import Foundation
import Observation
import TepfaCore
import TepfaSSH

/// One file moving between the Mac and a host (or, for server-to-server
/// copies, two hosts through the Mac).
@MainActor
@Observable
public final class TransferItem: Identifiable {
    public enum Kind: Sendable, Equatable {
        case download
        case upload
        /// Download from `hostID` to a temporary file, then upload to `targetHostID`.
        case copyBetweenHosts(targetHostID: UUID, targetHostName: String, targetPath: String)
    }

    public enum State: Equatable, Sendable {
        case queued, running, paused, completed, failed(String), cancelled

        public var isFinished: Bool {
            switch self {
            case .completed, .failed, .cancelled: true
            default: false
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    public let hostID: UUID
    public let hostName: String
    public let localURL: URL
    public let remotePath: String
    public private(set) var state: State = .queued
    public private(set) var transferred: Int64 = 0
    public private(set) var total: Int64?
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    /// Set when the transfer may continue from where it stopped.
    public private(set) var resumable = false

    init(kind: Kind, hostID: UUID, hostName: String, localURL: URL, remotePath: String, total: Int64?) {
        self.kind = kind
        self.hostID = hostID
        self.hostName = hostName
        self.localURL = localURL
        self.remotePath = remotePath
        self.total = total
    }

    public var displayName: String {
        switch kind {
        case .download, .copyBetweenHosts: SFTP.baseName(remotePath)
        case .upload: localURL.lastPathComponent
        }
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(Double(transferred) / Double(total), 1)
    }

    /// Bytes per second since the transfer started.
    public var rate: Double? {
        guard let startedAt, state == .running else { return nil }
        let seconds = Date.now.timeIntervalSince(startedAt)
        return seconds > 0.5 ? Double(transferred) / seconds : nil
    }

    fileprivate func set(state: State) {
        self.state = state
        if state.isFinished { finishedAt = .now }
    }

    fileprivate func progress(transferred: Int64, total: Int64?) {
        self.transferred = transferred
        if let total { self.total = total }
    }

    fileprivate func markStarted() {
        startedAt = .now
        state = .running
    }

    fileprivate func markResumable(_ value: Bool) {
        resumable = value
    }
}

/// Runs transfers a few at a time with pause, resume and cancel. The app
/// supplies SFTP clients through `clientProvider`.
@MainActor
@Observable
public final class TransferQueue {
    public typealias ClientProvider = @MainActor (UUID) async throws -> SFTPClient

    public private(set) var items: [TransferItem] = []
    public var maxConcurrent = 2
    public var clientProvider: ClientProvider?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Called when a transfer completes, so panes can refresh.
    public var onCompleted: ((TransferItem) -> Void)?

    public init() {}

    public var activeCount: Int { items.filter { $0.state == .running }.count }
    public var pendingCount: Int { items.filter { $0.state == .queued || $0.state == .running }.count }

    @discardableResult
    public func enqueueDownload(hostID: UUID, hostName: String, remotePath: String, to localURL: URL, size: Int64?) -> TransferItem {
        add(TransferItem(kind: .download, hostID: hostID, hostName: hostName, localURL: localURL, remotePath: remotePath, total: size))
    }

    @discardableResult
    public func enqueueUpload(hostID: UUID, hostName: String, localURL: URL, to remotePath: String) -> TransferItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value
        return add(TransferItem(kind: .upload, hostID: hostID, hostName: hostName, localURL: localURL, remotePath: remotePath, total: size))
    }

    @discardableResult
    public func enqueueCopy(fromHostID: UUID, fromHostName: String, remotePath: String, toHostID: UUID, toHostName: String, targetPath: String, size: Int64?) -> TransferItem {
        let temporary = FileManager.default.temporaryDirectory.appending(path: "tepfasonic-copy-\(UUID().uuidString)-\(SFTP.baseName(remotePath))")
        return add(TransferItem(kind: .copyBetweenHosts(targetHostID: toHostID, targetHostName: toHostName, targetPath: targetPath), hostID: fromHostID, hostName: fromHostName, localURL: temporary, remotePath: remotePath, total: size))
    }

    private func add(_ item: TransferItem) -> TransferItem {
        items.append(item)
        pump()
        return item
    }

    public func pause(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.state == .running || item.state == .queued else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        item.set(state: .paused)
        item.markResumable(true)
        pump()
    }

    public func resume(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        switch item.state {
        case .paused, .failed:
            item.set(state: .queued)
            pump()
        default:
            return
        }
    }

    public func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        if !item.state.isFinished { item.set(state: .cancelled) }
        pump()
    }

    public func remove(_ id: UUID) {
        cancel(id)
        items.removeAll { $0.id == id }
    }

    public func clearFinished() {
        items.removeAll { $0.state.isFinished }
    }

    public func pauseAll() {
        for item in items where item.state == .running || item.state == .queued { pause(item.id) }
    }

    private func pump() {
        guard let clientProvider else { return }
        var running = activeCount
        for item in items where item.state == .queued && running < maxConcurrent {
            running += 1
            item.markStarted()
            tasks[item.id] = Task { [weak self] in
                await self?.run(item, provider: clientProvider)
            }
        }
    }

    private func run(_ item: TransferItem, provider: ClientProvider) async {
        let resume = item.resumable
        let progress: SFTPClient.Progress = { transferred, total in
            Task { @MainActor in item.progress(transferred: transferred, total: total) }
        }
        do {
            switch item.kind {
            case .download:
                let client = try await provider(item.hostID)
                try await client.download(item.remotePath, to: item.localURL, resume: resume, progress: progress)
            case .upload:
                let client = try await provider(item.hostID)
                try await client.upload(item.localURL, to: item.remotePath, resume: resume, progress: progress)
            case .copyBetweenHosts(let targetHostID, _, let targetPath):
                let source = try await provider(item.hostID)
                try await source.download(item.remotePath, to: item.localURL, resume: resume, progress: progress)
                let target = try await provider(targetHostID)
                try await target.upload(item.localURL, to: targetPath, resume: false, progress: progress)
                try? FileManager.default.removeItem(at: item.localURL)
            }
            guard !Task.isCancelled else { return }
            item.set(state: .completed)
            onCompleted?(item)
        } catch is CancellationError {
            // Paused or cancelled: the state was set by the caller.
            if item.state == .running { item.set(state: .cancelled) }
        } catch {
            guard !Task.isCancelled else { return }
            item.set(state: .failed(error.localizedDescription))
            item.markResumable(true)
        }
        tasks[item.id] = nil
        pump()
    }
}

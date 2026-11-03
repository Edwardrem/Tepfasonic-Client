import Foundation
import SwiftData
import TepfaCore
import TepfaTerminal

/// Stores commands reported by sessions in the app database.
@MainActor
final class AppHistoryRecorder: CommandHistoryRecorder {
    static let maximumEntries = 50_000

    private let context: ModelContext
    private var open: [UUID: CommandHistoryEntry] = [:]
    private var insertsSincePrune = 0
    private var saveTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
    }

    func commandStarted(_ record: CommandRecord) {
        guard TerminalPreferences.recordHistory else { return }
        let entry = CommandHistoryEntry(
            uuid: record.id,
            command: record.command,
            hostID: record.hostID,
            hostName: record.hostName,
            hostTarget: record.hostTarget,
            startedAt: record.startedAt,
            workingDirectory: record.workingDirectory,
            source: record.source)
        context.insert(entry)
        open[record.id] = entry
        // Entries that never finish (typed without hooks, or the session dropped) must not pile up.
        if open.count > 64 {
            let oldest = open.min { $0.value.startedAt < $1.value.startedAt }
            if let oldest { open[oldest.key] = nil }
        }
        insertsSincePrune += 1
        if insertsSincePrune >= 500 {
            insertsSincePrune = 0
            prune()
        }
        saveSoon()
    }

    func commandFinished(id: UUID, exitStatus: Int?, at date: Date) {
        guard let entry = open.removeValue(forKey: id) else { return }
        entry.exitStatus = exitStatus
        entry.finishedAt = date
        saveSoon()
    }

    /// Deletes the oldest entries beyond `maximumEntries`.
    func prune() {
        let count = (try? context.fetchCount(FetchDescriptor<CommandHistoryEntry>())) ?? 0
        guard count > Self.maximumEntries else { return }
        var descriptor = FetchDescriptor<CommandHistoryEntry>(sortBy: [SortDescriptor(\.startedAt)])
        descriptor.fetchLimit = count - Self.maximumEntries
        for entry in (try? context.fetch(descriptor)) ?? [] {
            context.delete(entry)
        }
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [context] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? context.save()
        }
    }
}

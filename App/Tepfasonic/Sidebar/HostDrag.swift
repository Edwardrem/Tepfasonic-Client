import AppKit
import UniformTypeIdentifiers

/// The drag payload for hosts in the sidebar: a private type, so dropping a
/// host on a terminal or another app pastes nothing.
enum HostDrag {
    static let type = UTType(exportedAs: "com.tepfasonic.host-reference")

    static func provider(for ids: [UUID]) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data(ids.map(\.uuidString).joined(separator: "\n").utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    /// Reads every host id carried by the drop, in drag order, and hands them
    /// to `completion` on the main actor.
    static func loadIDs(from providers: [NSItemProvider], completion: @escaping @MainActor @Sendable ([UUID]) -> Void) {
        let relevant = providers.filter { $0.hasItemConformingToTypeIdentifier(type.identifier) }
        let results = Results(count: relevant.count)
        let group = DispatchGroup()
        for (slot, provider) in relevant.enumerated() {
            group.enter()
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                let ids = data.flatMap { String(data: $0, encoding: .utf8) }?
                    .split(separator: "\n").compactMap { UUID(uuidString: String($0)) } ?? []
                results.store(ids, at: slot)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ids = results.all
            MainActor.assumeIsolated { completion(ids) }
        }
    }

    /// Ids per provider, filled from the providers' completion threads.
    private final class Results: @unchecked Sendable {
        private var slots: [[UUID]]
        private let lock = NSLock()

        init(count: Int) { slots = Array(repeating: [], count: count) }

        func store(_ ids: [UUID], at slot: Int) {
            lock.lock(); defer { lock.unlock() }
            slots[slot] = ids
        }

        var all: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return slots.flatMap { $0 }
        }
    }
}

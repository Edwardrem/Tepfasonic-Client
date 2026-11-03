import Foundation
import Synchronization

/// Byte and connection counters shared between event loops and the UI.
public final class ForwardCounters: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var bytesSent: Int64 = 0
        public var bytesReceived: Int64 = 0
        public var connectionsTotal: Int = 0
        public var connectionsOpen: Int = 0
        public var lastError: String?

        public init() {}
    }

    private let storage = Mutex<Snapshot>(Snapshot())

    public init() {}

    public var snapshot: Snapshot { storage.withLock { $0 } }

    public func addSent(_ count: Int) { storage.withLock { $0.bytesSent += Int64(count) } }
    public func addReceived(_ count: Int) { storage.withLock { $0.bytesReceived += Int64(count) } }

    public func connectionOpened() {
        storage.withLock {
            $0.connectionsTotal += 1
            $0.connectionsOpen += 1
        }
    }

    public func connectionClosed() {
        storage.withLock { $0.connectionsOpen = max(0, $0.connectionsOpen - 1) }
    }

    public func setError(_ message: String?) {
        storage.withLock { $0.lastError = message }
    }

    public func reset() {
        storage.withLock { $0 = Snapshot() }
    }
}

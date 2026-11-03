import NIOCore
import NIOSSH
import Synchronization

/// Dispatches `forwarded-tcpip` channels the server opens (remote port
/// forwarding) to whoever asked for that listener. Registered with the
/// `NIOSSHHandler` as its inbound child channel initializer.
public final class ForwardedChannelRouter: Sendable {
    public typealias Handler = @Sendable (Channel, SSHChannelType.ForwardedTCPIP) -> EventLoopFuture<Void>

    private let handlers = Mutex<[String: Handler]>([:])

    public init() {}

    static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    /// Routes connections accepted on `host:port` by the server to `handler`.
    public func register(host: String, port: Int, handler: @escaping Handler) {
        handlers.withLock { $0[Self.key(host: host, port: port)] = handler }
    }

    public func unregister(host: String, port: Int) {
        handlers.withLock { $0[Self.key(host: host, port: port)] = nil }
    }

    public var isEmpty: Bool { handlers.withLock { $0.isEmpty } }

    func initialize(channel: Channel, type: SSHChannelType) -> EventLoopFuture<Void> {
        guard case .forwardedTCPIP(let info) = type else {
            return channel.eventLoop.makeFailedFuture(SSHClientError.channelFailed("unexpected inbound channel type"))
        }
        let handler = handlers.withLock { table -> Handler? in
            table[Self.key(host: info.listeningHost, port: info.listeningPort)]
                // Servers that bind "localhost" may report "" or "127.0.0.1"; fall back to a port-only match.
                ?? table.first { $0.key.hasSuffix(":\(info.listeningPort)") }?.value
        }
        guard let handler else {
            return channel.eventLoop.makeFailedFuture(SSHClientError.channelFailed("no forwarding rule for \(info.listeningHost):\(info.listeningPort)"))
        }
        return handler(channel, info)
    }
}

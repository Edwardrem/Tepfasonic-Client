import Foundation
import NIOCore
import NIOPosix
import Synchronization

/// Remote port forwarding: the server listens on `bindAddress:port` and every
/// connection it accepts is connected to `targetHost:targetPort` from the Mac.
/// Call `start(on:)` again after a reconnect; the server forgets the listener
/// when the connection drops.
public final class RemoteForwardBinding: @unchecked Sendable {
    public let bindAddress: String
    public let requestedPort: Int
    public let targetHost: String
    public let targetPort: Int
    public let counters = ForwardCounters()

    private struct Active {
        var connection: SSHConnection
        var port: Int
    }

    private let active = Mutex<Active?>(nil)

    public init(bindAddress: String, port: Int, targetHost: String, targetPort: Int) {
        self.bindAddress = bindAddress
        self.requestedPort = port
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public var boundPort: Int? { active.withLock { $0?.port } }
    public var isActive: Bool { active.withLock { $0?.connection.isActive ?? false } }

    /// Asks the server to listen. Returns the bound port.
    @discardableResult
    public func start(on connection: SSHConnection) async throws -> Int {
        await stop()
        let target = (targetHost, targetPort)
        let counters = self.counters
        let handler: ForwardedChannelRouter.Handler = { channel, _ in
            Self.accept(channel, target: target, counters: counters)
        }
        connection.forwardedChannels.register(host: bindAddress, port: requestedPort, handler: handler)
        let port: Int
        do {
            port = try await connection.requestRemoteForward(bindAddress: bindAddress, port: requestedPort)
        } catch {
            connection.forwardedChannels.unregister(host: bindAddress, port: requestedPort)
            throw error
        }
        if port != requestedPort {
            connection.forwardedChannels.register(host: bindAddress, port: port, handler: handler)
        }
        active.withLock { $0 = Active(connection: connection, port: port) }
        return port
    }

    public func stop() async {
        let current = active.withLock { active -> Active? in
            let value = active
            active = nil
            return value
        }
        guard let current else { return }
        current.connection.forwardedChannels.unregister(host: bindAddress, port: requestedPort)
        current.connection.forwardedChannels.unregister(host: bindAddress, port: current.port)
        if current.connection.isActive {
            await current.connection.cancelRemoteForward(bindAddress: bindAddress, port: current.port)
        }
    }

    /// Connects the forwarded channel to the local target. The SSH channel is
    /// only confirmed to the server once the local connection is up, so a
    /// refused local port is reported to the remote client as a failed open.
    private static func accept(_ sshChannel: Channel, target: (String, Int), counters: ForwardCounters) -> EventLoopFuture<Void> {
        counters.connectionOpened()
        sshChannel.closeFuture.whenComplete { _ in counters.connectionClosed() }
        let (sshGlue, localGlue) = GlueHandler.matchedPair(
            firstBytes: { counters.addReceived($0) },
            secondBytes: { counters.addSent($0) })
        return sshChannel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
            sshChannel.setOption(ChannelOptions.autoRead, value: false)
        }.flatMap {
            sshChannel.eventLoop.makeCompletedFuture {
                try sshChannel.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                try sshChannel.pipeline.syncOperations.addHandler(sshGlue)
            }
        }.flatMap {
            ClientBootstrap(group: sshChannel.eventLoop)
                .connectTimeout(.seconds(15))
                .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .channelInitializer { local in
                    local.eventLoop.makeCompletedFuture {
                        try local.pipeline.syncOperations.addHandler(localGlue)
                    }
                }
                .connect(host: target.0, port: target.1)
        }.flatMap { local in
            sshChannel.closeFuture.whenComplete { _ in local.close(promise: nil) }
            return sshChannel.setOption(ChannelOptions.autoRead, value: true).map { sshChannel.read() }
        }.flatMapErrorThrowing { error in
            counters.setError("Could not connect to \(target.0):\(target.1) on this Mac: \(SSHConnection.describe(error))")
            throw error
        }
    }
}

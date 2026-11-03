import Foundation
import NIOCore
import NIOPosix
import Synchronization

/// Dynamic forwarding: a SOCKS5 server on the Mac whose CONNECT requests
/// become direct-tcpip channels on the host, so a browser or any SOCKS-aware
/// program tunnels through the SSH connection.
public final class DynamicForwardListener: @unchecked Sendable {
    public let bindAddress: String
    public let requestedPort: Int
    public let counters = ForwardCounters()

    private let provider: SSHConnectionProvider
    private let serverChannel = Mutex<Channel?>(nil)

    public init(bindAddress: String, port: Int, provider: @escaping SSHConnectionProvider) {
        self.bindAddress = bindAddress
        self.requestedPort = port
        self.provider = provider
    }

    public var boundPort: Int? { serverChannel.withLock { $0?.localAddress?.port } }
    public var isListening: Bool { serverChannel.withLock { $0?.isActive ?? false } }

    @discardableResult
    public func start(group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> Int {
        let provider = self.provider
        let counters = self.counters
        let channel: Channel
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                .childChannelInitializer { child in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(SOCKS5ServerHandler(provider: provider, counters: counters))
                    }
                }
                .bind(host: bindAddress, port: requestedPort)
                .get()
        } catch {
            throw SSHClientError.channelFailed("could not listen on \(bindAddress):\(requestedPort): \(SSHConnection.describe(error))")
        }
        serverChannel.withLock { $0 = channel }
        return channel.localAddress?.port ?? requestedPort
    }

    public func stop() async {
        let channel = serverChannel.withLock { channel -> Channel? in
            let current = channel
            channel = nil
            return current
        }
        guard let channel else { return }
        try? await channel.close().get()
    }
}

/// Speaks the server side of SOCKS5 (no authentication, CONNECT only) and
/// hands the socket to `ForwardGlue` once the target is known.
final class SOCKS5ServerHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Phase { case greeting, request, connecting, done }

    private let provider: SSHConnectionProvider
    private let counters: ForwardCounters
    private var phase = Phase.greeting
    private var buffer = ByteBuffer()

    init(provider: @escaping SSHConnectionProvider, counters: ForwardCounters) {
        self.provider = provider
        self.counters = counters
    }

    func channelActive(context: ChannelHandlerContext) {
        counters.connectionOpened()
        let counters = self.counters
        context.channel.closeFuture.whenComplete { _ in counters.connectionClosed() }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard phase != .done else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        do {
            try advance(context: context)
        } catch {
            context.close(promise: nil)
        }
    }

    private func advance(context: ChannelHandlerContext) throws {
        switch phase {
        case .greeting:
            guard let (methods, length) = try SOCKS5.parseGreeting(buffer.readableBytesView) else { return }
            buffer.moveReaderIndex(forwardBy: length)
            guard methods.contains(0x00) else {
                send([0x05, 0xFF], context: context)
                context.close(promise: nil)
                return
            }
            send([0x05, 0x00], context: context)
            phase = .request
            try advance(context: context)
        case .request:
            guard let request = try SOCKS5.parseRequest(buffer.readableBytesView) else { return }
            buffer.moveReaderIndex(forwardBy: request.length)
            guard request.command == 0x01 else {
                send(SOCKS5.reply(code: SOCKS5.replyCommandNotSupported), context: context)
                context.close(promise: nil)
                return
            }
            guard let connection = provider(), connection.isActive else {
                counters.setError("Not connected to the host; a SOCKS request was refused.")
                send(SOCKS5.reply(code: SOCKS5.replyNetworkUnreachable), context: context)
                context.close(promise: nil)
                return
            }
            phase = .connecting
            let local = context.channel
            let replay = buffer
            buffer = ByteBuffer()
            // Stop reading until the tunnel is up; the glue takes over afterwards.
            local.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in }
            send(SOCKS5.reply(code: 0), context: context)
            phase = .done
            ForwardGlue.connect(local: local, through: connection, to: request.address.hostString, port: request.port, counters: counters, acceptHandler: self, replay: replay.readableBytes > 0 ? replay : nil)
        case .connecting, .done:
            return
        }
    }

    private func send(_ bytes: [UInt8], context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

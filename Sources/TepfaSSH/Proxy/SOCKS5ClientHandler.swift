import Foundation
import NIOCore

/// Connects through a SOCKS5 proxy (RFC 1928, with RFC 1929 username/password
/// authentication), then removes itself so the SSH handlers take over.
final class SOCKS5ClientHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Phase { case greeting, authentication, request, done }

    private let targetHost: String
    private let targetPort: Int
    private let credentials: (String, String)?
    private let established: EventLoopPromise<Void>
    private var phase = Phase.greeting
    private var buffer = ByteBuffer()

    init(targetHost: String, targetPort: Int, credentials: (String, String)?, established: EventLoopPromise<Void>) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.credentials = credentials
        self.established = established
    }

    func channelActive(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: 4)
        out.writeBytes(SOCKS5.clientGreeting(offersPassword: credentials != nil))
        context.writeAndFlush(NIOAny(out), promise: nil)
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
            fail(error, context: context)
        }
    }

    private func advance(context: ChannelHandlerContext) throws {
        while true {
            switch phase {
            case .greeting:
                guard buffer.readableBytes >= 2 else { return }
                let version = buffer.readInteger(as: UInt8.self)!
                let method = buffer.readInteger(as: UInt8.self)!
                guard version == 5 else { throw ProxyError.malformedReply }
                switch method {
                case 0x00:
                    phase = .request
                    send(SOCKS5.connectRequest(host: targetHost, port: targetPort), context: context)
                case 0x02:
                    guard let (user, password) = credentials else { throw ProxyError.authenticationRequired }
                    phase = .authentication
                    send(SOCKS5.passwordAuthentication(username: user, password: password), context: context)
                default:
                    throw ProxyError.authenticationRequired
                }
            case .authentication:
                guard buffer.readableBytes >= 2 else { return }
                _ = buffer.readInteger(as: UInt8.self)
                let status = buffer.readInteger(as: UInt8.self)!
                guard status == 0 else { throw ProxyError.authenticationFailed }
                phase = .request
                send(SOCKS5.connectRequest(host: targetHost, port: targetPort), context: context)
            case .request:
                guard let reply = try SOCKS5.parseReply(buffer.readableBytesView) else { return }
                buffer.moveReaderIndex(forwardBy: reply.length)
                guard reply.code == 0 else { throw ProxyError.socksRefused(reply.code) }
                phase = .done
                let remainder = buffer
                buffer = ByteBuffer()
                established.succeed(())
                context.pipeline.syncOperations.removeHandler(self, promise: nil)
                if remainder.readableBytes > 0 { context.fireChannelRead(wrapInboundOut(remainder)) }
                return
            case .done:
                return
            }
        }
    }

    private func send(_ bytes: [UInt8], context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if phase != .done {
            phase = .done
            established.fail(SSHClientError.connectionFailed("the proxy closed the connection"))
        }
        context.fireChannelInactive()
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard phase != .done else { return }
        phase = .done
        established.fail(error)
        context.close(promise: nil)
    }
}

import Foundation
import NIOCore

/// Opens a tunnel through an HTTP proxy with `CONNECT host:port`, then
/// removes itself and hands the connection to `onEstablished`, which adds
/// the SSH handlers. Bytes that arrive with the proxy's reply are replayed.
final class HTTPConnectHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let targetHost: String
    private let targetPort: Int
    private let credentials: (String, String)?
    private let established: EventLoopPromise<Void>
    private var buffer = ByteBuffer()
    private var done = false

    init(targetHost: String, targetPort: Int, credentials: (String, String)?, established: EventLoopPromise<Void>) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.credentials = credentials
        self.established = established
    }

    static func request(host: String, port: Int, credentials: (String, String)?) -> String {
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        var lines = ["CONNECT \(authority) HTTP/1.1", "Host: \(authority)", "Proxy-Connection: keep-alive", "User-Agent: Tepfasonic"]
        if let (user, password) = credentials {
            lines.append("Proxy-Authorization: Basic " + Data("\(user):\(password)".utf8).base64EncodedString())
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    func channelActive(context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: 256)
        out.writeString(Self.request(host: targetHost, port: targetPort, credentials: credentials))
        context.writeAndFlush(NIOAny(out), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard let headerEnd = Self.headerEnd(in: buffer) else {
            if buffer.readableBytes > 64 * 1024 { fail(ProxyError.malformedReply, context: context) }
            return
        }
        let headerText = buffer.getString(at: buffer.readerIndex, length: headerEnd) ?? ""
        buffer.moveReaderIndex(forwardBy: headerEnd + 4)
        switch Self.parseStatus(headerText) {
        case .success:
            done = true
            let remainder = buffer
            buffer = ByteBuffer()
            established.succeed(())
            context.pipeline.syncOperations.removeHandler(self, promise: nil)
            if remainder.readableBytes > 0 {
                context.fireChannelRead(wrapInboundOut(remainder))
            }
        case .failure(let error):
            fail(error, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            established.fail(SSHClientError.connectionFailed("the proxy closed the connection"))
        }
        context.fireChannelInactive()
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard !done else { return }
        done = true
        established.fail(error)
        context.close(promise: nil)
    }

    static func headerEnd(in buffer: ByteBuffer) -> Int? {
        let bytes = buffer.readableBytesView
        guard bytes.count >= 4 else { return nil }
        var index = bytes.startIndex
        while index + 3 < bytes.endIndex {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index - bytes.startIndex
            }
            index += 1
        }
        return nil
    }

    /// Reads `HTTP/1.x 200 …` out of the proxy's reply.
    static func parseStatus(_ header: String) -> Result<Void, ProxyError> {
        let firstLine = header.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return .failure(.malformedReply) }
        if (200..<300).contains(status) { return .success(()) }
        if status == 407 { return .failure(.authenticationRequired) }
        return .failure(.httpRefused(status, parts.count > 2 ? parts[2] : ""))
    }
}

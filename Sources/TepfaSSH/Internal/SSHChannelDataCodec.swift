import NIOCore
import NIOSSH

/// Turns an SSH child channel into a plain byte stream: inbound
/// `SSHChannelData` becomes `ByteBuffer`, outbound `ByteBuffer` is wrapped as
/// regular channel data. Used for direct-tcpip and forwarded-tcpip channels,
/// subsystems, and for running a second SSH handshake through a jump host.
final class SSHChannelDataCodec: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    /// When true, stderr data is passed through as well (merged into the stream).
    private let includeStderr: Bool

    init(includeStderr: Bool = false) {
        self.includeStderr = includeStderr
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        if channelData.type == .channel || (includeStderr && channelData.type == .stdErr) {
            context.fireChannelRead(wrapInboundOut(buffer))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

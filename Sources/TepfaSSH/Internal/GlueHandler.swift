import NIOCore
import Synchronization

/// Pipes bytes between two channels with back-pressure, the way the SwiftNIO
/// "glue" example does, but safe across event loops: the two channels may
/// live on different loops (an accepted TCP socket and an SSH child channel).
///
/// Create a pair with `matchedPair`, add one handler to each channel. Each
/// side forwards what it reads to its partner, stops reading when the partner
/// is not writable, closes its write side when the partner's input ends, and
/// closes fully when the partner goes away.
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let state = Mutex<State>(State())
    /// Called on the handler's loop with the number of bytes read on this side.
    private let onBytes: (@Sendable (Int) -> Void)?

    private struct State {
        weak var partner: GlueHandler?
        var context: ChannelHandlerContext?
        var loop: EventLoop?
        var pendingRead = false
        var writable = true
    }

    private init(onBytes: (@Sendable (Int) -> Void)?) {
        self.onBytes = onBytes
    }

    /// Two handlers that pipe into each other. `first` is normally the local
    /// socket and `second` the SSH channel; the byte callbacks are per side.
    static func matchedPair(
        firstBytes: (@Sendable (Int) -> Void)? = nil,
        secondBytes: (@Sendable (Int) -> Void)? = nil
    ) -> (GlueHandler, GlueHandler) {
        let first = GlueHandler(onBytes: firstBytes)
        let second = GlueHandler(onBytes: secondBytes)
        first.state.withLock { $0.partner = second }
        second.state.withLock { $0.partner = first }
        return (first, second)
    }

    private var partner: GlueHandler? { state.withLock { $0.partner } }

    // MARK: Pipeline

    func handlerAdded(context: ChannelHandlerContext) {
        state.withLock {
            $0.context = context
            $0.loop = context.eventLoop
            $0.writable = context.channel.isWritable
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        state.withLock {
            $0.context = nil
            $0.partner = nil
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
        state.withLock { $0.partner = nil }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onBytes?(buffer.readableBytes)
        partner?.partnerWrite(buffer)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
            partner?.partnerWriteEOF()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let writable = context.channel.isWritable
        state.withLock { $0.writable = writable }
        if writable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.isWritable {
            context.read()
        } else {
            state.withLock { $0.pendingRead = true }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: Partner calls (hop to our own loop)

    private var isWritable: Bool { state.withLock { $0.writable && $0.context != nil } }

    private func onLoop(_ body: @escaping @Sendable (ChannelHandlerContext) -> Void) {
        let (context, loop) = state.withLock { ($0.context, $0.loop) }
        guard let context, let loop else { return }
        if loop.inEventLoop {
            body(context)
        } else {
            loop.execute { body(context) }
        }
    }

    private func partnerWrite(_ buffer: ByteBuffer) {
        onLoop { context in context.write(NIOAny(buffer), promise: nil) }
    }

    private func partnerFlush() {
        onLoop { context in context.flush() }
    }

    private func partnerWriteEOF() {
        onLoop { context in context.close(mode: .output, promise: nil) }
    }

    private func partnerCloseFull() {
        onLoop { context in context.close(promise: nil) }
    }

    private func partnerBecameWritable() {
        let pending = state.withLock { state -> Bool in
            let pending = state.pendingRead
            state.pendingRead = false
            return pending
        }
        guard pending else { return }
        onLoop { context in context.read() }
    }
}

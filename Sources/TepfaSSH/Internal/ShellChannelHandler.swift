import NIOCore
import NIOSSH

/// Why a shell session ended.
public struct ShellCloseReason: Sendable, Equatable {
    public var exitStatus: Int?
    public var signal: String?
    public var error: String?

    public var message: String {
        if let exitStatus {
            return exitStatus == 0 ? "Session ended" : "Session ended with exit code \(exitStatus)"
        }
        if let signal {
            return "Session ended by signal \(signal)"
        }
        if let error {
            return error
        }
        return "Connection closed"
    }
}

/// Sits in the session child channel: unwraps inbound `SSHChannelData` into
/// raw bytes for the terminal and wraps outbound `ByteBuffer`s for the server.
final class ShellChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let onOutput: @Sendable (ArraySlice<UInt8>) -> Void
    private let onClose: @Sendable (ShellCloseReason) -> Void
    private var reason = ShellCloseReason()
    private var closed = false

    init(onOutput: @escaping @Sendable (ArraySlice<UInt8>) -> Void, onClose: @escaping @Sendable (ShellCloseReason) -> Void) {
        self.onOutput = onOutput
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        // stderr is merged into the terminal stream, as a PTY would.
        if channelData.type == .channel || channelData.type == .stdErr {
            onOutput(ArraySlice(buffer.readableBytesView))
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            reason.exitStatus = status.exitStatus
        case let signal as SSHChannelRequestEvent.ExitSignal:
            reason.signal = signal.signalName
        case is ChannelFailureEvent:
            reason.error = "The server refused the terminal or shell request."
            context.close(promise: nil)
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            context.close(promise: nil)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if reason.error == nil {
            reason.error = String(describing: error)
        }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !closed {
            closed = true
            onClose(reason)
        }
        context.fireChannelInactive()
    }
}

import NIOCore
import NIOSSH

/// Result of `SSHConnection.run`.
public struct CommandResult: Sendable, Equatable {
    public var exitStatus: Int?
    public var signal: String?
    public var stdout: [UInt8]
    public var stderr: [UInt8]

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitStatus == 0 }
}

/// Collects the output of an `exec` channel and completes a promise when it closes.
final class ExecChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let promise: EventLoopPromise<CommandResult>
    private let limit: Int
    private var result = CommandResult(exitStatus: nil, signal: nil, stdout: [], stderr: [])
    private var failure: Error?
    private var completed = false

    init(promise: EventLoopPromise<CommandResult>, outputLimit: Int) {
        self.promise = promise
        limit = outputLimit
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        switch channelData.type {
        case .channel:
            if result.stdout.count < limit { result.stdout.append(contentsOf: buffer.readableBytesView.prefix(limit - result.stdout.count)) }
        case .stdErr:
            if result.stderr.count < limit { result.stderr.append(contentsOf: buffer.readableBytesView.prefix(limit - result.stderr.count)) }
        default:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            result.exitStatus = status.exitStatus
        case let signal as SSHChannelRequestEvent.ExitSignal:
            result.signal = signal.signalName
        case is ChannelFailureEvent:
            failure = SSHClientError.channelFailed("The server refused the exec request.")
            context.close(promise: nil)
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            context.close(promise: nil)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if failure == nil { failure = error }
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            if let failure {
                promise.fail(failure)
            } else {
                promise.succeed(result)
            }
        }
        context.fireChannelInactive()
    }
}

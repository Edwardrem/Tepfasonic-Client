import NIOCore
import NIOSSH

/// Completes a promise once user authentication succeeds, or fails it if the
/// connection errors or closes first.
final class HandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let promise: EventLoopPromise<Void>
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.failure(SSHClientError.connectionClosed))
        context.fireChannelInactive()
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        promise.completeWith(result)
    }
}

import NIOCore
import NIOSSH

/// An interactive shell on an `SSHConnection`. Bytes typed into the terminal
/// go through `write`; output arrives via the `onOutput` callback given to
/// `SSHConnection.openShell`.
public final class SSHShellSession: @unchecked Sendable {
    private let channel: Channel

    init(channel: Channel) {
        self.channel = channel
    }

    public var isActive: Bool { channel.isActive }

    /// Sends keyboard input to the remote shell. Safe to call from any thread.
    public func write(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty, channel.isActive else { return }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(buffer, promise: nil)
    }

    public func write(_ text: String) {
        write(ArraySlice(text.utf8))
    }

    /// Tells the remote PTY the terminal has been resized.
    public func resize(cols: Int, rows: Int) {
        guard channel.isActive, cols > 0, rows > 0 else { return }
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0), promise: nil)
    }

    /// Closes the session channel. The connection stays open for other channels.
    public func close() {
        channel.close(promise: nil)
    }
}

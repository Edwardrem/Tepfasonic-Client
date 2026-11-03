import Darwin
import Foundation
import TepfaCore

public enum SerialPortError: Error, LocalizedError, Sendable, Equatable {
    case cannotOpen(String, Int32)
    case cannotConfigure(String)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path, let code):
            "Could not open \(path): \(String(cString: strerror(code))). Check that the device is plugged in and not in use by another program."
        case .cannotConfigure(let detail):
            "Could not configure the serial port: \(detail)."
        case .notOpen:
            "The serial port is not open."
        }
    }
}

/// A USB or built-in serial device opened with termios. Reads arrive on a
/// background queue through `onData`; `onClose` fires when the device goes
/// away (unplugged) or after `close()`.
public final class SerialPort: @unchecked Sendable {
    public let settings: SerialSettings
    private let queue = DispatchQueue(label: "com.tepfasonic.serial")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let onData: @Sendable ([UInt8]) -> Void
    private let onClose: @Sendable (String?) -> Void
    private var closed = false

    public init(settings: SerialSettings, onData: @escaping @Sendable ([UInt8]) -> Void, onClose: @escaping @Sendable (String?) -> Void) {
        self.settings = settings
        self.onData = onData
        self.onClose = onClose
    }

    public var isOpen: Bool { queue.sync { descriptor >= 0 && !closed } }

    public func open() throws {
        let path = settings.devicePath
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw SerialPortError.cannotOpen(path, errno) }
        // Exclusive access, as screen(1) does.
        _ = ioctl(fd, UInt(TIOCEXCL))
        do {
            try Self.configure(fd: fd, settings: settings)
        } catch {
            Darwin.close(fd)
            throw error
        }
        queue.sync { descriptor = fd }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.descriptor >= 0 {
                Darwin.close(self.descriptor)
                self.descriptor = -1
            }
        }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                onData(Array(buffer[0..<count]))
                if count < buffer.count { return }
                continue
            }
            if count == 0 {
                finish(reason: "The serial device was disconnected.")
                return
            }
            if errno == EAGAIN || errno == EINTR { return }
            finish(reason: "Read failed: \(String(cString: strerror(errno)))")
            return
        }
    }

    /// Writes synchronously on the port queue; short writes are retried.
    public func write(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard descriptor >= 0, !closed else { return }
            var offset = 0
            var spins = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                if written > 0 {
                    offset += written
                    spins = 0
                } else if errno == EAGAIN, spins < 1000 {
                    spins += 1
                    usleep(1000)
                } else {
                    return
                }
            }
        }
    }

    public func close() {
        queue.async { self.finish(reason: nil) }
    }

    private func finish(reason: String?) {
        guard !closed else { return }
        closed = true
        source?.cancel()
        source = nil
        if descriptor >= 0, source == nil {
            // The cancel handler closes the descriptor; nothing more to do here.
        }
        onClose(reason)
    }

    // MARK: termios

    static func configure(fd: Int32, settings: SerialSettings) throws {
        var options = termios()
        guard tcgetattr(fd, &options) == 0 else { throw SerialPortError.cannotConfigure(String(cString: strerror(errno))) }
        cfmakeraw(&options)

        // Control flags (values from <sys/termios.h>).
        let csize: tcflag_t = 0x300, cs5: tcflag_t = 0x000, cs6: tcflag_t = 0x100, cs7: tcflag_t = 0x200, cs8: tcflag_t = 0x300
        let cstopb: tcflag_t = 0x400, cread: tcflag_t = 0x800, parenb: tcflag_t = 0x1000, parodd: tcflag_t = 0x2000, clocal: tcflag_t = 0x8000
        let cctsOflow: tcflag_t = 0x00010000, crtsIflow: tcflag_t = 0x00020000
        let ixon: tcflag_t = 0x200, ixoff: tcflag_t = 0x400

        options.c_cflag &= ~(csize | cstopb | parenb | parodd | cctsOflow | crtsIflow)
        options.c_cflag |= cread | clocal
        switch settings.dataBits {
        case 5: options.c_cflag |= cs5
        case 6: options.c_cflag |= cs6
        case 7: options.c_cflag |= cs7
        default: options.c_cflag |= cs8
        }
        if settings.stopBits == 2 { options.c_cflag |= cstopb }
        switch settings.parity {
        case .none: break
        case .even: options.c_cflag |= parenb
        case .odd: options.c_cflag |= parenb | parodd
        }
        options.c_iflag &= ~(ixon | ixoff)
        switch settings.flowControl {
        case .none: break
        case .hardware: options.c_cflag |= cctsOflow | crtsIflow
        case .software: options.c_iflag |= ixon | ixoff
        }

        let standard = cfsetspeed(&options, speed_t(settings.baudRate)) == 0
        guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw SerialPortError.cannotConfigure(String(cString: strerror(errno))) }
        if !standard {
            // Non-standard rates go through IOSSIOSPEED (IOKit/serial/ioss.h: _IOW('T', 2, speed_t)).
            var speed = speed_t(settings.baudRate)
            let request: UInt = 0x8008_5402
            guard ioctl(fd, request, &speed) == 0 else {
                throw SerialPortError.cannotConfigure("the device does not accept \(settings.baudRate) baud")
            }
        }
        tcflush(fd, TCIOFLUSH)
    }
}

/// Serial devices present on the Mac.
public enum SerialDevices {
    public struct Device: Sendable, Hashable, Identifiable {
        public let path: String
        public var id: String { path }
        /// `usbserial-1420` from `/dev/cu.usbserial-1420`.
        public var shortName: String {
            let name = (path as NSString).lastPathComponent
            return name.hasPrefix("cu.") ? String(name.dropFirst(3)) : name
        }
        public var isLikelyUSB: Bool {
            let lower = path.lowercased()
            return lower.contains("usb") || lower.contains("serial") || lower.contains("acm") || lower.contains("slab") || lower.contains("wch")
        }
    }

    /// `/dev/cu.*`, USB adapters first, excluding the Bluetooth and debug ports macOS always has.
    public static func list() -> [Device] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .filter { !$0.lowercased().contains("bluetooth") && !$0.lowercased().contains("debug-console") }
            .map { Device(path: "/dev/" + $0) }
            .sorted { ($0.isLikelyUSB ? 0 : 1, $0.path) < ($1.isLikelyUSB ? 0 : 1, $1.path) }
    }
}

/// Formats bytes as a hex dump with an ASCII column, 16 bytes per line, for
/// the terminal's hex view.
public enum HexDump {
    public static func lines(_ bytes: [UInt8], offset: Int) -> String {
        var out = ""
        var index = 0
        while index < bytes.count {
            let chunk = bytes[index..<min(index + 16, bytes.count)]
            var line = String(format: "%08x  ", offset + index)
            for (position, byte) in chunk.enumerated() {
                line += String(format: "%02x ", byte)
                if position == 7 { line += " " }
            }
            let padding = 16 - chunk.count
            line += String(repeating: "   ", count: padding) + (padding > 8 ? " " : "")
            line += " |"
            for byte in chunk {
                line += (0x20...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : "."
            }
            line += "|\r\n"
            out += line
            index += 16
        }
        return out
    }
}

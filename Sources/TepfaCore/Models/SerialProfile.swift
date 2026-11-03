import Foundation
import SwiftData

public enum SerialParity: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, even, odd
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public enum SerialFlowControl: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    /// RTS/CTS.
    case hardware
    /// XON/XOFF.
    case software
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: "None"
        case .hardware: "Hardware (RTS/CTS)"
        case .software: "Software (XON/XOFF)"
        }
    }
}

/// What Return sends, and how incoming line endings are shown.
public enum SerialLineEnding: String, Codable, CaseIterable, Sendable, Identifiable {
    case cr, lf, crlf
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .cr: "CR"
        case .lf: "LF"
        case .crlf: "CR LF"
        }
    }
    public var bytes: [UInt8] {
        switch self {
        case .cr: [0x0D]
        case .lf: [0x0A]
        case .crlf: [0x0D, 0x0A]
        }
    }
}

/// A saved USB serial console: device, line settings and conversions.
@Model
public final class SerialProfile {
    @Attribute(.unique) public var uuid: UUID
    public var name: String
    /// `/dev/cu.usbserial-1420` and the like.
    public var devicePath: String
    public var baudRate: Int
    public var dataBits: Int
    public var parityRaw: String
    public var stopBits: Int
    public var flowControlRaw: String
    /// What Return sends.
    public var sendLineEndingRaw: String
    /// Convert bare LF from the device to CR LF so lines start at the left.
    public var convertIncomingLF: Bool
    public var localEcho: Bool
    /// Show bytes as hex alongside text.
    public var hexView: Bool
    public var colorLabel: String?
    public var sortOrder: Int
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        uuid: UUID = UUID(),
        name: String,
        devicePath: String,
        baudRate: Int = 115_200,
        dataBits: Int = 8,
        parity: SerialParity = .none,
        stopBits: Int = 1,
        flowControl: SerialFlowControl = .none,
        sendLineEnding: SerialLineEnding = .cr,
        convertIncomingLF: Bool = true,
        localEcho: Bool = false,
        hexView: Bool = false,
        colorLabel: String? = nil,
        sortOrder: Int = 0
    ) {
        self.uuid = uuid
        self.name = name
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parityRaw = parity.rawValue
        self.stopBits = stopBits
        self.flowControlRaw = flowControl.rawValue
        self.sendLineEndingRaw = sendLineEnding.rawValue
        self.convertIncomingLF = convertIncomingLF
        self.localEcho = localEcho
        self.hexView = hexView
        self.colorLabel = colorLabel
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    public var parity: SerialParity {
        get { SerialParity(rawValue: parityRaw) ?? .none }
        set { parityRaw = newValue.rawValue }
    }

    public var flowControl: SerialFlowControl {
        get { SerialFlowControl(rawValue: flowControlRaw) ?? .none }
        set { flowControlRaw = newValue.rawValue }
    }

    public var sendLineEnding: SerialLineEnding {
        get { SerialLineEnding(rawValue: sendLineEndingRaw) ?? .cr }
        set { sendLineEndingRaw = newValue.rawValue }
    }

    /// `115200 8N1`
    public var lineSummary: String {
        "\(baudRate) \(dataBits)\(parity.rawValue.prefix(1).uppercased())\(stopBits)"
    }
}

/// Sendable copy of a serial profile for the session.
public struct SerialSettings: Sendable, Hashable, Codable {
    public var devicePath: String
    public var baudRate: Int
    public var dataBits: Int
    public var parity: SerialParity
    public var stopBits: Int
    public var flowControl: SerialFlowControl
    public var sendLineEnding: SerialLineEnding
    public var convertIncomingLF: Bool
    public var localEcho: Bool
    public var hexView: Bool

    public init(devicePath: String, baudRate: Int = 115_200, dataBits: Int = 8, parity: SerialParity = .none, stopBits: Int = 1, flowControl: SerialFlowControl = .none, sendLineEnding: SerialLineEnding = .cr, convertIncomingLF: Bool = true, localEcho: Bool = false, hexView: Bool = false) {
        self.devicePath = devicePath
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flowControl = flowControl
        self.sendLineEnding = sendLineEnding
        self.convertIncomingLF = convertIncomingLF
        self.localEcho = localEcho
        self.hexView = hexView
    }

    @MainActor
    public init(_ profile: SerialProfile) {
        self.init(devicePath: profile.devicePath, baudRate: profile.baudRate, dataBits: profile.dataBits, parity: profile.parity, stopBits: profile.stopBits, flowControl: profile.flowControl, sendLineEnding: profile.sendLineEnding, convertIncomingLF: profile.convertIncomingLF, localEcho: profile.localEcho, hexView: profile.hexView)
    }

    public var lineSummary: String {
        "\(baudRate) \(dataBits)\(parity.rawValue.prefix(1).uppercased())\(stopBits)"
    }

    public static let commonBaudRates = [300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200, 230_400, 460_800, 921_600, 1_500_000]
}

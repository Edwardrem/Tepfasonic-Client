import SwiftUI

/// Preset colour labels plus hex parsing for custom ones.
enum HostColor {
    struct Preset: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let presets: [Preset] = [
        Preset(name: "Red", hex: "#FF5F57"),
        Preset(name: "Orange", hex: "#FF9F0A"),
        Preset(name: "Yellow", hex: "#FFD60A"),
        Preset(name: "Green", hex: "#32D74B"),
        Preset(name: "Teal", hex: "#40C8E0"),
        Preset(name: "Blue", hex: "#0A84FF"),
        Preset(name: "Purple", hex: "#BF5AF2"),
        Preset(name: "Pink", hex: "#FF375F"),
        Preset(name: "Grey", hex: "#98989D"),
    ]

    static func color(_ hex: String?) -> Color? {
        guard let hex else { return nil }
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

import SwiftUI

/// The few numbers the interface is built from: continuous corner radii and
/// a spacing scale, so every surface reads as one family.
enum Design {
    static let radiusSmall: CGFloat = 7
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 14
    static let radiusBubble: CGFloat = 16

    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// A rounded, gradient-filled square with a white symbol: the iOS app-icon
/// idiom used for hosts, files and empty states.
struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.98), color.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                in: Design.shape(size * 0.28))
            .overlay(Design.shape(size * 0.28).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A small status dot with a ring in the surface colour so it sits on an icon tile.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8
    @Environment(\.palette) private var palette

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(palette.fromScheme ? palette.surfaceColor : Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .frame(width: size + 3, height: size + 3)
    }
}

/// A one-pixel line in the palette's separator colour (replaces `Divider` in the chrome).
struct ChromeDivider: View {
    var axis: Axis = .horizontal
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// `⌘↩  Connect` — a key cap and what it does.
struct Keycap: View {
    let keys: String
    let label: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.caption.weight(.medium).monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(palette.raised, in: Design.shape(5))
                .overlay(Design.shape(5).strokeBorder(palette.separator, lineWidth: 0.5))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CardModifier: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(palette.raised, in: Design.shape(radius))
            .overlay(Design.shape(radius).strokeBorder(palette.separator, lineWidth: 0.5))
    }
}

private struct PillModifier: ViewModifier {
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.raised, in: Capsule())
    }
}

extension View {
    /// A raised card with a hairline edge.
    func card(padding: CGFloat = 10, radius: CGFloat = Design.radiusMedium) -> some View {
        modifier(CardModifier(padding: padding, radius: radius))
    }

    /// A small capsule for status information.
    func pill() -> some View {
        modifier(PillModifier())
    }
}

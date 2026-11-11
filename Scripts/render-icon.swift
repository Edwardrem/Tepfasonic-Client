// Renders the app icon into App/Tepfasonic/Assets.xcassets/AppIcon.appiconset.
//   swiftc -O -o /tmp/render-icon Scripts/render-icon.swift && /tmp/render-icon App/Tepfasonic/Assets.xcassets/AppIcon.appiconset
// Then copy icon_512x512.png to site/icon.png and icon_32x32@2x.png to site/favicon.png.
//
// prompt chevron followed by a blue "sonic" waveform. Usage: render_icon <out dir>
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.dropFirst().first ?? "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon into a context whose user space is 1024 x 1024 (origin bottom-left).
func draw(in ctx: CGContext) {
    let canvas: CGFloat = 1024
    // Apple's icon grid: the squircle fills 824 pt of the 1024 pt canvas.
    let inset: CGFloat = 100
    let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let radius = tile.width * 0.2237
    let squircle = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft shadow under the tile, like Apple's own icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(color(0x0E131B))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: deep navy gradient, lighter at the top.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [color(0x25364D), color(0x151D2A), color(0x0B0F16)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    // A faint accent glow in the upper right.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x2A99E6, 0.28), color(0x2A99E6, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 700, y: 760), startRadius: 0, endCenter: CGPoint(x: 700, y: 760), endRadius: 520, options: [])
    // Inner highlight along the top edge.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: radius - 3, cornerHeight: radius - 3, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // Prompt chevron ">" in white with a soft glow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: color(0xFFFFFF, 0.25))
    ctx.setStrokeColor(color(0xF5F7FA))
    ctx.setLineWidth(74)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 232, y: 652))
    ctx.addLine(to: CGPoint(x: 392, y: 512))
    ctx.addLine(to: CGPoint(x: 232, y: 372))
    ctx.strokePath()
    ctx.restoreGState()

    // Waveform: five rounded bars, blue to cyan, glowing.
    let heights: [CGFloat] = [118, 222, 330, 222, 118]
    let barWidth: CGFloat = 50
    let gap: CGFloat = 26
    var x: CGFloat = 452
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0x2A99E6, 0.55))
    for height in heights {
        let bar = CGRect(x: x, y: 512 - height / 2, width: barWidth, height: height)
        let path = CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let fill = CGGradient(colorsSpace: space, colors: [color(0x63E3F0), color(0x2A99E6)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: bar.maxY), end: CGPoint(x: 0, y: bar.minY), options: [])
        ctx.restoreGState()
        x += barWidth + gap
    }
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(in: ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    return rep.representation(using: .png, properties: [:])!
}

// Asset catalogue slots: (point size, scale).
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var entries: [String] = []
for (points, scale) in slots {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png"
    try! render(pixels: points * scale).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    entries.append("    { \"filename\" : \"\(name)\", \"idiom\" : \"mac\", \"scale\" : \"\(scale)x\", \"size\" : \"\(points)x\(points)\" }")
}
let contents = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try! contents.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(slots.count) icon sizes to \(outDir)")

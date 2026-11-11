#if DEBUG
import AppKit

/// Prints every window and its view tree; for diagnosing chrome drawn by AppKit.
@MainActor
enum QADump {
    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func windows() {
        for window in NSApp.windows where window.isVisible {
            log("WINDOW \(type(of: window)) frame=\(window.frame) opaque=\(window.isOpaque) bg=\(window.backgroundColor.description) appearance=\(window.appearance?.name.rawValue ?? "-") effective=\(window.effectiveAppearance.name.rawValue) titlebarTransparent=\(window.titlebarAppearsTransparent) style=\(window.styleMask.rawValue) level=\(window.level.rawValue)")
            if let view = window.contentView?.superview { dump(view, depth: 1) }
        }
    }

    /// Every view and layer that intersects the toolbar band of the detail
    /// column (x 255…430 pt from the left, the top 52 pt), with absolute frames.
    static func titleRegion() {
        for window in NSApp.windows where window.isVisible {
            let band = NSRect(x: 255, y: window.frame.height - 52, width: 175, height: 52)
            log("REGION \(type(of: window)) height=\(window.frame.height)")
            guard let root = window.contentView?.superview else { continue }
            walk(root, band: band, depth: 1)
        }
    }

    private static func walk(_ view: NSView, band: NSRect, depth: Int) {
        let absolute = view.convert(view.bounds, to: nil)
        if absolute.intersects(band), !view.isHidden, view.alphaValue > 0 {
            var extra = ""
            if let layer = view.layer {
                if let bg = layer.backgroundColor, let c = NSColor(cgColor: bg), c.alphaComponent > 0 { extra += " layerBg=\(c)" }
                if layer.contents != nil { extra += " layerContents" }
                for sub in layer.sublayers ?? [] { describe(sub, prefix: "    " + String(repeating: "  ", count: depth), depth: 0) }
            }
            log(String(repeating: "  ", count: depth) + "\(type(of: view)) abs=\(absolute.integral)\(extra)")
        }
        for sub in view.subviews { walk(sub, band: band, depth: depth + 1) }
    }

    private static func describe(_ layer: CALayer, prefix: String, depth: Int) {
        guard depth < 6, layer.delegate == nil || !(layer.delegate is NSView) else { return }
        var extra = ""
        if let bg = layer.backgroundColor, let c = NSColor(cgColor: bg), c.alphaComponent > 0 { extra += " bg=\(c)" }
        if layer.contents != nil { extra += " contents" }
        if layer.opacity < 1 { extra += " opacity=\(layer.opacity)" }
        if layer.isHidden { extra += " hidden" }
        log(prefix + "layer \(type(of: layer)) \(layer.frame.integral)\(extra)")
        for sub in layer.sublayers ?? [] { describe(sub, prefix: prefix + "  ", depth: depth + 1) }
    }

    private static func dump(_ view: NSView, depth: Int) {
        guard depth < 24 else { return }
        var extra = ""
        if let effect = view as? NSVisualEffectView { extra = " material=\(effect.material.rawValue) blending=\(effect.blendingMode.rawValue) state=\(effect.state.rawValue)" }
        if let layer = view.layer, let bg = layer.backgroundColor, let nsColor = NSColor(cgColor: bg), nsColor.alphaComponent > 0 { extra += " layerBg=\(nsColor.description)" }
        if let box = view as? NSBox { extra += " boxFill=\(box.fillColor.description) boxType=\(box.boxType.rawValue)" }
        if view.alphaValue < 1 { extra += " alpha=\(view.alphaValue)" }
        if let layer = view.layer, layer.opacity < 1 { extra += " layerOpacity=\(layer.opacity)" }
        for key in ["tintColor", "style", "material", "cornerRadius", "_backgroundColor", "fillColor", "backgroundColor", "appearance"] where view.responds(to: NSSelectorFromString(key)) {
            if let value = view.value(forKey: key) { extra += " \(key)=\(String(describing: value).prefix(80))" }
        }
        log(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral) hidden=\(view.isHidden) wantsLayer=\(view.wantsLayer)\(extra)")
        for sub in view.subviews { dump(sub, depth: depth + 1) }
    }
}
#endif

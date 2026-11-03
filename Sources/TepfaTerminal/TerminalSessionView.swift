import AppKit
import SwiftTerm
import SwiftUI

/// A SwiftTerm terminal bound to a `TerminalSession`.
public struct TerminalSessionView: NSViewRepresentable {
    private let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    public func makeNSView(context: Context) -> TepfaTerminalView {
        var options = TerminalOptions.default
        options.scrollback = TerminalPreferences.scrollback
        let view = TepfaTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: nil, options: options)
        view.font = Self.preferredFont()
        view.terminalDelegate = context.coordinator
        view.onFocusChange = { [weak session] focused in
            if focused { session?.noteFocused() }
        }
        applyPreferences(to: view)
        context.coordinator.view = view
        session.attach(context.coordinator)
        session.attachedView = view
        return view
    }

    public func updateNSView(_ nsView: TepfaTerminalView, context: Context) {
        applyPreferences(to: nsView)
    }

    public static func dismantleNSView(_ nsView: TepfaTerminalView, coordinator: Coordinator) {
        coordinator.session.detach()
        if coordinator.session.attachedView === nsView {
            coordinator.session.attachedView = nil
        }
        nsView.terminalDelegate = nil
    }

    private func applyPreferences(to view: TepfaTerminalView) {
        view.copyOnSelect = TerminalPreferences.copyOnSelect
        view.warnOnMultiLinePaste = TerminalPreferences.warnOnMultiLinePaste
        let font = Self.preferredFont()
        if view.font != font {
            view.font = font
        }
    }

    static func preferredFont() -> NSFont {
        let size = CGFloat(TerminalPreferences.fontSize)
        if let name = TerminalPreferences.fontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @MainActor
    public final class Coordinator: NSObject, TerminalSink {
        let session: TerminalSession
        weak var view: TepfaTerminalView?

        init(session: TerminalSession) {
            self.session = session
        }

        public func feed(_ bytes: ArraySlice<UInt8>) {
            view?.feed(byteArray: bytes)
        }
    }
}

extension TerminalSessionView.Coordinator: @preconcurrency TerminalViewDelegate {
    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(cols: newCols, rows: newRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        session.updateTitle(title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        session.updateCurrentDirectory(directory)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        session.send(data)
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

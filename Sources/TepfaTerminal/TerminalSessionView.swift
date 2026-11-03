import AppKit
import SwiftTerm
import SwiftUI
import TepfaCore

/// A SwiftTerm terminal bound to a `TerminalSession`, drawn with a `TerminalAppearance`.
public struct TerminalSessionView: NSViewRepresentable {
    private let session: TerminalSession
    private let appearance: TerminalAppearance

    public init(session: TerminalSession, appearance: TerminalAppearance) {
        self.session = session
        self.appearance = appearance
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    public func makeNSView(context: Context) -> TepfaTerminalView {
        var options = TerminalOptions.default
        options.scrollback = TerminalPreferences.scrollback
        options.cursorStyle = appearance.swiftTermCursorStyle
        let view = TepfaTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: appearance.font(), options: options)
        view.terminalDelegate = context.coordinator
        view.onFocusChange = { [weak session] focused in
            if focused { session?.noteFocused() }
        }
        view.linkReporting = .implicit
        context.coordinator.view = view
        applyPreferences(to: view, coordinator: context.coordinator)
        session.attach(context.coordinator)
        session.attachedView = view
        return view
    }

    public func updateNSView(_ nsView: TepfaTerminalView, context: Context) {
        applyPreferences(to: nsView, coordinator: context.coordinator)
    }

    public static func dismantleNSView(_ nsView: TepfaTerminalView, coordinator: Coordinator) {
        coordinator.session.detach()
        if coordinator.session.attachedView === nsView {
            coordinator.session.attachedView = nil
        }
        nsView.terminalDelegate = nil
    }

    private func applyPreferences(to view: TepfaTerminalView, coordinator: Coordinator) {
        view.copyOnSelect = TerminalPreferences.copyOnSelect
        view.warnOnMultiLinePaste = TerminalPreferences.warnOnMultiLinePaste
        guard coordinator.applied != appearance else { return }
        let previous = coordinator.applied
        coordinator.applied = appearance

        if previous?.theme != appearance.theme || previous?.backgroundOpacity != appearance.backgroundOpacity {
            let theme = appearance.theme
            view.installColors(theme.ansi.map(TerminalAppearance.terminalColor))
            view.nativeForegroundColor = TerminalAppearance.nsColor(theme.foreground)
            view.nativeBackgroundColor = TerminalAppearance.nsColor(theme.background).withAlphaComponent(appearance.backgroundOpacity)
            view.caretColor = TerminalAppearance.nsColor(theme.cursor)
            view.caretTextColor = theme.cursorText.map(TerminalAppearance.nsColor)
            view.selectedTextBackgroundColor = TerminalAppearance.nsColor(theme.selection)
            if let selectionText = theme.selectionText {
                view.selectedTextForegroundColor = TerminalAppearance.nsColor(selectionText)
            }
            view.translucentCellBackgrounds = appearance.backgroundOpacity < 1
            view.linkColor = TerminalAppearance.nsColor(theme.ansi[12])
        }
        if previous?.fontName != appearance.fontName || previous?.fontSize != appearance.fontSize || previous?.ligatures != appearance.ligatures {
            view.font = appearance.font()
        }
        if previous?.lineHeight != appearance.lineHeight {
            view.lineSpacing = CGFloat(max(appearance.lineHeight, 0.8))
        }
        if previous?.cursorStyle != appearance.cursorStyle || previous?.cursorBlink != appearance.cursorBlink {
            view.setCursorStyle(appearance.swiftTermCursorStyle)
        }
        if previous?.antialias != appearance.antialias {
            view.fontSmoothing = appearance.antialias
        }
        if previous?.minimumContrast != appearance.minimumContrast {
            view.minimumContrastRatio = CGFloat(appearance.minimumContrast)
        }
        if previous?.linkNeedsModifier != appearance.linkNeedsModifier {
            view.linkHighlightMode = appearance.linkNeedsModifier ? .hoverWithModifier : .hover
        }
    }

    @MainActor
    public final class Coordinator: NSObject, TerminalSink {
        let session: TerminalSession
        weak var view: TepfaTerminalView?
        var applied: TerminalAppearance?

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

public extension TepfaTerminalView {
    /// Opens SwiftTerm's find bar (the same one ⌘F opens when the view has focus).
    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        performTextFinderAction(item)
    }

    func findNextMatch() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.nextMatch.rawValue
        performTextFinderAction(item)
    }

    func findPreviousMatch() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.previousMatch.rawValue
        performTextFinderAction(item)
    }
}

public extension Notification.Name {
    /// Posted by the Find menu item; the focused pane opens the find bar.
    static let tepfaFindInTerminal = Notification.Name("com.tepfasonic.findInTerminal")
}

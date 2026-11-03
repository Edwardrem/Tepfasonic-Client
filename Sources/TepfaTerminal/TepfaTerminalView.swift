import AppKit
import SwiftTerm

/// SwiftTerm view with focus reporting, copy-on-select and a multi-line paste warning.
public final class TepfaTerminalView: TerminalView {
    public var onFocusChange: ((Bool) -> Void)?
    public var copyOnSelect = false
    public var warnOnMultiLinePaste = true

    public override var hasFocus: Bool {
        didSet {
            if hasFocus != oldValue {
                onFocusChange?(hasFocus)
            }
        }
    }

    public nonisolated override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        let copy = { @MainActor in
            guard self.copyOnSelect, let text = self.getSelection(), !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { copy() }
        } else {
            DispatchQueue.main.async { copy() }
        }
    }

    public override func paste(_ sender: Any) {
        guard warnOnMultiLinePaste,
              let text = NSPasteboard.general.string(forType: .string),
              text.contains(where: \.isNewline) else {
            super.paste(sender)
            return
        }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let alert = NSAlert()
        alert.messageText = "Paste \(lines) lines?"
        alert.informativeText = "The clipboard holds several lines. Each line will run as soon as it is pasted.\n\n" + String(text.prefix(600)) + (text.count > 600 ? "…" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            super.paste(sender)
        }
    }
}

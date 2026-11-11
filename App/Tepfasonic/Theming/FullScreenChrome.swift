import AppKit
import SwiftUI

/// Full screen moves the toolbar into a window of its own, and on macOS 26 that
/// window paints grey glass behind the title and the buttons that no SwiftUI
/// modifier reaches, so scheme-coloured chrome shows dark blocks there. With
/// the scheme on, the toolbar is hidden in full screen and the columns draw
/// their own header rows with the same controls.
struct FullScreenToolbarSwitch: NSViewRepresentable {
    @Binding var isFullScreen: Bool
    let hidesToolbar: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { attach(view, coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { attach(nsView, coordinator) }
    }

    private func attach(_ view: NSView, _ coordinator: Coordinator) {
        guard let window = view.window else { return }
        coordinator.onChange = { isFullScreen = $0 }
        coordinator.hidesToolbar = hidesToolbar
        coordinator.attach(to: window)
    }

    @MainActor
    final class Coordinator {
        var hidesToolbar = false { didSet { if hidesToolbar != oldValue { apply() } } }
        var onChange: ((Bool) -> Void)?
        private weak var window: NSWindow?
        private var reported: Bool?
        // Tokens only; removed in deinit, which Swift 6 does not isolate.
        nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { apply(); return }
            self.window = window
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let event = note.name.rawValue
                    MainActor.assumeIsolated {
                        #if DEBUG
                        QADump.log("fullscreen-switch: \(event)")
                        #endif
                        self?.apply()
                    }
                }
            }
            apply()
        }

        private func apply() {
            guard let window else { return }
            let isFullScreen = window.styleMask.contains(.fullScreen)
            let toolbarVisible = !(isFullScreen && hidesToolbar)
            #if DEBUG
            QADump.log("fullscreen-switch: apply isFullScreen=\(isFullScreen) hidesToolbar=\(hidesToolbar) toolbar=\(window.toolbar != nil) visible=\(window.toolbar?.isVisible ?? false)")
            #endif
            if let toolbar = window.toolbar, toolbar.isVisible != toolbarVisible { toolbar.isVisible = toolbarVisible }
            if reported != isFullScreen {
                reported = isFullScreen
                onChange?(isFullScreen)
            }
        }
    }
}

enum FullScreenHeader {
    static let height: CGFloat = 48
}

/// The sidebar's top row in full screen: the toggle where the toolbar keeps it.
struct FullScreenSidebarHeader: View {
    let hideSidebar: () -> Void

    var body: some View {
        HStack {
            Spacer()
            HeaderPill {
                HeaderIconButton(systemImage: "sidebar.leading", help: "Hide Sidebar (⌃⌘S)", action: hideSidebar)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: FullScreenHeader.height)
    }
}

/// The detail column's top row in full screen: title and subtitle where the
/// window title was, the controls at the trailing edge as in the toolbar.
struct FullScreenDetailHeader<Controls: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    let subtitle: String
    let showsSidebarToggle: Bool
    let showSidebar: () -> Void
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: 12) {
            if showsSidebarToggle {
                HeaderPill {
                    HeaderIconButton(systemImage: "sidebar.leading", help: "Show Sidebar (⌃⌘S)", action: showSidebar)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            controls
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: FullScreenHeader.height)
    }
}

/// A capsule that groups header buttons the way the toolbar's glass does.
struct HeaderPill<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 3)
            .frame(height: 32)
            .background(Capsule().fill(palette.raised))
            .overlay(Capsule().strokeBorder(palette.separator, lineWidth: 0.5))
    }
}

struct HeaderIconButton: View {
    @Environment(\.palette) private var palette
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(palette.text)
        .help(help)
    }
}

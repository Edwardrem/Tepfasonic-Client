import SwiftUI
import TepfaTerminal

/// Tab bar, the selected tab's pane tree, and a status bar for the focused session.
struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage("ui.showTabBar") private var showTabBar = true
    @AppStorage("ui.showStatusBar") private var showStatusBar = true

    var body: some View {
        VStack(spacing: 0) {
            if showTabBar, !workspace.tabs.isEmpty {
                TabBarView()
                ChromeDivider()
            }
            if let tab = workspace.selectedTab {
                PaneNodeView(tabID: tab.id, node: tab.tree)
                    .id(tab.id)
            } else {
                EmptyWorkspaceView()
            }
            if showStatusBar, let session = workspace.focusedSession {
                ChromeDivider()
                SessionStatusBar(session: session)
            }
        }
        .panelChrome()
        .navigationTitle(workspace.selectedTab.map { workspace.title(of: $0) } ?? "Tepfasonic")
        .navigationSubtitle(workspace.focusedSession?.host.target ?? "")
    }
}

/// What the detail column shows before the first session: one tile, one line, the three keys that matter.
struct EmptyWorkspaceView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 14) {
            IconTile(systemImage: "terminal", color: palette.accent ?? .accentColor, size: 64)
                .padding(.bottom, 4)
            Text("No Open Sessions")
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("Double-click a host in the sidebar, or type user@host in the quick-connect field.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 16) {
                Keycap(keys: "⌘↩", label: "Connect")
                Keycap(keys: "⌘T", label: "New Tab")
                Keycap(keys: "⌘K", label: "Search")
                Keycap(keys: "⌘⇧A", label: "Claude")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    }
}

/// Recursively renders a pane tree.
struct PaneNodeView: View {
    let tabID: UUID
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let id, let sessionID):
            SessionPaneView(tabID: tabID, leafID: id, sessionID: sessionID)
        case .split(let id, let axis, let first, let second, let fraction):
            SplitPaneView(tabID: tabID, splitID: id, axis: axis, fraction: fraction) {
                PaneNodeView(tabID: tabID, node: first)
            } second: {
                PaneNodeView(tabID: tabID, node: second)
            }
        }
    }
}

/// Two children with a draggable divider.
struct SplitPaneView<First: View, Second: View>: View {
    let tabID: UUID
    let splitID: UUID
    let axis: SplitAxis
    let fraction: Double
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var dragStartFraction: Double?

    private let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let available = max(total - dividerThickness, 0)
            let firstLength = available * fraction
            let secondLength = available - firstLength

            if axis == .horizontal {
                HStack(spacing: 0) {
                    first().frame(width: firstLength)
                    divider(total: available)
                    second().frame(width: secondLength)
                }
            } else {
                VStack(spacing: 0) {
                    first().frame(height: firstLength)
                    divider(total: available)
                    second().frame(height: secondLength)
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(palette.separator)
            .frame(width: axis == .horizontal ? dividerThickness : nil, height: axis == .vertical ? dividerThickness : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartFraction == nil { dragStartFraction = fraction }
                        guard let start = dragStartFraction, total > 0 else { return }
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        workspace.setFraction(start + Double(delta / total), splitID: splitID, tabID: tabID)
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
    }
}

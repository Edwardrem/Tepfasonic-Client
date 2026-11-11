import SwiftUI
import TepfaTerminal

/// Pill-shaped tabs on the scheme's surface colour; the selected one is raised.
struct TabBarView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppState.self) private var appState
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabItemView(tab: tab, index: index)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            Button {
                appState.isShowingNewTabPicker = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Design.shape(Design.radiusSmall))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
            .help("New Tab (⌘T)")
            .popover(isPresented: Bindable(appState).isShowingNewTabPicker, arrowEdge: .bottom) {
                NewTabPickerView()
            }
        }
        .frame(height: 36)
        .background(palette.surface)
    }
}

struct TabItemView: View {
    let tab: Workspace.Tab
    let index: Int
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @AppStorage("ui.showColorStripes") private var showColorStripes = true
    @State private var hovering = false

    private var isSelected: Bool { workspace.selectedTabID == tab.id }

    var body: some View {
        let status = workspace.status(of: tab)
        HStack(spacing: 6) {
            if showColorStripes, let color = HostColor.color(workspace.colorLabel(of: tab)) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: 12)
            }
            Circle()
                .fill(statusColor(status))
                .frame(width: 6, height: 6)
            if workspace.isAgentTab(tab) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(palette.accent ?? .accentColor)
                    .help("Agent log: commands Claude runs on this host")
            }
            Text(workspace.title(of: tab))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.callout.weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? palette.text : palette.secondaryText)
            if hovering || isSelected {
                Button {
                    workspace.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close Tab")
            } else {
                Spacer().frame(width: 16)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(minWidth: 110, maxWidth: 220)
        .frame(maxHeight: .infinity)
        .background(isSelected ? AnyShapeStyle(palette.raised) : (hovering ? AnyShapeStyle(palette.raised.opacity(0.55)) : AnyShapeStyle(.clear)), in: Design.shape(Design.radiusSmall))
        .overlay {
            if isSelected {
                Design.shape(Design.radiusSmall).strokeBorder(palette.separator, lineWidth: 0.5)
            }
        }
        .contentShape(Design.shape(Design.radiusSmall))
        .onHover { hovering = $0 }
        .onTapGesture { workspace.select(tabID: tab.id) }
        .contextMenu {
            Button("Close Tab") { workspace.closeTab(id: tab.id) }
            Button("Close Other Tabs") { workspace.closeOtherTabs(keeping: tab.id) }
                .disabled(workspace.tabs.count < 2)
        }
        .help("\(workspace.title(of: tab)) (⌘\(index + 1))")
    }

    private func statusColor(_ status: Workspace.TabStatus) -> Color {
        switch status {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

import SwiftUI
import TepfaTerminal

struct TabBarView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabItemView(tab: tab, index: index)
                    }
                }
            }
            Button {
                appState.isShowingNewTabPicker = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .help("New Tab (⌘T)")
            .popover(isPresented: Bindable(appState).isShowingNewTabPicker, arrowEdge: .bottom) {
                NewTabPickerView()
            }
        }
        .frame(height: 34)
        .background(.bar)
    }
}

struct TabItemView: View {
    let tab: Workspace.Tab
    let index: Int
    @Environment(Workspace.self) private var workspace
    @State private var hovering = false

    private var isSelected: Bool { workspace.selectedTabID == tab.id }

    var body: some View {
        let status = workspace.status(of: tab)
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 7, height: 7)
            if workspace.isAgentTab(tab) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("Agent log: commands Claude runs on this host")
            }
            Text(workspace.title(of: tab))
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.callout)
            if hovering || isSelected {
                Button {
                    workspace.closeTab(id: tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close Tab")
            } else {
                Spacer().frame(width: 12)
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 120, maxWidth: 220)
        .frame(maxHeight: .infinity)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        .overlay(alignment: .top) {
            if let color = HostColor.color(workspace.colorLabel(of: tab)) {
                Rectangle().fill(color).frame(height: 3)
            }
        }
        .contentShape(Rectangle())
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

import AppKit
import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal
import UniformTypeIdentifiers

/// One pane of the Files window: source picker, path bar, file table, drag and drop.
struct FileBrowserPane: View {
    @Bindable var model: SFTPWindowModel
    let side: SFTPWindowModel.Side
    let hosts: [SSHHost]
    let present: (SFTPWindowContentSheet) -> Void
    @State private var pathDraft = ""
    @State private var isDropTarget = false

    private var pane: PaneModel { model.pane(side) }
    private var isFocused: Bool { model.focusedSide == side }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pathBar
            Divider()
            ZStack {
                table
                if pane.isLoading {
                    ProgressView().controlSize(.small).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = pane.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).multilineTextAlignment(.center).font(.callout).textSelection(.enabled).frame(maxWidth: 360)
                        Button("Try Again") { Task { await pane.refresh() } }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .overlay {
                if isDropTarget {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false)
                }
            }
            .onDrop(of: [.plainText, .fileURL], isTargeted: $isDropTarget) { providers in
                handleDrop(providers, intoFolder: nil)
            }
        }
        .overlay {
            if isFocused {
                Rectangle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1).allowsHitTesting(false)
            }
        }
        .onTapGesture { model.focusedSide = side }
        .onChange(of: pane.path, initial: true) { _, path in pathDraft = path }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button("This Mac") { model.showLocal(in: side) }
                Divider()
                ForEach(hosts) { host in
                    Button(host.name) { Task { await model.showHost(host.uuid, in: side) } }
                }
            } label: {
                Label(pane.title, systemImage: pane.source.isRemote ? "server.rack" : "desktopcomputer")
            }
            .fixedSize()
            Spacer()
            Toggle("Hidden", isOn: Bindable(pane).showHidden).toggleStyle(.checkbox).controlSize(.small)
            Picker("Sort", selection: Bindable(pane).sortKey) {
                Text("Name").tag(PaneModel.SortKey.name)
                Text("Size").tag(PaneModel.SortKey.size)
                Text("Modified").tag(PaneModel.SortKey.modified)
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var pathBar: some View {
        HStack(spacing: 4) {
            Button { Task { await pane.goBack() } } label: { Image(systemName: "chevron.left") }.help("Back")
            Button { Task { await pane.goUp() } } label: { Image(systemName: "arrow.up") }.help("Enclosing folder")
            Button { Task { await pane.goHome() } } label: { Image(systemName: "house") }.help("Home")
            TextField("Path", text: $pathDraft)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { Task { await pane.load(pathDraft) } }
            if !pane.source.isRemote {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: pane.path)
                    if panel.runModal() == .OK, let url = panel.url { Task { await pane.load(url.path) } }
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose a folder")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var table: some View {
        Table(pane.visibleItems, selection: Bindable(pane).selection) {
            TableColumn("Name") { item in
                HStack(spacing: 6) {
                    Image(systemName: item.icon).foregroundStyle(item.isDirectory ? Color.accentColor : .secondary)
                    Text(item.name).lineLimit(1)
                }
                .onDrag { NSItemProvider(object: DragPayload(paneID: pane.id, paths: dragPaths(for: item)).encoded as NSString) }
                .onDrop(of: [.plainText, .fileURL], isTargeted: nil) { providers in
                    item.isDirectory ? handleDrop(providers, intoFolder: item.path) : false
                }
            }
            .width(min: 160)
            TableColumn("Size") { item in
                Text(item.sizeDescription).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(80)
            TableColumn("Modified") { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "").foregroundStyle(.secondary)
            }
            .width(150)
            TableColumn("Mode") { item in
                Text(item.modeString).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("Owner") { item in
                Text(item.owner ?? "").font(.caption).foregroundStyle(.secondary)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            guard let first = ids.first, let item = pane.items.first(where: { $0.path == first }) else { return }
            if item.isDirectory {
                Task { await pane.open(item) }
            } else if case .remote(let hostID) = pane.source {
                Task { await model.openWith.open(hostID: hostID, remotePath: item.path, chooseApplication: false) }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
        }
        .onChange(of: pane.selection) { _, _ in model.focusedSide = side }
    }

    private func dragPaths(for item: FileItem) -> [String] {
        pane.selection.contains(item.path) ? Array(pane.selection) : [item.path]
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let items = pane.items.filter { ids.contains($0.path) }
        if items.isEmpty {
            Button("New Folder…") { present(.newFolder(side)) }
            Button("Refresh") { Task { await pane.refresh() } }
        } else {
            Button(model.otherPane.source.isRemote ? "Copy to \(model.otherPane.title)" : "Download to \(model.otherPane.title)") {
                Task { await model.transfer(items, from: pane, to: model.otherPane) }
            }
            if items.count == 1, let item = items.first, !item.isDirectory {
                if case .remote(let hostID) = pane.source {
                    Button("Open") { Task { await model.openWith.open(hostID: hostID, remotePath: item.path, chooseApplication: false) } }
                    Button("Open With…") { Task { await model.openWith.open(hostID: hostID, remotePath: item.path, chooseApplication: true) } }
                } else {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                }
            }
            Divider()
            if items.count == 1, let item = items.first {
                Button("Rename…") { present(.rename(side, item)) }
            }
            Button("Permissions…") { present(.permissions(side, items)) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { Task { await pane.delete(items) } }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], intoFolder folder: String?) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                    let text = (data as? String) ?? (data as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    guard let payload = DragPayload.decode(text) else { return }
                    Task { @MainActor in
                        let source = payload.paneID == model.left.id ? model.left : model.right
                        guard source.id != pane.id || folder != nil else { return }
                        let items = source.items.filter { payload.paths.contains($0.path) }
                        await model.transfer(items, from: source, to: pane, intoFolder: folder)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), pane.source.isRemote {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in await model.upload(urls: [url], to: pane, intoFolder: folder) }
                }
            }
        }
        return handled
    }
}

typealias SFTPWindowContentSheet = SFTPWindowContent.PaneSheet

import SwiftData
import SwiftUI
import TepfaCore

struct SnippetEditorView: View {
    let target: AppState.SnippetEditorTarget

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SnippetFolder.sortOrder), SortDescriptor(\SnippetFolder.name)]) private var folders: [SnippetFolder]

    @State private var name = ""
    @State private var command = ""
    @State private var folderID: UUID?
    @State private var tagsText = ""
    @State private var notes = ""

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    private var variables: [SnippetVariables.Variable] { SnippetVariables.variables(in: command) }

    private var isValid: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(firstLine(of: command).isEmpty ? "Optional" : firstLine(of: command)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                        TextEditor(text: $command)
                            .font(.body.monospaced())
                            .frame(minHeight: 90, maxHeight: 200)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                    }
                    if variables.isEmpty {
                        Text("Use {{name}} or {{name:default}} for values to fill in when the snippet runs. Several lines run one after the other.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Asks for: " + variables.map { variable in
                            variable.defaultValue.map { "\(variable.name) (default \($0))" } ?? variable.name
                        }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Organisation") {
                    Picker("Folder", selection: $folderID) {
                        Text("None").tag(UUID?.none)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(Optional(folder.uuid))
                        }
                    }
                    TextField("Tags", text: $tagsText, prompt: Text("comma, separated"))
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .formStyle(.grouped)
            .themedForm()
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "Save" : "Add Snippet") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
        .onAppear(perform: load)
    }

    private func firstLine(of text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func load() {
        switch target {
        case .create(let folder, let prefill):
            folderID = folder?.uuid
            command = prefill ?? ""
        case .edit(let snippet):
            name = snippet.name
            command = snippet.command
            folderID = snippet.folder?.uuid
            tagsText = snippet.tags.joined(separator: ", ")
            notes = snippet.notes
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmedName.isEmpty ? String(firstLine(of: command).prefix(60)) : trimmedName
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let folder = folders.first { $0.uuid == folderID }
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .create:
            let count = (try? modelContext.fetchCount(FetchDescriptor<Snippet>())) ?? 0
            modelContext.insert(Snippet(name: finalName, command: trimmedCommand, tags: tags, notes: notes, sortOrder: count, folder: folder))
        case .edit(let snippet):
            snippet.name = finalName
            snippet.command = trimmedCommand
            snippet.tags = tags
            snippet.notes = notes
            snippet.folder = folder
        }
        try? modelContext.save()
        dismiss()
    }
}

/// Creates or renames a snippet folder.
struct SnippetFolderSheet: View {
    let folder: SnippetFolder?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var name = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(folder == nil ? "New Folder" : "Rename Folder").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(folder == nil ? "Create" : "Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { name = folder?.name ?? "" }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let folder {
            folder.name = trimmed
        } else {
            let count = (try? modelContext.fetchCount(FetchDescriptor<SnippetFolder>())) ?? 0
            modelContext.insert(SnippetFolder(name: trimmed, sortOrder: count))
        }
        try? modelContext.save()
        dismiss()
    }
}

import SwiftData
import SwiftUI
import TepfaCore

struct GroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var groups: [HostGroup]
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Group")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("Production, Home lab, …"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Group") {
                    let group = HostGroup(name: name.trimmingCharacters(in: .whitespaces), sortOrder: groups.count)
                    modelContext.insert(group)
                    try? modelContext.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

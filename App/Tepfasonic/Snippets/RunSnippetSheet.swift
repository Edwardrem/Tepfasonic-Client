import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// Asks for `{{variable}}` values and runs the snippet on its target.
struct RunSnippetSheet: View {
    let run: AppState.SnippetRun

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(Workspace.self) private var workspace
    @State private var values: [String: String] = [:]
    @FocusState private var focusedVariable: String?

    private var variables: [SnippetVariables.Variable] { run.snippet.variables }

    private var resolvedCommand: String {
        SnippetVariables.substitute(run.snippet.command, values: values)
    }

    private var isComplete: Bool {
        variables.allSatisfy { variable in
            !(values[variable.name] ?? variable.defaultValue ?? "").isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    ForEach(variables) { variable in
                        TextField(variable.name, text: binding(for: variable), prompt: variable.defaultValue.map(Text.init))
                            .focused($focusedVariable, equals: variable.name)
                            .onSubmit { if isComplete { runNow() } }
                    }
                } header: {
                    Text("Run \(run.snippet.name) on \(run.target.title(in: modelContext))")
                }
                Section("Command") {
                    Text(resolvedCommand)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run") { runNow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isComplete)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear { focusedVariable = variables.first?.name }
    }

    private func binding(for variable: SnippetVariables.Variable) -> Binding<String> {
        Binding(
            get: { values[variable.name] ?? "" },
            set: { values[variable.name] = $0 })
    }

    private func runNow() {
        var filled = values
        for variable in variables where (filled[variable.name] ?? "").isEmpty {
            filled[variable.name] = variable.defaultValue ?? ""
        }
        let command = SnippetVariables.substitute(run.snippet.command, values: filled)
        if SnippetRunner.run(command, on: run.target, workspace: workspace, context: modelContext) {
            run.snippet.noteUsed()
        }
        dismiss()
    }
}

import SwiftData
import SwiftUI
import TepfaCore
import TepfaTerminal

/// The "Identities & Keys" window: every reusable login on the left, its details on the right.
struct IdentitiesView: View {
    static let windowID = "identities"

    enum Sheet: Identifiable {
        case generate
        case importKey
        case newPassword

        var id: Self { self }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Identity.name) private var identities: [Identity]
    @State private var selection: UUID?
    @State private var sheet: Sheet?
    @State private var pendingDelete: Identity?

    private var selected: Identity? {
        identities.first { $0.uuid == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(identities) { identity in
                    IdentityRow(identity: identity)
                        .tag(identity.uuid)
                        .contextMenu {
                            Button("Delete…", role: .destructive) { pendingDelete = identity }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .overlay {
                if identities.isEmpty {
                    ContentUnavailableView {
                        Label("No Identities", systemImage: "person.badge.key")
                    } description: {
                        Text("Generate a key, import one, or save a password to reuse across hosts.")
                    }
                }
            }
        } detail: {
            if let selected {
                IdentityDetailView(identity: selected, onDelete: { pendingDelete = selected })
                    .id(selected.uuid)
            } else {
                ContentUnavailableView("Select an identity", systemImage: "person.badge.key")
            }
        }
        .navigationTitle("Identities & Keys")
        .onAppear { if selection == nil { selection = identities.first?.uuid } }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { sheet = .generate } label: { Label("Generate Key…", systemImage: "key.fill") }
                    Button { sheet = .importKey } label: { Label("Import Key…", systemImage: "square.and.arrow.down") }
                    Divider()
                    Button { sheet = .newPassword } label: { Label("Password Identity…", systemImage: "key.horizontal") }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New identity")
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .generate: GenerateKeySheet { selection = $0.uuid }
            case .importKey: ImportKeySheet { selection = $0.uuid }
            case .newPassword: NewPasswordIdentitySheet { selection = $0.uuid }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Identity", role: .destructive) {
                if let identity = pendingDelete {
                    if selection == identity.uuid { selection = nil }
                    IdentityOperations.delete(identity, in: modelContext)
                }
                pendingDelete = nil
            }
        } message: {
            if let identity = pendingDelete {
                Text(deleteMessage(for: identity))
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private func deleteMessage(for identity: Identity) -> String {
        var parts: [String] = []
        switch identity.credentialKind {
        case .password: parts.append("The saved password is removed from the Keychain.")
        case .keychainKey: parts.append("The private key is removed from the Keychain and cannot be recovered unless you exported it.")
        case .keyFile: parts.append("The key file on disk is left untouched; only the saved passphrase is removed.")
        }
        if !identity.hosts.isEmpty {
            parts.append("\(identity.hosts.count) host(s) use this identity and will ask for credentials next time.")
        }
        return parts.joined(separator: " ")
    }
}

struct IdentityRow: View {
    let identity: Identity

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: identity.credentialKind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !identity.username.isEmpty { parts.append(identity.username) }
        parts.append(identity.keyType ?? identity.credentialKind.displayName)
        return parts.joined(separator: " · ")
    }
}

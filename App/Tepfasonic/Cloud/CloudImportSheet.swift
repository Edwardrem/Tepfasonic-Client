import AppKit
import SwiftData
import SwiftUI
import TepfaCore

/// Lists instances at a cloud provider and adds the chosen ones as hosts
/// through the reviewed import.
struct CloudImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @State private var provider: CloudProviderKind = .aws
    @State private var instances: [CloudInstance] = []
    @State private var selection: Set<String> = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var groupName = ""
    @State private var preferPrivateIP = false
    @State private var username = ""
    @State private var onlyRunning = true

    private var hasCredentials: Bool {
        CloudCredentials.load(provider)?.isComplete ?? false
    }

    private var shown: [CloudInstance] {
        onlyRunning ? instances.filter(\.isRunning) : instances
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Provider", selection: $provider) {
                    ForEach(CloudProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .fixedSize()
                Button("Refresh") { Task { await load() } }
                    .disabled(isLoading || !hasCredentials)
                Toggle("Running only", isOn: $onlyRunning)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }
            .padding()
            Divider()
            if !hasCredentials {
                ContentUnavailableView {
                    Label("No \(provider.displayName) credentials", systemImage: "key")
                } description: {
                    Text(provider.credentialHint + " Add them in Settings → Cloud; they are stored in the Keychain and only used to list instances.")
                } actions: {
                    Button("Open Settings") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Could not list instances", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                Table(shown, selection: $selection) {
                    TableColumn("Name") { instance in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(instance.name)
                            Text(instance.instanceID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    TableColumn("Region", value: \.region).width(110)
                    TableColumn("Public IP") { Text($0.publicIP ?? "—").monospaced() }.width(130)
                    TableColumn("Private IP") { Text($0.privateIP ?? "—").monospaced() }.width(130)
                    TableColumn("State") { instance in
                        Text(instance.state).foregroundStyle(instance.isRunning ? .green : .secondary)
                    }
                    .width(90)
                    TableColumn("Tags") { instance in
                        Text(instance.tags.filter { $0.key != "Name" }.map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")).font(.caption).lineLimit(1)
                    }
                }
                .overlay {
                    if instances.isEmpty, !isLoading {
                        ContentUnavailableView("No instances", systemImage: "cloud", description: Text("Nothing was returned for this account."))
                    }
                }
            }
            Divider()
            HStack {
                TextField("Group", text: $groupName, prompt: Text(provider.displayName))
                    .frame(width: 150)
                TextField("Username", text: $username, prompt: Text("guessed from the image"))
                    .frame(width: 180)
                Toggle("Use private IPs", isOn: $preferPrivateIP)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(selection.count) Host\(selection.count == 1 ? "" : "s")…") { importSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
            .padding()
        }
        .frame(width: 860, height: 520)
        .task { if hasCredentials { await load() } }
        .onChange(of: provider) { _, _ in
            instances = []
            selection = []
            error = nil
            if hasCredentials { Task { await load() } }
        }
    }

    private func load() async {
        guard let credentials = CloudCredentials.load(provider) else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            instances = try await CloudProviders.provider(for: provider).listInstances(credentials: credentials)
            selection = Set(instances.filter(\.isRunning).map(\.id))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importSelected() {
        let chosen = shown.filter { selection.contains($0.id) }
        let document = CloudInstance.document(
            from: chosen,
            groupName: groupName.trimmingCharacters(in: .whitespaces).isEmpty ? provider.displayName : groupName,
            preferPrivateIP: preferPrivateIP,
            usernameOverride: username.trimmingCharacters(in: .whitespaces))
        dismiss()
        Task {
            appState.importFlow = await ImportFlow.open(document: document, source: provider.displayName, context: modelContext)
        }
    }
}

/// Settings → Cloud: credentials for each provider, stored in the Keychain.
struct CloudSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var provider: CloudProviderKind = .aws
    @State private var credentials = CloudCredentials(provider: .aws)
    @State private var regionsText = ""
    @State private var message: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $provider) {
                    ForEach(CloudProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                Text(provider.credentialHint).font(.caption).foregroundStyle(.secondary)
            }
            Section("Credentials") {
                switch provider {
                case .aws:
                    TextField("Access key ID", text: $credentials.keyID).font(.body.monospaced())
                    SecureField("Secret access key", text: $credentials.secret)
                    SecureField("Session token (optional)", text: $credentials.tenantID)
                    TextField("Regions", text: $regionsText, prompt: Text("us-east-1, eu-west-1 (empty lists the common ones)"))
                case .digitalOcean:
                    SecureField("Personal access token", text: $credentials.keyID)
                case .azure:
                    TextField("Tenant ID", text: $credentials.tenantID).font(.body.monospaced())
                    TextField("Client ID", text: $credentials.keyID).font(.body.monospaced())
                    SecureField("Client secret", text: $credentials.secret)
                    TextField("Subscription ID", text: $credentials.subscriptionID).font(.body.monospaced())
                }
                HStack {
                    Button("Save") { save() }
                    Button("Test") { Task { await test() } }.disabled(isTesting)
                    Button("Remove") { remove() }
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Credentials stay in your login Keychain and are only sent to the provider's API to list instances (read-only). Import hosts with File → Import From → Cloud Provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Import Instances…") { appState.isShowingCloudImport = true }
            }
        }
        .formStyle(.grouped)
        .themedForm()
        .padding(.bottom)
        .onAppear(perform: load)
        .onChange(of: provider) { _, _ in load() }
    }

    private func load() {
        credentials = CloudCredentials.load(provider) ?? CloudCredentials(provider: provider)
        regionsText = credentials.regions.joined(separator: ", ")
        message = nil
    }

    private func save() {
        credentials.provider = provider
        credentials.regions = regionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try credentials.save()
            message = "Saved in the Keychain."
        } catch {
            message = error.localizedDescription
        }
    }

    private func test() async {
        save()
        isTesting = true
        defer { isTesting = false }
        do {
            let instances = try await CloudProviders.provider(for: provider).listInstances(credentials: credentials)
            message = "OK: \(instances.count) instance(s) found."
        } catch {
            message = error.localizedDescription
        }
    }

    private func remove() {
        CloudCredentials.remove(provider)
        credentials = CloudCredentials(provider: provider)
        regionsText = ""
        message = "Removed."
    }
}

import AppKit
import Observation
import SwiftData
import SwiftUI
import TepfaCore

/// One import from start to finish: decode (asking for a passphrase when
/// needed), review, apply, report.
@MainActor
@Observable
final class ImportFlow: Identifiable {
    enum Stage {
        case passphrase(attemptFailed: Bool)
        case review(ImportPlan)
        case applying
        case done(ImportPlan.Result)
        case failed(String)
    }

    let id = UUID()
    let source: String
    private(set) var stage: Stage
    private let data: Data?
    private let context: ModelContext
    private let knownHosts: [KnownHostEntry]

    /// A `.tepfa` file.
    init(data: Data, source: String, context: ModelContext, knownHosts: [KnownHostEntry]) {
        self.data = data
        self.source = source
        self.context = context
        self.knownHosts = knownHosts
        if TepfaFile.isEncrypted(data) {
            stage = .passphrase(attemptFailed: false)
        } else {
            stage = .failed("")
            decode(passphrase: nil)
        }
    }

    /// A document built from another program's configuration.
    init(document: TepfaDocument, source: String, context: ModelContext, knownHosts: [KnownHostEntry]) {
        self.data = nil
        self.context = context
        self.source = source
        self.knownHosts = knownHosts
        stage = .failed("")
        review(document)
    }

    static func open(url: URL, context: ModelContext) async -> ImportFlow {
        let known = await KnownHostsStore.shared.allEntries()
        do {
            let data = try Data(contentsOf: url)
            return ImportFlow(data: data, source: url.lastPathComponent, context: context, knownHosts: known)
        } catch {
            let flow = ImportFlow(document: TepfaDocument(), source: url.lastPathComponent, context: context, knownHosts: known)
            flow.stage = .failed(error.localizedDescription)
            return flow
        }
    }

    static func open(document: TepfaDocument, source: String, context: ModelContext) async -> ImportFlow {
        ImportFlow(document: document, source: source, context: context, knownHosts: await KnownHostsStore.shared.allEntries())
    }

    func submitPassphrase(_ passphrase: String) {
        decode(passphrase: passphrase)
    }

    private func decode(passphrase: String?) {
        guard let data else { return }
        do {
            review(try TepfaFile.decode(data, passphrase: passphrase))
        } catch TepfaFile.Error.wrongPassphrase {
            stage = .passphrase(attemptFailed: true)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func review(_ document: TepfaDocument) {
        guard !document.isEmpty else {
            stage = .failed("Nothing to import: the file holds no hosts, identities, snippets, rules, themes, serial profiles or known hosts.")
            return
        }
        do {
            stage = .review(try ImportPlan(document: document, context: context, knownHosts: knownHosts))
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    func update(_ plan: ImportPlan) {
        stage = .review(plan)
    }

    func fail(_ message: String) {
        stage = .failed(message)
    }

    func apply(_ plan: ImportPlan) async {
        stage = .applying
        do {
            // Snapshot the current data first so the import can be undone.
            let before = try await ExportBuilder.document(from: context, knownHosts: knownHosts, options: ExportBuilder.Options(), appVersion: UpdateManager.currentShortVersion)
            if !before.isEmpty {
                try? Backups.store(try TepfaFile.encode(before, passphrase: nil), label: "before-import")
            }
            let result = try await plan.apply(to: context, knownHosts: KnownHostsStore.shared, secretWriter: { identity, secrets in
                try ExportSecrets.write(secrets, for: identity)
            }, proxyPasswordWriter: { ownerID, password in
                try ExportSecrets.writeProxyPassword(password, ownerID: ownerID)
            })
            stage = .done(result)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}

/// Hosts the stages of an `ImportFlow`.
struct ImportSheet: View {
    @Bindable var flow: ImportFlow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch flow.stage {
        case .passphrase(let attemptFailed):
            ImportPassphraseView(source: flow.source, attemptFailed: attemptFailed) { passphrase in
                if let passphrase { flow.submitPassphrase(passphrase) } else { dismiss() }
            }
        case .review(let plan):
            ImportReviewView(flow: flow, plan: plan)
        case .applying:
            VStack(spacing: 12) {
                ProgressView("Importing…")
            }
            .padding(40)
            .frame(width: 420)
        case .done(let result):
            ImportResultView(source: flow.source, result: result) { dismiss() }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 14) {
                Label("Import failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(message.isEmpty ? "The file could not be read." : message)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }
}

struct ImportPassphraseView: View {
    let source: String
    let attemptFailed: Bool
    let respond: (String?) -> Void
    @State private var passphrase = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Passphrase for \(source)", systemImage: "lock.doc")
                .font(.title3.weight(.semibold))
            if attemptFailed {
                Label("The passphrase was not accepted. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Text("This export is encrypted. Enter the passphrase it was exported with.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if !passphrase.isEmpty { respond(passphrase) } }
            HStack {
                Button("Cancel") { respond(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Unlock") { respond(passphrase) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

struct ImportReviewView: View {
    let flow: ImportFlow
    @State var plan: ImportPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from \(flow.source)").font(.title3.weight(.semibold))
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            List {
                ForEach(plan.kinds) { kind in
                    Section(kind.title) {
                        ForEach(orderedItems(of: kind)) { item in
                            row(item)
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack(spacing: 10) {
                Menu("All New") {
                    Button("Import") { plan.setImported(true, status: .new); flow.update(plan) }
                    Button("Skip") { plan.setImported(false, status: .new); flow.update(plan) }
                }
                .fixedSize()
                .disabled(plan.count(.new) == 0)
                Menu("All Changed") {
                    Button("Replace") { plan.setImported(true, status: .changed); flow.update(plan) }
                    Button("Skip") { plan.setImported(false, status: .changed); flow.update(plan) }
                }
                .fixedSize()
                .disabled(plan.count(.changed) == 0)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(plan.importedCount) Records") { Task { await flow.apply(plan) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.importedCount == 0)
            }
            .padding()
        }
        .frame(width: 640, height: 520)
    }

    /// Changed and new records first; identical ones (already present) last.
    private func orderedItems(of kind: ImportPlan.Kind) -> [ImportPlan.Item] {
        func rank(_ status: ImportPlan.Status) -> Int {
            switch status {
            case .changed: 0
            case .new: 1
            case .identical: 2
            }
        }
        return plan.items(of: kind).enumerated().sorted {
            (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset)
        }.map(\.element)
    }

    private var summary: String {
        var parts: [String] = []
        if plan.count(.new) > 0 { parts.append("\(plan.count(.new)) new") }
        if plan.count(.changed) > 0 { parts.append("\(plan.count(.changed)) changed") }
        if plan.count(.identical) > 0 { parts.append("\(plan.count(.identical)) identical (skipped)") }
        return parts.isEmpty ? "Nothing to import." : parts.joined(separator: " · ") + ". A backup of the current data is kept before importing."
    }

    private func row(_ item: ImportPlan.Item) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { item.isImported },
                set: { on in
                    plan.setAction(on ? (item.status == .new ? .add : .replace) : .skip, for: item.id)
                    flow.update(plan)
                }))
            .labelsHidden()
            .disabled(item.status == .identical)
            statusBadge(item.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.status == .changed, !item.changes.isEmpty {
                    Text("Changes: " + item.changes.joined(separator: ", ")).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer()
        }
        .opacity(item.status == .identical ? 0.55 : 1)
    }

    private func statusBadge(_ status: ImportPlan.Status) -> some View {
        let (text, color): (String, Color) = switch status {
        case .new: ("New", .green)
        case .changed: ("Changed", .orange)
        case .identical: ("Same", .secondary)
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .frame(width: 64)
    }
}

struct ImportResultView: View {
    let source: String
    let result: ImportPlan.Result
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Imported from \(source)", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(result.added) added, \(result.replaced) replaced, \(result.skipped) skipped.")
                if result.knownHostsAdded > 0 { Text("\(result.knownHostsAdded) host keys trusted.") }
                if result.secretsStored > 0 { Text("\(result.secretsStored) secrets stored in the Keychain.") }
                if result.proxyPasswordsStored > 0 { Text("\(result.proxyPasswordsStored) proxy passwords stored in the Keychain.") }
                if result.keysMovedToKeychain > 0 {
                    Text("\(result.keysMovedToKeychain) key files were not found on this Mac; their keys now live in the Keychain.")
                }
                Text("A backup of the previous data is in Settings → Data.").foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

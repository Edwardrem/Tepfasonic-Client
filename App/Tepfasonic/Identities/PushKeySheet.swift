import SwiftData
import SwiftUI
import TepfaCore
import TepfaSSH
import TepfaTerminal

/// ssh-copy-id: appends the identity's public key to a host's authorized_keys.
struct PushKeySheet: View {
    let identity: Identity

    enum Phase: Equatable {
        case form
        case running
        case done(String)
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SSHHost.name) private var hosts: [SSHHost]
    @State private var hostID: UUID?
    @State private var password = ""
    @State private var passphrase = ""
    @State private var phase: Phase = .form
    @State private var pendingHostKey: (HostKeyInfo, changed: Bool)?
    @State private var passphraseContinuation: CheckedContinuation<SecretAnswer?, Never>?
    @State private var needsPassphrase = false

    private var host: SSHHost? { hosts.first { $0.uuid == hostID } }
    private var descriptor: HostDescriptor? { host.map(HostDescriptor.init) }

    private var usesSavedCredentials: Bool {
        guard let descriptor else { return false }
        if let identity = descriptor.identity {
            return identity.kind != .password || IdentityOperations.store.hasStoredPassword(for: descriptor)
        }
        return IdentityOperations.store.hasStoredPassword(for: descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Push “\(identity.name)” to a Server").font(.title3.weight(.semibold))
            Text("Connects with the host's current credentials and appends the public key to ~/.ssh/authorized_keys, like ssh-copy-id.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Host", selection: $hostID) {
                Text("Choose a host").tag(UUID?.none)
                ForEach(hosts) { host in
                    Text("\(host.name) (\(host.displayTarget))").tag(Optional(host.uuid))
                }
            }

            if let descriptor {
                LabeledContent("Log in as", value: descriptor.target)
                if usesSavedCredentials {
                    Text("Using the host's saved credentials.").font(.caption).foregroundStyle(.secondary)
                } else {
                    SecureField("Password for \(descriptor.loginUsername)", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if needsPassphrase {
                HStack {
                    SecureField("Passphrase for the host's key", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                    Button("Unlock") { answerPassphrase(SecretAnswer(secret: passphrase)) }
                        .disabled(passphrase.isEmpty)
                }
            }

            if let (key, changed) = pendingHostKey {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(changed ? "Host key has CHANGED" : "Unknown host key", systemImage: changed ? "exclamationmark.triangle.fill" : "key.fill")
                            .foregroundStyle(changed ? .orange : .primary)
                        Text("\(key.keyType) \(key.fingerprintSHA256)").font(.caption.monospaced()).textSelection(.enabled)
                        Button(changed ? "Trust the new key and push" : "Trust and push") { Task { await push(trust: true) } }
                    }
                }
            }

            switch phase {
            case .form:
                EmptyView()
            case .running:
                HStack { ProgressView().controlSize(.small); Text("Pushing…").foregroundStyle(.secondary) }
            case .done(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(phase == .done("") ? "Done" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Push") { Task { await push(trust: false) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(descriptor == nil || phase == .running || (!usesSavedCredentials && password.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func answerPassphrase(_ answer: SecretAnswer?) {
        needsPassphrase = false
        passphraseContinuation?.resume(returning: answer)
        passphraseContinuation = nil
    }

    private func push(trust: Bool) async {
        guard let descriptor, let publicKey = identity.publicKey else { return }
        phase = .running
        pendingHostKey = nil
        let typedPassword = password
        let resolver = CredentialResolver(
            store: IdentityOperations.store,
            askPassword: { _ in typedPassword.isEmpty ? nil : SecretAnswer(secret: typedPassword) },
            askPassphrase: { _, _ in
                await withCheckedContinuation { continuation in
                    passphraseContinuation = continuation
                    needsPassphrase = true
                }
            })
        do {
            let resolution = try await resolver.resolve(for: descriptor)
            let outcome = try await KeyPusher.push(publicKey: publicKey, to: descriptor, credentials: resolution.credentials, trustHostKey: trust)
            switch outcome {
            case .added: phase = .done("Key added to \(descriptor.target).")
            case .alreadyPresent: phase = .done("The key was already authorized on \(descriptor.target).")
            }
        } catch KeyPusher.PushError.unknownHostKey(let key, let changed) {
            pendingHostKey = (key, changed)
            phase = .form
        } catch CredentialResolver.Failure.cancelled {
            phase = .failed("Cancelled.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

import SwiftUI
import TepfaCore
import TepfaTerminal

struct SecuritySettingsView: View {
    @AppStorage(Vault.requireAuthenticationKey) private var requireAuthentication = true
    @AppStorage(Vault.autoLockMinutesKey) private var autoLockMinutes = 15
    @AppStorage(Vault.lockOnSleepKey) private var lockOnSleep = true
    @State private var secretCount: Int?
    @State private var isClearing = false
    @State private var message: String?

    private var vault: Vault { Vault.shared }

    var body: some View {
        Form {
            Section("Secrets") {
                Toggle("Require Touch ID, Apple Watch or the login password to use saved secrets", isOn: $requireAuthentication)
                Picker("Lock again after", selection: $autoLockMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Never").tag(0)
                }
                .disabled(!requireAuthentication)
                Toggle("Lock when the Mac sleeps or the screen locks", isOn: $lockOnSleep)
                    .disabled(!requireAuthentication)
                HStack {
                    Label(vault.isLocked ? "Locked" : "Unlocked", systemImage: vault.isLocked ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Lock Now") { vault.lock() }
                        .disabled(vault.isLocked || !requireAuthentication)
                }
                Text("Passwords, passphrases and Keychain-resident keys are stored in your login Keychain, scoped to this app. Nothing is synced or sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Stored items") {
                LabeledContent("Items in the Keychain", value: secretCount.map(String.init) ?? "…")
                HStack {
                    Button("Remove All Saved Secrets…", role: .destructive) { isClearing = true }
                    Spacer()
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Not available yet") {
                Text("SSH agent forwarding, agent-held keys and FIDO2 security keys need signing support that SwiftNIO SSH does not provide. Ciphers and key exchange are negotiated by SwiftNIO SSH (AES-GCM, ChaCha20-Poly1305, Curve25519 and NIST ECDH).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .themedForm()
        .padding(.bottom)
        .task { refreshCount() }
        .onChange(of: requireAuthentication) { _, value in vault.requireAuthentication = value }
        .onChange(of: autoLockMinutes) { _, value in vault.autoLockMinutes = value }
        .confirmationDialog("Remove every saved password, passphrase and Keychain key?", isPresented: $isClearing, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                do {
                    try SecretStore.shared.deleteAll()
                    message = "All saved secrets were removed. Identities that kept their key in the Keychain can no longer connect."
                } catch {
                    message = error.localizedDescription
                }
                refreshCount()
            }
        } message: {
            Text("Keys kept only in the Keychain are lost unless you exported them. Key files on disk are not touched.")
        }
    }

    private func refreshCount() {
        secretCount = (try? SecretStore.shared.accounts().count) ?? 0
    }
}

# Tepfasonic Client

A free, open-source SSH client for macOS. No account, no sync server: your
hosts live in a local database and move between Macs as an encrypted `.tepfa`
file. The full plan, including the Claude agent panel and MCP server that come
later, is in [docs/PLAN.md](docs/PLAN.md).

**Status:** build steps 1 to 4 of 10 are done (SSH transport, terminal, host
list, tabs and splits, CI with Sparkle updates, Keychain vault with Touch ID and
key management). Nothing is released yet.

## What works today

- Host list in the sidebar with groups, tags, colour labels, quick-connect
  (`user@host:port`), ⌘K search, and a workspace of tabs and nested split panes
  that is restored at the next launch.
- Connect over SSH (SwiftNIO SSH) with a password or an identity. An identity
  is a username plus a credential: a password kept in the Keychain, a key file
  on disk, or a key kept only in the Keychain.
- **Identities & Keys** window (⌘⇧I): generate Ed25519, ECDSA P-256/384/521 and
  RSA 3072/4096 keys; import OpenSSH, PEM (PKCS#1, PKCS#8, SEC1) and PuTTY
  `.ppk` (v2 and v3, including Argon2-encrypted v3) keys from a file or the clipboard, including
  passphrase-protected OpenSSH keys (bcrypt KDF implemented in Swift); copy or
  export the public key; export the private key in OpenSSH format with an
  optional passphrase; push a key to a server's `authorized_keys` the way
  `ssh-copy-id` does.
- Secrets never leave the login Keychain. Reads go through a vault unlocked
  with Touch ID, Apple Watch or the login password, which locks again after a
  configurable idle time, on sleep and on screen lock (Settings → Security).
  Passwords and passphrases can be remembered from the connection prompts.
- Interactive terminal (SwiftTerm) with a real PTY, resizing, exit status,
  automatic reconnect with back-off after a dropped connection, and 100 000
  lines of scrollback.
- Trust-on-first-use host keys: the SHA256 fingerprint is shown before the
  first connection, a changed key is flagged loudly, and Settings → Known Hosts
  lists and removes trusted keys.
- **Snippets** (sidebar, ⌘⇧S): saved commands in folders with tags and notes;
  `{{name}}` and `{{name:default}}` placeholders are asked for when the snippet
  runs. Run one in the current tab, in every open tab, on a host, or on every
  host in a group (tabs are opened as needed). A host can run a snippet on
  connect.
- **Shell integration**: after connecting to a bash or zsh host, one line
  defines OSC 133 prompt hooks (nothing is written to the host), so the
  terminal knows where each prompt, command and output starts and the exit
  status of every command. Off per host or globally.
- **History** (sidebar, ⌘Y): every command run in every session, searchable,
  with host, directory and exit status; run again, copy, or save as a snippet.
  Without shell integration, commands are reconstructed from keystrokes and
  recorded without a status. Keystrokes the host does not echo (passwords)
  are never recorded.
- **Suggestions**: while typing at a prompt, matching history entries and
  snippets appear under the cursor; → accepts, ⌥↑/⌥↓ choose, Esc hides.
- **Export / import** (File menu, ⌘⇧E / ⌘⇧O): one `.tepfa` file carries hosts,
  groups, identities, snippets and trusted host keys. It is encrypted by
  default with a passphrase (Argon2id then ChaCha20-Poly1305; the KDF is
  implemented in Swift and checked against the RFC 9106 vectors), and an
  encrypted export can also carry the saved passwords, private keys and
  passphrases read from the Keychain. A plain export is an option with a
  warning and never contains secrets. Importing lists every record as new,
  changed (with the fields that differ) or identical, lets you choose what to
  apply, and snapshots the current data first. Key files that do not exist on
  the importing Mac are moved into its Keychain. Double-clicking a `.tepfa`
  file opens the import.
- **Interop**: import hosts from `~/.ssh/config` (following `Include`), a
  Termius CSV export, PuTTY sessions (a `.reg` export or the sessions folder)
  and Tabby's `config.yaml`; export saved hosts into one managed block of
  `~/.ssh/config` so `ssh name` works from any terminal, leaving the rest of
  the file alone and keeping a copy of the previous one.
- **Backups**: the last 10 exports and pre-import snapshots are kept under
  Application Support → Tepfasonic → Backups and listed in Settings → Data,
  where any of them can be restored through the same reviewed import.
- Updates: Sparkle 2 fed by an appcast on GitHub Pages, with a download-only
  fallback while builds are ad-hoc signed.

Known limits: RSA keys can be generated, imported, exported and pushed, but
SwiftNIO SSH cannot sign with them, so an RSA identity cannot be used to
connect. SSH agent forwarding, agent-held keys and FIDO2 security keys are not
available for the same reason. Keys kept only in the Keychain cannot be written
to `~/.ssh/config`, because `ssh` cannot read them. Shell integration needs
bash or zsh as the login shell; prompts that
rebuild `PS1` on every prompt (some zsh themes) lose the input marker, in which
case commands are still recorded from keystrokes. Still to come: port
forwarding, SFTP, the Claude agent panel and MCP server.

## Building

Requires Xcode 26 or later (Swift 6, macOS 15 SDK) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate            # writes Tepfasonic.xcodeproj (git-ignored)
open Tepfasonic.xcodeproj    # then Run
```

From the command line:

```sh
xcodebuild -project Tepfasonic.xcodeproj -scheme Tepfasonic -configuration Debug \
  -derivedDataPath .build/DerivedData -skipPackagePluginValidation -skipMacroValidation build
open .build/DerivedData/Build/Products/Debug/Tepfasonic.app
```

Builds are ad-hoc signed until a Developer ID certificate is available, so
Gatekeeper will complain about copies you give to other people.

## Repository layout

| Path | What |
|---|---|
| `Package.swift` | Swift package with the three library modules below |
| `Sources/TepfaCore` | SwiftData models (`SSHHost`, `HostGroup`, `Identity`), known-hosts store, Keychain `SecretStore`, Touch ID `Vault`, appcast parsing, app paths |
| `Sources/TepfaSSH` | SwiftNIO SSH transport: `SSHConnection` (shell + exec), key pairs (generate, OpenSSH/PEM/PPK parsing, OpenSSH encoding, bcrypt_pbkdf, AES), host-key verification |
| `Sources/TepfaTerminal` | `TerminalSession`, workspace/pane tree, credential store and resolver, `KeyPusher`, the SwiftTerm bridge |
| `App/Tepfasonic` | The SwiftUI app: sidebar, host editor, workspace, Identities & Keys window, settings, prompts, updater |
| `Tests/` | Unit tests plus opt-in live tests against a real sshd |
| `project.yml` | XcodeGen spec for the app target |
| `docs/PLAN.md` | The product and build plan |

## Testing

```sh
swift test                                   # unit tests, no network, no Keychain
Scripts/test-sshd.sh start                   # throwaway sshd on 127.0.0.1:2222, no root needed
source .build/test-sshd/env.sh && swift test --filter Live
Scripts/test-sshd.sh stop
TEPFA_KEYCHAIN_TESTS=1 swift test --filter SecretStore   # writes to and cleans the login keychain
TEPFA_ARGON2_TIMING=1 swift test -c release --filter Argon2Timing   # prints the export KDF cost
```

The live tests open a real PTY shell, check the terminal size reached the
server, resize it, read the exit status, run exec commands, push a key to a
temporary `authorized_keys`, install the shell-integration hooks and check that
commands are recorded with their exit status (and that un-echoed keystrokes are
not), and verify that an unauthorized key and a declined host key both fail
with clear errors. Key-format tests use vectors generated by
`ssh-keygen`, `puttygen` and `openssl`, and exported keys are checked with
`ssh-keygen` when it is installed.

For manual QA against scratch data, launch the Debug build with
`TEPFA_DATA_DIR=/some/dir TEPFA_KEYCHAIN_SERVICE=com.tepfasonic.qa` and the
arguments `--seed-demo --window=identities`. Debug builds also take
`--sidebar=hosts|snippets|history`, `--connect=<host name>` and
`--qa-type=<text>` (typed into the new session a few seconds after it opens);
with the test sshd environment sourced, `--seed-demo` adds a `local sshd` host
that runs the "Disk usage" snippet on connect. For export and import:
`--window=export|ssh-config-export`, `--import=<path>` (add
`--qa-import-apply` to apply it without a click) and `--qa-export=<path>`,
which writes a plain export, or an encrypted one with the passphrase `qa` when
the name ends in `.enc.tepfa`.

## Licence

MIT. See [LICENSE](LICENSE).

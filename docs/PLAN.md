# Tepfasonic Client — Revised Plan (No Sync, Export/Import)

_Nov 3, 2026 · Rufaro Mutepfa_

## Status

| Step | Area | State |
|---|---|---|
| 1 | SSH transport (SwiftNIO SSH) + SwiftTerm terminal + host list | **Done** (Nov 3, 2026) — see README for scope and known gaps |
| 2 | Tabs and split panes | **Done** (Nov 3, 2026) |
| 3 | GitHub Actions CI, GitHub Pages site, Sparkle updater | **Done** (Nov 3, 2026) — needs the Sparkle key and Developer ID secrets before a real release |
| 4 | Keychain vault + Touch ID, identities & keys | **Done** (Nov 3, 2026) — see README; agent forwarding and FIDO2 blocked by SwiftNIO SSH |
| 5 | Snippets and command history | **Done** (Nov 3, 2026) — folders, tags, `{{variables}}`, run in tab / all tabs / host / group, OSC 133 shell integration for bash & zsh, history with exit status, inline suggestions |
| 6 | `.tepfa` export / import and `~/.ssh/config` interop | **Done** (Nov 3, 2026) — encrypted `.tepfa` (Argon2id + ChaCha20-Poly1305 in Swift), reviewed import (new / changed / identical with field diff, per-record choice, pre-import backup), last 10 backups in Settings → Data, import from `~/.ssh/config`, Termius CSV, PuTTY sessions and Tabby, export to a managed `~/.ssh/config` block, `.tepfa` registered as a document type |
| 7 | Claude agent panel + MCP server with guardrails | Not started |
| 8 | Port forwarding | Not started |
| 9 | SFTP (dual-pane browser) | Not started |
| 10 | Serial and cloud-provider host imports (AWS, DigitalOcean, Azure) | Not started |

## Export / import instead of sync

Dropping sync removes the whole backend and makes "open source, free, no account" literally true. Moving between Macs is a single file export and import.

- **Format.** One `.tepfa` file containing versioned JSON (`"schemaVersion": 1`) so later releases can migrate older exports. Contents: hosts, groups, identities, snippets, port-forwarding rules, themes, known-hosts fingerprints, and optionally private keys.
- **Encrypted by default.** Export asks for a passphrase; the JSON is encrypted with Argon2id → ChaCha20-Poly1305 and wrapped in a small envelope (`{ "format": "tepfa", "kdf": {...}, "nonce": ..., "ciphertext": ... }`). Import on the other Mac asks for the same passphrase. Plain-JSON export is a checkbox with a warning, and private keys are always excluded from a plain export.
- **Merge, don't overwrite.** Import shows a review sheet listing new, changed and identical records, with "skip duplicates" and "replace existing" per record. Each host carries a stable UUID so repeated imports never create copies.
- **Informal team sharing.** A team keeps a shared `.tepfa` in Git, a shared drive or iCloud Drive and re-imports when it changes. Keys can be excluded from the team file so each person adds their own identity.
- **Interop.** Import from `~/.ssh/config`, Termius export, and PuTTY/Tabby config so switching costs nothing; export to `~/.ssh/config` too.
- **Mechanism.** SwiftData models conform to `Codable`; `NSSavePanel`/`NSOpenPanel` plus a registered `UTType` for `.tepfa` so files open by double-click and drag-onto-dock. The last 10 exports are kept automatically in `~/Library/Application Support/Tepfasonic/backups/` so a bad import is reversible.

## What's left in the plan

| Area | Decision |
|---|---|
| Storage | Everything local in SwiftData; passwords, private keys and the Anthropic API key in Keychain, unlocked with Touch ID |
| Claude integration | Unchanged: BYOK agent panel inside the app (Messages API with tool use) plus an MCP server so Claude Desktop/Code users drive it with their own subscription |
| Agent guardrails | Per-host permission mode (read-only / ask every command / allowlist), destructive-command detection always prompts, approval sheet shows the exact command, audit log, agent runs in its own PTY tab with Esc to interrupt, terminal output treated as untrusted data |
| Repo | Drop `tepfasonic-sync/`; `TepfaCore` gains an `Export/` module |
| Licence | MIT across the board |

## Distribution and updates via GitHub

The app updates itself from GitHub Releases, with GitHub Pages hosting the site and the update feed, so there is no server to run.

| Piece | How |
|---|---|
| Repo | `github.com/Edwardrem/Tepfasonic-Client` — client, docs and CI in one repo, MIT licence |
| Releases | Every tag `vX.Y.Z` publishes a GitHub Release with `Tepfasonic-X.Y.Z.dmg`, a `.zip` for the updater, `SHA256SUMS` and release notes |
| In-app updater | Sparkle 2 with EdDSA signing; the app checks an appcast on launch and daily, shows release notes, and installs in place |
| Appcast | `appcast.xml` served from GitHub Pages (`https://edwardrem.github.io/Tepfasonic-Client/appcast.xml`); CI regenerates it with `generate_appcast` on each release |
| Channels | Stable feed plus an optional beta feed (`appcast-beta.xml`) from pre-releases; toggle in Settings |
| CI | GitHub Actions on `macos-latest`: build, run tests, sign with Developer ID, notarize with `notarytool`, staple, attach to the Release, push the appcast to the `gh-pages` branch |
| Secrets | Sparkle EdDSA private key, Developer ID certificate and notarization credentials stored as repository secrets |
| Site | GitHub Pages: landing page, docs, download button pointing at the latest Release, and the `.tepfa` schema reference |
| Other install paths | Homebrew cask auto-bumped by CI; the Release assets double as the manual download |

No paid Apple Developer account yet: ship ad-hoc-signed builds and have the updater skip install (download only) until signing is in place, since Gatekeeper blocks unsigned auto-installs.

## Build order

Ship something usable early; each step reuses the previous one's plumbing.

1. SSH transport (SwiftNIO SSH) + SwiftTerm terminal + host list
2. Tabs and split panes
3. GitHub Actions CI, GitHub Pages site and Sparkle updater fed by GitHub Releases
4. Keychain vault + Touch ID
5. Snippets and command history
6. `.tepfa` export / import and `~/.ssh/config` interop
7. Claude agent panel + MCP server with guardrails
8. Port forwarding
9. SFTP (dual-pane browser)
10. Serial and cloud-provider host imports (AWS, DigitalOcean, Azure)

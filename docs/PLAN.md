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
| 7 | Claude agent panel + MCP server with guardrails | **Done** (Nov 3, 2026) — BYOK panel (Anthropic Messages API with tool use, or any OpenAI-compatible endpoint), six tools, per-host permission modes, destructive-command detection, approval sheet with Approve / Edit / Deny, audit log with JSON export, agent log tab with Esc to stop, output passed as untrusted data; MCP server (streamable HTTP on localhost + stdio bridge) with the same guardrails and a one-line config per client in Settings |
| 8 | Port forwarding | **Done** (Nov 3, 2026) — local, remote and dynamic (SOCKS5) rules per host, one-click start or auto-start on connect, live status and byte counts in the Port Forwarding sidebar, rules follow reconnects, exported in `.tepfa` |
| 9 | SFTP (dual-pane browser) | **Done** (Nov 3, 2026) — SFTP v3 client in Swift, Files window with local and remote panes (either pane can point at any host for server-to-server copies via the Mac), drag and drop, transfer queue with pause / resume / cancel, folder transfers, rename, chmod, delete, new folder, open-with that re-uploads on save |
| 10 | Serial and cloud-provider host imports (AWS, DigitalOcean, Azure) | **Done** (Nov 3, 2026) — USB serial consoles (`/dev/cu.*`) with saved line settings, line-ending conversion, local echo and a hex view, in the same tabs and splits; read-only EC2 / DigitalOcean / Azure listings with Keychain credentials that add instances through the reviewed import |
| — | Jump hosts and proxies (section 6), group defaults | **Done** (Nov 3, 2026) — chained bastions over direct-tcpip channels, HTTP CONNECT and SOCKS5 proxies per host or group, group defaults for identity, jump host, proxy, theme and font |
| — | Theming (section 16) | **Done** (Nov 3, 2026) — 13 bundled schemes, editor with live sample, import from iTerm2 / Windows Terminal / VS Code / Alacritty / Ghostty, JSON export, `tepfasonic://theme?url=` install links, bundled JetBrains Mono, cursor / contrast / opacity / blur, app appearance and accent, per-host and per-group overrides, background tint and watermark, corner badge, light / dark auto-switch by system or schedule, themes in `.tepfa` |
| — | 0.2.1 polish | **Done** (Nov 11, 2026) — unsigned builds start again (hardened runtime off without a Developer ID; 0.1.0 and 0.2.0 died at launch), host editor could not add hosts (self-jump check fired on empty ids; the editor now shows why Save is off), app icon, the colour scheme drives the light / dark look of every window by default (`docs/releases/0.2.1.md`) |
| — | 0.3.3: update feed, developer page | **Done** (Nov 11, 2026) — the release workflow writes an unsigned `appcast.xml` when no Sparkle key is set, so Check for Updates finds new builds and offers the DMG; HTTP errors from the feed are reported as such; the site has an About the developer section (`docs/releases/0.3.3.md`) |
| — | 0.3.2: full-screen header rows, fleet positioning | **Done** (Nov 11, 2026) — with the scheme on the chrome, full screen hides the system toolbar and draws header rows (no grey glass behind title or buttons); group scope with host counts in the Claude panel; README, site and repository describe the app as a DevOps/AIOps fleet tool (`docs/releases/0.3.2.md`) |
| — | 0.3.1: full-screen chrome, group management | **Done** (Nov 11, 2026) — the full-screen toolbar keeps the scheme colour (title hidden there, scroll-edge strips off); groups as projects: `+` menu, host checklist in the group editor, drag and drop between groups, reorder, collapse, new host in group (`docs/releases/0.3.1.md`) |
| — | 0.3.0: design pass, scheme-coloured chrome, files in and out of the Claude panel | **Done** (Nov 11, 2026) — iOS-flavoured sidebar tiles, pill tabs, status capsule, message bubbles and a rounded composer; the colour scheme derives the palette for the whole app (switchable in Appearance); attachments (images, PDF, Word, text) sent as image and document blocks; `create_document` writes PDF / DOCX / HTML / Markdown / text / CSV with file cards (`docs/releases/0.3.0.md`) |

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

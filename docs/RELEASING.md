# Releasing

Releases are cut by pushing a tag. CI does the rest (see `.github/workflows/release.yml`).

**State on 2026-11-12:** `v0.3.7` is the current release (ad-hoc signed DMG, ZIP and `SHA256SUMS`): chat copy and edit, a dictation recording meter, the Lagoon theme family and larger side panels. It was built and published by hand from a developer Mac, following "Local packaging" below plus `gh release create` and a manual `gh-pages` update, because GitHub Actions runs for the repository stayed queued without starting; the `v0.3.6` tag has no GitHub Release for the same reason. `v0.3.6` was the previous version, hardening dictation against a macOS 26/27 SwiftUI system crash (after `v0.3.5` fixed the dictation permission crash in `v0.3.4`); `v0.2.1` was the first build that starts. The `v0.1.0` (2026-11-03) and `v0.2.0` builds do not start: they were made with the hardened runtime on while only ad-hoc signed (see below). GitHub Pages is enabled from the `gh-pages` branch and serves the landing, download and releases pages. The release workflow publishes `appcast.xml` (and `appcast-beta.xml` for pre-releases) to `gh-pages` on every release: unsigned items written by the workflow itself when no Sparkle key is configured, which the download-only build reads to offer the DMG, or a `generate_appcast` feed when the key is set. Still to do by the repository owner, because each needs a secret or a new repository: the Sparkle key pair (enables signed, in-place updates), the Developer ID certificate and notarization credentials (enables in-place updates), and the Homebrew tap repository with its token (enables `brew install --cask tepfasonic`).

Each release's hand-written notes live in `docs/releases/<version>.md`; the workflow prints them above the list of commits since the previous tag. Write that file before pushing the tag.

```sh
git tag v0.2.0 && git push origin v0.2.0        # stable → appcast.xml
git tag v0.3.0-beta.1 && git push origin v0.3.0-beta.1   # pre-release → appcast-beta.xml
```

Each release gets `Tepfasonic-X.Y.Z.dmg`, `Tepfasonic-X.Y.Z.zip` (what the updater downloads), `SHA256SUMS` and generated notes.

## One-time setup

All secrets go in the repository's **Settings → Secrets and variables → Actions**. Every step degrades gracefully when its secret is missing, so you can add them over time.

### Sparkle signing (enables the update feed)

```sh
curl -sSL -o sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
mkdir sparkle && tar -xf sparkle.tar.xz -C sparkle
./sparkle/bin/generate_keys            # prints the public key, stores the private key in your login Keychain
./sparkle/bin/generate_keys -x ed25519.key   # exports the private key to a file
```

- Put the printed public key in `project.yml` under `SUPublicEDKey` (replace `REPLACE_WITH_SPARKLE_PUBLIC_KEY`) and also save it as the secret `SPARKLE_PUBLIC_KEY`.
- Save the contents of `ed25519.key` as the secret `SPARKLE_PRIVATE_KEY`, then delete the file.

Without these the app still checks the feed but offers downloads only.

### Developer ID signing and notarization (enables in-place updates)

Needs a paid Apple Developer account. Until then CI ships ad-hoc signed builds; the app detects this and keeps updates download-only, because Gatekeeper blocks unsigned auto-installs. Ad-hoc builds are made without the hardened runtime (`ENABLE_HARDENED_RUNTIME` is off in `project.yml`): with it on, library validation needs a Team ID and the embedded Sparkle framework fails to load. The workflow turns it on only when it signs with the Developer ID, which notarization requires.

- `DEVELOPER_ID_P12`: your "Developer ID Application" certificate exported as `.p12`, base64-encoded (`base64 -i cert.p12 | pbcopy`).
- `DEVELOPER_ID_P12_PASSWORD`: its password.
- `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8`: an App Store Connect API key with the Developer role (the `.p8` contents go in `NOTARY_KEY_P8`).

### GitHub Pages

Enable Pages for the repository with the `gh-pages` branch as the source. The site workflow publishes `site/` there and the release workflow adds `appcast.xml` / `appcast-beta.xml` next to it, so the feed is `https://edwardrem.github.io/Tepfasonic-Client/appcast.xml`.

### Homebrew cask

Create a tap repository (default `Edwardrem/homebrew-tepfasonic`) and add a fine-grained token with write access as the secret `HOMEBREW_TAP_TOKEN`. Override the tap name with the repository variable `HOMEBREW_TAP`. Users then run:

```sh
brew tap edwardrem/tepfasonic && brew install --cask tepfasonic
```

## Local packaging

```sh
xcodegen generate
xcodebuild -project Tepfasonic.xcodeproj -scheme Tepfasonic -configuration Release \
  -derivedDataPath .build/DerivedData -archivePath .build/Tepfasonic.xcarchive \
  -skipPackagePluginValidation -skipMacroValidation archive
Scripts/package.sh .build/Tepfasonic.xcarchive/Products/Applications/Tepfasonic.app 0.2.0 dist
```

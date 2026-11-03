# Releasing

Releases are cut by pushing a tag. CI does the rest (see `.github/workflows/release.yml`).

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

Needs a paid Apple Developer account. Until then CI ships ad-hoc signed builds; the app detects this and keeps updates download-only, because Gatekeeper blocks unsigned auto-installs.

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

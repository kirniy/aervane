# Homebrew distribution

Aervane ships as a native macOS app through [kirniy/tap](https://github.com/kirniy/homebrew-tap). No Node runtime or npm account is needed.

The first public release is **not published yet**. Developer ID signing and notarization must be completed before this command can install it:

```sh
brew install --cask kirniy/tap/aervane
```

The initial release targets Apple Silicon and macOS 14+. A tap provides an installation path without waiting for inclusion in Homebrew's central catalog. See [Homebrew taps](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap).

## Signing

Apple requires a **Developer ID Application** certificate, Hardened Runtime and a secure timestamp for notarization. The development certificate currently on this Mac is insufficient. The owner confirms an existing paid Apple Developer membership. Creating a Developer ID certificate requires the Account Holder role. [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Keep the private key in the local keychain. Configure `xcrun notarytool store-credentials aervane-notary` through its secure interactive prompt, never command history or repository files. API-key credentials are also supported. The release does not require uploading signing keys to GitHub.

## Build and prepare

Set the numeric version in `VERSION`, then run on the signing Mac:

```sh
swift test
SIGN_IDENTITY='Developer ID Application: …' NOTARY_PROFILE=aervane-notary tools/release.sh
python3 tools/prepare-distribution.py
brew style dist/distribution/aervane.rb
```

`release.sh` signs the app and helper, submits the archive, staples the accepted ticket and verifies the extracted archive. `prepare-distribution.py` checks identity/version, matching app/helper signing teams, architecture, Gatekeeper and the stapled ticket before generating the versioned ZIP, SHA-256 checksum, release metadata and matching cask.

Ad hoc and development-signed archives are rejected. No placeholder checksums are published.

## Publish and verify

1. Publish the verified ZIP, `release.json` and `SHA256SUMS.txt` in GitHub release `v<VERSION>`.
2. Push the generated `aervane.rb` into `Casks/` in `kirniy/homebrew-tap`.
3. Run `brew update`, `brew audit --cask --online kirniy/tap/aervane`, then verify installation in a separate application directory.
4. Check the downloaded archive checksum, extracted signature and notarization ticket before declaring the release ready.

Quit Aervane before upgrading; normal Quit restores automatic fan control. The cask's uninstall hook unregisters the signed helper after quitting the app. An unregistered or missing helper exits successfully without requiring a hardware probe. Setup may request macOS approval again when the new app opens.

Keep release assets immutable after publication. A correction requires a new version. The app does not poll for updates; `brew upgrade --cask kirniy/tap/aervane` performs an explicit upgrade.

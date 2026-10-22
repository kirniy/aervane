# Distribution

Homebrew and npm install the same native app archive. The npm package is a small, dependency-free installer/launcher; it is not part of the running app. It does not run an install lifecycle script.

The first public release is **not published yet**. Signing and npm account authentication must be completed before the commands below can install it.

## Public commands

After publication:

```sh
brew install --cask kirniy/tap/aervane
```

Or:

```sh
npx aervane install
npx aervane open
```

Both channels initially target Apple Silicon and macOS 14+. A Homebrew tap provides an installation path without waiting for inclusion in Homebrew's central catalog. See [Homebrew taps](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap).

## Signing account

Apple requires a **Developer ID Application** certificate, Hardened Runtime and a secure timestamp for notarization. The development certificate currently available on the development Mac does not meet that requirement. Use an existing paid Apple Developer Program membership; do not buy or enroll automatically. Creating a Developer ID certificate requires the Account Holder role. [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Keep the private key in the local keychain. Configure notarization with `xcrun notarytool store-credentials aervane-notary`; supply credentials through its secure interactive prompt, never command history or repository files. API-key credentials are also supported. A release does not require uploading signing keys to GitHub.

## Build and prepare

Keep `VERSION` and `npm/package.json` at the same numeric version. Then, on the signing Mac:

```sh
swift test
npm --prefix npm test
SIGN_IDENTITY='Developer ID Application: …' NOTARY_PROFILE=aervane-notary tools/release.sh
python3 tools/prepare-distribution.py
cd dist/distribution/npm
npm pack --dry-run
```

`release.sh` signs the app and helper, submits the archive for notarization, staples the ticket and verifies the extracted archive. `prepare-distribution.py` checks app/helper signing teams, app identity/version, architecture, Gatekeeper and the stapled ticket before generating:

- A versioned ZIP and SHA-256 checksum.
- A matching Homebrew cask.
- A prepared npm package containing the exact release URL, checksum and signing team.

An ad hoc or development-signed archive is rejected. No placeholder checksums are published. Installer tests cover checksum failures, download limits, signature failure before replacement, preservation of the old app and symlink destinations.

## Publish

Publish the verified ZIP, `release.json` and `SHA256SUMS.txt` in the matching GitHub release `v<VERSION>`. Push the generated `aervane.rb` into `Casks/` in `kirniy/homebrew-tap`, then audit and test that cask. Publish from the generated npm directory, not the source `npm/` directory:

```sh
npm login --auth-type=web
cd dist/distribution/npm
npm publish --access public
```

npm requires authenticated publishing with the applicable 2FA challenge. An npm login or publish challenge must be completed by the account owner; do not commit tokens or weaken account settings. [npm publishing authentication](https://docs.npmjs.com/requiring-2fa-for-package-publishing-and-settings-modification/).

Verify the public release URL and checksum, registry version, Homebrew audit and an installation in an isolated application directory. Do not overwrite a running Aervane during these checks. The installer rejects a running app; normal Quit returns fan control to macOS.

Upgrades unregister the previous signed helper only after the replacement is copied and verified. The old app must have the same signing team. Homebrew's uninstall hook also unregisters the helper after quitting the app. The app requests any required helper approval when opened again. A valid development signature or Gatekeeper acceptance on the development Mac alone does not establish notarization; the preparation tool requires Developer ID and a stapled ticket independently.

Keep GitHub release assets immutable once published. A correction requires a new version. The native app does not poll for updates; `brew upgrade` or a newer npm installer performs an explicit upgrade.

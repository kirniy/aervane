# Homebrew distribution

Aervane ships as a native macOS app through [kirniy/tap](https://github.com/kirniy/homebrew-tap). No Node runtime or npm account is needed.

Install the signed and notarized release:

```sh
brew install --cask kirniy/tap/aervane
```

The 0.5 build targets Intel and Apple Silicon on macOS 13+ with one universal archive. A tap provides an installation path without waiting for inclusion in Homebrew's central catalog. See [Homebrew taps](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap).

## Signing

Apple requires a **Developer ID Application** certificate, Hardened Runtime and a secure timestamp for notarization. A Developer ID certificate and local notarization Keychain profile are now configured on the signing Mac. Creating a Developer ID certificate requires the Account Holder role. [Apple's certificate instructions](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Keep the private key in the local keychain. Configure `xcrun notarytool store-credentials aervane-notary` through its secure interactive prompt, never command history or repository files. API-key credentials are also supported. The release does not require uploading signing keys to GitHub.

## Build and prepare

Set the numeric version in `VERSION`, then run on the signing Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
SIGN_IDENTITY='Developer ID Application: …' NOTARY_PROFILE=aervane-notary tools/release.sh
python3 tools/prepare-distribution.py
```

`release.sh` signs the app and helper, submits the archive, staples the accepted ticket and verifies the extracted archive. `prepare-distribution.py` checks identity/version, matching app/helper signing teams, both arm64 and x86_64 slices in each executable, the Mach-O minimum OS of every slice, Gatekeeper and the stapled ticket before generating the versioned ZIP, SHA-256 checksum, release metadata and matching cask.

Ad hoc and development-signed archives are rejected. No placeholder checksums are published.

## Publish and verify

1. Publish the verified ZIP, `release.json` and `SHA256SUMS.txt` in GitHub release `v<VERSION>`.
2. Push the generated `aervane.rb` into `Casks/` in `kirniy/homebrew-tap`.
3. Run `brew style Casks/aervane.rb` from the tap checkout (Homebrew recognizes the `Casks/` directory), then `brew audit --cask --online kirniy/tap/aervane` and verify a fresh installation.
4. Check the downloaded archive checksum, extracted signature and notarization ticket before declaring the release ready.

Quit Aervane before upgrading; normal Quit restores automatic fan control. The cask's uninstall hook unregisters the signed helper after quitting the app. An unregistered or missing helper exits successfully without requiring a hardware probe. Setup may request macOS approval again when the new app opens.

Keep release assets immutable after publication. A correction requires a new version. The app does not poll for updates; `brew upgrade --cask kirniy/tap/aervane` performs an explicit upgrade.

## 0.2.0 release receipt

Apple accepted notarization submission `f68f7cab-e535-4d76-b5e5-e0afe2307797`. The app was stapled and validated, then re-archived and extracted for strict signature verification. Distribution preparation also passed Gatekeeper assessment, arm64 and minimum-version checks, matching app/helper Developer ID teams, and ticket validation.

Archive SHA-256: `34c6a12cb9ae9255eb37cd5a4e827b11e1251526dd6165b96ff70f6126263991`.

A fresh Homebrew installation of the public archive succeeded on the development Mac. Its downloaded checksum, installed Developer ID signatures and stapled ticket were verified. The ordinary first-launch Open confirmation was accepted; a newly registered helper then applied manual 76%. The tap’s macOS CI workflow passed cask style and the online audit: https://github.com/kirniy/homebrew-tap/actions/runs/39855983205.

## 0.3.0 release receipt

Apple accepted submission `b67b970a-0834-4a43-b410-4c87cb41320f`. The final temperature-crossfade build passed 257 Mac tests, Developer ID signature verification, stapling, extracted-archive checks and distribution preparation. Archive SHA-256: `3b6f6b21e31ea37a1d7b140dd2558cd403f77a5897ea8b6b8411ef7ac3705018`.

The development Mac has a pre-existing global Gatekeeper override; assessment on this machine is not clean-machine Gatekeeper validation. Cryptographic signatures and the stapled Apple ticket were checked separately.

The public Homebrew upgrade from 0.2.0 to 0.3.0 succeeded on the development Mac. The downloaded installation passed strict signature verification, matching Developer ID team verification and stapled-ticket validation. The helper reconnected and independently measured 3724 RPM at manual 76%. The tap's online audit and style CI passed: https://github.com/kirniy/homebrew-tap/actions/runs/39946315049.


## 0.4.0 public release

- Source: `38b53efdb5e384608e01f48040ebf58f4708d78a`.
- Release: https://github.com/kirniy/aervane/releases/tag/v0.4.0
- Notarization accepted: `9ff9edb3-b1aa-4ef9-b445-9fe328764991`.
- Archive SHA-256: `8489498d6c7f8f666718d09f663244296b769413d2cad2de7c38dd52c8f2af36`.
- Tap commit: `7050c85`; tap CI `39959109179` passed.
- Public Homebrew upgrade 0.3.0 → 0.4.0 succeeded. Installed Developer ID signature and stapled-ticket validation passed.
- Source CI runs `39959072564` and `39959083715` were still running at this record; local Mac suite passed 300 tests, followed by focused checks of the final chart Accessibility and temperature-sync changes.
- Final independent fan readback: manual, target 3724 RPM, actual 3725 RPM (76%).

## 0.5.0 universal release

- [Public release](https://github.com/kirniy/aervane/releases/tag/v0.5.0): one Intel/Apple Silicon archive for macOS 13+.
- Source: `5af76dd9fda9edfd05da7f82da6802e723e38543`.
- Apple notarization accepted: `e1fd2c37-caa7-4aeb-a9e1-c47cc080b5b1`.
- SHA-256: `ac6f3d37ac4c49fa3a2012e517ee7e85d48ca7104d37cfe3a83309f9efd85ebb`.
- Source CI `39999909209` passed tests and universal builds on Intel and Apple Silicon.
- Local public Homebrew upgrade 0.4.0 → 0.5.0 passed; installed signatures and ticket validated.
- [Full verification receipt](verification-0.5.0.md).
- Tap CI `40000620676` passed fresh public installation, online audit, signature/ticket and executable signing checks on both Intel and Apple Silicon.

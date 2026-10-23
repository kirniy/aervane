# Aervane — development handoff

Updated 2026-10-23. Public repository: https://github.com/kirniy/aervane. Native Swift/AppKit menu-bar app, with a small C AppleSMC bridge and no third-party runtime dependencies.

## Current work

Version 0.3.0 is ready for publication. The final Mac suite passed **257 tests**, including actual presentation-layer motion over time, rotor RPM scaling, full-cooling flow, reopen, and temperature-transition behavior. The signed archive passed Apple notarization and stapled-ticket validation.

Dot Grid is the default for new or invalid preferences; saved choices remain. Dot Grid has no fan graphics. Channel rotors follow actual measured RPM at a proportional visual scale. Both styles have continuous maximum-cooling effects. Temperature uses rounded tabular digits and a short crossfade rather than pushing the whole number.

The static-animation complaint was traced to system Reduce Motion=true. At the user's explicit request it was disabled through System Settings and read back as false; Reduce Transparency remains on. Other users' accessibility settings remain respected. Dot Grid below 100% currently has interaction motion only; all-speed vitality and onboarding are proposals, not shipped features.

Actual Claude collaborated via claude-vps; source was reviewed, tested and signed locally. No signing credentials were sent remotely. Final notarization: b67b970a-0834-4a43-b410-4c87cb41320f. Final archive SHA-256:3b6f6b21e31ea37a1d7b140dd2558cd403f77a5897ea8b6b8411ef7ac3705018. Never publish intermediate archives.

## Persistent product requirements

A tiny, exceptionally polished macOS menu-bar utility. Temperature at a glance, percentage fan control, editable presets, inline settings, no speed dialog. CPU is the original default; preserve saved sensor preferences. Use event-driven microanimations, readable native materials and minimal copy. The user specifically asks for actual Claude collaboration.

> Cut taglines, helper text and secondary labels. If a screen needs them to make sense, fix the layout.

> Make the best decision that will elevate all three: the user experience (UX), developer experience (DX), and agent experience (AX) always, without breaking anything.

**High temperature must not block manual fan control.** The former 95°C restriction was an Aervane policy mistake, not an AppleSMC limit. It was removed from command acceptance and watchdog restoration. Do not reintroduce it. Hardware bounds, stale/invalid telemetry, lost clients, failed-write rollback and recovery remain applicable.

Manual control has no expiry by default. Return to Auto is opt-in, with a 5–120 minute settings slider. It is separate from the helper connection watchdog and applies only to manual speeds. The user’s requested final state after all work is **Manual 76%, Smart OFF, Return to Auto OFF**. The user actively exercises the app during development; recheck the final state rather than relying on an earlier sample.

Slider style is independent of effects: **Channel** or **Dot Grid**. The latest request authorizes redesigning both. Effects are Off/Subtle/Expressive, with system Reduce Motion/Transparency respected. The requested miniature fan pattern may rotate while the panel is visible using bounded compositor animations; stop it when hidden or motion/effects are disabled. No per-frame application loop, display link, network polling, telemetry or embedded browser. Actual heat and cooling power use distinct colors.

## Hardware and control evidence

Development Mac: M4 Mac mini, `Mac16,10`, one fan, maximum 4900 RPM and minimum 1000 RPM (21% after rounding). Zero is not supported on this machine; never relabel the hardware floor as 0%.

- Authenticated signed helper and XPC are working. Real 100% and 60% writes, Auto restoration, optional five-minute expiry and manual control at high temperature have been independently read back. See [verification](docs/verification.md).
- At the first 0.3.0 installed checkpoint, Manual 76% read mode 1, target 3724 and actual 3722 RPM. Boost from Smart disabled Smart and read target 4900 / actual 4902. Auto from Smart read mode 0 / target 1000 / actual 1007. The old Smart controller also reduced from 100% toward lower speeds, but that policy is being replaced; do not claim validation of the forthcoming target controller from those samples.
- The target-verification failure was write ordering: switch mode before writing RPM, then passive readback and rollback. REA/Hopper verified the established controller’s ordering.
- Missing XPC signing metadata was fixed with `kSecCSSigningInformation`. Both sides still authenticate code-signing requirements.
- The serial command reducer preserves user intent, ticket identity, Smart epochs and stale telemetry generations. Recovery journal captures the raw pre-write target, even in Auto. This attribution is not an atomic hardware lock against another controller.
- High-temperature regression tests at 100°C and 129°C use simulated readings; do not describe them as additional physical tests.

## Compatibility catalog

[Embedded compatibility facts](docs/compatibility/mfc-1.5.21/README.md) cover 237 unique temperature identifiers, 414 sensor occurrences, 205 sensor/group rules, 46 model aliases, 14 fan-label entries and 15 initialized control constants from Macs Fan Control 1.5.21. Both architecture resource slices match; control predicates were checked against ARM64 instructions. No vendor executable, assets or decompiled source are committed.

`Mac16,10` maps to `Macmini11,1`. Aervane reads its exact ten CPU keys. Catalog GPU keys `Tg04`/`Tg12` were absent in live reads here; GPU display reports unavailable rather than substituting unrelated temperatures. Other models retain candidate fallback. The catalog is not proof of universal fan control; this release currently supports one fan.

## Build, diagnostics and distribution

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
tools/build.sh
```

Set `SIGN_IDENTITY` to an Apple signing identity for hardware-control builds. Default ad hoc builds are for read-only interface work. Installed app: `/Applications/Aervane.app`. `Aervane --probe` is read-only. `--verify-control` changes the real fan (100% then Auto); use only within the user’s authorization. Normal quit restores Auto before helper replacement. `--unregister-helper` refuses to proceed while the fan is manual.

Distribution is **Homebrew only**. npm was explicitly canceled. Use `tools/release.sh` with `SIGN_IDENTITY` and local Keychain profile `NOTARY_PROFILE=aervane-notary`. The script signs, submits to Apple, staples, rearchives and verifies the extracted signature. `tools/prepare-distribution.py --output dist/distribution-<version>` checks signatures, architecture, version, Gatekeeper and ticket before creating the versioned archive/checksum/cask. Never overwrite published version assets. No private keys go in Git or remote workspaces.

0.2.0: https://github.com/kirniy/aervane/releases/tag/v0.2.0. Its accepted notarization, public Homebrew installation and cask online audit are recorded in [verification](docs/verification.md) and [distribution](docs/distribution.md). The tap is https://github.com/kirniy/homebrew-tap. CI verifies builds but no longer uploads disposable test-build artifacts. Preserve legitimate release assets.

This Mac’s existing Gatekeeper global configuration reports `override=security disabled`; it was not changed. Accepted notarization, signatures and stapled tickets are verified separately. Homebrew’s local online-audit preflight rejects Xcode 26.2 on macOS 27; the supported GitHub macOS 26 runner provides that check. Do not change global Xcode/security settings to work around it.

## Follow-up verification

- Public release/tap/CI evidence belongs in docs/distribution.md. Current real app images and Dot Grid animation are in docs/assets.
- Finish local work with Manual 76%, SmartOFF, ReturnToAutoOFF. Preserve latest saved target (last observed 72°C); user actively changes settings.
- Physical dragging was user-confirmed. Broader crash/sleep/wake/watchdog, fanless/multi-fan models, VoiceOver, 1× and multi-display checks remain incomplete. Unit tests do not establish hardware coverage.
- Read temperature independently of fan failures before claiming temperature-only support on fanless/unsupported models. The current release is physically verified only on the M4 mini.

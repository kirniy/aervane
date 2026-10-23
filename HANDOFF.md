# Aervane — development handoff

Updated 2026-10-24. Public repository: https://github.com/kirniy/aervane. Native Swift/AppKit menu-bar app, with a small C AppleSMC bridge and no third-party runtime dependencies.

## Current work

0.5.0 adds universal Intel/Apple Silicon app and helper builds on macOS 13+, discovered multi-fan control, model-aware SMC/HID temperatures, fanless monitoring and multi-fan journal recovery. Actual Claude implemented the main compatibility package; local integration added GPU-peak failure handling, native HID ownership/ABI corrections, aggregate-gate readback, scoped recovery and universal release checks.

The 394-test suite passed natively and through Intel executables. The signed universal app passed the real helper verification: 100% target, independent fan readback and confirmed Auto restoration. See [0.5.0 verification](docs/verification-0.5.0.md), [Mac compatibility](docs/mac-compatibility.md), and [distribution](docs/distribution.md) for exact release/CI receipts.

The existing design remains: live Dot Grid and Channel, editable Smart target on the graph, inline onboarding and one shared temperature readout for menu bar and panel. Motion stops when hidden. No runtime dependencies, per-frame application loops or network polling were added.

After the public Homebrew upgrade, the panel is running Smart at the saved 70°C target; Return to Auto is off. Preserve the latest active selection rather than restoring an older request. System Reduce Motion is off at the user's request; Reduce Transparency is on. Respect other users' accessibility preferences.

## Persistent product requirements

A tiny, exceptionally polished macOS menu-bar utility. Temperature at a glance, percentage fan control, editable presets, inline settings, no speed dialog. CPU is the original default; preserve saved sensor preferences. Use event-driven microanimations, readable native materials and minimal copy. The user specifically asks for actual Claude collaboration.

> Cut taglines, helper text and secondary labels. If a screen needs them to make sense, fix the layout.

> Make the best decision that will elevate all three: the user experience (UX), developer experience (DX), and agent experience (AX) always, without breaking anything.

**High temperature must not block manual fan control.** The former 95°C restriction was an Aervane policy mistake, not an AppleSMC limit. It was removed from command acceptance and watchdog restoration. Do not reintroduce it. Hardware bounds, stale/invalid telemetry, lost clients, failed-write rollback and recovery remain applicable.

Manual control has no expiry by default. Return to Auto is opt-in, with a 5–120 minute settings slider. It is separate from the helper connection watchdog and applies only to manual speeds. Preserve the latest user-selected state, currently **Smart ON, target 70°C, Return to Auto OFF** (superseding the earlier Manual 76% request). The user actively exercises the app during development; recheck the final state rather than relying on an earlier sample.

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

`Mac16,10` maps to `Macmini11,1`. Aervane reads its exact ten CPU keys. Catalog GPU keys `Tg04`/`Tg12` were absent in live reads here; GPU display reports unavailable rather than substituting unrelated temperatures. Other models retain candidate fallback. The 0.5 implementation uses this catalog at runtime, discovers all fans, resolves Intel/per-fan control protocols and applies a linked percentage against each fan’s limits. See [Mac compatibility](docs/mac-compatibility.md).

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
- Finish local work with the latest user selection; recheck preferences before replacement. Preserve latest saved target (last observed 70°C); user actively changes settings.
- Physical dragging was user-confirmed. Broader crash/sleep/wake/watchdog, fanless/multi-fan models, VoiceOver, 1× and multi-display checks remain incomplete. Unit tests do not establish hardware coverage.
- Temperature and fan failures are independent. Fanless monitoring and multi-model protocol fixtures have regression tests; keep physical hardware observations distinct from fixture coverage.

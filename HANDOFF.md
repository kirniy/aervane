# Aervane — development handoff

Updated 2026-10-23. Public repository: https://github.com/kirniy/aervane. Native Swift/AppKit menu-bar app, with a small C AppleSMC bridge and no third-party runtime dependencies.

## Current work

Public Homebrew release is **0.2.0**. The integrated **0.3.0 Smart regulation and sensor-display correction passed 230 Mac tests**, was signed and installed, and exercised real fan changes. The user confirmed physical slider dragging and immediate Smart → Manual takeover. Two intermediate drafts passed notarization, but neither should be published: a further slider redesign is underway.

The reported 68°C beside “Above 73° · max cooling” had two causes. Smart used the hottest core while the panel showed averages; Smart now displays its actual controlling measurement, while the menu bar retains the selected source. The former target−3 full-speed curve was also too aggressive. The corrected working-target curve is 70% at the target and 100% at target+5°C, with a 1.5°C thermal deadband and bounded rising-trend anticipation. No artificial cooling-down timer or command-count ramp. At target86°C on the Mac, hottest CPU83.6–86.4°C produced confirmed targets80→76→71% as the load settled.

The latest request explicitly replaces the requirement to preserve the original Dot Grid artwork: **make Dot Grid taller, redesign both styles' effects, fully frost Channel at maximum, and add miniature rotating fan patterns whose speed follows cooling speed**. Actual Claude (`claude-vps`, session `5607838c-35a8-4f9d-9d16-b0e88e4fabf9`) is implementing this from a fresh integrated snapshot in **`/workspace/aervane-slider-redesign-20261023`**, base **`d7c16ddc2b4de3be80957e76c5be6e2490dca4df`**. The controller/helper/SMC paths are outside its scope.

Claude owns slider skins/support, necessary slider layout, related tests, DESIGN.md and its sidecar. The parent owns the remaining docs, Mac verification, signing and release. No signing credentials are on Claude's host. Never reapply an earlier full patch or publish a superseded distribution directory.

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

## Validation still required

- Integrate Claude's new slider redesign, review it, run the complete Mac suite and signed build. Render both styles, full frost, measured-speed rotors, all effects settings and motion lifecycle; measure open/closed resource use.
- Preserve the completed Smart fixes: actual controlled temperature, moderate cooling around the working target, rising/falling behavior, target persistence/units, immediate Manual/Auto override. See [Smart cooling](docs/smart-cooling.md) for the 230-test checkpoint and live trace.
- Re-notarize the final redesign, publish 0.3.0, update the tap, verify CI and a public Brew update. Leave **Manual 76%, SmartOFF, ReturnToAutoOFF**. Preserve the latest saved target: the user is actively testing and has changed it several times; last observed86°C, not the earlier73/67 or temporary90°C test.
- Physical slider drag is user-confirmed. Repeated status-item clicks/outside dismissal, real VoiceOver, system Reduce Motion/Transparency, 1× and multiple displays remain incompletely tested. Light appearance and three-digit Fahrenheit were rendered on the Mac at the regulation checkpoint.
- Physical crash/sleep/wake/lease-expiry, additional Mac models and multiple fans need broader testing. Automated policy/recovery tests are not hardware validation.

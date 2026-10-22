# Aervane — development handoff

Updated 2026-10-23. Repository: https://github.com/kirniy/aervane, branch `fix/fan-control`.

## Current user priorities

A tiny, exceptionally polished native macOS menu-bar temperature/fan utility. CPU is the original default; preserve the user's saved sensor selection. Percentage slider, editable presets, inline settings, no speed dialog. Use native Liquid Glass, precise microanimations, and minimal copy. The user explicitly requests real collaboration through `claude-vps`.

Latest instructions:

> Cut taglines, helper text and secondary labels. If a screen needs them to make sense, fix the layout.

> Make the best decision that will elevate all three: the user experience (UX), developer experience (DX), and agent experience (AX) always, without breaking anything.

**High temperature must not block manual fan control.** The earlier 95°C restriction was an Aervane policy mistake, not an AppleSMC limit. It has been removed from both command acceptance and watchdog restoration. Never reintroduce a temperature-only override. Invalid/stale telemetry, lost clients, expired leases, hardware bounds and failed write rollback still matter.

## What is now verified

- 89 tests pass on the actual Mac with Xcode 26.2. Production app/helper build and pass strict code-signature verification with the existing Apple development identity.
- Installed signed helper approval and authenticated XPC work.
- Real 100% → Auto test: independent SMC read saw `F0Md=1`, `F0Tg=4900`; fan reached about 4900 RPM. Auto then read `F0Md=0`; firmware subsequently returned to about 1000 RPM. Initial hottest CPU sample was 98.8°C.
- Actual UI Boost and Auto actions succeeded. After removing the temperature policy, UI Balanced 60% also succeeded: independent target 2940 RPM, actual 2941 RPM, manual mode. Hottest sample in that separate physical test was 92.1°C. Tests additionally cover 60% retention at 100°C and 129°C; do not describe these simulated temperatures as physical measurements.
- The root cause of the target verification error was write ordering. REA/Hopper shows the established controller switching modes before writing RPM. Aervane now does the same, with passive readback and rollback.
- Missing XPC signing metadata was separately fixed by requesting `kSecCSSigningInformation`. Both app and helper still verify code-signing requirements.
- The command queue preserves the latest user intent, including Auto during an in-flight write. Reconnection and quit use bounded callbacks and ownership-aware recovery.
- The crash journal captures the raw pre-write target even in Auto, covering a crash between mode and target writes. This attribution is not an atomic hardware lock against other controllers.

## Sensor and key catalog

See [the complete embedded compatibility catalog](docs/compatibility/mfc-1.5.21/README.md). It contains 237 unique SMC temperature identifiers, 414 sensor occurrences, 205 sensor/group rules, 46 model aliases, 14 fan-label entries and all 15 initialized SMC control constants. The sensor resources were verified identical in both architecture slices; control predicates were checked against ARM64 instructions. Scope limits are explicit.

`Mac16,10` maps to `Macmini11,1`. Aervane now reads its exact ten CPU keys, including previously missing `Te0U` and `Te0V`. The catalog's GPU keys `Tg04` and `Tg12` were absent in the live probe on this machine; GPU selection must report unavailable rather than mislabel unrelated sensors. Other models retain the previous candidate fallback; the catalog is not a claim that Aervane controls every model yet.

## Architecture and file ownership

| Area | Files |
| --- | --- |
| Menu bar, panel lifecycle | `Sources/Zephyr/main.swift` |
| Native UI | `Sources/Zephyr/{PanelView,PercentSlider,Theme}.swift` |
| Model/helper communication | `Sources/Zephyr/{AppModel,HelperClient,HelperInstaller}.swift` |
| Hardware read/write | `Sources/SMC`, `Sources/SMCClient` |
| Authenticated helper, recovery journal | `Sources/ZephyrHelper` |
| Transactions, leases, command queue | `Sources/ZephyrCore` |

Keep native runtime dependency-free. Hardware control currently requires one fan and the supported mode key. Never import vendor binaries, assets or decompiled code. Compatibility facts and independent code are in the repo.

## Collaboration

Actual Claude session `48ef955d-dd80-4094-b719-459f7e1f5917` through the user's `claude-vps` launcher implemented both an earlier UI pass and the control repair. Its repair workspace was `/workspace/aervane-repair-20261023`. The integrated repository is authoritative; old remote drafts do not include the local journal, sensor and temperature-policy corrections. Start a fresh clone for the next UI pass, restrict edits to native UI files, and let the parent run Mac builds and hardware verification.

## Build and test

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
tools/build.sh
```

Set `SIGN_IDENTITY` for an Apple-signed helper build. The installed app is `/Applications/Aervane.app`. Read-only diagnostics: `Aervane --probe`. Explicit hardware verification: `Aervane --verify-control` (100% briefly, then Auto; only run within user authorization). Close the competing controller for an isolated test.

## Open validation and distribution work

- Physical pointer drag, repeated actual status-item clicks, outside dismissal, rapid toggles and multiple monitors. Native handler regression tests and keyboard/accessibility paths pass; app-scoped CUA reports `AXError.notImplemented` for pointer drag/click on the custom slider. Do not claim a physical drag test.
- Real VoiceOver, Reduce Motion/Transparency, light theme, 1× screens and long-content states.
- Physical helper/app crash, sleep/wake and expired-lease scenarios beyond the controlled normal restoration tests.
- More Mac models, multiple fans and Intel/alternate mode-key support.
- Public Developer ID signing, notarization, release install and a real Brew cask. The current identity is development-only; `Casks/aervane.rb.in` remains a template.

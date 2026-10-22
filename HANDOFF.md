# Aervane — development handoff

Updated 2026-10-23. Repository: https://github.com/kirniy/aervane. The current implementation is on `main`; `fix/fan-control` retains the same repair and redesign history.

## Current user priorities

A tiny, exceptionally polished native macOS menu-bar temperature/fan utility. CPU is the original default; preserve the user's saved sensor selection. Percentage slider, editable presets, inline settings, no speed dialog. Use native Liquid Glass, precise microanimations, and minimal copy. The user explicitly requests real collaboration through `claude-vps`.

Latest instructions:

> Cut taglines, helper text and secondary labels. If a screen needs them to make sense, fix the layout.

> Make the best decision that will elevate all three: the user experience (UX), developer experience (DX), and agent experience (AX) always, without breaking anything.

**High temperature must not block manual fan control.** The earlier 95°C restriction was an Aervane policy mistake, not an AppleSMC limit. It has been removed from both command acceptance and watchdog restoration. Never reintroduce a temperature-only override. Invalid/stale telemetry, lost clients, expired leases, hardware bounds and failed write rollback still matter.

## Latest settings and motion brief

Manual mode must persist by default. The user rejected the unrequested fixed 30-minute timeout, then asked for an **optional Return to Auto toggle and a time slider in settings**. `AppModel.autoReturnEnabled` defaults false; `autoReturnMinutes` is 5–120, in five-minute steps. `ManualReturnTimer` has deterministic tests for no expiry by default, opt-in start, duration edits, cancellation and invalid persisted values. It is independent of the helper connection watchdog.

The UI now has progressive slider effects and ice forming at maximum cooling, temperature-specific states and microanimations, configurable compact menu-bar spacing/content/effects, and a GitHub icon on Source code. Actual heat and cooling power use separate color scales. Effects stay event-driven with no idle loops and respect accessibility preferences in code. Claude's patch from `/workspace/aervane-ui-20261023` is integrated, corrected, compiled, signed and installed. Current screenshots in `docs/assets` are actual macOS captures.

## What is now verified

- 113 tests pass on the actual Mac with Xcode 26.2. Production app/helper build and pass strict code-signature verification with the existing Apple development identity.
- The signed development archive also passes strict signature verification after extraction. CI builds an ad hoc UI-preview archive and performs the same extraction check; it is not a notarized public installer.
- Installed signed helper approval and authenticated XPC work.
- Real 100% → Auto test: independent SMC read saw `F0Md=1`, `F0Tg=4900`; fan reached about 4900 RPM. Auto then read `F0Md=0`; firmware subsequently returned to about 1000 RPM. Initial hottest CPU sample was 98.8°C.
- Actual UI Boost and Auto actions succeeded. After removing the temperature policy, UI Balanced 60% also succeeded: independent target 2940 RPM, actual 2941 RPM, manual mode. Hottest sample in that separate physical test was 92.1°C. Tests additionally cover 60% retention at 100°C and 129°C; do not describe these simulated temperatures as physical measurements.
- The root cause of the target verification error was write ordering. REA/Hopper shows the established controller switching modes before writing RPM. Aervane now does the same, with passive readback and rollback.
- Missing XPC signing metadata was separately fixed by requesting `kSecCSSigningInformation`. Both app and helper still verify code-signing requirements.
- The command queue preserves the latest user intent, including Auto during an in-flight write. Reconnection and quit use bounded callbacks and ownership-aware recovery.
- The crash journal captures the raw pre-write target even in Auto, covering a crash between mode and target writes. This attribution is not an atomic hardware lock against other controllers.
- The installed redesign applies 100% and 60% through its native controls. The five-minute opt-in timer kept 86% manual control at 285.7 seconds and had restored Auto at 300.8 seconds, verified by an independent SMC probe. The timer was then disabled and the user's 86% restored.
- Menu-bar content/spacing, all effects levels, heat color and Celsius/Fahrenheit were exercised. Selected presentation settings persisted across restart. The settings panel and three-digit Fahrenheit figure fit the compact layout.
- Missing GPU display data now shows an error without losing manual control: independent readback stayed at 60%, target 2940, actual 2941 RPM. Returning to the available sensor clears the error.
- Parent review corrected ice formation during a continuous drag to 100%, interrupted animations, settings-page error visibility, and Auto/Manual accessibility values. Heartbeats run in the common run-loop modes, including native control tracking.
- Short resource samples with the helper running measured about 34 MiB physical footprint for the closed app and 0.33% of one CPU core. Helper RSS was 8.6 MiB; its physical footprint was unavailable without additional privilege. See `docs/performance.md` for methods and limits.

## Sensor and key catalog

See [the complete embedded compatibility catalog](docs/compatibility/mfc-1.5.21/README.md). It contains 237 unique SMC temperature identifiers, 414 sensor occurrences, 205 sensor/group rules, 46 model aliases, 14 fan-label entries and all 15 initialized SMC control constants. The sensor resources were verified identical in both architecture slices; control predicates were checked against ARM64 instructions. Scope limits are explicit.

`Mac16,10` maps to `Macmini11,1`. Aervane now reads its exact ten CPU keys, including previously missing `Te0U` and `Te0V`. The catalog's GPU keys `Tg04` and `Tg12` were absent in the live probe on this machine; GPU selection reports unavailable rather than mislabeling unrelated sensors. The optional-GPU failure path was verified in the installed UI with manual control retained. Other models retain the previous candidate fallback; the catalog is not a claim that Aervane controls every model yet.

## Architecture and file ownership

| Area | Files |
| --- | --- |
| Menu bar, panel lifecycle | `Sources/Zephyr/main.swift` |
| Native UI | `Sources/Zephyr/{PanelView,PercentSlider,Theme}.swift` |
| Presentation preferences and pure visual rules | `Sources/Zephyr/PresentationPreferences.swift` |
| Model/helper communication | `Sources/Zephyr/{AppModel,HelperClient,HelperInstaller}.swift` |
| Hardware read/write | `Sources/SMC`, `Sources/SMCClient` |
| Authenticated helper, recovery journal | `Sources/ZephyrHelper` |
| Transactions, leases, command queue | `Sources/ZephyrCore` |

Keep native runtime dependency-free. Hardware control currently requires one fan and the supported mode key. Never import vendor binaries, assets or decompiled code. Compatibility facts and independent code are in the repo.

## Collaboration

Actual Claude session `48ef955d-dd80-4094-b719-459f7e1f5917` through the user's `claude-vps` launcher implemented earlier UI/control repairs and the latest glass/ice redesign. Its latest workspace was `/workspace/aervane-ui-20261023`. Claude checked Foundation-only presentation logic on Linux; the parent integrated the patch, fixed review findings and ran the full macOS build, 113 tests and live UI/hardware checks. The integrated repository is authoritative: remote drafts do not include all subsequent local corrections. Start a fresh clone for further work.

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

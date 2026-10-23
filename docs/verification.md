# Final 0.3.0 checkpoint

The final Mac suite passed **257 tests** after the temperature crossfade change. Tests check rounded tabular digit widths, immediate latest values, one replaceable transition, and no fade for unit/source/missing-data changes. Core Animation stores CATransition under its reserved transition key; cancellation now uses that key. Two existing motion fixtures were corrected to exclude style-initialization reactions and render actual mode-switch geometry with system motion enabled.

Installed app captures were refreshed, including an approximately 5-second Dot Grid recording with motion enabled. Apple accepted the final archive, and its ticket was stapled and validated; see distribution.md for the receipt.

# Latest 0.3.0 verification checkpoint

On 2026-10-23 the Mac suite passed 247 tests, including real-time presentation-layer movement at measured rotor rates, both maximum-cooling effects, redundant updates, reopening, and stopping under Reduce Motion. The initial freeze fixture sampled the preceding compositor frame; the corrected fixture commits the stop before taking its stationary baseline. These checks verify motion mechanics, not subjective visual quality.

Installed UI inspection found system Reduce Motion enabled, correctly suppressing motion despite Expressive effects. It was disabled at the user's explicit request and independently read back as false; Reduce Transparency stayed enabled. Two subsequent live slider captures differ across the track. Current development media and screenshots must state the actual app version/settings; old 0.2 assets are not evidence for 0.3.

Actual manual 100% readback: target 4900 RPM, measured 4898 RPM. Manual 76%: target 3724 RPM, measured 3724 RPM. Model support remains limited to the tested M4 Mac mini.

# Verification record

2026-10-23 · M4 Mac mini (Mac16,10), macOS 27.0, Xcode 26.2.

## 0.3.0 regulation checkpoint (before the final slider redesign)

- 230 tests passed on the Mac. The signed app and helper built successfully; strict installed signatures passed.
- Smart at target86°C reduced confirmed targets80→76→71% over a 36-second, 13-sample read-only trace with hottest CPU83.6–86.4°C. The panel displayed CPU PEAK and the slider followed the changing command. See [Smart cooling](smart-cooling.md).
- Auto from Smart restored mode0/target1000. A slider adjustment selected Manual and applied76%: mode1/target3724/actual3725 RPM.
- Light appearance, both slider styles, target persistence, whole-degree Fahrenheit conversion, a three-digit temperature header and the expanded settings explanation were rendered on the installed app.
- The user confirmed physical mouse dragging works and immediately leaves Smart. The automated native interface exercises Accessibility/keyboard paths, not that physical drag.
- This checkpoint passed notarization, but its archive is superseded by the requested slider redesign and is not a public release. New rendering, performance, signing and distribution checks remain required for the final design.

## 0.2.0 historical verification on the development Mac

- 153 tests pass: sensor decoding and discovery, fan limits, write order/settling/rollback, leases, journals, client deadlines, command queuing, optional timer behavior, native slider handlers and presentation rules.
- Production app and helper compile, Developer ID signing with secure timestamps succeeds, and `codesign --verify --deep --strict` passes. The final 0.2.0 archive is accepted by Apple, stapled, and passes ticket validation, Gatekeeper assessment and extracted signature verification.
- The development ZIP was extracted and its signature checked again. Packaging omits filesystem resource metadata after a reproduced FinderInfo/resource-fork failure; `tools/release.sh` now checks the extracted archive as well as the original bundle.
- The helper is approved, runs as administrator, and accepts the signed app over authenticated XPC. A fresh unregister/register cycle started the Developer ID-signed helper and applied 76%: mode 1, target 3724 RPM, actual 3723 RPM, hottest CPU sample 93.3°C. No extra authentication was needed on the already-approved Mac.
- Real 100% write: independent readback `F0Md=1`, `F0Tg=4900`. Actual speed settled near 4900 RPM after about six seconds. Starting hottest CPU sample: 98.8°C.
- Restore: independent `F0Md=0`, then firmware reduced target and actual speed to about 1000 RPM.
- Actual panel Boost and Auto actions work. After removing the artificial temperature gate, Balanced 60% also applies: `F0Md=1`, target 2940, actual 2941 RPM. That physical sample's hottest temperature was 92.1°C.
- Separate automated cases verify 60% manual control is accepted and retained at 100°C and 129°C with fresh telemetry and a live lease. These are simulated temperatures, not additional hardware measurements.
- The exact ten M4 CPU keys all read successfully. Catalog GPU keys `Tg04`/`Tg12` were absent in the live probe; GPU display correctly remains unavailable instead of substituting unrelated temperatures.
- Keyboard and accessibility value adjustments, preview/applied distinction, preset editing/persistence and native text editing were previously exercised in the installed app.
- The redesigned installed panel was exercised at 100% and 60%, with independent mode/target readback. Choosing the unavailable GPU sensor at 60% showed an error while manual mode, target 2940 RPM and actual 2941 RPM were retained. Returning to the available sensor cleared the error.
- The user-enabled five-minute timer was checked with independent probes every 15 seconds: manual 86% at 285.7 seconds, Auto at 300.8 seconds and still Auto at 330.8 seconds. It was then switched off and the user's 86% restored. Default indefinite manual mode also has an automated seven-day no-expiry case.
- Menu-bar icon/temperature options, Compact/Comfortable spacing, all three effects levels, heat color and units were exercised. Presentation preferences persisted across app restart. A three-digit Fahrenheit reading fitted the header. Actual dark-appearance main and settings captures are in `docs/assets`.
- A regression case failed before the drag-to-100% ice correction and passes afterward. It checks that continuous pointer tracking forms the crown while the thumb itself stays immediate. Auto/Manual now exposes distinct selected values in the actual accessibility tree.
- The draft editor keeps `123am` as typed text without triggering fan shortcuts. Escape discards edits, Return saves, ⌘, opens settings, and a coordinate right-click opens the preset context menu in the installed app.
- The window now clips its material and content to one rounded boundary, refreshes its shadow after size changes, and sits two points below the menu-bar trigger. The app-window capture is clean, and the user confirmed that the outer rectangular outline is gone.
- Channel and Dot Grid are both rendered in the installed app. Switching at 76% preserved mode 1 and target 3724 RPM (actual 3722 RPM after the switch); the style choice is independent of effect intensity. Both styles were checked at 100%, and the new Settings row fits without clipping.
- The new Cooling Channel is rendered in the installed app. Boost independently read back target 4900 / actual 4906 RPM; keyboard Right/Left changed 76→77→76%, and Effects Off removed the decorative frost.
- Closing the panel removes transient layer animations. A 30-second background sample with the helper active measured 0.33% of one core for the app; see [resource measurements](performance.md) for memory and sampling limits.
- REA/Hopper CLI produced saved evidence for the control routines, obfuscated constants and model predicates. All five embedded resource pairs match between Intel and ARM slices.

## Public release installation

Version 0.2.0 is published at [GitHub Releases](https://github.com/kirniy/aervane/releases/tag/v0.2.0), with the cask in [kirniy/tap](https://github.com/kirniy/homebrew-tap). Source CI passed at `a20130f`. A fresh `brew install --cask kirniy/tap/aervane` downloaded the public archive, verified its checksum and installed it in Applications. The cask passes local style and [the online Homebrew audit on GitHub’s macOS runner](https://github.com/kirniy/homebrew-tap/actions/runs/39855983205). Local audit setup rejects Xcode 26.2 on macOS 27; the supported runner completed the same check. The cached archive SHA-256 matches `34c6a12cb9ae9255eb37cd5a4e827b11e1251526dd6165b96ff70f6126263991`. Strict installed signatures and the stapled ticket validate.

The first launch showed macOS’s normal Internet-download confirmation, explicitly stating that Apple checked the app and found no malicious software. After Open, the app launched and a newly registered helper applied 76%: mode 1, target 3724 RPM, actual 3725 RPM. Dot Grid persisted across replacement/relaunch, and Return to Auto remained off. Channel was selected afterward and manual 76% left active at the user’s request.

`spctl` reported `source=Notarized Developer ID`, but also `override=security disabled` from this Mac’s existing global configuration. That configuration was not changed. Apple’s accepted notarization result, stapled ticket and signed code were separately verified; this is not a test of every clean Mac’s policy configuration.

## Remaining checks

- Repeated clicks on the actual menu-bar status item, and physical pointer verification of the forthcoming slider redesign. Dragging on the regulation checkpoint is user-confirmed; CUA handler tests do not substitute for that evidence.
- Real VoiceOver, system Reduce Motion/Transparency, 1× displays and multiple screens. Light and dark appearance have been rendered at different checkpoints; final-design captures remain required.
- Physical crash, sleep/wake, lease-expiry and fault-injection recovery beyond the normal verified Auto restoration. Automated recovery tests cover the corresponding policy and journal paths.
- Additional Mac models, multiple fans and alternate mode-key implementations.


No flawless or universal-hardware-support claim is made.


## 0.4.0 — 2026-10-23

- Mac suite: 300 passing tests (105 core, 13 SMC, 171 interface, 11 helper), Xcode 27.1. Subsequent focused chart and telemetry tests passed after the Accessibility-enabled fix and explicit CPU-average/peak synchronization assertion.
- Installed-app checks: Smart target dragged physically from 70 to 72°C; bracket keys stepped it back to 70°C; Accessibility set it to 71°C and back. Target changes kept Smart enabled. Actual live Dot Grid motion was captured below maximum cooling.
- Replayed onboarding through Settings, selected Temperature only, and verified `F0Md=0`, target 1000 RPM, current 1005 RPM using the independent probe. Re-enabled fan controls through Settings.
- Normal quit independently verified Auto before helper replacement. Return-to-Auto preference remained disabled. Existing target preserved at 70°C.
- Independent temperature/fan failures and fanless monitoring paths use simulated fixtures; physical hardware coverage remains the M4 Mac mini.
- Menu-bar/panel use the same TemperatureReadout in all modes; regression uses CPU average 68°C versus Smart peak 74°C, Fahrenheit and stale telemetry. App-window captures do not include the desktop menu-bar item.
- Full VoiceOver navigation, multi-display, fanless hardware and fresh-account OS authorization prompts remain unverified.

Public Homebrew 0.4.0 installation was then verified. The final chart target is correctly exposed as an enabled Accessibility slider. Existing helper approval was reused. Final readback: `F0Md=1`, `F0Tg=3724`, `F0Ac=3725` (76% manual); Smart off, Return to Auto off, target preference 70°C.

# Verification record

2026-10-23 · M4 Mac mini (Mac16,10), macOS 27.0, Xcode 26.2.

## Confirmed on the development Mac

- 89 tests pass: sensor decoding and discovery, fan limits, write order/settling/rollback, leases, journals, client deadlines, command queuing and native slider handlers.
- Production app and helper compile, development signing succeeds, and `codesign --verify --deep --strict` passes.
- The helper is approved, runs as administrator, and accepts the signed app over authenticated XPC.
- Real 100% write: independent readback `F0Md=1`, `F0Tg=4900`. Actual speed settled near 4900 RPM after about six seconds. Starting hottest CPU sample: 98.8°C.
- Restore: independent `F0Md=0`, then firmware reduced target and actual speed to about 1000 RPM.
- Actual panel Boost and Auto actions work. After removing the artificial temperature gate, Balanced 60% also applies: `F0Md=1`, target 2940, actual 2941 RPM. That physical sample's hottest temperature was 92.1°C.
- Separate automated cases verify 60% manual control is accepted and retained at 100°C and 129°C with fresh telemetry and a live lease. These are simulated temperatures, not additional hardware measurements.
- The exact ten M4 CPU keys all read successfully. Catalog GPU keys `Tg04`/`Tg12` were absent in the live probe; GPU display correctly remains unavailable instead of substituting unrelated temperatures.
- Keyboard and accessibility value adjustments, preview/applied distinction, preset editing/persistence and native text editing were previously exercised in the installed app.
- REA/Hopper CLI produced saved evidence for the control routines, obfuscated constants and model predicates. All five embedded resource pairs match between Intel and ARM slices.

## Remaining checks

- Physical pointer dragging and repeated clicks on the actual menu-bar status item. CUA's app-scoped native interface returns `AXError.notImplemented` for pointer drag/click on the custom slider; handler tests do not substitute for physical pointer testing.
- Real VoiceOver, Reduce Motion/Transparency, light appearance, 1× displays and multiple screens.
- Physical crash, sleep/wake, lease-expiry and fault-injection recovery beyond the normal verified Auto restoration. Automated recovery tests cover the corresponding policy and journal paths.
- Additional Mac models, multiple fans and alternate mode-key implementations.
- Developer ID signing, notarization, public release installation and Homebrew packaging. The current certificate is a development identity.

No flawless or universal-hardware-support claim is made.

# Aervane — development handoff

Updated 2026-10-23. This file is the starting point for Codex, Claude, or a human contributor. Read actual source and rerun checks; this is a progress record, not proof that unfinished paths work.

## Product brief

A very lightweight native macOS menu-bar-only fan utility. CPU temperature is the user's confirmed default. Opening the status item reveals one compact glass panel with a directly draggable percentage slider, automatic control, and editable presets. No separate fan-speed dialog. The user wants exceptional polish: restrained microinteractions, a custom identity, and the illuminated graduated/pixel texture of Claude Code / Codex effort sliders. Respect Reduce Motion and keyboard/VoiceOver use. Never run decorative animations while hidden.

The first chrome propeller icon was rejected. The current folded airflow icon is a second direction, not yet approved. The working name changed from Zephyr to Aervane after exact npm/Homebrew checks; see docs/name-check.md. Some internal target names still use Zephyr.

## Most recent user feedback — priority zero

1. Clicking the menu-bar item while open must close the panel. A dismissal monitor previously closed it on mouse-down and the button action reopened it on mouse-up.
2. The slider did not drag because it was disabled until the privileged helper was enabled. It must respond immediately and distinguish preview from applied state.
3. The slider and overall craft need a stronger design pass. Use the effort-slider references as interaction inspiration; keep the finished app native and legible.

Source now excludes the status-item rectangle from outside-dismiss monitors and runs the button action on mouse-down, avoiding close/reopen ordering. Slider previews work before setup. Claude's redesigned dot field uses native mouse event handlers, a larger hit area, cached layer images, and an inline editor. Codex fixed zero-size layer initialization, keyboard focus, accessibility setters, standard Edit commands, and hover cleanup.

**Keyboard, AX adjustments and preset edit persistence were tested in the running Mac app. Physical pointer dragging and repeated status-item clicks remain unverified:** the available app-scoped automation cannot drag this control or address the status item. The control's pointer handlers are covered by regression tests; do not represent those as physical pointer testing.

## Architecture

| Area | Files | Notes |
| --- | --- | --- |
| Menu bar, panel lifecycle | Sources/Zephyr/main.swift | AppKit, NSPanel, NSStatusItem, native glass on 26+ |
| Interface | Sources/Zephyr/{PanelView,PercentSlider,Theme}.swift | Custom native controls, inline settings/preset editor |
| Model/helper client | Sources/Zephyr/{AppModel,HelperClient,HelperInstaller}.swift | Serialized reads, XPC, ServiceManagement |
| Hardware | Sources/SMC, Sources/SMCClient | Independent IOKit envelope; currently fan index 0 |
| Helper | Sources/ZephyrHelper | Shared serial lease controller; authenticated XPC |
| Pure policy | Sources/ZephyrCore | Limits, ownership, signing requirements, timeout state |
| Verification | Tests, tools/smc-probe.c | Tests do not issue physical fan writes |

## Build and verification

Use Xcode 26.2+ (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). `swift test` passed **30 tests** locally on 2026-10-23; the three UI tests passed again after the final hover/keyboard changes. `tools/build.sh` produced a development-signed app and helper, verified with `codesign --verify --deep --strict`. The latest signed build is also installed at `/Applications/Aervane.app` on the development Mac. No privileged helper has been enabled.

Read-only probe: `dist/Aervane.app/Contents/MacOS/Aervane --probe`.

Local machine: M4 Mac mini, Mac16,10, macOS 27.0. CPU mean and one fan were read successfully. Firmware minimum around 1000 RPM, maximum around 4800 RPM: true 0% is unavailable. UI must not relabel minimum as zero. See `docs/performance.md` for short measured samples, including their limits and the higher startup peak.

The available certificate is an Apple development identity, not Developer ID Application. No private keys or signing credentials belong in this repository. Public notarization is not complete.

## Outstanding work

- Verify open/close by clicking the actual menu bar item repeatedly; outside click and Escape; rapid toggling and multiple displays.
- Finish physical pointer testing: thumb grab, track click, release outside, Escape mid-drag and sample refresh during drag. Keyboard arrows, Shift+arrows, AX set value, and presets work in the live app.
- Check real VoiceOver, Reduce Motion, light mode, 1× displays, and multiple monitors. The dark capture passed an independent Impeccable visual review (`ship`); that verdict covers the captured appearance only. The README uses an actual development capture.
- Finish helper installation on the signed app and verify controlled physical writes, actual readback, automatic restoration, app crash, lease expiry, sensor faults, and helper failure. No physical writes have been tested yet.
- Expand model sensor coverage and support for more than one fan. Strict SMC type/length/bounds validation, missing discovered CPU sensors, and Intel fallback have automated coverage. Current physical hardware coverage is narrow.
- Physically verify the helper's journal/restart recovery. Production-adapter tests cover non-owner journal preservation, previous target recovery, obsolete journal rejection, startup retry without clients, and restrictive permissions.
- Add deterministic AppModel XPC/poll ordering tests. Current generation guards discard pre-command polls and late callbacks from disconnected helpers; polling pauses during commands. These race fixes received source review but not a mocked callback-order regression suite.
- Create and verify a notarized release, then a real Homebrew cask. The current cask is a template only.
- Keep the project runtime dependency-free. DESIGN.md and `.impeccable/design.json` are present and grounded in the current native sources.

## Collaboration

Codex handled local macOS integration, hardware policy/recovery, signing, repository management and testing. Claude was actually invoked through the user's `claude-vps` launcher, cloned the public repo, and redesigned `PercentSlider.swift`, `PanelView.swift` and `Theme.swift`. Its draft was imported, compiled and corrected on the Mac. A subsequent Claude review found hover and busy-state polish issues, which were incorporated.

Claude's VPS worktree is `/workspace/aervane-design-20261022`. Its original draft is older than this repository: **pull/use this repository as the source of truth; do not replace the integrated files with that draft.** The follow-up session ID is `48ef955d-dd80-4094-b719-459f7e1f5917` for the user's launcher. The first long-running print session was stopped after its files were retrieved; the concise follow-up completed successfully. No other Claude work was interrupted.

Coordinate file ownership before concurrent editing. Linux/VPS review cannot validate AppKit rendering or hardware. Every imported change still needs a Mac build and appropriate verification. See `CLAUDE.md`.

## Reverse-engineering scope

REA/Hopper decompilation verified the installed helper's SMC read/write envelope and XPC write-handler behavior. This is a bounded interoperability investigation, not a claim that every feature or function in Macs Fan Control has been reverse engineered. Only independent code and summarized evidence belong in the public repo. See docs/reverse-engineering.md.

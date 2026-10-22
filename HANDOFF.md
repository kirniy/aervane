# Aervane — development handoff

Updated 2026-10-22. This file is the starting point for Codex, Claude, or a human contributor. Read actual source and rerun checks; this is a progress record, not proof that unfinished paths work.

## Product brief

A very lightweight native macOS menu-bar-only fan utility. CPU temperature is the user's confirmed default. Opening the status item reveals one compact glass panel with a directly draggable percentage slider, automatic control, and editable presets. No separate fan-speed dialog. The user wants exceptional polish: restrained microinteractions, a custom identity, and the illuminated graduated/pixel texture of Claude Code / Codex effort sliders. Respect Reduce Motion and keyboard/VoiceOver use. Never run decorative animations while hidden.

The first chrome propeller icon was rejected. The current folded airflow icon is a second direction, not yet approved. The working name changed from Zephyr to Aervane after exact npm/Homebrew checks; see docs/name-check.md. Some internal target names still use Zephyr.

## Most recent user feedback — priority zero

1. Clicking the menu-bar item while open must close the panel. A dismissal monitor previously closed it on mouse-down and the button action reopened it on mouse-up.
2. The slider did not drag because it was disabled until the privileged helper was enabled. It must respond immediately and distinguish preview from applied state.
3. The slider and overall craft need a stronger design pass. Use the effort-slider references as interaction inspiration; keep the finished app native and legible.

Source changes now exclude the status-item rectangle from outside-dismiss monitors and permit slider previews before helper setup. **These fixes still need real pointer/keyboard testing. Do not call them verified on the strength of compilation.**

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

Use Xcode 26.2+ (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). `swift test` passed **14 tests** locally on 2026-10-22 before the latest UI work. `tools/build.sh` produced a development-signed app and helper, verified with `codesign --verify --deep --strict`.

Read-only probe: `dist/Aervane.app/Contents/MacOS/Aervane --probe`.

Local machine: M4 Mac mini, Mac16,10, macOS 27.0. CPU mean and one fan were read successfully. Firmware minimum around 1000 RPM, maximum around 4800 RPM: true 0% is unavailable. UI must not relabel minimum as zero. One sample of physical memory was about 26 MB, **not a settled benchmark**. No performance claim is approved yet.

The available certificate is an Apple development identity, not Developer ID Application. No private keys or signing credentials belong in this repository. Public notarization is not complete.

## Outstanding work

- Verify open/close by clicking the actual menu bar item repeatedly; outside click and Escape; rapid toggling and multiple displays.
- Redesign and test slider pointer drag, thumb hit area, click-to-position, keyboard, VoiceOver, disabled/stale data, percent readback. Preview must not be mistaken for applied speed.
- Improve in-panel hierarchy and icon clarity. Capture actual light/dark UI for the README after validation, not a fabricated mockup.
- Finish helper installation on the signed app and verify controlled physical writes, actual readback, automatic restoration, app crash, lease expiry, sensor faults, and helper failure. No physical writes have been tested yet.
- Audit strict SMC type/length/bounds validation, model sensor coverage, missing hottest sensors, and support for more than one fan. Current hardware coverage is narrow.
- Evaluate persistence/recovery if the helper itself crashes while manual control is active.
- Measure settled memory/CPU with the panel closed and open. Publish methodology and actual results.
- Create and verify a notarized release, then a real Homebrew cask. The current cask is a template only.
- Add final DESIGN.md and design tokens after review. Keep the project runtime dependency-free.

## Collaboration

Codex is handling local macOS integration, hardware validation, repository management, and the event-handling regression. Claude via the user's `claude-vps` launcher is invited to redesign the interface and propose code changes. Work on a branch or patch; coordinate file ownership before editing. Linux/VPS review cannot validate AppKit rendering or hardware. Codex must compile, inspect the real interface, and test every imported change on the Mac.

## Reverse-engineering scope

REA/Hopper decompilation verified the installed helper's SMC read/write envelope and XPC write-handler behavior. This is a bounded interoperability investigation, not a claim that every feature or function in Macs Fan Control has been reverse engineered. Only independent code and summarized evidence belong in the public repo. See docs/reverse-engineering.md.

# Aervane
<!-- impeccable:product-schema 1 -->

## Platform
Native macOS menu bar application (AppKit).

## Stack
Delegated by the user. Swift with a small C IOKit bridge; zero third-party runtime dependencies. AppKit for low baseline memory and native glass.

## Users
Mac users who want to see CPU temperature at a glance and change cooling without opening a separate window.

## Product Purpose
Replace nested fan menus and modal controls with one immediate, beautiful menu bar panel.

## Operating Context
The user's Mac mini M4, macOS 27.0. CPU temperature is the confirmed default; alternatives are selectable. macOS 14+ baseline, system Liquid Glass on macOS 26+.

## Capabilities and Constraints
Menu-bar-only. Percentage controls; editable presets; no speed-adjustment dialog. Must respect hardware bounds, reflect actual state, restore automatic control on exit, handle stale sensor data and competing controllers. True zero is only possible if firmware supports it. Native, lightweight, no telemetry. Open-source project and Homebrew distribution requested. Actual memory and CPU to be measured. Developer ID signing/notarization availability remains unconfirmed.

## Brand Commitments
Modern native glass, beautiful custom icon, snappy microinteractions. The user named Emil and Impeccable for design guidance and Ideogram for artwork. Aervane replaces the earlier working name Zephyr after exact package-name checks.

## Evidence on Hand
Installed Macs Fan Control 1.5.21 and the user's screenshots. REA/Hopper verified the SMC envelope and write path; live MCP connection is repaired. Actual native panel captures and a short local resource measurement exist. Hardware-write validation and public distribution remain incomplete.

## Product Principles
- One direct gesture for fan adjustment.
- Tell the truth about the hardware.
- Spend resources only when they serve the interaction.
- Make automatic control easy to recover.

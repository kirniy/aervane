# Aervane

Read HANDOFF.md, PRODUCT.md, and the relevant source before making changes.

Swift/AppKit menu-bar-only macOS app. No Electron, web view, runtime packages, telemetry, or network polling. Xcode 26.2+ is required to build; deployment target is macOS 14.

Validate with `swift test` and `tools/build.sh` on a Mac. VPS/Linux work must be clearly marked uncompiled until checked on macOS. UI work needs actual pointer, keyboard, and rendered verification. Never claim fan writes, restoration, notarization, or Homebrew installation are verified without direct evidence.

Fan percentages are physical speed divided by the firmware maximum, clamped to the hardware minimum. Never pretend that a nonzero floor is 0%. Keep privileged writes behind authenticated XPC and preserve automatic restoration paths. Never test hardware writes without coordinating with the person working on the Mac.

Keep generated output in ignored work/ or dist/. Do not commit credentials, signing material, private machine data, proprietary binaries, or decompiled source. Document verification gaps in HANDOFF.md.

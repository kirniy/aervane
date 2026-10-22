# Verification record

2026-10-23 · M4 Mac mini (Mac16,10), macOS 27.0, Xcode 26.2.

## Confirmed

- `swift test`: 30 tests passed. Twelve core ownership/safety tests; five production helper-adapter/journal tests; ten SMC decoding/bounds/sensor tests; three AppKit slider tests.
- Slider tests reproduce the initial zero-size rendering regression, exercise drag preview/floor/single-release commit, and check accessible value/debounced commit. These call the native control's handlers in a test window; they do not synthesize a physical mouse drag.
- Production app and helper build and pass `codesign --verify --deep --strict`. Available identity is an Apple development identity, not Developer ID Application.
- Live read-only CPU and fan probe succeeds. The reported hardware floor is 21% on this Mac.
- In the actual signed app: arrow adjustment, Shift+arrow steps, accessible values, preview labels, measured/target separation, editing preset values across editor/settings transitions, and Command-A in preset text fields.
- Dark panel and inline editor were visually captured. Independent Impeccable review returned `ship` for these captures. This is a visual verdict, not a hardware or distribution certificate.
- Live REA/Hopper MCP open/analyze/close workflow succeeds; see the investigation record.

## Still required

- Actual pointer drag, click-to-position, status-item repeated click, outside dismissal, Escape and rapid toggling. App-scoped automation activates/reopens the app during observation, cannot address its status item, and reports `AXError.notImplemented` for pointer dragging. No physical verification is claimed.
- Helper registration/approval, authenticated XPC in the installed app, physical fan writes and readback, Auto restoration, app kill, helper kill, lease expiry, sleep/wake and sensor-fault recovery.
- Real VoiceOver, light mode, Reduce Motion, 1× rendering, multiple displays, additional Mac models and multiple fans.
- Deterministic model callback-order tests for polls crossing XPC commands and disconnected connections.
- Developer ID signing, notarization, release installation and a real Homebrew cask.

No production-ready or flawless-operation claim is made while these remain open.

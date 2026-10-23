# Mac compatibility

Aervane ships one universal app and helper for Intel and Apple Silicon, on macOS 13 and later. Hardware is discovered at runtime: processor architecture is not a fan-control whitelist.

## Cooling controls

One slider controls the Mac's fans together. A requested percentage is calculated separately against each fan's maximum speed, then limited to that fan's reported minimum. Different fans can therefore run at different RPM while following the same cooling request. The app does not invent a zero-RPM mode when firmware reports a nonzero minimum.

Fanless Macs provide temperature monitoring without fan setup. A failed hardware read is distinguished from an actual zero-fan inventory.

Control protocols include the Intel aggregate manual-mode mask and the uppercase/lowercase per-fan mode keys. Model-dependent transaction flags are selected using the compatibility catalog and validated register metadata. Reads and writes use the same protocol; an unsuccessful write is not retried through guessed alternative registers.

## Temperatures

The built-in catalog normalizes model aliases and selects CPU/GPU sensors by family. Apple Silicon also supports read-only HID temperature events selected by exact CPU/GPU service names; Macs without those services use SMC. A bounded discovery path handles additional known sensor-key patterns. Smart cooling uses the hottest available selected CPU/GPU sensor, independently of the display preference. Missing or invalid temperature data is reported explicitly.

## Release checks

Both the application and privileged helper include native arm64 and x86_64 code. Distribution preparation verifies all signatures and checks the actual deployment target of each slice. CI runs the test suite on Apple Silicon and Intel runners.

See the linked verification receipt for protocol fixtures, failure recovery, runtime checks and the exact release revision.

# Hardware findings

This document records observations from the installed Macs Fan Control 1.5.21
bundle and a read-only AppleSMC probe on the development Mac mini (Mac16,10,
M4). It is a compatibility guide, not a copy of the vendor implementation.

## Shipped artifact observations

The app executable is a universal Mach-O (`arm64` selected on this machine),
SHA-256 `65146b1964ae6f5a37f87c00ea9bd3b1d9a51265f72f022fbb0c3458487da8b3`.
The bundle links IOKit, ServiceManagement, Security and Qt. Its Info.plist
declares a privileged executable named
`com.crystalidea.macsfancontrol.smcwrite`. The helper is also universal and
imports IOKit. Readable helper strings establish an XPC command surface with
`process_command_open`, `process_command_close`, and
`process_command_write`; the helper validates the requesting code signature.
The vendor helper is not linked or reused by Aervane.

REA Mach-O summary evidence: `ev_ebd07ad30ced5ec8b3a9f1e4922422e1f04b20577c6567e6f83ad1587b27b066`
(derived shipped-artifact evidence; symbol/import completeness is limited by
stripping and the provider did not return an exhaustive list). Hopper was
subsequently verified through the installed REA CLI after the stale MCP session
was identified. It successfully decompiled `_SMCReadKey` and `_SMCWriteKey`
from the helper. Evidence IDs are
`ev_f8c1676a3410fdca338264a6a93a710edcc8c41aa5c6c02b47fc87e632b1098b` and
`ev_d0cfc7bbbc8ce05bd4ba63516b0ef2d146575602c2f2270a4978fcc3cc64261e`.
Hopper confirms selector 2 with an 80-byte envelope, a static key-info cache,
and write-side validation that the requested data size matches the key's
existing size before issuing the write. A second concurrent open was rejected
because the same target was held by REA session
`e5f82a47-eda3-4422-9c14-7616906d78c4`; the CLI result above is the valid
decompilation. A further Hopper trace of `__Z21process_command_writePv`
(`ev_9510df99e73220684aef7dbd9a67fd38ad61d56c426a04fecebf776725c0be70`)
shows the helper accepting XPC `key` and hexadecimal `value` strings, decoding
bytes, and returning a success/error reply. Aervane does not expose that raw
surface to the UI; its API validates the fan index, percentage, and firmware
range first.

The REA Codex registration was repaired with `rea setup --client codex --yes`;
the doctor check then reported an aligned registration and an available Hopper
provider. The already-running Codex MCP connection retained an older Hopper
runtime, however: after closing the stale session, the live MCP call still
returned `cleanup_incomplete` for `hopper-document` and `/tmp/rea-IJ2EMM`.
No other REA server or Hopper process was stopped. The CLI path is therefore
the verified recovery path for this task; a fresh Codex MCP connection is
required before claiming live MCP decompilation.

After isolating and closing the translocated, unlicensed Hopper process, the
live REA MCP Hopper provider opened the helper and decompiled `_SMCReadKey`
successfully. Current MCP evidence is
`ev_62c8244dbc4e2d9d220b108ff8512aa2d10f9fff9bfe7cf464ab14302b9eb3a5`; the
provider reported the helper's arm64 slice, selector-2 `IOConnectCallStructMethod`
calls, an 80-byte request envelope, lazy `KeyInfoMap` caching, and the
key-name reconstruction path. The closed evidence snapshot is stored at
`work/rea/hopper-mcp-read-key.json`.

## AppleSMC read protocol

`Sources/SMC/SMC.c` implements the independent AppleSMC user-client envelope:
`IOServiceMatching("AppleSMC")`, `IOServiceOpen`, and
`IOConnectCallStructMethod` selector 2. The 80-byte parameter layout is the
standard key/version/p-limit/key-info/result/status/command/data/bytes envelope.
Reads use command 9 (key info), then command 5 (read bytes), with the returned
key data size copied back into the second request. Constrained writes use mode
0 for automatic and mode 1 for manual, with `F%dTg` as a `flt ` target. Some
firmware reports mode 3 for system-managed automatic control; the reader treats
both 0 and 3 as automatic.

On this M4 Mac, `FNum` reads as one fan. `F0Ac`, `F0Mn`, and `F0Mx` are `flt `
values and are available without root. During the probe they reported a
current value around 4733 RPM, a minimum around 1000 RPM, and a maximum around
4787 RPM (values fluctuate). These are raw observations. Aervane exposes fan
speed as current RPM divided by the reported maximum RPM, while writes use maximum RPM × requested percentage / 100, clamped to the
firmware minimum and maximum.

The older Intel keys (`TC0P`, `TC0E`, `TC0F`) are not present on this M4. The
M4 exposes per-core CPU keys in the `Tp*` and `Te*` families; the implementation
averages only those model-mapped CPU keys. `TCMb`, `Ts0S`, and `Tg0D` are also
present as `flt ` values, but are not relabeled as CPU sensors. A read-only
sample decoded them to approximately 79.5 C, 61.1 C, and 65.3 C respectively.

The key-count/index commands are rejected on this platform, so Aervane uses a
small model-aware candidate list and verifies each key by key-info/read. This
is an explicit coverage limit, not evidence that no additional sensors exist.

`zsmc_set_fan_percent` computes a physical percentage of `F%dMx` and clamps
the result to `F%dMn`…`F%dMx`. The UI clamps its minimum to the corresponding
nonzero percentage. True 0% is available only when the firmware minimum is zero.
A nonzero minimum is never relabeled as zero. Writes have not yet been verified
on physical hardware.

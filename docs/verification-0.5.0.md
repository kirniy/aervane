# 0.5.0 compatibility verification

## Build and protocols

The universal app and privileged helper contain arm64 and x86_64 slices, each targeting macOS 13. Developer ID signatures are checked for both architectures. The release archive is 3.6 MB; no runtime package dependencies were added.

The native Mac suite passed **394 tests**: 191 Core, 177 Interface, 21 Helper and 5 SMC. The same 394 tests passed through the x86_64 test executables under Rosetta. The Intel executable also passed a live read-only probe and correctly selected the host hardware platform rather than its process architecture.

Fixtures cover zero, one, two, six and ten fans; unequal hardware limits; float and fixed-point speeds; uppercase/lowercase per-fan mode registers; legacy Intel masks with unrelated bits preserved; aggregate-gate write ordering and readback; delayed firmware acknowledgement; rollback; journal restart; topology changes; foreign targets; and malformed or missing registers. Sensor tests cover model aliases, catalog matching, GPU peaks, HID preference, transient failures and failed known-sensor handling.

REA checked the installed Macs Fan Control protocol paths. Independent implementation and catalog evidence are recorded in [the compatibility catalog](compatibility/mfc-1.5.21/README.md). The HID adapter was reviewed for ABI, optional symbol availability and CF ownership. Live enumeration found no matching HID services on the development host, so its live readings used the SMC path; HID event values are covered by injected-source tests rather than a physical HID sensor result.

## Signed installation and real control

Installed the notarized universal bundle, verified all architecture signatures, registered its helper and ran the explicit control verification. The independent SMC reader reported:

- Before: Auto, actual 1000 RPM.
- Manual request: 100%, target 4900 RPM, read back independently.
- Eight-second response: actual settled to 4897 RPM.
- Restore: Auto independently confirmed.

Both temperature and fan telemetry remained available in the updated panel. This is a real hardware control check; the multi-model protocol fixtures above are simulated hardware responses, not a claim that every physical Mac model was available for testing.

## Distribution

Source: `5af76dd9fda9edfd05da7f82da6802e723e38543` (the final commit changes only a test fixture for Swift 6.2).

Apple accepted notarization `e1fd2c37-caa7-4aeb-a9e1-c47cc080b5b1`. The stapled ticket and extracted-archive signatures validate. SHA-256: `ac6f3d37ac4c49fa3a2012e517ee7e85d48ca7104d37cfe3a83309f9efd85ebb`.

The development machine has a pre-existing global Gatekeeper override. Signature and stapled-ticket validation are separate checks; this is not a clean-machine Gatekeeper assessment.

Source CI [39999909209](https://github.com/kirniy/aervane/actions/runs/39999909209) passed on native Intel and Apple Silicon runners, including tests, universal builds and rejection of unnotarized distribution.

The public Homebrew upgrade from 0.4.0 to 0.5.0 completed successfully. Installed signatures and stapled-ticket validation passed; the helper reconnected and the live panel resumed Smart at 70°C. Tap source is `317709021d782eb47c86b173fd6a4cf40094eafb`.

Homebrew CI [40000620676](https://github.com/kirniy/homebrew-tap/actions/runs/40000620676) passed on both Intel and Apple Silicon: cask style, online audit, fresh public installation, all-architecture signature verification, stapled-ticket validation and executing the installed signing check. Neither runner registered the helper or attempted hardware writes.

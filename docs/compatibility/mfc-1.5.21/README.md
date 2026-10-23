# Macs Fan Control 1.5.21 compatibility catalog

Extracted from the locally installed universal Mach-O, build 82. Whole-file SHA-256: `65146b1964ae6f5a37f87c00ea9bd3b1d9a51265f72f022fbb0c3458487da8b3`. The five embedded resources were recovered separately from both Intel and ARM slices and verified byte-for-byte identical. Control predicates below come from the ARM64 instructions inspected with REA/Hopper.

## Complete embedded tables

- **237 unique SMC temperature identifiers**, in 385 model-scoped occurrences.
- **29 IOKit sensor occurrences**. These are service sensor names, not four-byte SMC keys.
- **205 sensor/group rules**, flattened into **414 rows**.
- **46 model aliases**, plus **14 fan-label entries** across nine model-selector groups.
- **15 initialized control-related constants**: 13 SMC identifiers/templates and two data-type names. `fpe2` is also used by the RPM-writing path.

| File | Contents |
| --- | --- |
| [sensor-catalog.json](sensor-catalog.json) | All rules, exact group members, labels, attributes, exclusions, aliases, resource offsets and hashes |
| [sensors-by-model.csv](sensors-by-model.csv) | Every sensor occurrence with its model selector and group |
| [smc-temperature-keys.txt](smc-temperature-keys.txt) | Deduplicated four-character SMC temperature identifiers |
| [model-aliases.csv](model-aliases.csv) | Modern identifier → internal model identifier |
| [fans-by-model.csv](fans-by-model.csv) | Fan labels and model selectors |
| [control-keys.json](control-keys.json) | Initialized constants, exact capability predicates and REA evidence IDs |
| [control-keys.csv](control-keys.csv) | Flat control-constant inventory |

Model selectors are preserved exactly, including case, semicolon alternatives, `all`, and the `+` suffix. Resource selection matters: the legacy and ARM tables each have their own `all` group. Do not combine both global groups blindly. The alias table is a separate normalization step; the numeric parser removes non-digit characters from the internal identifier and parses the remaining decimal integer.

## Control identifiers

`{}` is a fan-index placeholder. Case and trailing spaces are significant: `F0Md` and `F0md` are distinct, and `FS! ` / `flt ` each contain a final space.

| Exact value | Role |
| --- | --- |
| `#KEY` | key count |
| `FNum` | fan count |
| `FS! ` | aggregate manual-mode mask |
| `F{}ID` | per-fan identifier |
| `F{}Mn` | minimum fan speed |
| `F{}Mx` | maximum fan speed |
| `F{}Ac` | actual fan speed |
| `F{}Tg` | target fan speed |
| `F{}Sf` | per-fan identifier; exact role not established in this pass |
| `F{}Md` | default per-fan mode spelling |
| `F{}md` | newer alternate per-fan mode spelling |
| `Ftst` | additional aggregate control flag on selected models |
| `LKSB` | initialized SMC identifier; purpose not established in this pass |
| `sp78` | signed fixed-point temperature data type |
| `flt ` | floating-point data type |

`LKSB` is included as a decoded identifier, not asserted to be a data type. Initialization alone does not establish its purpose.

## Model-dependent behavior

Comparisons were checked against ARM64 branch instructions. Hopper pseudocode rendered several strict boundaries incorrectly; the following uses the instructions.

| Predicate | Exact condition |
| --- | --- |
| `requiresNewSMCKeyForManualControl` | `family == MacBookPro and version > 201` |
| `requiresNewF0mdForManualControl` | `(family == MacBookPro and version > 220) or (family == MacStudio and version > 30)` |
| `isModelNotWorking` | `family == MacBookPro and 202 <= version <= 215` |
| `hasZeroRpmMode` | `(family == MacBookAir and version == 81) or (family == MacBookPro and (version in [121,131,132,141,142,152,162,163] or version > 170))` |
| `canTurnOffFans` | `(family == MacBookAir and version == 81) or (family == MacBookPro and (121 <= version <= 132 or 141 <= version <= 142 or version in [152,162,163] or version > 170))` |
| `modelHasNoFans` | `(family == MacBook and version in [81,91,101]) or (family == MacBookAir and version > 100) or family == MacBookNeo` |
| `isT2Chip` | `false in the analyzed arm64 implementation` |

The vendor flag named `isModelNotWorking` is reported as an observed predicate. It is not an independent conclusion that every fan operation fails on those machines. Likewise, a zero-RPM capability flag does not override the current firmware limits. The ARM64 `isT2Chip` result says nothing about its Intel implementation.

The constant-speed path calls the mode writer **before** the target-speed writer. Per-fan modes use the default `F{}Md` spelling or the newer `F{}md` spelling selected above. Applicable MacBook Pro paths also write `Ftst` after per-fan modes. A legacy path uses the two-byte `FS! ` mask. Runtime key availability and metadata remain necessary; do not write every identifier in this inventory.

## Verified Mac mini M4 mapping

`Mac16,10 → Macmini11,1` in the alias resource.

- CPU: `Tp01`, `Tp05`, `Tp09`, `Tp0D`, `Te05`, `Te09`, `Te0H`, `Te0S`, `Te0U`, `Te0V`.
- GPU: `Tg04`, `Tg12`.
- Memory: `Tm1p`.
- Fan label: Exhaust, inherited from the `Macmini8,1+` selector.
- Live control: `F0Md` exists; `F0md`, `Ftst`, and `FS! ` were absent on the test Mac. Mode-first → target was physically verified at 100%, followed by Auto.

## Reproduce the resource extraction

From the repository root, with the matching installed build:
```sh
python3 tools/extract-mfc-catalog.py \
  "/Applications/Macs Fan Control.app/Contents/MacOS/Macs Fan Control" \
  docs/compatibility/mfc-1.5.21
```

The script uses only Python’s standard library, rejects an unexpected binary hash, verifies both architecture copies, and emits compatibility facts. It does not launch the application or access hardware. Control-key facts were separately decoded from the initializer and checked with Hopper; their evidence identities and addresses are retained in JSON.

## Coverage boundary

This is the complete **embedded sensor/fan/model catalog and inspected SMC initializer**, not a dump of every register on every Mac ever made. MFC can enumerate additional keys dynamically. The Intel aggregate-mode reader/writer and target decoder were subsequently traced; the details below record those results. Presence in these tables does not establish that a key exists, is writable, or is supported by Aervane on every matching machine. Aervane’s physical control validation is currently one Mac16,10. No proprietary binaries, XML resources, or decompiled implementation are redistributed here.


## Additional control-path analysis

The Intel aggregate mode writer constructs a two-byte `FS! ` value `[0x00, mask]`; bit 0 selects fan 0, bit 1 selects fan 1, and so forth through the low byte. The decoder uses the same byte order. An independent implementation must preserve unrelated mask bits when changing its participating fans, rather than replacing the entire register. The observed `fpe2` target format is big-endian unsigned fixed point with two fractional bits.

The ARM64 mode writer at `0x10004b2a8` applies the model-gated `Ftst` flag **after the per-fan mode writes and before target writes**. It writes one byte: `1` when any fan is manual, `0` when all are automatic. This is a transaction-level flag, not an additional per-fan speed. Register presence, type and size still need runtime validation.

REA evidence identities:

- Intel mode reader: `ev_5f90ac5c6d056b5349bf5b7f7a12b4026d1ca0c22ca642608871a8056d6464d2`.
- Intel fixed-point decoder: `ev_82f35e145b95da5184b7486a2a33e96d075f7cef23244630e587f49109e03831`.
- Helper write byte order: `ev_17e5838def2ce79a359188157076e355988599965007890d8260a28c6dcde1ea`.
- ARM64 mode/Ftst writer: `ev_cc45fbfa175b4a6e11f0d96aba2fa6f046976bd9d5b72e813d6483c0242fa974`.

These are protocol observations. No vendor implementation is linked, copied into the app, or distributed.


Protocol selection was traced separately on Intel. Initialization probes `FS! ` first and selects the aggregate protocol when that probe succeeds, including when per-fan keys also exist. Otherwise it selects the model-appropriate per-fan protocol. Both mode reads and writes use that stored selection; a later failure does not trigger a silent switch. There is no separate T2 test in this selection routine. Evidence: `ev_27513b6fcfe6503bd997069113f8fd0faedaa05e7779ddb5e6f0454d0e60325f` and `ev_058550683546eb9f6666dd77438645646040dd74b039e3fde8ed521fd49d868e`.

### Apple Silicon HID temperature events

The separate HID path enumerates services matching `PrimaryUsagePage=0xff00`, `PrimaryUsage=5`, selects exact catalog Product names and reads event type `15`, temperature field `0xf0000`. Each poll copies a fresh event. CPU and GPU service names are distinct; PMU, SSD and ambient sensors are not substituted for CPU temperature. REA evidence: `ev_717aa288b720aa7566f34a99c3afd9c77395e8619bdaf87b59760b2856f45269` (discovery), `ev_b4ff291c43c1080f6841940b0ace81f4aa6ed5bcb72bf210cc1d2c190500220e` (event read).

Aervane implements this read-only interface independently with optional dynamic symbols, retained service/client lifetimes and balanced event ownership. `IOHIDFloat` uses the 64-bit `double` ABI. Macs without matching services retain their SMC sensor plan. A failed known HID sensor propagates an error instead of silently switching to a cooler subset.

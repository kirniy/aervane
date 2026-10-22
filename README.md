<p align="center">
  <img src="docs/assets/aervane-icon.png" alt="Aervane folded airflow icon" width="160">
</p>

<h1 align="center">Aervane</h1>
<p align="center">A little more quiet. A little more control.</p>
<p align="center">
  <a href="https://github.com/kirniy/aervane/actions/workflows/ci.yml"><img src="https://github.com/kirniy/aervane/actions/workflows/ci.yml/badge.svg" alt="Build and tests"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14 and later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-7bd5bb" alt="MIT license"></a>
</p>

A native Mac menu-bar utility with CPU temperature at a glance, direct percentage-based fan control, and editable presets in one glass panel. Built with Swift, AppKit, and a small C bridge to AppleSMC. No embedded browser, runtime packages, telemetry, or background network requests.

**Development preview.** Live temperature/fan reads and a signed local build have been verified on an M4 Mac mini. Privileged installation and physical fan writes are still being validated. The interface is being revised following hands-on feedback. There is no production release or working Homebrew cask yet.

### Build locally

Requires a Mac and **Xcode 26.2 or newer** to compile the native glass interface. The resulting app targets macOS 14+, with a vibrancy fallback on versions before 26. Sensor compatibility is currently verified only on the M4 Mac mini.

```sh
git clone https://github.com/kirniy/aervane.git
cd aervane
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
tools/build.sh
open dist/Aervane.app
```

For a development-signed build, set `SIGN_IDENTITY` to an identity from `security find-identity -v -p codesigning`. The default is ad hoc signing, suitable for read-only interface work. A Developer ID identity and notarization are required for the intended public distribution workflow.

### How control works

- Click the menu bar temperature to open or close the panel.
- Drag the fan slider or choose a preset. Before helper setup, the panel labels this as a preview; no fan write occurs.
- Fan speed means **percentage of the reported maximum speed**. Firmware limits apply: a Mac with a 21% minimum cannot be commanded to stop. The interface shows that limit explicitly.
- The helper is designed to return to automatic control after lost heartbeats, critical temperature, sensor failure, disconnection, or the manual-session timeout. These paths require hardware validation before release.

### Development

Start with [HANDOFF.md](HANDOFF.md) for current work, acceptance criteria, and validation gaps. [PRODUCT.md](PRODUCT.md) captures the brief; [hardware findings](docs/reverse-engineering.md) document the independent implementation and investigation scope.

Homebrew packaging is staged in [`Casks/aervane.rb.in`](Casks/aervane.rb.in). A real checksum and release URL will be added after a distributable build is verified.

### License

[MIT](LICENSE). Independently implemented. No proprietary app binaries, assets, or decompiled code are included.

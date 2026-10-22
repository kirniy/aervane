# Aervane

A native Mac menu-bar temperature and fan app. This package installs the signed macOS app; Node does not run in the background.

```sh
npx aervane install
npx aervane open
```

Or install the command once:

```sh
npm install -g aervane
aervane install
```

Requires macOS 14 or later, Apple Silicon, and Node 22 or later. The installer checks a pinned SHA-256 checksum, the app's Apple Developer ID signature, and Gatekeeper acceptance before replacing an app. Quit Aervane before an upgrade. Existing preferences are preserved. No installation scripts run during `npm install`.

Use `aervane doctor` to inspect an installation. `--app-dir /path/to/Applications` selects a different destination; `/Applications` is the default. Administrator helper approval happens inside the app through macOS, never inside npm.

Source and hardware compatibility: [kirniy/aervane](https://github.com/kirniy/aervane).

This directory is the package source. Publish only the prepared `dist/npm` package produced by `tools/prepare-distribution.py`; it includes the verified release manifest. Publishing an unprepared source directory is deliberately rejected.

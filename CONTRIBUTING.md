# Contributing

Aervane is a native Swift/AppKit menu-bar utility for macOS 14 and newer.

Run swift test before opening a pull request. Use tools/build.sh for a local app bundle; set SIGN_IDENTITY to an installed Apple signing identity when you need a signed build. The default - identity creates an ad hoc local build.

Keep the runtime dependency-free. Sensor reads belong in the SMC layer, fan writes belong behind the privileged helper, and UI work should stay in the menu-bar app. Do not commit credentials, provisioning profiles, generated .build output, or files from work/.

Hardware changes must include a safe automatic-restore path and should be tested on a supported Mac before release.

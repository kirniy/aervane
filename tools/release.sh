#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
"$ROOT/tools/build.sh"
ditto -c -k --keepParent "$ROOT/dist/Aervane.app" "$ROOT/dist/Aervane.app.zip"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$ROOT/dist/Aervane.app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$ROOT/dist/Aervane.app"
  rm "$ROOT/dist/Aervane.app.zip"
  ditto -c -k --keepParent "$ROOT/dist/Aervane.app" "$ROOT/dist/Aervane.app.zip"
fi
shasum -a 256 "$ROOT/dist/Aervane.app.zip"

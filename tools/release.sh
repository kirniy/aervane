#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
"$ROOT/tools/build.sh"
ditto -c -k --keepParent "$ROOT/dist/Aervane.app" "$ROOT/dist/Aervane.app.zip"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if ! codesign --display --verbose=4 "$ROOT/dist/Aervane.app" 2>&1 | rg -q '^Authority=Developer ID Application:'; then
    echo 'Public notarization requires a Developer ID Application signing identity.' >&2
    exit 1
  fi
  xcrun notarytool submit "$ROOT/dist/Aervane.app.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$ROOT/dist/notary-result.json"
  if [[ "$(plutil -extract status raw -o - "$ROOT/dist/notary-result.json")" != Accepted ]]; then
    echo 'Notarization was not accepted. See dist/notary-result.json.' >&2
    exit 1
  fi
  xcrun stapler staple "$ROOT/dist/Aervane.app"
  xcrun stapler validate "$ROOT/dist/Aervane.app"
  rm "$ROOT/dist/Aervane.app.zip"
  ditto -c -k --keepParent "$ROOT/dist/Aervane.app" "$ROOT/dist/Aervane.app.zip"
fi
shasum -a 256 "$ROOT/dist/Aervane.app.zip"

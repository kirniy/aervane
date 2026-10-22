#!/bin/zsh
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
"$ROOT/tools/build.sh"
# Filesystem metadata is not part of this bundle. In particular, restored
# FinderInfo/resource forks can invalidate an otherwise valid code signature.
ditto --norsrc --noextattr -c -k --keepParent "$ROOT/dist/Aervane.app" "$ROOT/dist/Aervane.app.zip"
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
  ditto --norsrc --noextattr -c -k --keepParent "$ROOT/dist/Aervane.app" "$ROOT/dist/Aervane.app.zip"
fi
VERIFY_DIR=$(mktemp -d "$ROOT/dist/archive-check.XXXXXX")
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ROOT/dist/Aervane.app.zip" "$VERIFY_DIR"
codesign --verify --deep --strict "$VERIFY_DIR/Aervane.app"
shasum -a 256 "$ROOT/dist/Aervane.app.zip"

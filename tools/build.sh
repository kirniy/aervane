#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

CONFIG=release
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_TIMESTAMP=none
if [[ -n "${NOTARY_PROFILE:-}" ]]; then SIGN_TIMESTAMP=enabled; fi
APP_ID="dev.kirniy.aervane"
HELPER_ID="dev.kirniy.aervane.helper"
BUILD_DIR="$ROOT/.build"
APP="$ROOT/dist/Aervane.app"
AERVANE_VERSION=$(<"$ROOT/VERSION")
if [[ ! "$AERVANE_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo 'VERSION must contain a numeric major.minor.patch version.' >&2
  exit 1
fi

swift build -c "$CONFIG" --product Aervane
swift build -c "$CONFIG" --product AervaneHelper

mkdir -p "$ROOT/dist"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BUILD_DIR/$CONFIG/Aervane" "$APP/Contents/MacOS/Aervane"
cp "$BUILD_DIR/$CONFIG/AervaneHelper" "$APP/Contents/Library/LaunchDaemons/AervaneHelper"
cp "$ROOT/Resources/Aervane.icns" "$APP/Contents/Resources/Aervane.icns"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/Resources/dev.kirniy.aervane.helper.plist" "$APP/Contents/Library/LaunchDaemons/dev.kirniy.aervane.helper.plist"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.kirniy.aervane</string>
  <key>CFBundleExecutable</key><string>Aervane</string>
  <key>CFBundleName</key><string>Aervane</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$AERVANE_VERSION</string>
  <key>CFBundleVersion</key><string>$AERVANE_VERSION</string>
  <key>CFBundleIconFile</key><string>Aervane</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

timestamp_args=(--timestamp=none)
if [[ "$SIGN_TIMESTAMP" == enabled ]]; then timestamp_args=(--timestamp); fi
codesign --force --identifier "$HELPER_ID" --options runtime "${timestamp_args[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Library/LaunchDaemons/AervaneHelper"
codesign --force --options runtime "${timestamp_args[@]}" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  "$APP/Contents/MacOS/Aervane" --check-signing
fi
echo "Built $APP"

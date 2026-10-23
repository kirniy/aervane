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

# Build both native slices, including the privileged helper. Each uses its
# own SwiftPM build directory so outputs cannot silently reuse the host arch.
for arch in arm64 x86_64; do
  swift build -c "$CONFIG" --arch "$arch" --scratch-path "$BUILD_DIR/$arch" --product Aervane
  swift build -c "$CONFIG" --arch "$arch" --scratch-path "$BUILD_DIR/$arch" --product AervaneHelper
done

mkdir -p "$ROOT/dist"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
ARM_BIN=$(swift build -c "$CONFIG" --arch arm64 --scratch-path "$BUILD_DIR/arm64" --show-bin-path)
INTEL_BIN=$(swift build -c "$CONFIG" --arch x86_64 --scratch-path "$BUILD_DIR/x86_64" --show-bin-path)
for product in Aervane AervaneHelper; do
  if [[ "$product" == Aervane ]]; then
    target="$APP/Contents/MacOS/Aervane"
  else
    target="$APP/Contents/Library/LaunchDaemons/AervaneHelper"
  fi
  lipo -create "$ARM_BIN/$product" \
               "$INTEL_BIN/$product" -output "$target"
  lipo "$target" -verify_arch arm64
  lipo "$target" -verify_arch x86_64
done
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
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST

timestamp_args=(--timestamp=none)
if [[ "$SIGN_TIMESTAMP" == enabled ]]; then timestamp_args=(--timestamp); fi
codesign --force --identifier "$HELPER_ID" --options runtime "${timestamp_args[@]}" --sign "$SIGN_IDENTITY" "$APP/Contents/Library/LaunchDaemons/AervaneHelper"
codesign --force --options runtime "${timestamp_args[@]}" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --all-architectures --deep --strict "$APP"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  "$APP/Contents/MacOS/Aervane" --check-signing
fi
echo "Built $APP"

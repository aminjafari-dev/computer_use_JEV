#!/bin/zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "Building Release (ad-hoc signature, no launch)"
xcodebuild \
  -project DesktopPilot.xcodeproj \
  -scheme DesktopPilot \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/build/DerivedData" \
  build \
  CODE_SIGN_IDENTITY="-"

APP="$ROOT/build/DerivedData/Build/Products/Release/Desktop Pilot.app"
if [[ ! -d "$APP" ]]; then
  echo "Release app was not produced at: $APP" >&2
  exit 1
fi

STAGE="$ROOT/build/dmg-root"
rm -rf "$STAGE" "$ROOT/build/DesktopPilot.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
hdiutil create -volname "Desktop Pilot" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/build/DesktopPilot.dmg"
echo "Wrote $ROOT/build/DesktopPilot.dmg"

xcodebuild \
  -project DesktopPilot.xcodeproj \
  -scheme DesktopPilot \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/build/DerivedData" \
  -archivePath "$ROOT/build/DesktopPilot.xcarchive" \
  archive \
  CODE_SIGN_IDENTITY="-"
echo "Wrote $ROOT/build/DesktopPilot.xcarchive"
echo "This script builds and packages only. It does not launch the app."

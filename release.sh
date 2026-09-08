#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
./build.sh
PLIST="$ROOT/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
DIST="$ROOT/dist"
mkdir -p "$DIST"
ZIP="$DIST/BigUwidget-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$ROOT/BigUwidget.app" "$ZIP"
echo "Packed $ZIP"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "Unsigned. Set SIGN_IDENTITY and rebuild before notarizing."
  echo "Users must right-click → Open."
  exit 0
fi
echo "Next:"
echo "  xcrun notarytool submit \"$ZIP\" --apple-id EMAIL --team-id TEAMID --wait"
echo "  unzip, then: xcrun stapler staple \"$ROOT/BigUwidget.app\""
echo "  ditto -c -k --keepParent \"$ROOT/BigUwidget.app\" \"$ZIP\""

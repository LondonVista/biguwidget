#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/BigUwidget.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
mkdir -p "$BIN" "$RES"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/AppIcon.icns" ]]; then
  cp "$ROOT/AppIcon.icns" "$RES/AppIcon.icns"
fi
swiftc -O -parse-as-library -o "$BIN/BigUwidget" "$ROOT/BigUwidget.swift" \
  -framework Cocoa -framework SwiftUI -framework WebKit \
  -target arm64-apple-macos13
chmod +x "$BIN/BigUwidget"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with $SIGN_IDENTITY"
fi
if [[ -w /Applications ]]; then
  rm -rf /Applications/BigUwidget.app
  cp -R "$APP" /Applications/BigUwidget.app
  echo "Installed /Applications/BigUwidget.app"
fi
echo "Built $APP"

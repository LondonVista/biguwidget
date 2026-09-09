#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -d BigUwidget.app ]]; then
  osascript -e 'display dialog "BigUwidget.app is missing from this folder." buttons {"OK"} default button 1'
  exit 1
fi
mkdir -p /Applications
rm -rf /Applications/BigUwidget.app
cp -R BigUwidget.app /Applications/BigUwidget.app
xattr -cr /Applications/BigUwidget.app
open /Applications/BigUwidget.app
osascript -e 'display notification "Installed to /Applications/BigUwidget.app" with title "BigUwidget 1.1.1"'

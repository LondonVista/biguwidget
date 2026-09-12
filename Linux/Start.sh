#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Starting BigUwidget for Linux..."

if ! command -v npm >/dev/null 2>&1; then
  echo "Error: Node.js 20+ and npm are required to run BigUwidget on Linux."
  echo "Install Node.js from https://nodejs.org or via your package manager (e.g. sudo apt install nodejs npm)."
  exit 1
fi

if [ ! -d "node_modules/electron" ]; then
  echo "Installing dependencies (first run only)..."
  npm install
fi

# Auto-detect DBUS_SESSION_BUS_ADDRESS from running session if not set
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  for _pid in $(pgrep -u "$(id -u)" xfwm4 xfce4-session plank openbox 2>/dev/null); do
    _dbus=$(cat /proc/$_pid/environ 2>/dev/null | tr '\0' '\n' | grep '^DBUS_SESSION_BUS_ADDRESS=' | head -1)
    if [ -n "$_dbus" ]; then
      export $_dbus
      break
    fi
  done
fi

exec npm start

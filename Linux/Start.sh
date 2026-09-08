#!/bin/sh
set -e
cd "$(dirname "$0")"

if ! command -v npm >/dev/null 2>&1; then
  echo "Node.js 20+ is required. Install it from https://nodejs.org/ then run this again."
  exit 1
fi

if [ ! -d node_modules/electron ]; then
  echo "Installing BigUwidget 1.0.3 for Linux (first run only)…"
  npm install
fi

if [ ! -e node_modules/electron/dist/electron ]; then
  node node_modules/electron/install.js
fi

exec npm start

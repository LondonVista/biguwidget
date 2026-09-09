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

exec npm start

#!/bin/bash
set -e
cd "$(dirname "$0")"

# If user explicitly requests electron: ./Start.sh --electron
if [ "$1" = "--electron" ]; then
  echo "Starting BigUwidget (Electron)..."
  if ! command -v npm >/dev/null 2>&1; then
    echo "Node.js 20+ is required for Electron. Install it from https://nodejs.org/"
    exit 1
  fi
  if [ ! -d node_modules/electron ]; then
    npm install
  fi
  exec npm start
fi

# Track B: Ultra-Low RAM Native Qt / PySide Meter (~40 MB RSS)
if command -v python3 >/dev/null 2>&1; then
  # 1. Check if PySide6 or PyQt is already available in system python
  if python3 -c "import PySide6" 2>/dev/null || python3 -c "import PyQt5" 2>/dev/null || python3 -c "import PyQt6" 2>/dev/null; then
    echo "Starting BigUwidget Track B (Native Qt Meter, ~40 MB RAM)..."
    exec python3 biguwidget.py "$@"
  fi

  # 2. Check or set up local venv
  if [ ! -d ".venv" ]; then
    echo "Setting up BigUwidget Track B native environment (first run only)..."
    python3 -m venv .venv 2>/dev/null || true
  fi

  if [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
    if ! python3 -c "import PySide6" 2>/dev/null; then
      echo "Installing PySide6 (~40 MB native GUI)..."
      pip install -q PySide6
    fi
    echo "Starting BigUwidget Track B (Native Qt Meter, ~40 MB RAM)..."
    exec python3 biguwidget.py "$@"
  fi
fi

# Fallback to Electron if python3 is missing or venv creation failed
if command -v npm >/dev/null 2>&1; then
  echo "Starting BigUwidget (Electron fallback)..."
  if [ ! -d node_modules/electron ]; then
    npm install
  fi
  exec npm start
fi

echo "Error: Python 3 (recommended for ~40 MB Track B) or Node.js is required."
exit 1

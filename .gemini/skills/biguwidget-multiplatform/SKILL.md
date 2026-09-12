---
name: biguwidget-multiplatform
description: Enforces strict dual-platform parity (Linux & Windows), separate git commit conventions, macOS isolation, and mandatory version bumping for BigUwidget.
---

# BigUwidget Cross-Platform Rules & Guidelines

## 1. Dual Platform Sync (Linux & Windows)
- When building features, UI changes, bug fixes, or scrapers/fetchers for the Linux app (`Linux/`), immediately apply the exact same logic/styling to the Windows app (`Windows/`).
- Keep features identical across both platforms:
  - Window dragging & frameless boundaries
  - Translucent glassmorphism (`styles.css`)
  - Real daily calendar tracking (`daily-usage.json`)
  - Real prompt consumption delta pills (`session-deltas.json`)
  - Intra-week reset bonus calculations
  - Card collapse states, settings window, and auto-updaters
- Ensure Windows-specific scripts/files (`Start.bat`, Windows electron configurations, PowerShell unzippers) are maintained properly without Linux-specific bash assumptions breaking them.

## 2. Strictly Separate Git Commits (Zero Cross-Contamination)
- **NEVER** mix platforms in a single commit or commit message.
- If making changes for Linux, ONLY stage `Linux/` (and shared root files if strictly relevant) and commit with:
  `Linux: <description>`
- If making changes for Windows, ONLY stage `Windows/` and commit with:
  `Windows: <description>`
- On GitHub's file tree, each folder must display strictly its own OS prefix in the commit column.
- **macOS Preservation**: NEVER touch Mac files (`BigUwidget.swift`, `Info.plist`, `Mac/`) when working on Linux/Windows. macOS stays at its stable version unless a Mac-specific fix is explicitly requested.

## 3. Mandatory Version Bumping on Every Push
- Every single release push MUST increment the version (e.g., `1.1.6` -> `1.1.7`).
- Match version strings across:
  - `Linux/package.json`, `Linux/src/renderer.js`, `Linux/src/updater.js`
  - `Windows/package.json`, `Windows/src/renderer.js`, `Windows/src/updater.js`
  - `latest.json` & root `README.md`
- In-app Settings panel footer must display the matching new version.

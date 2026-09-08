# BigUwidget 1.0.8 — Windows

Copy **this folder** onto a Windows PC. Do not copy `electron/` or `Linux/`.

Needs [Node.js 20+](https://nodejs.org/).

## Run

Double-click **Start.bat**.

First run downloads Electron (~150–200 MB) for Windows. After that, Start.bat or `npm start`.

## Installer (Setup + portable .exe)

In Command Prompt, from this folder:

```bat
npm run dist
```

Files land in `dist\`:

- `BigUwidget-1.0.8-win-x64.exe` (NSIS installer)
- portable `.exe`

Build this on Windows (cross-build from Mac/Linux needs Wine).

## Updates

Settings → **Off / Prompt / Auto**. Prompt is the default. The app checks [GitHub Releases](https://github.com/LondonVista/biguwidget/releases) for a newer zip.

Donate: https://ko-fi.com/london_vista  
Unofficial. Not affiliated with Google, xAI, OpenAI, or Cursor.

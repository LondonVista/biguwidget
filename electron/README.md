# BigUwidget 1.0.7 (dev workspace)

This is the Mac-side Electron workspace (`node_modules` lives here). **Do not copy this folder to Linux or Windows.**

Ship these instead:

- `../Linux/` — copy to a Linux machine, run `./Start.sh`
- `../Windows/` — copy to a Windows PC, run `Start.bat`

| | |
|---|---|
| Version | **1.0.7** (matches macOS `CFBundleShortVersionString`) |
| App id | `com.lodonvista.biguwidget` |
| Runtime | Electron **35.7.5** |
| Packager | electron-builder **25.1.8** |
| Node | 20 or newer |

Cards: Grok, Grok Bot (Cursor), AGY (Gemini), Claude & GPT (from AGY), optional ChatGPT.

Not affiliated with Google, xAI, OpenAI, or Cursor. Quota endpoints are unofficial and can break.

## Run from source

```bash
cd BigUwidget/electron
npm install
# if Electron’s binary did not download (install scripts blocked):
node node_modules/electron/install.js
npm start
```

The window stays on top. Drag the title row to move it. **Settings** toggles cards and order. **Sign in** opens a browser that shares cookies with the fetchers; close it to refresh. Heart opens [ko-fi.com/london_vista](https://ko-fi.com/london_vista).

## Installers

Built artifacts land in `electron/dist/` as:

- Linux: `BigUwidget-1.0.3-linux-x64.AppImage`, `BigUwidget-1.0.3-linux-arm64.AppImage`, `.deb` (x64)
- Windows: NSIS installer + portable `.exe` (x64)

```bash
npm run dist:linux    # run on Linux (or CI)
npm run dist:win      # run on Windows (cross-build needs Wine)
```

macOS users should keep using `./build.sh` in the repo root, not this Electron shell.

## What this is not

- Not an App Store / Microsoft Store / Snap listing.
- Not a pixel-perfect clone of the Mac calendar graphs.
- Claude.ai, Copilot, Perplexity, OpenRouter are not live cards.

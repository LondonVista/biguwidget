# BigUwidget 1.1.1 — Linux

Copy **this folder** onto a Linux machine. Do not copy `electron/` or `Windows/`.

BigUwidget on Linux runs via **Electron** with pixel-perfect CSS glassmorphism (`backdrop-filter: blur()`), seamless OAuth login, clipboard paste support, and real-time usage meters.

## Quick Start

```bash
chmod +x Start.sh
./Start.sh
```

*(or run `npm install && npm start`)*

Requires **Node.js 20+** and `npm`.

## Standalone AppImage / .deb

To build a standalone portable binary:

```bash
npm run dist
```

Generated packages will be in `dist/`:
- `BigUwidget-1.1.1-linux-x64.AppImage`
- `BigUwidget-1.1.1-linux-arm64.AppImage`
- `.deb` (x64)

## Updates

Settings → **Off / Prompt / Auto**. Prompt is the default. The app checks [GitHub Releases](https://github.com/LondonVista/biguwidget/releases) for newer versions.

Donate: https://ko-fi.com/london_vista  
Unofficial. Not affiliated with Google, xAI, OpenAI, or Cursor.

# BigUwidget 1.0.6 — Linux

Copy **this folder** onto a Linux machine. Do not copy `electron/` or `Windows/`.

BigUwidget on Linux now offers **Track B: Native Qt / PySide** with an ultra-low memory footprint (~35–45 MB RSS vs ~530 MB on Electron).

## Quick Start

```bash
chmod +x Start.sh
./Start.sh
```

- **Track B (Default)**: Automatically runs the native Qt meter via Python 3 + PySide6 (~40 MB RAM).
- **Electron (Fallback)**: Run `./Start.sh --electron` or `npm start` if you prefer the Electron shell.

## Installer (AppImage + .deb)

```bash
npm run dist
```

Files land in `dist/`:

- `BigUwidget-1.0.6-linux-x64.AppImage`
- `BigUwidget-1.0.6-linux-arm64.AppImage`
- `.deb` (x64)

## Updates

Settings → **Off / Prompt / Auto**. Prompt is the default. The app checks [GitHub Releases](https://github.com/LondonVista/biguwidget/releases) for a newer zip.

Donate: https://ko-fi.com/london_vista  
Unofficial. Not affiliated with Google, xAI, OpenAI, or Cursor.

# BigUwidget 1.0.6 — Linux

Copy **this folder** onto a Linux machine. Do not copy `electron/` or `Windows/`.

Needs [Node.js 20+](https://nodejs.org/).

## Run

```bash
chmod +x Start.sh
./Start.sh
```

First run downloads Electron (~150–200 MB) for Linux. After that, `./Start.sh` or `npm start`.

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

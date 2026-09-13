# BigUwidget

![BigUwidget on macOS — Grok, Grok Bot, AGY, and Claude & GPT quota cards](docs/screenshot.png)

Always-on-top **AI usage / quota widget** for **Mac, Linux, and Windows**.

See how much of your weekly (and 5-hour) allowance you have used for:

- **Grok** (grok.com / xAI) — S1
- **Grok Bot** in **Cursor** — S2
- **Antigravity** — Gemini (**AGY**) and **Claude & GPT** from AGY — S3 & S4
- **ChatGPT** (optional card)

Unofficial desktop dashboard. Not affiliated with Google, xAI, OpenAI, Anthropic, or Cursor. Quota endpoints can change.

### Demo

![BigUwidget demo](docs/demo.gif)

[▶ Full video on X](https://x.com/London_Vista/status/2097908803475742791?s=20)

## Features & What's New in v1.1.7

- 📊 **Real Weekly Calendar Breakdown**: Live Monday-to-Sunday daily tracking using `daily-usage.json` with reset weekday indicator, active today indicator, and intra-week bonus quota gain badges (`+N`).
- ⚡ **Real Vertical Delta Badges**: Live consumption log tracking positive usage changes into `session-deltas.json` with timestamps (`14m +0.70%`, etc.).
- 🎯 **Native Card Layout across Linux & Windows**: Refined hero quota numbers, progress bars with 100% cap indicators, highlighted reset dates, and 5h rolling limit counters.
- 📌 **Window Position Persistence**: Automatically saves and restores exact desktop coordinates across restarts.

## Platform Status

- 🍏 **macOS** — **Primary & Best Maintained** (native Swift / SwiftUI app, fully tested and actively maintained).
- 🐧 **Linux** — **Best Maintained** (translucent glassmorphism, real calendar tracking, persistent window bounds, and seamless sign-in).
- 🪟 **Windows** — **Experimental (Community Tested)**. Windows users are welcome to test, report issues, or contribute fixes!

## Download

Latest release: **[v1.1.7](https://github.com/LondonVista/biguwidget/releases/latest)**

| OS | Status | File |
|---|---|---|
| **Mac** | Native App (Recommended) | [BigUwidget-1.1.4-Mac.zip](https://github.com/LondonVista/biguwidget/releases/download/v1.1.7/BigUwidget-1.1.4-Mac.zip) |
| **Linux** | Tested & Maintained | [BigUwidget-1.1.7-Linux.zip](https://github.com/LondonVista/biguwidget/releases/latest/download/BigUwidget-1.1.7-Linux.zip) |
| **Windows** | Experimental (Untested) | [BigUwidget-1.1.7-Windows.zip](https://github.com/LondonVista/biguwidget/releases/latest/download/BigUwidget-1.1.7-Windows.zip) |

- **Mac**: unzip and run **Install.command**, or drag `BigUwidget.app` to `/Applications`.  
- **Linux**: Node.js 20+, then `./Start.sh` (or `npm install && npm start`).  
- **Windows**: Node.js 20+, then `Start.bat`.

## Updates

In **Settings** choose:

- **Prompt** (default) — asks when a new GitHub release is out
- **Auto** — downloads the new zip
- **Off** — no checks

## Support

[ko-fi.com/london_vista](https://ko-fi.com/london_vista)

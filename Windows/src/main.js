const { app, BrowserWindow, ipcMain, shell, screen, Menu } = require("electron");

// Performance & lightweight memory profile
if (process.platform === "linux") {
  app.commandLine.appendSwitch("enable-transparent-visuals");
}
app.commandLine.appendSwitch("renderer-process-limit", "1");
app.commandLine.appendSwitch("disable-features", "SpareRendererForSitePerProcess,CalculateNativeWinOcclusion");
app.commandLine.appendSwitch("js-flags", "--max-old-space-size=96 --expose-gc");
app.commandLine.appendSwitch("disable-background-networking");
app.commandLine.appendSwitch("disable-component-update");
app.commandLine.appendSwitch("disable-domain-reliability");
app.commandLine.appendSwitch("disable-sync");
app.commandLine.appendSwitch("disable-breakpad");
app.commandLine.appendSwitch("disable-crash-reporter");
app.commandLine.appendSwitch("disable-speech-api");
app.commandLine.appendSwitch("disable-print-preview");
app.commandLine.appendSwitch("disable-logging");
app.commandLine.appendSwitch("disable-notifications");

const path = require("path");
const fs = require("fs");
const fetchers = require("./fetchers");
const updater = require("./updater");

const tracker = require("./tracker");

const DONATE = "https://ko-fi.com/london_vista";
const FEEDBACK = `https://github.com/LondonVista/biguwidget/issues/new?title=%5BFeedback%2FBug%5D+v${updater.VERSION}&body=%2A%2AOS%2A%2A%3A+${process.platform}%0A%2A%2AVersion%2A%2A%3A+v${updater.VERSION}%0A%0A%2A%2ADescribe+the+issue+or+feedback%2A%2A%3A%0A`;
const VERSION = updater.VERSION;

const CARDS = [
  { id: "grok", title: "Grok", login: "https://grok.com" },
  { id: "grokBot", title: "Grok Bot", login: "https://cursor.com/login" },
  { id: "agy", title: "AGY", login: "https://antigravity.google" },
  { id: "claudeGPT", title: "Claude & GPT (from AGY)", login: "https://antigravity.google" },
  { id: "chatGPT", title: "ChatGPT", login: "https://chatgpt.com" },
];

const DEFAULT_ENABLED = ["grok", "grokBot", "agy", "claudeGPT"];

function statePath() {
  return path.join(app.getPath("userData"), "state.json");
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(statePath(), "utf8"));
  } catch {
    return { enabled: DEFAULT_ENABLED, order: DEFAULT_ENABLED, snapshots: {}, bounds: null, updatePolicy: "prompt", agyToken: null };
  }
}

function saveState() {
  fs.mkdirSync(path.dirname(statePath()), { recursive: true });
  const { update, ...rest } = state;
  fs.writeFileSync(statePath(), JSON.stringify(rest, null, 2));
}

let state = loadState();
let widget = null;
let loginWin = null;
let settingsWin = null;

function emptySnap(id) {
  return { id, status: "loading", weekly: 0, five: null, reset: null, fiveReset: null, fetchedAt: 0, days: [], recentDeltas: [], todayLeft: null, todayUsed: 0 };
}

function publicState() {
  const snapshots = {};
  for (const c of CARDS) snapshots[c.id] = state.snapshots[c.id] || emptySnap(c.id);
  const order = Array.isArray(state.order) && state.order.length ? state.order : CARDS.map((c) => c.id);
  for (const c of CARDS) if (!order.includes(c.id)) order.push(c.id);
  return {
    version: VERSION,
    cards: CARDS,
    enabled: state.enabled,
    order,
    snapshots,
    updatePolicy: state.updatePolicy || "prompt",
    update: state.update || null,
  };
}

function broadcast() {
  const pub = publicState();
  if (widget && !widget.isDestroyed()) widget.webContents.send("state", pub);
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.webContents.send("state", pub);
}

function applyResult(id, res) {
  if (!res || !res.ok) {
    state.snapshots[id] = {
      ...(state.snapshots[id] || emptySnap(id)),
      status: res && res.needLogin ? "needsLogin" : "error",
      error: (res && res.error) || (res && res.needLogin ? "offline" : "Couldn't refresh"),
    };
    return;
  }
  const prevSnap = state.snapshots[id];
  const tracked = tracker.processUsageUpdate(app.getPath("userData"), id, res, prevSnap);

  state.snapshots[id] = {
    id,
    status: "ready",
    weekly: res.weekly ?? 0,
    five: res.five ?? null,
    reset: res.reset || null,
    fiveReset: res.fiveReset || null,
    plan: res.plan || CARDS.find((c) => c.id === id)?.title,
    fetchedAt: Date.now(),
    days: tracked.days,
    recentDeltas: tracked.recentDeltas,
    todayLeft: tracked.todayLeft,
    todayUsed: tracked.todayUsed,
  };
}

async function fetchOne(id) {
  try {
    if (id === "agy" || id === "claudeGPT") {
      const res = await fetchers.fetchAGY(state.agyToken);
      if (id === "agy") {
        applyResult("agy", res.ok ? { ok: true, weekly: res.gemini.weekly, five: res.gemini.five, reset: res.gemini.reset, fiveReset: res.gemini.fiveReset } : res);
      } else {
        applyResult("claudeGPT", res.ok ? { ok: true, weekly: res.claude.weekly, five: res.claude.five, reset: res.claude.reset, fiveReset: res.claude.fiveReset } : res);
      }
    } else if (id === "grok") applyResult("grok", await fetchers.fetchGrok());
    else if (id === "grokBot") applyResult("grokBot", await fetchers.fetchGrokBot());
    else if (id === "chatGPT") applyResult("chatGPT", await fetchers.fetchChatGPT());
  } catch (e) {
    applyResult(id, { ok: false, error: String(e.message || e) });
  }
  saveState();
  broadcast();
}

async function fetchAll() {
  const en = new Set(state.enabled);
  const jobs = [];
  if (en.has("agy") || en.has("claudeGPT")) {
    jobs.push(
      fetchers.fetchAGY(state.agyToken).then((res) => {
        if (en.has("agy")) applyResult("agy", res.ok ? { ok: true, weekly: res.gemini.weekly, five: res.gemini.five, reset: res.gemini.reset, fiveReset: res.gemini.fiveReset } : res);
        if (en.has("claudeGPT")) applyResult("claudeGPT", res.ok ? { ok: true, weekly: res.claude.weekly, five: res.claude.five, reset: res.claude.reset, fiveReset: res.claude.fiveReset } : res);
      })
    );
  }
  if (en.has("grok")) jobs.push(fetchers.fetchGrok().then((r) => applyResult("grok", r)));
  if (en.has("grokBot")) jobs.push(fetchers.fetchGrokBot().then((r) => applyResult("grokBot", r)));
  if (en.has("chatGPT")) jobs.push(fetchers.fetchChatGPT().then((r) => applyResult("chatGPT", r)));
  await Promise.all(jobs);
  saveState();
  broadcast();
}

function openLogin(id) {
  const card = CARDS.find((c) => c.id === id) || CARDS[0];
  if (loginWin && !loginWin.isDestroyed()) loginWin.close();

  if (id === "agy" || id === "claudeGPT") {
    loginWin = new BrowserWindow({
      width: 580,
      height: 640,
      title: `Sign in to ${card.title} — BigUwidget`,
      autoHideMenuBar: true,
      alwaysOnTop: true,
      backgroundColor: "#141416",
      webPreferences: {
        preload: path.join(__dirname, "preload.js"),
        partition: "persist:bigu",
        contextIsolation: true,
        nodeIntegration: false,
        spellcheck: false,
        devTools: false,
      },
    });
    loginWin.loadFile(path.join(__dirname, "agy-login.html"));
    loginWin.show();
    loginWin.focus();
    loginWin.on("closed", () => {
      if (loginWin && !loginWin.isDestroyed()) {
        loginWin.destroy();
      }
      loginWin = null;
      fetchOne("agy");
      fetchOne("claudeGPT");
      if (global.gc) { try { global.gc(); } catch {} }
    });
    return;
  }

  loginWin = new BrowserWindow({
    width: 900,
    height: 680,
    title: `Sign in to ${card.title} — BigUwidget`,
    autoHideMenuBar: true,
    alwaysOnTop: true,
    webPreferences: {
      preload: path.join(__dirname, "login-preload.js"),
      partition: "persist:bigu",
      userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
      spellcheck: false,
      devTools: false,
    },
  });
  loginWin.loadURL(card.login);

  // Enable Ctrl+V (or Cmd+V) and keyboard shortcuts for paste/copy on Linux/Windows
  loginWin.webContents.on("before-input-event", (event, input) => {
    if ((input.control || input.meta) && input.type === "keyDown") {
      const k = input.key.toLowerCase();
      if (k === "v") {
        loginWin.webContents.paste();
        event.preventDefault();
      } else if (k === "c") {
        loginWin.webContents.copy();
        event.preventDefault();
      } else if (k === "x") {
        loginWin.webContents.cut();
        event.preventDefault();
      } else if (k === "a") {
        loginWin.webContents.selectAll();
        event.preventDefault();
      }
    }
  });

  // Enable right-click context menu with Paste, Copy, Cut
  loginWin.webContents.on("context-menu", (_e, params) => {
    const menu = Menu.buildFromTemplate([
      { role: "undo" },
      { role: "redo" },
      { type: "separator" },
      { role: "cut" },
      { role: "copy" },
      { role: "paste" },
      { role: "selectAll" },
    ]);
    menu.popup({ window: loginWin, x: params.x, y: params.y });
  });

  loginWin.show();
  loginWin.focus();
  loginWin.on("closed", () => {
    if (loginWin && !loginWin.isDestroyed()) {
      loginWin.destroy();
    }
    loginWin = null;
    fetchOne(id);
    if (global.gc) { try { global.gc(); } catch {} }
  });
}

function createWidget() {
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width: screenWidth, height: screenHeight } = primaryDisplay.workAreaSize;
  const defaultWidth = 254;
  const initialHeight = Math.min(state.bounds?.height || 420, screenHeight - 60);

  // Default to screen center
  let x = Math.round((screenWidth - defaultWidth) / 2);
  let y = Math.round((screenHeight - initialHeight) / 2);

  if (state.bounds && typeof state.bounds.x === "number" && typeof state.bounds.y === "number") {
    try {
      const display = screen.getDisplayMatching(state.bounds);
      const { x: dx, y: dy, width: dw, height: dh } = display.workArea;
      if (
        state.bounds.x >= dx - 200 &&
        state.bounds.x < dx + dw - 20 &&
        state.bounds.y >= dy - 20 &&
        state.bounds.y < dy + dh - 20
      ) {
        x = state.bounds.x;
        y = state.bounds.y;
      }
    } catch {
      if (state.bounds.x >= 0 && state.bounds.x < screenWidth - 40 && state.bounds.y >= 0 && state.bounds.y < screenHeight - 40) {
        x = state.bounds.x;
        y = state.bounds.y;
      }
    }
  }

  widget = new BrowserWindow({
    width: defaultWidth,
    height: initialHeight,
    x: x,
    y: y,
    minWidth: 240,
    maxWidth: 320,
    minHeight: 100,
    maxHeight: screenHeight - 40,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: false,
    type: process.platform === "darwin" ? "utility" : "normal",
    show: false,
    backgroundColor: "#00000000",
    title: "BigUwidget",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      partition: "persist:bigu",
      spellcheck: false,
      backgroundThrottling: true,
      devTools: false,
      enableWebSQL: false,
    },
  });

  if (process.platform === "darwin") {
    widget.setAlwaysOnTop(true, "floating");
  } else {
    widget.setAlwaysOnTop(true);
  }

  widget.loadFile(path.join(__dirname, "index.html"));

  // Explicitly set bounds to guarantee position and prevent WM centering bugs
  widget.setBounds({ x, y, width: defaultWidth, height: initialHeight });

  widget.once("ready-to-show", () => {
    if (widget && !widget.isDestroyed()) {
      widget.show();
      widget.focus();
    }
  });
  // Fallback show after 200ms in case WM doesn't fire ready-to-show
  setTimeout(() => {
    if (widget && !widget.isDestroyed() && !widget.isVisible()) {
      widget.show();
    }
  }, 200);

  const saveBounds = () => {
    if (widget && !widget.isDestroyed()) {
      const b = widget.getBounds();
      state.bounds = { ...(state.bounds || {}), x: b.x, y: b.y, width: b.width, height: b.height };
      saveState();
    }
  };

  widget.on("move", saveBounds);
  widget.on("moved", saveBounds);
  widget.on("resize", saveBounds);
  widget.on("resized", saveBounds);

  widget.on("close", () => {
    saveBounds();
  });

  widget.on("closed", () => {
    widget = null;
  });
}

function openSettingsWindow() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    return;
  }
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width: screenWidth, height: screenHeight } = primaryDisplay.workAreaSize;
  const winWidth = 320;
  const winHeight = 520;
  const x = Math.round((screenWidth - winWidth) / 2);
  const y = Math.round((screenHeight - winHeight) / 2);

  settingsWin = new BrowserWindow({
    width: winWidth,
    height: winHeight,
    x: x,
    y: y,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: false,
    show: false,
    backgroundColor: "#00000000",
    title: "BigUwidget Settings",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      partition: "persist:bigu",
      spellcheck: false,
      devTools: false,
    },
  });

  if (process.platform === "darwin") {
    settingsWin.setAlwaysOnTop(true, "floating");
  } else {
    settingsWin.setAlwaysOnTop(true);
  }

  settingsWin.loadFile(path.join(__dirname, "settings.html"));

  settingsWin.once("ready-to-show", () => {
    if (settingsWin && !settingsWin.isDestroyed()) {
      settingsWin.show();
      settingsWin.focus();
    }
  });

  settingsWin.on("closed", () => {
    settingsWin = null;
  });
}

function closeSettingsWindow() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.close();
    settingsWin = null;
  }
}

app.setName("BigUwidget");
app.whenReady().then(() => {
  const loaded = loadState();
  state = {
    enabled: Array.isArray(loaded.enabled) ? loaded.enabled : DEFAULT_ENABLED,
    order: Array.isArray(loaded.order) ? loaded.order : DEFAULT_ENABLED,
    snapshots: loaded.snapshots || {},
    bounds: loaded.bounds || null,
    updatePolicy: loaded.updatePolicy || "prompt",
    agyToken: loaded.agyToken || null,
    update: null,
  };
  createWidget();
  fetchAll();
  setInterval(fetchAll, 60000); // Poll 60s
  setInterval(() => {
    try {
      const { session } = require("electron");
      session.fromPartition("persist:bigu").clearCache();
    } catch {}
    if (global.gc) {
      try { global.gc(); } catch {}
    }
  }, 60 * 1000);
  setTimeout(checkForUpdates, 4000);
  setInterval(checkForUpdates, 6 * 60 * 60 * 1000);
});

async function checkForUpdates(force = false) {
  const policy = state.updatePolicy || "prompt";
  if (!force && policy === "off") return;
  try {
    const latest = await updater.fetchLatest();
    if (!latest || updater.cmpVer(latest.version, VERSION) <= 0) {
      state.update = null;
      broadcast();
      return;
    }
    state.update = latest;
    saveState();
    broadcast();
    if (policy === "auto") {
      await updater.installUpdate(latest);
    }
  } catch {
    /* no feed yet */
  }
}

app.on("window-all-closed", () => app.quit());

ipcMain.handle("get-state", () => publicState());
ipcMain.handle("fetch-all", async () => {
  await fetchAll();
  return publicState();
});
ipcMain.handle("fetch-one", async (_e, id) => {
  await fetchOne(id);
  return publicState();
});
ipcMain.handle("login", async (_e, id) => {
  openLogin(id);
  return true;
});
ipcMain.handle("set-enabled", (_e, id, on) => {
  const set = new Set(state.enabled);
  if (on) set.add(id);
  else set.delete(id);
  state.enabled = [...set];
  if (on && Array.isArray(state.order) && !state.order.includes(id)) state.order.push(id);
  saveState();
  broadcast();
  if (on) fetchOne(id);
  return publicState();
});
ipcMain.handle("set-order", (_e, ids) => {
  if (Array.isArray(ids)) {
    state.order = ids.filter((id) => CARDS.some((c) => c.id === id));
    saveState();
    broadcast();
  }
  return publicState();
});
ipcMain.handle("open-donate", () => shell.openExternal(DONATE));
ipcMain.handle("open-feedback", () => shell.openExternal(FEEDBACK));
ipcMain.handle("minimize", () => {
  if (widget && !widget.isDestroyed()) widget.minimize();
  return true;
});
ipcMain.handle("open-settings-window", () => {
  openSettingsWindow();
  return true;
});
ipcMain.handle("close-settings-window", () => {
  closeSettingsWindow();
  return true;
});
ipcMain.handle("quit", () => app.quit());
ipcMain.handle("set-update-policy", (_e, policy) => {
  if (["off", "prompt", "auto"].includes(policy)) {
    state.updatePolicy = policy;
    saveState();
    broadcast();
    if (policy !== "off") checkForUpdates();
  }
  return publicState();
});
ipcMain.handle("install-update", async () => {
  if (state.update) await updater.installUpdate(state.update);
  return publicState();
});
ipcMain.handle("check-updates", async () => {
  await checkForUpdates(true);
  return publicState();
});
ipcMain.handle("open-releases", () => shell.openExternal(updater.PAGE));

ipcMain.handle("save-agy-token", async (_e, rawToken) => {
  const token = fetchers.cleanToken(rawToken);
  if (!token) return { ok: false, error: "Token is empty or invalid" };
  const res = await fetchers.fetchAGY(token);
  if (!res.ok) {
    return { ok: false, error: "Could not authenticate with Google Cloud Code API using this token." };
  }
  state.agyToken = token;
  saveState();
  applyResult("agy", { ok: true, weekly: res.gemini.weekly, five: res.gemini.five, reset: res.gemini.reset, fiveReset: res.gemini.fiveReset });
  applyResult("claudeGPT", { ok: true, weekly: res.claude.weekly, five: res.claude.five, reset: res.claude.reset, fiveReset: res.claude.fiveReset });
  broadcast();
  return { ok: true };
});

ipcMain.handle("detect-agy-token", async () => {
  const info = fetchers.detectAGYToken(state.agyToken);
  if (!info || !info.token) {
    return { found: false };
  }
  const testRes = await fetchers.fetchAGY(info.token);
  return {
    found: true,
    source: info.source,
    valid: testRes.ok,
    token: info.token,
  };
});

ipcMain.handle("clear-agy-token", () => {
  state.agyToken = null;
  saveState();
  fetchOne("agy");
  fetchOne("claudeGPT");
  return true;
});

ipcMain.handle("open-google-login", () => {
  if (loginWin && !loginWin.isDestroyed()) {
    loginWin.loadURL("https://accounts.google.com/ServiceLogin", {
      userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    });
  }
  return true;
});

ipcMain.handle("close-login", () => {
  if (loginWin && !loginWin.isDestroyed()) {
    loginWin.close();
  }
  return true;
});

ipcMain.handle("fit-height", (_e, height) => {
  if (widget && !widget.isDestroyed() && typeof height === "number" && height > 50) {
    const primaryDisplay = screen.getPrimaryDisplay();
    const maxHeight = primaryDisplay.workAreaSize.height - 40;
    const targetH = Math.min(Math.max(100, Math.ceil(height)), maxHeight);
    const [w] = widget.getSize();
    const [x, y] = widget.getPosition();
    widget.setSize(w, targetH);
  }
  return true;
});

ipcMain.on("open-external-url", (_e, url) => {
  if (url && (url.startsWith("https://") || url.startsWith("http://"))) {
    shell.openExternal(url);
  }
});


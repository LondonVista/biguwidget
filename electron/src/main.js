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
  { id: "cursor", title: "Cursor", login: "https://cursor.com/login" },
  { id: "agy", title: "AGY", login: "https://antigravity.google" },
  { id: "claudeGPT", title: "Claude & GPT (from AGY)", login: "https://antigravity.google" },
  { id: "chatGPT", title: "ChatGPT", login: "https://chatgpt.com" },
];

const DEFAULT_ENABLED = ["grok", "grokBot", "cursor", "agy", "claudeGPT"];


function statePath() {
  return path.join(app.getPath("userData"), "state.json");
}

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(statePath(), "utf8"));
  } catch {
    return { enabled: DEFAULT_ENABLED, order: DEFAULT_ENABLED, undocked: [], undockedBounds: {}, snapshots: {}, bounds: null, updatePolicy: "prompt", agyToken: null, zoom: 1.0, opacity: 1.0, hideWeekDays: {}, centerTodayInWeekStrip: true, showProjectedFutureDays: true };
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
let calendarWin = null;
let currentCalendarServiceId = "agy";
const undockedWins = new Map();

function emptySnap(id) {
  return { id, status: "loading", weekly: 0, five: null, reset: null, fiveReset: null, fetchedAt: 0, days: [], recentDeltas: [], todayLeft: null, todayOverrun: 0, futureDailyBudget: null, todayUsed: 0 };
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
    undocked: Array.isArray(state.undocked) ? state.undocked : [],
    snapshots,
    updatePolicy: state.updatePolicy || "prompt",
    update: state.update || null,
    zoom: typeof state.zoom === "number" ? state.zoom : 1.0,
    opacity: typeof state.opacity === "number" ? state.opacity : 1.0,
    hideWeekDays: state.hideWeekDays && typeof state.hideWeekDays === "object" ? state.hideWeekDays : {},
    centerTodayInWeekStrip: state.centerTodayInWeekStrip !== false,
    showProjectedFutureDays: state.showProjectedFutureDays !== false,
  };
}

function broadcast() {
  const pub = publicState();
  if (widget && !widget.isDestroyed()) widget.webContents.send("state", pub);
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.webContents.send("state", pub);
  if (calendarWin && !calendarWin.isDestroyed()) calendarWin.webContents.send("state", pub);
  for (const win of undockedWins.values()) {
    if (win && !win.isDestroyed()) {
      win.webContents.send("state", pub);
    }
  }
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
  const tracked = tracker.processUsageUpdate(app.getPath("userData"), id, res, prevSnap, state.centerTodayInWeekStrip);

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
    todayOverrun: tracked.todayOverrun,
    futureDailyBudget: tracked.futureDailyBudget,
    todayUsed: tracked.todayUsed,
  };
}

let isFetchingAll = false;

async function fetchOne(id) {
  try {
    if (id === "agy" || id === "claudeGPT") {
      const res = await fetchers.fetchAGY(state.agyToken);
      if (id === "agy") {
        applyResult("agy", res.ok ? { ok: true, weekly: res.gemini.weekly, five: res.gemini.five, reset: res.gemini.reset, fiveReset: res.gemini.fiveReset } : res);
      } else {
        applyResult("claudeGPT", res.ok ? { ok: true, weekly: res.claude.weekly, five: res.claude.five, reset: res.claude.reset, fiveReset: res.claude.fiveReset } : res);
      }
    } else if (id === "grok") {
      applyResult("grok", await fetchers.fetchGrok());
    } else if (id === "grokBot") {
      applyResult("grokBot", await fetchers.fetchGrokBot());
    } else if (id === "cursor") {
      applyResult("cursor", await fetchers.fetchCursor());
    } else if (id === "chatGPT") {
      applyResult("chatGPT", await fetchers.fetchChatGPT());
    }
  } catch (e) {
    applyResult(id, { ok: false, error: String(e.message || e) });
  }
  saveState();
  broadcast();
}

async function fetchAll() {
  if (isFetchingAll) return;
  isFetchingAll = true;
  try {
    const en = new Set(state.enabled);
    const jobs = [];
    if (en.has("agy") || en.has("claudeGPT")) {
      jobs.push(
        fetchers.fetchAGY(state.agyToken).then((res) => {
          if (en.has("agy")) applyResult("agy", res.ok ? { ok: true, weekly: res.gemini.weekly, five: res.gemini.five, reset: res.gemini.reset, fiveReset: res.gemini.fiveReset } : res);
          if (en.has("claudeGPT")) applyResult("claudeGPT", res.ok ? { ok: true, weekly: res.claude.weekly, five: res.claude.five, reset: res.claude.reset, fiveReset: res.claude.fiveReset } : res);
        }).catch((e) => {
          if (en.has("agy")) applyResult("agy", { ok: false, error: String(e.message || e) });
          if (en.has("claudeGPT")) applyResult("claudeGPT", { ok: false, error: String(e.message || e) });
        })
      );
    }
    if (en.has("grok")) {
      jobs.push(
        fetchers.fetchGrok()
          .then((r) => applyResult("grok", r))
          .catch((e) => applyResult("grok", { ok: false, error: String(e.message || e) }))
      );
    }
    if (en.has("grokBot")) {
      jobs.push(
        fetchers.fetchGrokBot()
          .then((r) => applyResult("grokBot", r))
          .catch((e) => applyResult("grokBot", { ok: false, error: String(e.message || e) }))
      );
    }
    if (en.has("cursor")) {
      jobs.push(
        fetchers.fetchCursor()
          .then((r) => applyResult("cursor", r))
          .catch((e) => applyResult("cursor", { ok: false, error: String(e.message || e) }))
      );
    }
    if (en.has("chatGPT")) {
      jobs.push(
        fetchers.fetchChatGPT()
          .then((r) => applyResult("chatGPT", r))
          .catch((e) => applyResult("chatGPT", { ok: false, error: String(e.message || e) }))
      );
    }
    await Promise.allSettled(jobs);
    saveState();
    broadcast();
  } finally {
    isFetchingAll = false;
  }
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
  const zoom = typeof state.zoom === "number" ? state.zoom : 1.0;
  const defaultWidth = Math.round(254 * zoom);
  const initialHeight = Math.min(state.bounds?.height || Math.round(420 * zoom), screenHeight - 60);

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
    minWidth: 180,
    maxWidth: 420,
    minHeight: 100,
    maxHeight: screenHeight - 40,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: true,
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

  widget.webContents.on("did-finish-load", () => {
    if (widget && !widget.isDestroyed()) {
      try {
        widget.webContents.setZoomFactor(state.zoom || 1.0);
      } catch {}
    }
  });

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
  const winWidth = 360;
  const winHeight = 660;
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
  settingsWin.setBounds({ x, y, width: winWidth, height: winHeight });

  settingsWin.once("ready-to-show", () => {
    if (settingsWin && !settingsWin.isDestroyed()) {
      settingsWin.show();
      settingsWin.focus();
    }
  });
  setTimeout(() => {
    if (settingsWin && !settingsWin.isDestroyed() && !settingsWin.isVisible()) {
      settingsWin.show();
      settingsWin.focus();
    }
  }, 200);

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

function openCalendarWindow(id) {
  if (id) currentCalendarServiceId = id;
  if (calendarWin && !calendarWin.isDestroyed()) {
    calendarWin.loadFile(path.join(__dirname, "calendar.html"), { query: { service: currentCalendarServiceId } });
    calendarWin.show();
    calendarWin.focus();
    return;
  }
  const primaryDisplay = screen.getPrimaryDisplay();
  const { width: screenWidth, height: screenHeight } = primaryDisplay.workAreaSize;
  const winWidth = 460;
  const winHeight = 660;
  const x = Math.round((screenWidth - winWidth) / 2);
  const y = Math.round((screenHeight - winHeight) / 2);

  calendarWin = new BrowserWindow({
    width: winWidth,
    height: winHeight,
    x: x,
    y: y,
    minWidth: 380,
    minHeight: 440,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: true,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: false,
    show: false,
    backgroundColor: "#00000000",
    title: "BigUwidget - Usage Calendar",
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
    calendarWin.setAlwaysOnTop(true, "floating");
  } else {
    calendarWin.setAlwaysOnTop(true);
  }

  calendarWin.loadFile(path.join(__dirname, "calendar.html"), { query: { service: currentCalendarServiceId } });

  calendarWin.once("ready-to-show", () => {
    if (calendarWin && !calendarWin.isDestroyed()) {
      calendarWin.show();
      calendarWin.focus();
    }
  });
  setTimeout(() => {
    if (calendarWin && !calendarWin.isDestroyed() && !calendarWin.isVisible()) {
      calendarWin.show();
      calendarWin.focus();
    }
  }, 200);

  calendarWin.on("closed", () => {
    calendarWin = null;
  });
}

function closeCalendarWindow() {
  if (calendarWin && !calendarWin.isDestroyed()) {
    calendarWin.close();
    calendarWin = null;
  }
}

function createUndockedWindow(id) {
  if (undockedWins.has(id)) {
    const existing = undockedWins.get(id);
    if (existing && !existing.isDestroyed()) {
      existing.show();
      existing.focus();
      return;
    }
  }

  const primaryDisplay = screen.getPrimaryDisplay();
  const { width: screenWidth, height: screenHeight } = primaryDisplay.workAreaSize;
  const zoom = typeof state.zoom === "number" ? state.zoom : 1.0;
  const defaultWidth = Math.round(254 * zoom);
  const initialHeight = Math.min(260, screenHeight - 60);

  let x = Math.round((screenWidth - defaultWidth) / 2) + (undockedWins.size * 30);
  let y = Math.round((screenHeight - initialHeight) / 2) + (undockedWins.size * 30);

  const savedBounds = state.undockedBounds && state.undockedBounds[id];
  if (savedBounds && typeof savedBounds.x === "number" && typeof savedBounds.y === "number") {
    try {
      const display = screen.getDisplayMatching(savedBounds);
      const { x: dx, y: dy, width: dw, height: dh } = display.workArea;
      if (
        savedBounds.x >= dx - 200 &&
        savedBounds.x < dx + dw - 20 &&
        savedBounds.y >= dy - 20 &&
        savedBounds.y < dy + dh - 20
      ) {
        x = savedBounds.x;
        y = savedBounds.y;
      }
    } catch {
      if (savedBounds.x >= 0 && savedBounds.x < screenWidth - 40 && savedBounds.y >= 0 && savedBounds.y < screenHeight - 40) {
        x = savedBounds.x;
        y = savedBounds.y;
      }
    }
  }

  const cardObj = CARDS.find((c) => c.id === id);
  const cardTitle = cardObj ? cardObj.title : id;

  const win = new BrowserWindow({
    width: (savedBounds && savedBounds.width) || defaultWidth,
    height: (savedBounds && savedBounds.height) || initialHeight,
    x: x,
    y: y,
    minWidth: 180,
    maxWidth: 420,
    minHeight: 80,
    maxHeight: screenHeight - 40,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: true,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: false,
    type: process.platform === "darwin" ? "utility" : "normal",
    show: false,
    backgroundColor: "#00000000",
    title: `BigUwidget - ${cardTitle}`,
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
    win.setAlwaysOnTop(true, "floating");
  } else {
    win.setAlwaysOnTop(true);
  }

  win.webContents.on("did-finish-load", () => {
    if (win && !win.isDestroyed()) {
      try {
        win.webContents.setZoomFactor(state.zoom || 1.0);
      } catch {}
    }
  });

  win.loadFile(path.join(__dirname, "index.html"), { query: { card: id } });

  win.once("ready-to-show", () => {
    if (win && !win.isDestroyed()) {
      win.show();
      win.focus();
    }
  });
  setTimeout(() => {
    if (win && !win.isDestroyed() && !win.isVisible()) {
      win.show();
    }
  }, 200);

  const saveWinBounds = () => {
    if (win && !win.isDestroyed()) {
      const b = win.getBounds();
      state.undockedBounds = state.undockedBounds || {};
      state.undockedBounds[id] = { x: b.x, y: b.y, width: b.width, height: b.height };
      saveState();
    }
  };

  win.on("move", saveWinBounds);
  win.on("moved", saveWinBounds);
  win.on("resize", saveWinBounds);
  win.on("resized", saveWinBounds);

  win.on("close", () => {
    saveWinBounds();
  });

  win.on("closed", () => {
    undockedWins.delete(id);
  });

  undockedWins.set(id, win);
}

function syncUndockedWindows() {
  const undockedList = Array.isArray(state.undocked) ? state.undocked : [];
  const enabledSet = new Set(state.enabled || []);

  // Open windows for cards that are enabled and in state.undocked
  for (const id of undockedList) {
    if (enabledSet.has(id)) {
      if (!undockedWins.has(id)) {
        createUndockedWindow(id);
      }
    }
  }

  // Close windows for cards no longer undocked or no longer enabled
  for (const [id, win] of undockedWins.entries()) {
    if (!undockedList.includes(id) || !enabledSet.has(id)) {
      if (win && !win.isDestroyed()) {
        win.close();
      }
      undockedWins.delete(id);
    }
  }
}

app.whenReady().then(() => {
  const loaded = loadState();
  const userData = app.getPath("userData");
  const snapshots = loaded.snapshots || {};
  for (const c of CARDS) {
    if (snapshots[c.id]) {
      const dir = tracker.getServiceDir(userData, c.id);
      const deltas = tracker.getRecentDeltas(dir);
      if (deltas && deltas.length) {
        snapshots[c.id].recentDeltas = deltas;
      }
      const centerToday = loaded.centerTodayInWeekStrip !== false;
      const days = tracker.getDaysForDisplay(dir, snapshots[c.id].weekly || 0, snapshots[c.id].reset, centerToday);
      if (days && days.length) {
        snapshots[c.id].days = days;
        const todayDay = days.find((d) => d.isToday);
        const todayUsed = todayDay ? todayDay.percent : 0;
        const dailyStatus = tracker.calculateDailyStatus(snapshots[c.id].weekly || 0, todayUsed, snapshots[c.id].reset);
        snapshots[c.id].todayLeft = dailyStatus.todayLeft;
        snapshots[c.id].todayOverrun = dailyStatus.todayOverrun;
        snapshots[c.id].futureDailyBudget = dailyStatus.futureDailyBudget;
        snapshots[c.id].todayUsed = todayUsed;
      }
    }
  }
  state = {
    enabled: Array.isArray(loaded.enabled) ? loaded.enabled : DEFAULT_ENABLED,
    order: Array.isArray(loaded.order) ? loaded.order : DEFAULT_ENABLED,
    undocked: Array.isArray(loaded.undocked) ? loaded.undocked : [],
    undockedBounds: loaded.undockedBounds && typeof loaded.undockedBounds === "object" ? loaded.undockedBounds : {},
    snapshots: snapshots,
    bounds: loaded.bounds || null,
    updatePolicy: loaded.updatePolicy || "prompt",
    agyToken: loaded.agyToken || null,
    zoom: typeof loaded.zoom === "number" ? loaded.zoom : 1.0,
    opacity: typeof loaded.opacity === "number" ? loaded.opacity : 1.0,
    hideWeekDays: loaded.hideWeekDays && typeof loaded.hideWeekDays === "object" ? loaded.hideWeekDays : {},
    centerTodayInWeekStrip: loaded.centerTodayInWeekStrip !== false,
    showProjectedFutureDays: loaded.showProjectedFutureDays !== false,
    update: null,
  };
  createWidget();
  syncUndockedWindows();
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
  syncUndockedWindows();
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
ipcMain.handle("set-hide-week-days", (_e, id, hide) => {
  state.hideWeekDays = state.hideWeekDays || {};
  if (hide) {
    state.hideWeekDays[id] = true;
  } else {
    delete state.hideWeekDays[id];
  }
  saveState();
  broadcast();
  return publicState();
});
ipcMain.handle("set-center-today-in-week-strip", (_e, enabled) => {
  state.centerTodayInWeekStrip = !!enabled;
  const userData = app.getPath("userData");
  for (const c of CARDS) {
    if (state.snapshots[c.id]) {
      const dir = tracker.getServiceDir(userData, c.id);
      const days = tracker.getDaysForDisplay(dir, state.snapshots[c.id].weekly || 0, state.snapshots[c.id].reset, state.centerTodayInWeekStrip);
      if (days && days.length) {
        state.snapshots[c.id].days = days;
      }
    }
  }
  saveState();
  broadcast();
  return publicState();
});
ipcMain.handle("set-show-projected-future-days", (_e, enabled) => {
  state.showProjectedFutureDays = !!enabled;
  saveState();
  broadcast();
  return publicState();
});
ipcMain.handle("toggle-undock", (_e, id) => {
  const undocked = Array.isArray(state.undocked) ? [...state.undocked] : [];
  const idx = undocked.indexOf(id);
  if (idx >= 0) {
    undocked.splice(idx, 1);
  } else {
    undocked.push(id);
  }
  state.undocked = undocked;
  saveState();
  syncUndockedWindows();
  broadcast();
  return publicState();
});
ipcMain.handle("set-undocked", (_e, id, isUndocked) => {
  const undockedSet = new Set(Array.isArray(state.undocked) ? state.undocked : []);
  if (isUndocked) {
    undockedSet.add(id);
  } else {
    undockedSet.delete(id);
  }
  state.undocked = [...undockedSet];
  saveState();
  syncUndockedWindows();
  broadcast();
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
ipcMain.handle("open-calendar", (_e, id) => {
  openCalendarWindow(id);
  return true;
});
ipcMain.handle("close-calendar", () => {
  closeCalendarWindow();
  return true;
});
ipcMain.handle("get-calendar-data", (_e, id, targetYear) => {
  const serviceId = id || currentCalendarServiceId || "agy";
  const snap = state.snapshots[serviceId] || {};
  return tracker.getCalendarData(
    app.getPath("userData"),
    serviceId,
    targetYear,
    snap.reset,
    snap.weekly || 0
  );
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

ipcMain.handle("set-zoom", (_e, zoom) => {
  const z = Math.min(1.5, Math.max(0.7, typeof zoom === "number" ? zoom : 1.0));
  state.zoom = Math.round(z * 100) / 100;
  saveState();
  broadcast();
  const zoomVal = typeof state.zoom === "number" ? state.zoom : 1.0;
  const targetW = Math.round(254 * zoomVal);
  if (widget && !widget.isDestroyed()) {
    try {
      widget.webContents.setZoomFactor(state.zoom);
    } catch {}
    const [x, y] = widget.getPosition();
    const [, h] = widget.getSize();
    widget.setBounds({ x, y, width: targetW, height: h });
  }
  for (const win of undockedWins.values()) {
    if (win && !win.isDestroyed()) {
      try {
        win.webContents.setZoomFactor(state.zoom);
      } catch {}
      const [wx, wy] = win.getPosition();
      const [, wh] = win.getSize();
      win.setBounds({ x: wx, y: wy, width: targetW, height: wh });
    }
  }
  return publicState();
});

ipcMain.handle("set-opacity", (_e, opacity) => {
  const op = Math.min(1.0, Math.max(0.2, typeof opacity === "number" ? opacity : 1.0));
  state.opacity = Math.round(op * 100) / 100;
  saveState();
  broadcast();
  return publicState();
});

ipcMain.handle("fit-height", (_e, height) => {
  if (widget && !widget.isDestroyed() && typeof height === "number" && height > 50) {
    const primaryDisplay = screen.getPrimaryDisplay();
    const maxHeight = primaryDisplay.workAreaSize.height - 40;
    const zoomVal = typeof state.zoom === "number" ? state.zoom : 1.0;
    const targetW = Math.round(254 * zoomVal);
    const targetH = Math.min(Math.max(100, Math.ceil(height * zoomVal)), maxHeight);
    const [x, y] = widget.getPosition();
    widget.setBounds({ x, y, width: targetW, height: targetH });
  }
  return true;
});

ipcMain.handle("fit-undocked-height", (_e, id, height) => {
  if (id && undockedWins.has(id) && typeof height === "number" && height > 30) {
    const win = undockedWins.get(id);
    if (win && !win.isDestroyed()) {
      const primaryDisplay = screen.getPrimaryDisplay();
      const maxHeight = primaryDisplay.workAreaSize.height - 40;
      const zoomVal = typeof state.zoom === "number" ? state.zoom : 1.0;
      const targetW = Math.round(254 * zoomVal);
      const targetH = Math.min(Math.max(80, Math.ceil(height * zoomVal)), maxHeight);
      const [x, y] = win.getPosition();
      win.setBounds({ x, y, width: targetW, height: targetH });
    }
  }
  return true;
});

ipcMain.on("open-external-url", (_e, url) => {
  if (url && (url.startsWith("https://") || url.startsWith("http://"))) {
    shell.openExternal(url);
  }
});


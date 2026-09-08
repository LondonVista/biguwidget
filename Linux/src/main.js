const { app, BrowserWindow, ipcMain, shell } = require("electron");
const path = require("path");
const fs = require("fs");
const fetchers = require("./fetchers");
const updater = require("./updater");

const DONATE = "https://ko-fi.com/london_vista";
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

function emptySnap(id) {
  return { id, status: "loading", weekly: 0, five: null, reset: null, fiveReset: null, fetchedAt: 0 };
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
  if (widget && !widget.isDestroyed()) widget.webContents.send("state", publicState());
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
  state.snapshots[id] = {
    id,
    status: "ready",
    weekly: res.weekly ?? 0,
    five: res.five ?? null,
    reset: res.reset || null,
    fiveReset: res.fiveReset || null,
    plan: res.plan || CARDS.find((c) => c.id === id)?.title,
    fetchedAt: Date.now(),
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
      },
    });
    loginWin.loadFile(path.join(__dirname, "agy-login.html"));
    loginWin.show();
    loginWin.focus();
    loginWin.on("closed", () => {
      loginWin = null;
      fetchOne("agy");
      fetchOne("claudeGPT");
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
      partition: "persist:bigu",
      userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    },
  });
  loginWin.loadURL(card.login);
  loginWin.show();
  loginWin.focus();
  loginWin.on("closed", () => {
    loginWin = null;
    fetchOne(id);
  });
}

function createWidget() {
  const bounds = state.bounds || { width: 236, height: 740, x: undefined, y: undefined };
  widget = new BrowserWindow({
    width: bounds.width || 236,
    height: bounds.height || 740,
    x: bounds.x,
    y: bounds.y,
    minWidth: 220,
    minHeight: 160,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: true,
    skipTaskbar: false,
    backgroundColor: "#00000000",
    title: "BigUwidget",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      partition: "persist:bigu",
    },
  });
  widget.setAlwaysOnTop(true, "floating");
  widget.loadFile(path.join(__dirname, "index.html"));
  widget.on("close", () => {
    state.bounds = widget.getBounds();
    saveState();
  });
  widget.on("closed", () => {
    widget = null;
  });
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
  setInterval(fetchAll, 25000);
  setTimeout(checkForUpdates, 4000);
  setInterval(checkForUpdates, 6 * 60 * 60 * 1000);
});

async function checkForUpdates() {
  const policy = state.updatePolicy || "prompt";
  if (policy === "off") return;
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
  await checkForUpdates();
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

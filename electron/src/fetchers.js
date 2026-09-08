const { net, session } = require("electron");
const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

function cookieHeader(cookies) {
  return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
}

async function cookiesFor(urls) {
  const ses = session.fromPartition("persist:bigu");
  const all = [];
  for (const url of urls) {
    const list = await ses.cookies.get({ url });
    all.push(...list);
  }
  const byName = new Map();
  for (const c of all) byName.set(c.name, c);
  return [...byName.values()];
}

function request(opts) {
  return new Promise((resolve) => {
    const req = net.request(opts);
    for (const [k, v] of Object.entries(opts.headers || {})) {
      req.setHeader(k, v);
    }
    const chunks = [];
    req.on("response", (res) => {
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        resolve({ status: res.statusCode || 0, buf });
      });
    });
    req.on("error", () => resolve({ status: 0, buf: Buffer.alloc(0) }));
    if (opts.body) req.write(opts.body);
    req.end();
  });
}

function parseWindow(win) {
  if (!win || typeof win !== "object") return { used: null, reset: null };
  const used = typeof win.used_percent === "number" ? win.used_percent : null;
  let reset = null;
  if (typeof win.reset_at === "number" && win.reset_at > 1e9) {
    reset = win.reset_at * 1000;
  } else if (typeof win.reset_after_seconds === "number" && win.reset_after_seconds > 0) {
    reset = Date.now() + win.reset_after_seconds * 1000;
  }
  return { used, reset };
}

function cleanToken(raw) {
  if (!raw || typeof raw !== "string") return null;
  let str = raw.trim();
  if (!str) return null;
  if (str.startsWith("go-keyring-base64:")) {
    try {
      str = Buffer.from(str.slice("go-keyring-base64:".length), "base64").toString("utf8").trim();
    } catch {}
  }
  if (str.startsWith("{")) {
    try {
      const obj = JSON.parse(str);
      const tok = obj?.token?.access_token || obj?.access_token;
      if (tok && typeof tok === "string") return tok.trim();
    } catch {}
  }
  return str;
}

function detectAGYToken(savedToken) {
  if (savedToken) {
    const cleaned = cleanToken(savedToken);
    if (cleaned) return { source: "saved", token: cleaned };
  }

  // 1. Linux Secret Service (via secret-tool)
  if (process.platform === "linux") {
    try {
      const out = cp.execFileSync("secret-tool", ["lookup", "service", "gemini", "username", "antigravity"], {
        encoding: "utf8",
        timeout: 1500,
        stdio: ["ignore", "pipe", "ignore"],
      });
      const tok = cleanToken(out);
      if (tok) return { source: "Secret Service (secret-tool)", token: tok };
    } catch {}
  }

  // 2. macOS Keychain
  if (process.platform === "darwin") {
    try {
      const out = cp.execFileSync("/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"], {
        encoding: "utf8",
        timeout: 1500,
        stdio: ["ignore", "pipe", "ignore"],
      });
      const tok = cleanToken(out);
      if (tok) return { source: "macOS Keychain", token: tok };
    } catch {}
  }

  // 3. Credential files on disk
  const candidates = [
    path.join(os.homedir(), ".gemini", "antigravity-cli", "antigravity-oauth-token"),
    path.join(os.homedir(), ".gemini", "oauth_creds.json"),
    path.join(os.homedir(), ".config", "antigravity", "oauth_creds.json"),
    path.join(os.homedir(), ".config", "antigravity-cli", "antigravity-oauth-token"),
  ];

  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) {
        const raw = fs.readFileSync(candidate, "utf8");
        const tok = cleanToken(raw);
        if (tok) return { source: candidate, token: tok };
      }
    } catch {}
  }

  return null;
}

function parseAGYGroups(buf) {
  let json;
  try {
    json = JSON.parse(buf.toString("utf8"));
  } catch {
    return null;
  }
  const groups = json.groups || [];
  let gemini = { weekly: 0, five: null, reset: null, fiveReset: null };
  let claude = { weekly: 0, five: null, reset: null, fiveReset: null };
  for (const g of groups) {
    const name = String(g.displayName || "").toLowerCase();
    for (const b of g.buckets || []) {
      const rem = typeof b.remainingFraction === "number" ? b.remainingFraction : 1;
      const used = Math.max(0, Math.min(100, (1 - rem) * 100));
      const reset = b.resetTime ? Date.parse(b.resetTime) : null;
      const target = name.includes("gemini") ? gemini : name.includes("claude") || name.includes("gpt") ? claude : null;
      if (!target) continue;
      if (b.window === "weekly") {
        target.weekly = used;
        target.reset = reset;
      } else if (b.window === "5h") {
        target.five = used;
        target.fiveReset = reset;
      }
    }
  }
  return { gemini, claude };
}

async function fetchAGY(explicitToken) {
  const tokenInfo = detectAGYToken(explicitToken);
  const token = tokenInfo?.token;

  const endpoints = [
    "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
    "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
  ];

  // 1. Try Bearer Token if available
  if (token) {
    for (const url of endpoints) {
      const { status, buf } = await request({
        method: "POST",
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${token}`,
          "User-Agent": "Antigravity/1.0",
        },
        body: "{}",
      });
      if (status === 200) {
        const parsed = parseAGYGroups(buf);
        if (parsed) {
          return { ok: true, gemini: parsed.gemini, claude: parsed.claude, source: tokenInfo?.source || "token" };
        }
      }
    }
  }

  // 2. Cookie fallback
  const cookies = await cookiesFor([
    "https://antigravity.google",
    "https://google.com",
    "https://accounts.google.com",
  ]);
  if (cookies.length) {
    const header = cookieHeader(cookies);
    for (const url of endpoints) {
      const { status, buf } = await request({
        method: "POST",
        url,
        headers: {
          "Content-Type": "application/json",
          Cookie: header,
          "User-Agent": UA,
        },
        body: "{}",
      });
      if (status === 200) {
        const parsed = parseAGYGroups(buf);
        if (parsed) {
          return { ok: true, gemini: parsed.gemini, claude: parsed.claude, source: "cookie" };
        }
      }
    }
  }

  return { ok: false, needLogin: true };
}

function headlineFloats(buf) {
  const out = [];
  for (let i = 0; i + 5 <= buf.length; i++) {
    if (buf[i] !== 0x15) continue;
    const n = buf.readFloatLE(i + 1);
    if (Number.isFinite(n) && n >= 0 && n <= 100) out.push(n);
  }
  return out;
}

function parseGrokBinary(buf) {
  const floats = headlineFloats(buf);
  if (!floats.length) return null;
  const ints = [...new Set(floats.map((f) => Math.round(f)))];
  const usagePercent = ints.length ? ints[0] : floats[0];
  return { usagePercent, periodEnd: null };
}

async function fetchGrok() {
  const cookies = await cookiesFor(["https://grok.com", "https://x.ai"]);
  if (!cookies.length) return { ok: false, needLogin: true };
  const { status, buf } = await request({
    method: "POST",
    url: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig",
    headers: {
      "Content-Type": "application/grpc-web+proto",
      "connect-protocol-version": "1",
      "x-grpc-web": "1",
      Origin: "https://grok.com",
      Cookie: cookieHeader(cookies),
      "User-Agent": UA,
    },
    body: Buffer.from([0, 0, 0, 0, 0]),
  });
  if (status === 401 || status === 403) return { ok: false, needLogin: true };
  if (status !== 200) return { ok: false, needLogin: status === 0 };
  const parsed = parseGrokBinary(buf);
  if (!parsed) return { ok: false, error: "Couldn't parse Grok usage" };
  return { ok: true, weekly: parsed.usagePercent, reset: parsed.periodEnd };
}

async function fetchGrokBot() {
  const cookies = await cookiesFor(["https://cursor.com", "https://www.cursor.com"]);
  if (!cookies.length) return { ok: false, needLogin: true };
  const { status, buf } = await request({
    method: "POST",
    url: "https://cursor.com/api/dashboard/get-sand-usage-status",
    headers: {
      "Content-Type": "application/json",
      Origin: "https://cursor.com",
      Referer: "https://cursor.com",
      Cookie: cookieHeader(cookies),
      "User-Agent": UA,
    },
    body: "{}",
  });
  if (status === 401 || status === 403) return { ok: false, needLogin: true };
  if (status !== 200) return { ok: false, needLogin: status === 0 };
  let json;
  try {
    json = JSON.parse(buf.toString("utf8"));
  } catch {
    return { ok: false, error: "Couldn't parse Cursor usage" };
  }
  const weekly = typeof json.usagePercent === "number" ? json.usagePercent : 0;
  const reset = json.nextResetTimestampUtc ? Date.parse(json.nextResetTimestampUtc) : null;
  return { ok: true, weekly, reset, plan: json.grokPlanLabel || "Grok Bot" };
}

async function fetchChatGPT() {
  const cookies = await cookiesFor(["https://chatgpt.com", "https://openai.com"]);
  if (!cookies.length) return { ok: false, needLogin: true };
  const header = cookieHeader(cookies);
  const sessionRes = await request({
    method: "GET",
    url: "https://chatgpt.com/api/auth/session",
    headers: {
      Accept: "application/json",
      Origin: "https://chatgpt.com",
      Referer: "https://chatgpt.com/",
      Cookie: header,
      "User-Agent": UA,
    },
  });
  if (sessionRes.status === 401 || sessionRes.status === 403) return { ok: false, needLogin: true };
  let token = "";
  try {
    const s = JSON.parse(sessionRes.buf.toString("utf8"));
    token = s.accessToken || "";
  } catch {
    token = "";
  }
  if (!token) return { ok: false, needLogin: true };
  const usageRes = await request({
    method: "GET",
    url: "https://chatgpt.com/backend-api/wham/usage",
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${token}`,
      Origin: "https://chatgpt.com",
      Referer: "https://chatgpt.com/",
      Cookie: header,
      "User-Agent": UA,
    },
  });
  if (usageRes.status === 401 || usageRes.status === 403) return { ok: false, needLogin: true };
  if (usageRes.status !== 200) return { ok: false, error: `Couldn't refresh (${usageRes.status})` };
  let json;
  try {
    json = JSON.parse(usageRes.buf.toString("utf8"));
  } catch {
    return { ok: false, error: "Couldn't parse ChatGPT usage" };
  }
  const usage = json.usage || json;
  const rate = usage.rate_limit || {};
  const primary = parseWindow(rate.primary_window);
  const secondary = parseWindow(rate.secondary_window);
  return {
    ok: true,
    weekly: secondary.used ?? primary.used ?? 0,
    five: primary.used,
    reset: secondary.reset,
    fiveReset: primary.reset,
    plan: usage.plan_type || "ChatGPT",
  };
}

module.exports = { fetchAGY, fetchGrok, fetchGrokBot, fetchChatGPT, detectAGYToken, cleanToken };

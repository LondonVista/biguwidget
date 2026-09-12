const { app, net, shell, dialog } = require("electron");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawn, spawnSync } = require("child_process");
const { pipeline } = require("stream/promises");
const { Readable } = require("stream");

const VERSION = "1.1.7";
const FEED = "https://github.com/LondonVista/biguwidget/releases/latest/download/latest.json";
const GITHUB_API = "https://api.github.com/repos/LondonVista/biguwidget/releases/latest";
const PAGE = "https://github.com/LondonVista/biguwidget/releases/latest";

function cmpVer(a, b) {
  const pa = String(a || "0").split(".").map((n) => parseInt(n, 10) || 0);
  const pb = String(b || "0").split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0;
    const y = pb[i] || 0;
    if (x > y) return 1;
    if (x < y) return -1;
  }
  return 0;
}

function platformKey() {
  if (process.platform === "darwin") return "darwin";
  if (process.platform === "win32") return "win32";
  return "linux";
}

function getJSON(url) {
  return new Promise((resolve, reject) => {
    const req = net.request({ url, method: "GET" });
    req.setHeader("User-Agent", "BigUwidget/" + VERSION);
    req.setHeader("Accept", "application/json");
    const chunks = [];
    req.on("response", (res) => {
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error("HTTP " + res.statusCode));
          return;
        }
        try {
          resolve(JSON.parse(body));
        } catch (e) {
          reject(e);
        }
      });
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end();
  });
}

function normalizeFeed(data) {
  if (!data) return null;
  if (data.version) {
    const downloads = data.downloads || {};
    return {
      version: String(data.version).replace(/^v/, ""),
      notes: data.notes || "",
      html_url: data.html_url || PAGE,
      url: downloads[platformKey()] || data.url || data.html_url || PAGE,
    };
  }
  if (data.tag_name) {
    const ver = String(data.tag_name).replace(/^v/, "");
    const assets = data.assets || [];
    const key = platformKey();
    const match =
      assets.find((a) => {
        const n = (a.name || "").toLowerCase();
        if (key === "darwin") return n.includes("mac") || n.includes("darwin");
        if (key === "win32") return n.includes("win") || n.includes("windows");
        return n.includes("linux");
      }) || assets[0];
    return {
      version: ver,
      notes: data.body || "",
      html_url: data.html_url || PAGE,
      url: (match && match.browser_download_url) || data.html_url || PAGE,
    };
  }
  return null;
}

async function fetchLatest() {
  try {
    return normalizeFeed(await getJSON(FEED));
  } catch {
    return normalizeFeed(await getJSON(GITHUB_API));
  }
}

async function downloadTo(url, dest) {
  const res = await fetch(url, { redirect: "follow", headers: { "User-Agent": "BigUwidget/" + VERSION } });
  if (!res.ok) throw new Error("Download HTTP " + res.status);
  await pipeline(Readable.fromWeb(res.body), fs.createWriteStream(dest));
}

function unzip(zip, dest) {
  fs.mkdirSync(dest, { recursive: true });
  if (process.platform === "win32") {
    const r = spawnSync(
      "powershell.exe",
      ["-NoProfile", "-Command", `Expand-Archive -Force -LiteralPath "${zip}" -DestinationPath "${dest}"`],
      { encoding: "utf8" }
    );
    if (r.status !== 0) throw new Error(r.stderr || "unzip failed");
    return;
  }
  const r = spawnSync("unzip", ["-o", zip, "-d", dest], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr || "unzip failed");
}

function copyTree(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  for (const name of fs.readdirSync(src)) {
    if (name === "node_modules" || name === "dist") continue;
    const from = path.join(src, name);
    const to = path.join(dst, name);
    const st = fs.statSync(from);
    if (st.isDirectory()) copyTree(from, to);
    else fs.copyFileSync(from, to);
  }
}

async function installUpdate(info) {
  if (!info || !info.url) {
    await shell.openExternal(PAGE);
    return { ok: true, opened: PAGE };
  }
  if (!/\.zip$/i.test(info.url.split("?")[0])) {
    await shell.openExternal(info.url);
    return { ok: true, opened: info.url };
  }
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "bigu-"));
  const zip = path.join(tmp, "update.zip");
  await downloadTo(info.url, zip);
  const out = path.join(tmp, "out");
  unzip(zip, out);
  const packed = fs.readdirSync(out).map((n) => path.join(out, n)).find((p) => fs.statSync(p).isDirectory()) || out;
  const root = path.join(__dirname, "..");
  copyTree(packed, root);
  app.relaunch();
  app.exit(0);
  return { ok: true };
}

module.exports = { VERSION, PAGE, cmpVer, fetchLatest, installUpdate };

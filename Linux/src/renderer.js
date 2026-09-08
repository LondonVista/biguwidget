function remaining(ts) {
  if (!ts) return "";
  const mins = Math.max(0, Math.floor((ts - Date.now()) / 60000));
  const d = Math.floor(mins / (24 * 60));
  const h = Math.floor((mins % (24 * 60)) / 60);
  const m = mins % 60;
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function resetTone(ts) {
  if (!ts) return "";
  const hours = (ts - Date.now()) / 3600000;
  if (hours <= 24) return "hot";
  if (hours <= 48) return "warm";
  return "cool";
}

function fiveTone(ts) {
  if (!ts) return "";
  const mins = (ts - Date.now()) / 60000;
  if (mins <= 30) return "hot";
  if (mins <= 90) return "warm";
  return "ok";
}

function ago(ts) {
  if (!ts) return "";
  const s = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  if (s < 5) return "Refreshed just now";
  if (s < 60) return `Refreshed ${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `Refreshed ${m}m ago`;
  return `Refreshed ${Math.floor(m / 60)}h ago`;
}

function fmtPct(n) {
  if (n == null || Number.isNaN(n)) return "0";
  const r = Math.round(n * 10) / 10;
  return r === Math.round(r) ? String(Math.round(r)) : r.toFixed(1);
}

let state = { cards: [], enabled: [], order: [], snapshots: {}, version: "1.0.5", updatePolicy: "prompt", update: null };
let showSettings = false;
const collapsed = new Set();

function orderedCards() {
  const byId = Object.fromEntries((state.cards || []).map((c) => [c.id, c]));
  const order = state.order && state.order.length ? state.order : (state.cards || []).map((c) => c.id);
  const seen = new Set();
  const list = [];
  for (const id of order) {
    if (byId[id] && !seen.has(id)) {
      list.push(byId[id]);
      seen.add(id);
    }
  }
  for (const c of state.cards || []) if (!seen.has(c.id)) list.push(c);
  return list;
}

function render() {
  const root = document.getElementById("root");
  const enabled = new Set(state.enabled || []);
  const all = orderedCards();
  const cards = all.filter((c) => enabled.has(c.id));
  let html = `<div class="stack">`;
  html += `<div class="card drag chrome">
    <div class="row">
      <div class="brand">BigUwidget</div>
      <div class="ver">${state.version || "1.0.5"}</div>
      <div class="space"></div>
      <button class="btn no-drag" data-act="settings" title="Settings">⚙</button>
      <button class="btn no-drag" data-act="refresh" title="Refresh">↻</button>
      <button class="btn no-drag" data-act="donate" title="Donate">♥</button>
      <button class="btn no-drag" data-act="quit" title="Quit">✕</button>
    </div>
  </div>`;
  if (state.update && state.update.version && (state.updatePolicy || "prompt") !== "off") {
    html += `<div class="card no-drag update">
      <div class="utitle">Update ${state.update.version}</div>
      <div class="unotes">${state.update.notes ? String(state.update.notes).slice(0, 160) : "A newer BigUwidget is on GitHub."}</div>
      <div class="urow">
        <button class="done" data-act="install-update">Install</button>
        <button class="link" data-act="open-releases">GitHub</button>
      </div>
    </div>`;
  }

  if (showSettings) {
    html += `<div class="card no-drag settings">
      <div class="stitle">Widget Settings</div>
      <div class="shelp">Toggle cards. ChatGPT is opt-in. Sign in after enabling.</div>`;
    for (const card of all) {
      const on = enabled.has(card.id);
      html += `<div class="srow">
        <span class="sname">${card.title}</span>
        <button class="btn" data-act="login" data-id="${card.id}" title="Sign in">👤</button>
        <button class="tog ${on ? "on" : ""}" data-act="toggle" data-id="${card.id}">${on ? "On" : "Off"}</button>
      </div>`;
    }
    const pol = state.updatePolicy || "prompt";
    html += `<div class="shelp" style="margin-top:10px">Updates (GitHub)</div>
      <div class="srow">
        <button class="tog ${pol === "off" ? "on" : ""}" data-act="update-policy" data-id="off">Off</button>
        <button class="tog ${pol === "prompt" ? "on" : ""}" data-act="update-policy" data-id="prompt">Prompt</button>
        <button class="tog ${pol === "auto" ? "on" : ""}" data-act="update-policy" data-id="auto">Auto</button>
        <button class="btn" data-act="check-updates" title="Check now">↻</button>
      </div>`;
    html += `<div class="sfoot">
      <button class="link" data-act="donate">Donate</button>
      <span class="sver">v${state.version || "1.0.5"}</span>
      <button class="done" data-act="settings">Done</button>
    </div></div>`;
  }

  if (!cards.length && !showSettings) {
    html += `<div class="card"><div class="muted">No cards enabled. Open Settings to turn services on.</div></div>`;
  }

  for (const card of cards) {
    const snap = (state.snapshots && state.snapshots[card.id]) || { status: "loading" };
    const isCol = collapsed.has(card.id);
    html += `<div class="card">`;
    html += `<div class="row drag"><div class="title">${card.title}</div>`;
    if (snap.status === "needsLogin") {
      html += `<span class="offline no-drag" data-act="login" data-id="${card.id}">offline</span>`;
    }
    html += `<div class="space"></div>
      <button class="btn no-drag" data-act="collapse" data-id="${card.id}" title="Collapse">${isCol ? "▾" : "▴"}</button>
      <button class="btn no-drag" data-act="login" data-id="${card.id}" title="Sign in">👤</button>
    </div>`;
    if (isCol && snap.status === "ready") {
      html += `<div class="mini"><span class="mpct">${fmtPct(snap.weekly)}%</span> used
        <span class="space"></span><span class="ago no-drag" data-act="fetch" data-id="${card.id}">${ago(snap.fetchedAt)}</span></div>`;
    } else if (snap.status === "loading") {
      html += `<div class="muted">Loading…</div>`;
    } else if (snap.status === "needsLogin") {
      html += `<div class="muted no-drag" data-act="login" data-id="${card.id}">Sign in</div>`;
    } else if (snap.status === "error") {
      html += `<div class="warn no-drag" data-act="fetch" data-id="${card.id}">${snap.error || "Couldn't refresh"}</div>`;
    } else {
      html += `<div class="row"><span class="pct">${fmtPct(snap.weekly)}</span><span class="used">% used</span></div>`;
      if (snap.reset) html += `<div class="reset ${resetTone(snap.reset)}">Resets in ${remaining(snap.reset)}</div>`;
      html += `<div class="bar"><span style="width:${Math.min(100, Math.max(0, snap.weekly || 0))}%"></span></div>`;
      if (snap.five != null) {
        const fr = snap.fiveReset ? ` · reset in ${remaining(snap.fiveReset)}` : "";
        html += `<div class="five ${fiveTone(snap.fiveReset)}">5h: ${fmtPct(snap.five)}% used${fr}</div>`;
      }
      const left = Math.max(0, 100 - (snap.weekly || 0));
      html += `<div class="foot"><span class="today">${left > 0.05 ? `weekly ${fmtPct(left)}% left` : "weekly 0% left"}</span>
        <span class="ago no-drag" data-act="fetch" data-id="${card.id}">${ago(snap.fetchedAt)}</span></div>`;
    }
    html += `</div>`;
  }

  if (!enabled.has("chatGPT")) {
    html += `<div class="card add no-drag"><button class="addbtn" data-act="add" data-id="chatGPT">+ Add ChatGPT</button></div>`;
  }
  html += `</div>`;
  root.innerHTML = html;
}

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-act]");
  if (!t || !window.bigu) return;
  const act = t.getAttribute("data-act");
  const id = t.getAttribute("data-id");
  if (act === "quit") window.bigu.quit();
  if (act === "donate") window.bigu.openDonate();
  if (act === "refresh") window.bigu.fetchAll();
  if (act === "settings") {
    showSettings = !showSettings;
    render();
  }
  if (act === "collapse" && id) {
    if (collapsed.has(id)) collapsed.delete(id);
    else collapsed.add(id);
    render();
  }
  if (act === "toggle" && id) {
    const on = !(state.enabled || []).includes(id);
    window.bigu.setEnabled(id, on);
  }
  if (act === "add" && id) {
    window.bigu.setEnabled(id, true);
    window.bigu.login(id);
  }
  if (act === "login" && id) {
    window.bigu.setEnabled(id, true);
    window.bigu.login(id);
  }
  if (act === "fetch" && id) window.bigu.fetchOne(id);
  if (act === "update-policy" && id) window.bigu.setUpdatePolicy(id);
  if (act === "install-update") window.bigu.installUpdate();
  if (act === "check-updates") window.bigu.checkUpdates();
  if (act === "open-releases") window.bigu.openReleases();
});

async function boot() {
  if (!window.bigu) return;
  state = await window.bigu.getState();
  render();
  window.bigu.onState((s) => {
    state = s;
    render();
  });
  // Lightweight 60s ticker for relative time labels without rebuilding the DOM
  setInterval(() => {
    document.querySelectorAll(".ago[data-id]").forEach((el) => {
      const id = el.getAttribute("data-id");
      const snap = state.snapshots && state.snapshots[id];
      if (snap && snap.fetchedAt) {
        el.textContent = ago(snap.fetchedAt);
      }
    });
  }, 60000);
}

boot();

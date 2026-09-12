function remainingParts(ts) {
  if (!ts) return { days: "", rest: "" };
  const mins = Math.max(0, Math.floor((ts - Date.now()) / 60000));
  const d = Math.floor(mins / (24 * 60));
  const h = Math.floor((mins % (24 * 60)) / 60);
  const m = mins % 60;
  if (d > 0) {
    return { days: `${d}d`, rest: `${h}h ${m}m` };
  }
  if (h > 0) {
    return { days: `${h}h`, rest: `${m}m` };
  }
  return { days: `${m}m`, rest: "" };
}

function formatResetDate(ts) {
  if (!ts) return "";
  try {
    const d = new Date(ts);
    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const day = days[d.getDay()];
    const mon = months[d.getMonth()];
    const date = d.getDate();
    let h = d.getHours();
    const m = String(d.getMinutes()).padStart(2, "0");
    const ampm = h >= 12 ? "PM" : "AM";
    h = h % 12 || 12;
    return `on ${day} ${mon} ${date} at ${h}:${m} ${ampm}`;
  } catch {
    return "";
  }
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

let state = { cards: [], enabled: [], order: [], snapshots: {}, version: "1.1.7", updatePolicy: "prompt", update: null };
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

function renderDeltas(snap) {
  const list = snap.recentDeltas;
  if (!list || !list.length) return "";
  return list.slice(0, 4).map(d => {
    const mins = Math.max(0, Math.floor((Date.now() - (d.timestamp || Date.now())) / 60000));
    const timeStr = mins < 60 ? `${mins}m` : `${Math.floor(mins / 60)}h`;
    const valStr = `+${(d.delta || 0).toFixed(2)}%`;
    return `<div class="delta-row"><span class="delta-time">${timeStr}</span><span class="delta-badge">${valStr}</span></div>`;
  }).join("");
}

function renderWeek(snap) {
  const days = Array.isArray(snap.days) && snap.days.length ? snap.days : [];
  if (!days.length) {
    const labels = ["M", "T", "W", "T", "F", "S", "S"];
    const now = new Date();
    const todayIdx = (now.getDay() + 6) % 7;
    let fallback = `<div class="week-row">`;
    for (let i = 0; i < 7; i++) {
      const isToday = i === todayIdx;
      fallback += `<div class="day-col ${isToday ? "today-day" : ""}">
        ${isToday ? `<div class="day-caret">▲</div><div class="day-lbl"><span class="day-dot">•</span>${labels[i]}</div>` : `<div class="day-lbl">${labels[i]}</div>`}
        <div class="day-pct">0%</div>
      </div>`;
    }
    fallback += `</div>`;
    return fallback;
  }

  let html = `<div class="week-row">`;
  for (const day of days) {
    const isToday = !!day.isToday;
    const isReset = !!day.isReset && !isToday;
    const hasBonus = (day.accumulatedGain || 0) >= 0.5;
    const gainInt = Math.round(day.accumulatedGain || 0);

    let cls = "day-col";
    if (isToday) cls += " today-day";
    else if (isReset) cls += " target-day";

    html += `<div class="${cls}">`;
    if (hasBonus) {
      html += `<div class="day-bonus">+${gainInt}</div>`;
      html += `<div class="day-lbl">${day.label}</div>`;
    } else if (isToday) {
      html += `<div class="day-caret">▲</div>`;
      html += `<div class="day-lbl"><span class="day-dot">•</span>${day.label}</div>`;
    } else {
      html += `<div class="day-lbl">${day.label}</div>`;
    }
    const val = Math.round(day.percent || 0);
    html += `<div class="day-pct">${val}%</div>`;
    html += `</div>`;
  }
  html += `</div>`;
  return html;
}

function render() {
  const root = document.getElementById("root");
  const enabled = new Set(state.enabled || []);
  const all = orderedCards();
  const cards = all.filter((c) => enabled.has(c.id));
  let html = `<div class="stack">`;

  // Top window bar chrome
  html += `<div class="card drag chrome">
    <div class="row">
      <div class="brand">BigUwidget</div>
      <div class="ver">${state.version || "1.1.6"}</div>
      <div class="space"></div>
      <button class="btn no-drag" data-act="refresh" title="Refresh">↻</button>
      <button class="btn no-drag" data-act="settings" title="Settings">⚙</button>
      <button class="btn no-drag" data-act="minimize" title="Minimize">−</button>
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

  if (!cards.length) {
    html += `<div class="card"><div class="muted">No cards enabled. <button class="link" data-act="settings" style="text-decoration:underline">Open Settings</button> to turn services on.</div></div>`;
  }

  for (const card of cards) {
    const snap = (state.snapshots && state.snapshots[card.id]) || { status: "loading" };
    const isCol = collapsed.has(card.id);

    html += `<div class="card">`;
    html += `<div class="card-header drag">
      <div class="title">${card.title}</div>
      <div class="row no-drag">`;
    if (snap.status === "needsLogin") {
      html += `<span class="offline" data-act="login" data-id="${card.id}">offline</span>`;
    }
    if (snap.status !== "ready") {
      html += `<button class="btn" data-act="login" data-id="${card.id}" title="Sign in">👤</button>`;
    }
    html += `<button class="btn chevron-btn" data-act="collapse" data-id="${card.id}" title="Collapse">${isCol ? "▾" : "▴"}</button>
      </div>
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
      const resetP = remainingParts(snap.reset);
      const resetStr = resetP.days ? `<span class="hl-orange">${resetP.days}</span> ${resetP.rest}` : resetP.rest;
      const dateSubtitle = snap.reset ? formatResetDate(snap.reset) : "";
      const deltasHtml = renderDeltas(snap);

      // 1. Top Section: Big percentage & Resets + Deltas
      html += `<div class="top-section">
        <div class="main-metrics">
          <div class="pct-wrap">
            <span class="pct">${fmtPct(snap.weekly)}%</span>
            <span class="used">used</span>
          </div>
          ${snap.reset ? `<div class="reset-info">Resets in ${resetStr}</div>` : ""}
          ${dateSubtitle ? `<div class="reset-date">${dateSubtitle}</div>` : ""}
        </div>
        ${deltasHtml ? `<div class="deltas-stack">${deltasHtml}</div>` : ""}
      </div>`;

      // 2. Progress Bar
      html += `<div class="bar-wrap">
        <div class="bar"><span style="width:${Math.min(100, Math.max(0, snap.weekly || 0))}%"></span></div>
        <div class="bar-max">100%</div>
      </div>`;

      // 3. 5h Window
      if (snap.five != null || snap.fiveReset != null) {
        const fiveP = remainingParts(snap.fiveReset);
        const fiveResetStr = fiveP.days ? `<span class="hl-orange">${fiveP.days} ${fiveP.rest}</span>` : `<span class="hl-orange">${fiveP.rest}</span>`;
        const fiveUsed = fmtPct(snap.five || 0);
        html += `<div class="five-row">5h: ${fiveUsed}% used · reset in ${fiveResetStr}</div>`;
      }

      // 4. 7-Day Weekly Breakdown (Real Calendar Data)
      html += renderWeek(snap);

      // 5. Footer: Real today left & refreshed time
      const todayLeftVal = snap.todayLeft != null ? snap.todayLeft : Math.max(0, 100 - (snap.weekly || 0)) / 7;
      html += `<div class="foot">
        <span class="today">today: ${todayLeftVal.toFixed(1)}% left</span>
        <span class="ago no-drag" data-act="fetch" data-id="${card.id}">${ago(snap.fetchedAt)}</span>
      </div>`;
    }

    html += `</div>`;
  }

  if (!enabled.has("chatGPT")) {
    html += `<div class="card add no-drag"><button class="addbtn" data-act="add" data-id="chatGPT">+ Add ChatGPT</button></div>`;
  }
  html += `</div>`;
  root.innerHTML = html;

  if (window.bigu && typeof window.bigu.fitHeight === "function") {
    requestAnimationFrame(() => {
      const h = root.offsetHeight;
      if (h > 0) {
        window.bigu.fitHeight(h + 8);
      }
    });
  }
}

document.addEventListener("click", async (e) => {
  const t = e.target.closest("[data-act]");
  if (!t || !window.bigu) return;
  const act = t.getAttribute("data-act");
  const id = t.getAttribute("data-id");

  if (act === "quit") window.bigu.quit();
  if (act === "minimize") window.bigu.minimize();
  if (act === "settings") window.bigu.openSettingsWindow();
  if (act === "refresh") window.bigu.fetchAll();
  if (act === "collapse" && id) {
    if (collapsed.has(id)) collapsed.delete(id);
    else collapsed.add(id);
    render();
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
  if (act === "install-update") window.bigu.installUpdate();
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
  setInterval(() => {
    document.querySelectorAll(".ago[data-id]").forEach((el) => {
      const id = el.getAttribute("data-id");
      const snap = state.snapshots && state.snapshots[id];
      if (snap && snap.fetchedAt) {
        el.textContent = ago(snap.fetchedAt);
      }
    });
  }, 10000);
}

boot();

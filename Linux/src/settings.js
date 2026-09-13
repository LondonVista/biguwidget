let state = { cards: [], enabled: [], order: [], snapshots: {}, version: "1.1.9", updatePolicy: "prompt", update: null, zoom: 1.0 };
let isCheckingUpdates = false;
let checkStatusMsg = "";
let checkStatusTimer = null;
let isInteractingWithSlider = false;

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

function updateZoomControlsOnly() {
  const slider = document.getElementById("zoom-slider");
  const lbl = document.getElementById("zoom-lbl");
  const resetBtn = document.querySelector("[data-act='zoom-reset']");
  const currentZoom = typeof state.zoom === "number" ? state.zoom : 1.0;
  const zoomPct = Math.round(currentZoom * 100);

  if (slider && !isInteractingWithSlider && document.activeElement !== slider) {
    slider.value = zoomPct;
  }
  if (lbl) {
    lbl.textContent = `${zoomPct}%`;
  }
  if (resetBtn) {
    if (zoomPct === 100) resetBtn.classList.add("on");
    else resetBtn.classList.remove("on");
  }
}

function renderSettings() {
  const container = document.getElementById("settings-modal");
  if (!container) return;

  const slider = document.getElementById("zoom-slider");
  if (slider && (isInteractingWithSlider || document.activeElement === slider)) {
    updateZoomControlsOnly();
    return;
  }

  const enabled = new Set(state.enabled || []);
  const all = orderedCards();
  const currentZoom = typeof state.zoom === "number" ? state.zoom : 1.0;
  const zoomPct = Math.round(currentZoom * 100);

  let html = `
    <div class="row drag" style="margin-bottom: 8px;">
      <div class="stitle" style="margin: 0; font-size: 14px; font-weight: 700;">Widget Settings</div>
      <div class="space"></div>
      <button class="btn no-drag" data-act="close" title="Close" style="font-size: 14px;">✕</button>
    </div>
    <div class="shelp">Toggle cards. ChatGPT is opt-in. Sign in after enabling.</div>
  `;

  for (const card of all) {
    const on = enabled.has(card.id);
    html += `
      <div class="srow">
        <span class="sname">${card.title}</span>
        <button class="btn no-drag" data-act="login" data-id="${card.id}" title="Sign in">👤</button>
        <button class="tog no-drag ${on ? "on" : ""}" data-act="toggle" data-id="${card.id}">${on ? "On" : "Off"}</button>
      </div>
    `;
  }

  // Zoom / Scale Slider Row
  html += `
    <div class="shelp" style="margin-top: 12px; margin-bottom: 6px;">Widget Scale (<span id="zoom-lbl" style="color: var(--cyan); font-weight: 700;">${zoomPct}%</span>)</div>
    <div class="srow zoom-row">
      <button class="btn no-drag zoom-btn" data-act="zoom-step" data-step="-0.05" title="Zoom out">−</button>
      <input type="range" class="zoom-slider no-drag" min="70" max="150" step="5" value="${zoomPct}" id="zoom-slider" />
      <button class="btn no-drag zoom-btn" data-act="zoom-step" data-step="0.05" title="Zoom in">+</button>
      <button class="tog no-drag reset-zoom ${zoomPct === 100 ? "on" : ""}" data-act="zoom-reset" title="Reset to 100%">100%</button>
    </div>
  `;

  const pol = state.updatePolicy || "prompt";
  html += `
    <div class="shelp" style="margin-top: 12px; margin-bottom: 6px;">Updates (GitHub)</div>
    <div class="srow">
      <button class="tog no-drag ${pol === "off" ? "on" : ""}" data-act="update-policy" data-id="off">Off</button>
      <button class="tog no-drag ${pol === "prompt" ? "on" : ""}" data-act="update-policy" data-id="prompt">Prompt</button>
      <button class="tog no-drag ${pol === "auto" ? "on" : ""}" data-act="update-policy" data-id="auto">Auto</button>
      <button class="btn no-drag ${isCheckingUpdates ? "spinning" : ""}" data-act="check-updates" title="Check now">↻</button>
      ${checkStatusMsg ? `<span class="check-status">${checkStatusMsg}</span>` : ""}
    </div>
  `;

  html += `
    <div class="sfoot" style="margin-top: 16px;">
      <div class="sfoot-links">
        <button class="link no-drag" data-act="donate">Donate</button>
        <button class="link fb no-drag" data-act="feedback">Feedback</button>
      </div>
      <span class="sver">v${state.version || "1.1.8"}</span>
      <button class="done no-drag" data-act="close">Done</button>
    </div>
  `;

  container.innerHTML = html;

  const newSlider = document.getElementById("zoom-slider");
  if (newSlider) {
    newSlider.addEventListener("mousedown", () => { isInteractingWithSlider = true; });
    newSlider.addEventListener("touchstart", () => { isInteractingWithSlider = true; });
    window.addEventListener("mouseup", () => { isInteractingWithSlider = false; });
    window.addEventListener("touchend", () => { isInteractingWithSlider = false; });

    newSlider.addEventListener("input", (e) => {
      const val = parseInt(e.target.value, 10);
      const lbl = document.getElementById("zoom-lbl");
      if (lbl) lbl.textContent = `${val}%`;
      const resetBtn = document.querySelector("[data-act='zoom-reset']");
      if (resetBtn) {
        if (val === 100) resetBtn.classList.add("on");
        else resetBtn.classList.remove("on");
      }
      if (window.bigu && typeof window.bigu.setZoom === "function") {
        window.bigu.setZoom(val / 100);
      }
    });
  }
}

document.addEventListener("click", async (e) => {
  const t = e.target.closest("[data-act]");
  if (!t || !window.bigu) return;
  const act = t.getAttribute("data-act");
  const id = t.getAttribute("data-id");

  if (act === "close") {
    window.bigu.closeSettingsWindow();
  }
  if (act === "donate") {
    window.bigu.openDonate();
  }
  if (act === "feedback") {
    window.bigu.openFeedback();
  }
  if (act === "toggle" && id) {
    const on = !(state.enabled || []).includes(id);
    window.bigu.setEnabled(id, on);
  }
  if (act === "login" && id) {
    window.bigu.setEnabled(id, true);
    window.bigu.login(id);
  }
  if (act === "zoom-step") {
    const step = parseFloat(t.getAttribute("data-step") || "0");
    const current = typeof state.zoom === "number" ? state.zoom : 1.0;
    const next = Math.min(1.5, Math.max(0.7, Math.round((current + step) * 100) / 100));
    window.bigu.setZoom(next);
  }
  if (act === "zoom-reset") {
    window.bigu.setZoom(1.0);
  }
  if (act === "update-policy" && id) {
    window.bigu.setUpdatePolicy(id);
  }
  if (act === "check-updates") {
    if (isCheckingUpdates) return;
    isCheckingUpdates = true;
    checkStatusMsg = "";
    if (checkStatusTimer) clearTimeout(checkStatusTimer);
    renderSettings();
    try {
      const res = await window.bigu.checkUpdates();
      if (res && res.update && res.update.version) {
        checkStatusMsg = `v${res.update.version} available!`;
      } else {
        checkStatusMsg = "Up to date ✓";
      }
    } catch {
      checkStatusMsg = "Check failed";
    } finally {
      isCheckingUpdates = false;
      renderSettings();
      checkStatusTimer = setTimeout(() => {
        checkStatusMsg = "";
        renderSettings();
      }, 3500);
    }
  }
});

async function boot() {
  if (!window.bigu) return;
  state = await window.bigu.getState();
  renderSettings();
  window.bigu.onState((s) => {
    state = s;
    renderSettings();
  });
}

boot();

let state = { cards: [], enabled: [], order: [], snapshots: {}, version: "1.1.6", updatePolicy: "prompt", update: null };
let isCheckingUpdates = false;
let checkStatusMsg = "";
let checkStatusTimer = null;

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

function renderSettings() {
  const container = document.getElementById("settings-modal");
  if (!container) return;
  const enabled = new Set(state.enabled || []);
  const all = orderedCards();

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
      <span class="sver">v${state.version || "1.1.5"}</span>
      <button class="done no-drag" data-act="close">Done</button>
    </div>
  `;

  container.innerHTML = html;
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

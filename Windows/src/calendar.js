let state = null;
let currentServiceId = "agy";
let currentYear = new Date().getFullYear();
let calendarData = null;

const urlParams = new URLSearchParams(window.location.search);
if (urlParams.get("service")) {
  currentServiceId = urlParams.get("service");
}

function renderHeader() {
  const headerRoot = document.getElementById("cal-header-root");
  if (!headerRoot) return;

  const card = (state && state.cards && state.cards.find((c) => c.id === currentServiceId)) || { title: currentServiceId };
  const enabledCards = (state && state.cards && state.cards.filter((c) => (state.enabled || []).includes(c.id))) || [];

  let servicePills = "";
  if (enabledCards.length > 1) {
    servicePills = `<div class="row" style="gap: 4px; overflow-x: auto; max-width: 320px; padding: 2px 0;">`;
    for (const c of enabledCards) {
      const isSel = c.id === currentServiceId;
      servicePills += `<button class="tog no-drag ${isSel ? "on" : ""}" data-act="switch-service" data-id="${c.id}" style="font-size: 10px; padding: 2px 7px;">${c.title}</button>`;
    }
    servicePills += `</div>`;
  }

  headerRoot.innerHTML = `
    <div class="row drag" style="margin-bottom: 4px; padding-bottom: 4px; border-bottom: 1px solid rgba(255,255,255,0.08);">
      <div style="display: flex; align-items: baseline; gap: 8px;">
        <span style="font-size: 14px; font-weight: 700; color: #ffffff;">${card.title} Calendar</span>
        <span style="font-size: 11px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; opacity: 0.5;">${currentYear}</span>
      </div>
      <div class="space"></div>
      ${servicePills}
      <button class="btn no-drag" data-act="close" title="Close" style="font-size: 14px; margin-left: 6px;">✕</button>
    </div>
    <div class="cal-subtitle">Each day is % of that week’s ${card.title} pool. Weeks and months are the sum of those days.</div>
  `;
}

function renderCalendar() {
  const contentRoot = document.getElementById("cal-content-root");
  if (!contentRoot || !calendarData) return;

  const now = new Date();
  const currentMonth = now.getMonth() + 1;
  const snap = (state && state.snapshots && state.snapshots[currentServiceId]) || {};
  const futureBudgetVal = typeof snap.futureDailyBudget === "number" ? snap.futureDailyBudget : (typeof snap.todayLeft === "number" ? snap.todayLeft : 0);
  const showProjected = state && state.showProjectedFutureDays !== false && futureBudgetVal > 0;
  const projPct = Math.round(futureBudgetVal);

  let html = "";

  for (const month of calendarData.months) {
    const isCurrentMonth = month.monthNum === currentMonth;
    html += `
      <div class="cal-month-card" id="month-${month.monthNum}">
        <div class="cal-month-header">
          <span class="cal-month-title">${month.name}</span>
          <span class="cal-month-sum">${Math.round(month.monthTotal)}%</span>
        </div>
        <div class="cal-week-headers">
          <span class="cal-col-header">M</span>
          <span class="cal-col-header">T</span>
          <span class="cal-col-header">W</span>
          <span class="cal-col-header">T</span>
          <span class="cal-col-header">F</span>
          <span class="cal-col-header">S</span>
          <span class="cal-col-header">S</span>
          <span class="cal-col-header" style="text-align: right;">week</span>
        </div>
    `;

    for (const row of month.rows) {
      html += `<div class="cal-grid-row">`;
      for (const cell of row.cells) {
        if (!cell) {
          html += `<div class="cal-cell" style="visibility: hidden;"></div>`;
          continue;
        }

        const isToday = !!cell.isToday;
        const isReset = !!cell.isReset;
        const isFuture = !!cell.isFuture;
        const hasUsed = cell.used > 0;

        let dayNumHtml = isReset
          ? `<span class="cal-day-num reset-badge">${cell.dayNum}</span>`
          : `<span class="cal-day-num" style="${isToday ? "color: rgba(255,255,255,0.95); font-weight:700;" : ""}">${cell.dayNum}</span>`;

        let pctHtml = "";
        if (isFuture) {
          if (showProjected) {
            pctHtml = `<span class="cal-day-pct projected">${projPct}%</span>`;
          } else {
            pctHtml = `<span class="cal-day-pct idle">0%</span>`;
          }
        } else if (hasUsed) {
          pctHtml = `<span class="cal-day-pct">${Math.round(cell.used)}%</span>`;
        } else {
          pctHtml = `<span class="cal-day-pct idle">0%</span>`;
        }

        const cellCls = `cal-cell ${isToday ? "today-cell" : ""}`;
        html += `
          <div class="${cellCls}" title="${cell.key}: ${hasUsed ? Math.round(cell.used) + "% used" : (isFuture && showProjected ? "Projected daily budget: " + projPct + "%" : "0% used")}">
            ${dayNumHtml}
            ${pctHtml}
          </div>
        `;
      }

      html += `<span class="cal-row-sum">${Math.round(row.rowSum)}%</span>`;
      html += `</div>`;
    }

    html += `</div>`;
  }

  contentRoot.innerHTML = html;

  // Scroll to current month if in the current year
  if (currentYear === now.getFullYear()) {
    setTimeout(() => {
      const el = document.getElementById(`month-${currentMonth}`);
      if (el) {
        el.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    }, 100);
  }
}

async function loadDataAndRender() {
  if (!window.bigu) return;
  state = await window.bigu.getState();
  calendarData = await window.bigu.getCalendarData(currentServiceId, currentYear);
  renderHeader();
  renderCalendar();
}

document.addEventListener("click", async (e) => {
  const t = e.target.closest("[data-act]");
  if (!t || !window.bigu) return;
  const act = t.getAttribute("data-act");
  const id = t.getAttribute("data-id");

  if (act === "close") {
    window.bigu.closeCalendar();
  }
  if (act === "switch-service" && id) {
    currentServiceId = id;
    calendarData = await window.bigu.getCalendarData(currentServiceId, currentYear);
    renderHeader();
    renderCalendar();
  }
});

async function boot() {
  if (!window.bigu) return;
  await loadDataAndRender();
  window.bigu.onState(async (s) => {
    state = s;
    calendarData = await window.bigu.getCalendarData(currentServiceId, currentYear);
    renderHeader();
    renderCalendar();
  });
}

boot();

const fs = require("fs");
const path = require("path");

function getServiceDir(userDataPath, serviceId) {
  const dir = path.join(userDataPath, "services", serviceId);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function isResetWeekday(keyOrDate, resetDate) {
  if (!resetDate) return false;
  try {
    let d;
    if (typeof keyOrDate === "string") {
      d = new Date(keyOrDate + "T12:00:00Z");
    } else if (keyOrDate instanceof Date) {
      const key = keyOrDate.toISOString().slice(0, 10);
      d = new Date(key + "T12:00:00Z");
    } else {
      return false;
    }
    const r = new Date(resetDate);
    return d.getUTCDay() === r.getUTCDay();
  } catch {
    return false;
  }
}

function loadJson(filePath, def = null) {
  try {
    if (fs.existsSync(filePath)) {
      return JSON.parse(fs.readFileSync(filePath, "utf8"));
    }
  } catch {}
  return def;
}

function saveJson(filePath, data) {
  try {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
  } catch {}
}

function appendPositiveDelta(dir, prevTotal, newTotal, fiveHour, nowTs, minStep = 0.005) {
  if (prevTotal == null || newTotal <= prevTotal + minStep) return;
  const deltasPath = path.join(dir, "session-deltas.json");
  let list = loadJson(deltasPath, []);
  if (!Array.isArray(list)) list = [];

  const diff = newTotal - prevTotal;
  const now = new Date(nowTs * 1000);
  const df = now.toISOString().replace("T", " ").slice(0, 19);

  const rec = {
    date: df,
    timestamp: nowTs,
    weeklyDelta: diff,
    weeklyTotal: newTotal,
  };
  if (fiveHour != null) rec.fiveHourPercent = fiveHour;

  list.push(rec);

  // Filter last 366 days and cap at 4000
  const cutoff = nowTs - 366 * 86400;
  list = list.filter((item) => (item.timestamp || 0) >= cutoff);
  if (list.length > 4000) list = list.slice(-4000);

  saveJson(deltasPath, list);
}

function updateDailyUsage(dir, totalPercent, nowTs, resetsAt) {
  const dailyPath = path.join(dir, "daily-usage.json");
  let map = loadJson(dailyPath, {}) || {};

  const now = new Date(nowTs * 1000);
  const todayKey = now.toISOString().slice(0, 10);
  const yesterday = new Date(now.getTime() - 86400000);
  const yesterdayKey = yesterday.toISOString().slice(0, 10);

  let entry = map[todayKey] || {};
  const yesterdayClose = map[yesterdayKey]?.close;

  if (entry.open == null) {
    entry.open = yesterdayClose != null ? yesterdayClose : totalPercent;
  }

  const prevClose = entry.close != null ? entry.close : yesterdayClose;
  if (prevClose != null && totalPercent + 5 < prevClose) {
    const resetDate = resetsAt ? new Date(resetsAt) : null;
    const scheduled = isResetWeekday(todayKey, resetDate);
    if (scheduled) {
      entry.accumulated = 0;
    } else {
      const drop = prevClose - totalPercent;
      entry.accumulated = (entry.accumulated || 0) + drop;
    }
    entry.open = totalPercent;
  }

  entry.close = totalPercent;
  if (entry.accumulated == null) entry.accumulated = 0;
  map[todayKey] = entry;

  saveJson(dailyPath, map);
}

function effectiveAccumulated(key, map, resetsAt) {
  const entry = map[key] || {};
  const acc = entry.accumulated || 0;
  if (acc < 0.5) return 0;
  if (isResetWeekday(key, resetsAt ? new Date(resetsAt) : null)) return 0;

  const open = entry.open || 0;
  const close = entry.close || 0;
  const d = new Date(key + "T12:00:00Z");
  const prevD = new Date(d.getTime() - 86400000);
  const prevKey = prevD.toISOString().slice(0, 10);
  const prevClose = map[prevKey]?.close;

  if (prevClose != null && Math.abs(acc - prevClose) < 1.5 && close > 10 && open < 0.5) {
    return 0;
  }
  return acc;
}

function usedPercent(key, map, currentTotal, isToday, resetsAt) {
  const e = map[key] || {};
  const open = e.open != null ? e.open : 0;
  let close = isToday ? currentTotal : (e.close != null ? e.close : 0);
  if (e.open == null && e.close == null && !isToday) return 0.0;

  const bonus = effectiveAccumulated(key, map, resetsAt);
  let effectiveOpen = open;
  // Only back-fill effectiveOpen with prev-day's close when open=0 is a
  // gap (tracker wasn't running at midnight). On a reset weekday open=0 is
  // correct — the quota actually restarted — so skip the substitution.
  const isReset = isResetWeekday(key, resetsAt ? new Date(resetsAt) : null);
  if (!isReset && effectiveOpen === 0 && bonus < 0.5) {
    const d = new Date(key + "T12:00:00Z");
    const prevD = new Date(d.getTime() - 86400000);
    const prevKey = prevD.toISOString().slice(0, 10);
    if (map[prevKey]?.close > 0) {
      effectiveOpen = map[prevKey].close;
    }
  }
  return Math.max(0, close - effectiveOpen);
}

function localDateKey(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function getDaysForDisplay(dir, currentTotal, resetsAt, centerToday = false) {
  const dailyPath = path.join(dir, "daily-usage.json");
  const map = loadJson(dailyPath, {}) || {};

  const cal = new Date();
  const today = new Date(cal.getFullYear(), cal.getMonth(), cal.getDate());
  const todayKey = localDateKey(today);
  const out = [];

  if (centerToday) {
    // 3 days past, Today in middle (index 3), 3 days future
    const dayLabels = ["S", "M", "T", "W", "T", "F", "S"];
    for (let offset = -3; offset <= 3; offset++) {
      const d = new Date(today);
      d.setDate(today.getDate() + offset);
      const key = localDateKey(d);
      const isToday = offset === 0;
      const isFuture = offset > 0;
      const percent = usedPercent(key, map, currentTotal, isToday, resetsAt);
      const gain = effectiveAccumulated(key, map, resetsAt);
      const isReset = isResetWeekday(d, resetsAt ? new Date(resetsAt) : null);

      out.push({
        key,
        label: dayLabels[d.getDay()],
        percent: Math.round(percent * 10) / 10,
        accumulatedGain: gain,
        isToday,
        isFuture,
        isReset,
      });
    }
  } else {
    // Standard Monday-Sunday strip
    const mondayOffset = (today.getDay() + 6) % 7; // Monday = 0, Sunday = 6
    const monday = new Date(today);
    monday.setDate(today.getDate() - mondayOffset);
    const labels = ["M", "T", "W", "T", "F", "S", "S"];
    for (let i = 0; i < 7; i++) {
      const d = new Date(monday);
      d.setDate(monday.getDate() + i);
      const key = localDateKey(d);
      const isToday = key === todayKey;
      const isFuture = d > today;
      const percent = usedPercent(key, map, currentTotal, isToday, resetsAt);
      const gain = effectiveAccumulated(key, map, resetsAt);
      const isReset = isResetWeekday(d, resetsAt ? new Date(resetsAt) : null);

      out.push({
        key,
        label: labels[i],
        percent: Math.round(percent * 10) / 10,
        accumulatedGain: gain,
        isToday,
        isFuture,
        isReset,
      });
    }
  }
  return out;
}

function getRecentDeltas(dir) {
  const deltasPath = path.join(dir, "session-deltas.json");
  const list = loadJson(deltasPath, []) || [];
  if (!Array.isArray(list)) return [];
  return list
    .slice(-4)
    .reverse()
    .map((item) => ({
      delta: item.weeklyDelta || item.delta || 0,
      timestamp: (item.timestamp || 0) * 1000,
    }));
}

function calculateDailyStatus(totalPercent, todayUsed, resetsAt) {
  const effectiveTodayUsed = Math.max(0, todayUsed);
  const remainingAtOpen = Math.max(0, 100.0 - Math.max(0, totalPercent - effectiveTodayUsed));
  const poolRemainingNow = Math.max(0, 100.0 - totalPercent);
  const evenDailyShare = 100.0 / 7.0;

  if (!resetsAt) {
    const budget = Math.min(remainingAtOpen, evenDailyShare);
    const left = Math.min(Math.max(0, budget - effectiveTodayUsed), poolRemainingNow);
    const overrun = Math.max(0, effectiveTodayUsed - budget);
    return { todayLeft: left, todayOverrun: overrun };
  }

  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const reset = new Date(resetsAt);
  const secondsFromMorning = Math.max(0, (reset.getTime() - startOfToday.getTime()) / 1000);
  const daysFromMorning = Math.max(0.05, secondsFromMorning / 86400.0);

  const todayBudget = daysFromMorning <= 1.0 ? remainingAtOpen : remainingAtOpen / daysFromMorning;
  const todayLeft = Math.min(Math.max(0, todayBudget - effectiveTodayUsed), poolRemainingNow);
  const todayOverrun = Math.max(0, effectiveTodayUsed - todayBudget);
  return { todayLeft, todayOverrun };
}

function processUsageUpdate(userDataPath, serviceId, res, prevSnap, centerToday = false) {
  const dir = getServiceDir(userDataPath, serviceId);
  const nowTs = Date.now() / 1000;
  const totalPercent = res.weekly ?? 0;
  const prevTotal = prevSnap && typeof prevSnap.weekly === "number" ? prevSnap.weekly : null;

  appendPositiveDelta(dir, prevTotal, totalPercent, res.five, nowTs);
  updateDailyUsage(dir, totalPercent, nowTs, res.reset);

  const days = getDaysForDisplay(dir, totalPercent, res.reset, centerToday);
  const recentDeltas = getRecentDeltas(dir);
  const todayDay = days.find((d) => d.isToday);
  const todayUsed = todayDay ? todayDay.percent : 0;
  const dailyStatus = calculateDailyStatus(totalPercent, todayUsed, res.reset);

  return {
    days,
    recentDeltas,
    todayLeft: dailyStatus.todayLeft,
    todayOverrun: dailyStatus.todayOverrun,
    todayUsed,
  };
}

function getCalendarData(userDataPath, serviceId, targetYear, resetsAt, currentTotal) {
  const dir = getServiceDir(userDataPath, serviceId);
  const dailyPath = path.join(dir, "daily-usage.json");
  const map = loadJson(dailyPath, {}) || {};

  const year = targetYear || (new Date()).getFullYear();
  const now = new Date();
  const todayKey = localDateKey(now);
  const resetDate = resetsAt ? new Date(resetsAt) : null;

  const months = [];
  const monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
  ];

  for (let m = 0; m < 12; m++) {
    const start = new Date(year, m, 1);
    const daysInMonth = new Date(year, m + 1, 0).getDate();
    const weekday = (start.getDay() + 6) % 7; // Monday = 0
    const totalCells = weekday + daysInMonth;
    const numRows = Math.ceil(totalCells / 7);

    const rows = [];
    let monthTotal = 0;

    for (let r = 0; r < numRows; r++) {
      const cells = [];
      let rowSum = 0;
      for (let c = 0; c < 7; c++) {
        const cellIdx = r * 7 + c;
        const dayNum = cellIdx - weekday + 1;
        if (dayNum >= 1 && dayNum <= daysInMonth) {
          const d = new Date(year, m, dayNum);
          const key = localDateKey(d);
          const isToday = key === todayKey;
          const isFuture = d > now && !isToday;
          const isReset = isResetWeekday(key, resetDate);
          const used = usedPercent(key, map, currentTotal, isToday, resetsAt);
          const val = Math.round(used * 10) / 10;
          rowSum += val;
          monthTotal += val;

          cells.push({
            dayNum,
            key,
            isToday,
            isFuture,
            isReset,
            used: val,
            hasData: !!map[key] || isToday,
          });
        } else {
          cells.push(null);
        }
      }
      rows.push({
        cells,
        rowSum: Math.round(rowSum * 10) / 10,
      });
    }

    months.push({
      monthNum: m + 1,
      name: monthNames[m],
      rows,
      monthTotal: Math.round(monthTotal * 10) / 10,
    });
  }

  return {
    year,
    serviceId,
    months,
  };
}

module.exports = {
  processUsageUpdate,
  getDaysForDisplay,
  getRecentDeltas,
  calculateDailyStatus,
  getServiceDir,
  getCalendarData,
  localDateKey,
};

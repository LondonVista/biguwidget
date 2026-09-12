const fs = require("fs");
const path = require("path");

function getServiceDir(userDataPath, serviceId) {
  const dir = path.join(userDataPath, "services", serviceId);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function isResetWeekday(key, resetDate) {
  if (!resetDate) return false;
  try {
    const d = new Date(key + "T12:00:00Z");
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
  if (effectiveOpen === 0 && bonus < 0.5) {
    const d = new Date(key + "T12:00:00Z");
    const prevD = new Date(d.getTime() - 86400000);
    const prevKey = prevD.toISOString().slice(0, 10);
    if (map[prevKey]?.close > 0) {
      effectiveOpen = map[prevKey].close;
    }
  }
  return Math.max(0, close - effectiveOpen);
}

function getDaysForDisplay(dir, currentTotal, resetsAt) {
  const dailyPath = path.join(dir, "daily-usage.json");
  const map = loadJson(dailyPath, {}) || {};

  const now = new Date();
  const dayOfWeek = (now.getDay() + 6) % 7; // Monday = 0, Sunday = 6
  const monday = new Date(now);
  monday.setDate(now.getDate() - dayOfWeek);
  monday.setHours(0, 0, 0, 0);

  const labels = ["M", "T", "W", "T", "F", "S", "S"];
  const days = [];
  const todayKey = now.toISOString().slice(0, 10);

  for (let i = 0; i < 7; i++) {
    const d = new Date(monday);
    d.setDate(monday.getDate() + i);
    const key = d.toISOString().slice(0, 10);
    const isToday = key === todayKey;
    const percent = usedPercent(key, map, currentTotal, isToday, resetsAt);
    const gain = effectiveAccumulated(key, map, resetsAt);
    const isReset = isResetWeekday(key, resetsAt ? new Date(resetsAt) : null);

    days.push({
      key,
      label: labels[i],
      percent: Math.round(percent * 10) / 10,
      accumulatedGain: gain,
      isToday,
      isReset,
    });
  }
  return days;
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
    return { todayLeft: left };
  }

  const now = new Date();
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const reset = new Date(resetsAt);
  const secondsFromMorning = Math.max(0, (reset.getTime() - startOfToday.getTime()) / 1000);
  const daysFromMorning = Math.max(0.05, secondsFromMorning / 86400.0);

  const todayBudget = daysFromMorning <= 1.0 ? remainingAtOpen : remainingAtOpen / daysFromMorning;
  const todayLeft = Math.min(Math.max(0, todayBudget - effectiveTodayUsed), poolRemainingNow);
  return { todayLeft };
}

function processUsageUpdate(userDataPath, serviceId, res, prevSnap) {
  const dir = getServiceDir(userDataPath, serviceId);
  const nowTs = Date.now() / 1000;
  const totalPercent = res.weekly ?? 0;
  const prevTotal = prevSnap && typeof prevSnap.weekly === "number" ? prevSnap.weekly : null;

  appendPositiveDelta(dir, prevTotal, totalPercent, res.five, nowTs);
  updateDailyUsage(dir, totalPercent, nowTs, res.reset);

  const days = getDaysForDisplay(dir, totalPercent, res.reset);
  const recentDeltas = getRecentDeltas(dir);
  const todayDay = days.find((d) => d.isToday);
  const todayUsed = todayDay ? todayDay.percent : 0;
  const dailyStatus = calculateDailyStatus(totalPercent, todayUsed, res.reset);

  return {
    days,
    recentDeltas,
    todayLeft: dailyStatus.todayLeft,
    todayUsed,
  };
}

module.exports = {
  processUsageUpdate,
  getDaysForDisplay,
  getRecentDeltas,
  calculateDailyStatus,
  getServiceDir,
};

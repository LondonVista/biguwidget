const { contextBridge, ipcRenderer, webFrame } = require("electron");

contextBridge.exposeInMainWorld("bigu", {
  version: "1.2.2",
  fetchAll: () => ipcRenderer.invoke("fetch-all"),
  fetchOne: (id) => ipcRenderer.invoke("fetch-one", id),
  login: (id) => ipcRenderer.invoke("login", id),
  getState: () => ipcRenderer.invoke("get-state"),
  setEnabled: (id, on) => ipcRenderer.invoke("set-enabled", id, on),
  setOrder: (ids) => ipcRenderer.invoke("set-order", ids),
  setZoom: (zoom) => ipcRenderer.invoke("set-zoom", zoom),
  setOpacity: (opacity) => ipcRenderer.invoke("set-opacity", opacity),
  setHideWeekDays: (id, hide) => ipcRenderer.invoke("set-hide-week-days", id, hide),
  setCenterTodayInWeekStrip: (enabled) => ipcRenderer.invoke("set-center-today-in-week-strip", enabled),
  setShowProjectedFutureDays: (enabled) => ipcRenderer.invoke("set-show-projected-future-days", enabled),
  toggleUndock: (id) => ipcRenderer.invoke("toggle-undock", id),
  setUndocked: (id, undocked) => ipcRenderer.invoke("set-undocked", id, undocked),
  setZoomFactor: (factor) => {
    try {
      if (typeof factor === "number" && factor > 0) {
        webFrame.setZoomFactor(factor);
      }
    } catch {}
  },
  openDonate: () => ipcRenderer.invoke("open-donate"),
  openFeedback: () => ipcRenderer.invoke("open-feedback"),
  minimize: () => ipcRenderer.invoke("minimize"),
  openSettingsWindow: () => ipcRenderer.invoke("open-settings-window"),
  closeSettingsWindow: () => ipcRenderer.invoke("close-settings-window"),
  openCalendar: (id) => ipcRenderer.invoke("open-calendar", id),
  closeCalendar: () => ipcRenderer.invoke("close-calendar"),
  getCalendarData: (id, year) => ipcRenderer.invoke("get-calendar-data", id, year),
  quit: () => ipcRenderer.invoke("quit"),
  setUpdatePolicy: (policy) => ipcRenderer.invoke("set-update-policy", policy),
  installUpdate: () => ipcRenderer.invoke("install-update"),
  checkUpdates: () => ipcRenderer.invoke("check-updates"),
  openReleases: () => ipcRenderer.invoke("open-releases"),
  saveAGYToken: (token) => ipcRenderer.invoke("save-agy-token", token),
  detectAGYToken: () => ipcRenderer.invoke("detect-agy-token"),
  clearAGYToken: () => ipcRenderer.invoke("clear-agy-token"),
  openGoogleLogin: () => ipcRenderer.invoke("open-google-login"),
  closeLogin: () => ipcRenderer.invoke("close-login"),
  fitHeight: (h) => ipcRenderer.invoke("fit-height", h),
  fitUndockedHeight: (id, h) => ipcRenderer.invoke("fit-undocked-height", id, h),
  onState: (fn) => {
    ipcRenderer.on("state", (_e, data) => fn(data));
  },
});

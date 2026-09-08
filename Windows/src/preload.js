const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("bigu", {
  version: "1.0.9",
  fetchAll: () => ipcRenderer.invoke("fetch-all"),
  fetchOne: (id) => ipcRenderer.invoke("fetch-one", id),
  login: (id) => ipcRenderer.invoke("login", id),
  getState: () => ipcRenderer.invoke("get-state"),
  setEnabled: (id, on) => ipcRenderer.invoke("set-enabled", id, on),
  setOrder: (ids) => ipcRenderer.invoke("set-order", ids),
  openDonate: () => ipcRenderer.invoke("open-donate"),
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
  onState: (fn) => {
    ipcRenderer.on("state", (_e, data) => fn(data));
  },
});

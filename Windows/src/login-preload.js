const { ipcRenderer, webFrame } = require("electron");

// 1. Execute in the Main World so the page's scripts (e.g. x.com / grok.com)
// default to the standard password prompt instead of hanging on the passkey spinner.
webFrame.executeJavaScript(`
(() => {
  try {
    if (window.PublicKeyCredential) {
      window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
      if (typeof window.PublicKeyCredential.isConditionalMediationAvailable === "function") {
        window.PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
      }
    }
    if (navigator.credentials) {
      const origGet = navigator.credentials.get ? navigator.credentials.get.bind(navigator.credentials) : null;
      navigator.credentials.get = function(options) {
        if (options && options.publicKey) {
          return Promise.reject(new DOMException("WebAuthn not supported in embedded window", "NotAllowedError"));
        }
        return origGet ? origGet(options) : Promise.reject(new DOMException("Not supported", "NotSupportedError"));
      };
      navigator.credentials.create = function() {
        return Promise.reject(new DOMException("WebAuthn not supported in embedded window", "NotAllowedError"));
      };
    }
  } catch (e) {}
})();
`);

// 2. Floating helper pill for users who prefer using their hardware Passkey / Security Key
window.addEventListener("DOMContentLoaded", () => {
  try {
    const pill = document.createElement("div");
    pill.id = "bigu-passkey-helper";
    pill.style.cssText = `
      position: fixed;
      top: 10px;
      right: 14px;
      z-index: 2147483647;
      display: flex;
      align-items: center;
      gap: 8px;
      background: rgba(18, 18, 24, 0.92);
      border: 1px solid rgba(255, 255, 255, 0.15);
      border-radius: 20px;
      padding: 5px 12px;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      font-size: 11px;
      color: #e2e8f0;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.6);
      user-select: none;
      backdrop-filter: blur(8px);
    `;

    pill.innerHTML = `
      <div style="display: flex; flex-direction: column; gap: 3px;">
        <div style="display: flex; align-items: center; gap: 6px;">
          <span style="color:#ffd60a; font-weight:600;">📋 Tip:</span>
          <span>If Ctrl+V doesn't paste password, <b>Right-Click → Paste</b>.</span>
        </div>
        <div style="font-size: 10px; opacity: 0.75;">
          ⏳ After signing in, please wait ~20–30s while the widget connects.
        </div>
      </div>
      <button id="bigu-ext-btn" style="
        background: #6366f1;
        color: #ffffff;
        border: none;
        border-radius: 12px;
        padding: 3px 9px;
        font-size: 10px;
        font-weight: 600;
        cursor: pointer;
        display: flex;
        align-items: center;
        gap: 3px;
        white-space: nowrap;
      ">Passkey? ↗</button>
      <button id="bigu-ext-close" style="
        background: transparent;
        color: #94a3b8;
        border: none;
        cursor: pointer;
        font-size: 13px;
        margin-left: 2px;
        padding: 0 4px;
      ">✕</button>
    `;

    document.body.appendChild(pill);

    const btn = pill.querySelector("#bigu-ext-btn");
    if (btn) {
      btn.addEventListener("click", () => {
        ipcRenderer.send("open-external-url", window.location.href);
      });
    }

    const closeBtn = pill.querySelector("#bigu-ext-close");
    if (closeBtn) {
      closeBtn.addEventListener("click", () => {
        pill.remove();
      });
    }
  } catch (e) {}
});

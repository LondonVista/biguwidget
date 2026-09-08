const { webFrame } = require("electron");

// Execute in the Main World so the page's scripts (e.g. x.com / grok.com)
// see that WebAuthn / Passkeys are not supported on this embedded window.
// This prevents Twitter/X from getting stuck on "Sign in with passkey"
// and forces it to immediately present the standard password field.
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
          return Promise.reject(new DOMException("WebAuthn not supported", "NotAllowedError"));
        }
        return origGet ? origGet(options) : Promise.reject(new DOMException("Not supported", "NotSupportedError"));
      };
      navigator.credentials.create = function() {
        return Promise.reject(new DOMException("WebAuthn not supported", "NotAllowedError"));
      };
    }
  } catch (e) {}
})();
`);

// Intercepts WebAuthn / Passkey calls in embedded login window.
// Electron does not implement native OS passkey/biometric dialogs on Linux,
// which causes X/Twitter to hang indefinitely on "Sign in with passkey".
// Disabling publicKey credentials forces X/Twitter to immediately offer the standard password prompt.

try {
  if (globalThis.PublicKeyCredential) {
    globalThis.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => Promise.resolve(false);
    if (typeof globalThis.PublicKeyCredential.isConditionalMediationAvailable === "function") {
      globalThis.PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
    }
  }

  const nav = globalThis.navigator;
  if (nav && nav.credentials) {
    const origGet = nav.credentials.get ? nav.credentials.get.bind(nav.credentials) : null;
    nav.credentials.get = function (options) {
      if (options && options.publicKey) {
        return Promise.reject(new DOMException("Passkeys not supported in embedded login window", "NotAllowedError"));
      }
      return origGet ? origGet(options) : Promise.reject(new DOMException("Not supported", "NotSupportedError"));
    };
  }
} catch (e) {}

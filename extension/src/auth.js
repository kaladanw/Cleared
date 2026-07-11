/**
 * Cleared extension — auth module
 *
 * Handles JWT storage (chrome.storage.local) and renders the login form
 * injected into the Cleared panel when no token is present.
 */
(function init(root) {
  const STORAGE_KEY = "cleared_jwt";
  const DEFAULT_BACKEND_URL = "https://cleared-backend-production.up.railway.app";

  /** Read the stored JWT. Returns a Promise<string|null>. */
  function getToken() {
    return new Promise((resolve) => {
      if (typeof chrome === "undefined" || !chrome.storage) {
        // Fallback for non-extension contexts (e.g. tests).
        resolve(null);
        return;
      }
      chrome.storage.local.get([STORAGE_KEY], (result) => {
        resolve(result[STORAGE_KEY] || null);
      });
    });
  }

  /** Persist the JWT. Returns a Promise<void>. */
  function setToken(token) {
    return new Promise((resolve) => {
      if (typeof chrome === "undefined" || !chrome.storage) {
        resolve();
        return;
      }
      chrome.storage.local.set({ [STORAGE_KEY]: token }, resolve);
    });
  }

  /** Remove the stored JWT. Returns a Promise<void>. */
  function clearToken() {
    return new Promise((resolve) => {
      if (typeof chrome === "undefined" || !chrome.storage) {
        resolve();
        return;
      }
      chrome.storage.local.remove([STORAGE_KEY], resolve);
    });
  }

  /**
   * Attempt login against the backend.
   * Returns { access_token, user } on success, throws on failure.
   */
  async function loginRequest(email, password, backendUrl) {
    const base = backendUrl || DEFAULT_BACKEND_URL;
    const resp = await fetch(base + "/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    if (!resp.ok) {
      const data = await resp.json().catch(() => ({}));
      throw new Error(data.detail || "Login failed (" + resp.status + ")");
    }
    return resp.json();
  }

  /**
   * Render the login form HTML to inject into the panel output area.
   *
   * The form emits a custom event "cleared:login-success" on the container
   * element when the user authenticates successfully. The content script
   * listens for this event to re-initialise the panel.
   */
  function renderLoginHtml() {
    return `
      <section class="cleared-login">
        <p class="cleared-login__msg">Sign in to check this listing.</p>
        <form class="cleared-login__form" novalidate>
          <label class="cleared-login__field">
            <span>Email</span>
            <input type="email" autocomplete="email" placeholder="you@example.com" required>
          </label>
          <label class="cleared-login__field">
            <span>Password</span>
            <input type="password" autocomplete="current-password" placeholder="••••••••" required>
          </label>
          <button class="cleared-button" type="submit">Sign in</button>
          <p class="cleared-login__error" style="display:none"></p>
        </form>
      </section>
    `;
  }

  const api = {
    getToken,
    setToken,
    clearToken,
    loginRequest,
    renderLoginHtml,
  };

  root.ClearedAuth = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);

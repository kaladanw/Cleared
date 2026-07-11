(function init(root) {
  const PRODUCTION_BACKEND = "https://cleared-backend-production.up.railway.app";
  const LOCAL_BACKEND = "http://localhost:8000";
  const STORAGE_KEY = "cleared_backend_url";

  function normalizeBackendUrl(value) {
    if (!value) return PRODUCTION_BACKEND;
    const trimmed = String(value).trim().replace(/\/+$/, "");
    if (trimmed === LOCAL_BACKEND || /^https:\/\/[a-z0-9.-]+$/i.test(trimmed)) {
      return trimmed;
    }
    return PRODUCTION_BACKEND;
  }

  function getBackendUrl(storageArea) {
    const storage = storageArea ||
      (typeof chrome !== "undefined" && chrome.storage && chrome.storage.local);
    if (!storage) return Promise.resolve(PRODUCTION_BACKEND);

    return new Promise((resolve) => {
      storage.get([STORAGE_KEY], (result) => {
        resolve(normalizeBackendUrl(result && result[STORAGE_KEY]));
      });
    });
  }

  const api = {
    LOCAL_BACKEND,
    PRODUCTION_BACKEND,
    STORAGE_KEY,
    getBackendUrl,
    normalizeBackendUrl,
  };

  root.ClearedConfig = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : window);

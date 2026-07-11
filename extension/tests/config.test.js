const assert = require("node:assert/strict");
const { describe, it } = require("node:test");
const {
  LOCAL_BACKEND,
  PRODUCTION_BACKEND,
  STORAGE_KEY,
  getBackendUrl,
  normalizeBackendUrl,
} = require("../src/config.js");

describe("backend configuration", () => {
  it("defaults to the deployed Railway backend", async () => {
    assert.equal(
      PRODUCTION_BACKEND,
      "https://cleared-backend-production.up.railway.app",
    );
    assert.equal(await getBackendUrl(null), PRODUCTION_BACKEND);
  });

  it("reads the explicit localhost development override", async () => {
    const storage = {
      get(keys, callback) {
        assert.deepEqual(keys, [STORAGE_KEY]);
        callback({ [STORAGE_KEY]: LOCAL_BACKEND + "/" });
      },
    };
    assert.equal(await getBackendUrl(storage), LOCAL_BACKEND);
  });

  it("rejects insecure or malformed remote overrides", () => {
    assert.equal(normalizeBackendUrl("http://example.com"), PRODUCTION_BACKEND);
    assert.equal(normalizeBackendUrl("javascript:alert(1)"), PRODUCTION_BACKEND);
    assert.equal(normalizeBackendUrl("https://preview.example.com/"), "https://preview.example.com");
  });
});

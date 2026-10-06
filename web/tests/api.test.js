import test from "node:test";
import assert from "node:assert/strict";

import { DEFAULT_API_URL } from "../src/auth.js";
import { fetchReports } from "../src/api.js";

test("fetchReports calls /api/reports with Bearer token", async () => {
  let request;
  const rows = [{ id: "1", marketplace: "depop", listing_name: "Polo" }];
  const result = await fetchReports("token-abc", {
    fetchImpl: async (url, options) => {
      request = { url, options };
      return { ok: true, status: 200, json: async () => rows };
    },
  });

  assert.equal(request.url, `${DEFAULT_API_URL}/api/reports`);
  assert.equal(request.options.headers.Authorization, "Bearer token-abc");
  assert.deepEqual(result, rows);
});

test("fetchReports applies marketplace query filter", async () => {
  let request;
  await fetchReports("token-abc", {
    marketplace: "depop",
    fetchImpl: async (url, options) => {
      request = { url, options };
      return { ok: true, status: 200, json: async () => [] };
    },
  });

  assert.equal(request.url, `${DEFAULT_API_URL}/api/reports?marketplace=depop`);
});

test("fetchReports maps 401 to an unauthorized error", async () => {
  await assert.rejects(
    () =>
      fetchReports("stale", {
        fetchImpl: async () => ({ ok: false, status: 401 }),
      }),
    (error) => {
      assert.match(error.message, /session expired/i);
      assert.equal(error.code, "unauthorized");
      return true;
    },
  );
});

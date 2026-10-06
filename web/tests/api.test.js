import test from "node:test";
import assert from "node:assert/strict";

import { DEFAULT_API_URL } from "../src/auth.js";
import { fetchReports, recheckReport, updateReport } from "../src/api.js";

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

test("fetchReports applies triage query filters", async () => {
  let request;
  await fetchReports("token-abc", {
    marketplace: "depop",
    verdict: "buy",
    status: "watching",
    q: "polo",
    date_from: "2026-10-01",
    date_to: "2026-10-06",
    fetchImpl: async (url, options) => {
      request = { url, options };
      return { ok: true, status: 200, json: async () => [] };
    },
  });

  const url = new URL(request.url);
  assert.equal(url.origin + url.pathname, `${DEFAULT_API_URL}/api/reports`);
  assert.equal(url.searchParams.get("marketplace"), "depop");
  assert.equal(url.searchParams.get("verdict"), "buy");
  assert.equal(url.searchParams.get("status"), "watching");
  assert.equal(url.searchParams.get("q"), "polo");
  assert.equal(url.searchParams.get("date_from"), "2026-10-01");
  assert.equal(url.searchParams.get("date_to"), "2026-10-06");
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

test("updateReport PATCHes triage fields", async () => {
  let request;
  const row = { id: "abc", hub_status: "watching", notes: "gift", tags: ["winter"] };
  const result = await updateReport(
    "token-abc",
    "abc",
    { status: "watching", notes: "gift", tags: ["winter"] },
    {
      fetchImpl: async (url, options) => {
        request = { url, options };
        return { ok: true, status: 200, json: async () => row };
      },
    },
  );
  assert.equal(request.url, `${DEFAULT_API_URL}/api/reports/abc`);
  assert.equal(request.options.method, "PATCH");
  assert.deepEqual(JSON.parse(request.options.body), {
    status: "watching",
    notes: "gift",
    tags: ["winter"],
  });
  assert.deepEqual(result, row);
});

test("recheckReport POSTs to the recheck endpoint", async () => {
  let request;
  await recheckReport("token-abc", "abc", {
    fetchImpl: async (url, options) => {
      request = { url, options };
      return { ok: true, status: 200, json: async () => ({ verdict: { recommendation: "buy" } }) };
    },
  });
  assert.equal(request.url, `${DEFAULT_API_URL}/api/reports/abc/recheck`);
  assert.equal(request.options.method, "POST");
});

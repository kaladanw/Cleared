import test from "node:test";
import assert from "node:assert/strict";

import { DEFAULT_API_URL } from "../src/auth.js";
import {
  buildReportQuery,
  createShare,
  exportReportsCsv,
  fetchReports,
  fetchShared,
  recheckReport,
  revokeShare,
  shareUrl,
  updateReport,
} from "../src/api.js";

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

function recorder(response) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url, init });
    return response;
  };
  return { calls, fetchImpl };
}

test("buildReportQuery includes seller and skips empty filters", () => {
  assert.equal(buildReportQuery({}), "");
  assert.equal(
    buildReportQuery({ seller: "vintage.finds", verdict: "buy", q: "" }),
    "?verdict=buy&seller=vintage.finds",
  );
});

test("fetchReports passes the seller filter", async () => {
  const { calls, fetchImpl } = recorder({ ok: true, status: 200, json: async () => [] });
  await fetchReports("tok", { seller: "thrift_queen", fetchImpl });
  assert.equal(calls[0].url, `${DEFAULT_API_URL}/api/reports?seller=thrift_queen`);
});

test("exportReportsCsv GETs reports.csv with current filters and Bearer token", async () => {
  const blob = new Blob(["checked_at,marketplace\r\n"], { type: "text/csv" });
  const { calls, fetchImpl } = recorder({ ok: true, status: 200, blob: async () => blob });
  const result = await exportReportsCsv("tok", { status: "watching", seller: "a.b" }, { fetchImpl });
  assert.equal(calls[0].url, `${DEFAULT_API_URL}/api/reports.csv?status=watching&seller=a.b`);
  assert.equal(calls[0].init.headers.Authorization, "Bearer tok");
  assert.equal(result.blob, blob);
  assert.match(result.filename, /^cleared-checks-\d{4}-\d{2}-\d{2}\.csv$/);
});

test("exportReportsCsv maps 401 to unauthorized", async () => {
  const { fetchImpl } = recorder({ ok: false, status: 401 });
  await assert.rejects(exportReportsCsv("tok", {}, { fetchImpl }), (err) => err.code === "unauthorized");
});

test("createShare POSTs and revokeShare DELETEs the share endpoint", async () => {
  const created = { token: "t".repeat(43), path: `/r/${"t".repeat(43)}`, shared_at: "2026-10-07T12:00:00+00:00" };
  const post = recorder({ ok: true, status: 200, json: async () => created });
  assert.deepEqual(await createShare("tok", "rep-1", { fetchImpl: post.fetchImpl }), created);
  assert.equal(post.calls[0].url, `${DEFAULT_API_URL}/api/reports/rep-1/share`);
  assert.equal(post.calls[0].init.method, "POST");
  assert.equal(post.calls[0].init.headers.Authorization, "Bearer tok");

  const del = recorder({ ok: true, status: 200, json: async () => ({ revoked: true }) });
  assert.deepEqual(await revokeShare("tok", "rep-1", { fetchImpl: del.fetchImpl }), { revoked: true });
  assert.equal(del.calls[0].init.method, "DELETE");
});

test("fetchShared is public (no auth header) and maps 404 to revoked/missing", async () => {
  const ok = recorder({ ok: true, status: 200, json: async () => ({ listing_name: "Coat" }) });
  await fetchShared("abc_DEF-123", { fetchImpl: ok.fetchImpl });
  assert.equal(ok.calls[0].url, `${DEFAULT_API_URL}/api/shared/abc_DEF-123`);
  assert.equal(ok.calls[0].init.headers, undefined);

  const missing = recorder({ ok: false, status: 404 });
  await assert.rejects(fetchShared("x", { fetchImpl: missing.fetchImpl }), /revoked/);
  const limited = recorder({ ok: false, status: 429 });
  await assert.rejects(fetchShared("x", { fetchImpl: limited.fetchImpl }), /Too many/);
});

test("shareUrl builds /r/<token> on the given origin", () => {
  assert.equal(shareUrl("tok123", "https://cleared.example"), "https://cleared.example/r/tok123");
});

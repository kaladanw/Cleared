import test from "node:test";
import assert from "node:assert/strict";

import { renderSharedReport, tokenFromLocation } from "../src/share-view.js";
import { sellerSummaryText, summarizeSeller } from "../src/seller-summary.js";
import { safeUrl } from "../src/format.js";

const TOKEN = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcd"; // 42 chars

test("tokenFromLocation reads /r/<token> and ?t=<token>", () => {
  assert.equal(tokenFromLocation(`/r/${TOKEN}`, ""), TOKEN);
  assert.equal(tokenFromLocation(`/r/${TOKEN}/`, ""), TOKEN);
  assert.equal(tokenFromLocation("/share.html", `?t=${TOKEN}`), TOKEN);
  assert.equal(tokenFromLocation("/share", `?t=${TOKEN}`), TOKEN);
});

test("tokenFromLocation rejects missing or malformed tokens", () => {
  assert.equal(tokenFromLocation("/share", ""), null);
  assert.equal(tokenFromLocation("/r/short", ""), null);
  assert.equal(tokenFromLocation("/share", "?t=<script>alert(1)</script>"), null);
  assert.equal(tokenFromLocation(`/r/${TOKEN}/extra`, ""), null);
});

const shared = {
  listing_name: "Vintage <b>Barbour</b> coat",
  listing_url: "https://www.depop.com/products/vintage-barbour/",
  marketplace: "depop",
  verdict: "negotiate",
  checked_at: "2026-10-07T12:00:00+00:00",
  seller_username: "vintage.finds",
  report: {
    listing_facts: { asking_price: 120, currency: "USD", model_or_name: "Barbour Beaufort" },
    price_read: { fairness: "high", retail_estimate: 400, suggested_offer_low: 80, suggested_offer_high: 95 },
    listing_trust: { missing_info: ["No tag photo"], concerns: [], questions_to_ask: ["Any rips in the lining?"] },
    auth_flag: { applicable: false },
    verdict: { recommendation: "negotiate", one_line: "Fair coat, high ask — offer $80–95." },
  },
};

test("renderSharedReport shows the highlights and escapes HTML", () => {
  const html = renderSharedReport(shared);
  assert.match(html, /data-shared-report/);
  assert.match(html, /Vintage &lt;b&gt;Barbour&lt;\/b&gt; coat/);
  assert.doesNotMatch(html, /<b>Barbour<\/b>/);
  assert.match(html, /hub-pill--negotiate/);
  assert.match(html, /@vintage\.finds/);
  assert.match(html, /\$120/);
  assert.match(html, /\$80–\$95/);
  assert.match(html, /No tag photo/);
  assert.match(html, /Any rips in the lining\?/);
  assert.match(html, /rel="noreferrer noopener"/);
  assert.match(html, /not an authenticity guarantee/);
});

test("renderSharedReport never turns a non-http URL into a link", () => {
  const html = renderSharedReport({ ...shared, listing_url: "javascript:alert(1)" });
  assert.doesNotMatch(html, /javascript:/);
  assert.match(html, /href="#"/);
  assert.equal(safeUrl("data:text/html,x"), "#");
  assert.equal(safeUrl("https://www.depop.com/x/"), "https://www.depop.com/x/");
});

test("renderSharedReport tolerates rows without seller or report detail", () => {
  const html = renderSharedReport({ listing_name: "Bare", verdict: "skip", report: {} });
  assert.match(html, /Bare/);
  assert.doesNotMatch(html, /hub-seller-static/);
  assert.match(html, /No issues flagged/);
});

test("summarizeSeller counts checks and verdict mix", () => {
  const summary = summarizeSeller([
    { verdict: "buy" },
    { verdict: "skip" },
    { verdict: "skip" },
    { verdict: null, report_json: { verdict: { recommendation: "negotiate" } } },
    { verdict: "weird" },
  ]);
  assert.deepEqual(summary, { count: 5, mix: { buy: 1, negotiate: 1, skip: 2, other: 1 } });
  assert.equal(
    sellerSummaryText("vintage.finds", summary),
    "@vintage.finds — 5 checks — 1 buy · 1 negotiate · 2 skip · 1 other",
  );
  assert.equal(sellerSummaryText("solo", summarizeSeller([{ verdict: "buy" }])), "@solo — 1 check — 1 buy");
  assert.equal(sellerSummaryText("none", summarizeSeller([])), "@none — 0 checks");
});

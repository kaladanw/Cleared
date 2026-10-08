import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";

const pages = ["index.html", "hub.html", "privacy.html", "support.html", "share.html"];

test("every public page has essential metadata and navigation", async () => {
  for (const page of pages) {
    const html = await readFile(new URL(`../${page}`, import.meta.url), "utf8");
    assert.match(html, /<title>[^<]+<\/title>/);
    assert.match(html, /name="description"/);
    assert.match(html, /href="\/privacy"/);
    assert.match(html, /href="\/support"/);
  }
});

test("landing page exposes invite auth and honest extension setup", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /data-auth-mode="signup"/);
  assert.match(html, /data-auth-mode="login"/);
  assert.match(html, /chrome:\/\/extensions/);
  assert.match(html, /sign in once more inside the extension/i);
  assert.match(html, /not an authenticity guarantee/);
  assert.doesNotMatch(html, /universal link/i);
});

test("hub page lists past checks with triage filters and install steps", async () => {
  const html = await readFile(new URL("../hub.html", import.meta.url), "utf8");
  assert.match(html, /data-reports-list/);
  assert.match(html, /data-hub-filters/);
  assert.match(html, /data-filter-marketplace/);
  assert.match(html, /data-filter-verdict/);
  assert.match(html, /data-filter-status/);
  assert.match(html, /data-filter-q/);
  assert.match(html, /id="install"/);
  assert.match(html, /chrome:\/\/extensions/);
  assert.match(html, /Past/);
});

test("web session uses sessionStorage rather than durable or password storage", async () => {
  const source = await readFile(new URL("../src/auth.js", import.meta.url), "utf8");
  assert.match(source, /sessionStorage/);
  assert.doesNotMatch(source, /localStorage/);
  assert.doesNotMatch(source, /setItem\([^\n]*password/i);
});

test("landing redirects signed-in users to the hub", async () => {
  const source = await readFile(new URL("../src/main.js", import.meta.url), "utf8");
  assert.match(source, /\/hub/);
  assert.match(source, /goToHub/);
});

test("Vercel uses clean URLs and security headers", async () => {
  const config = JSON.parse(await readFile(new URL("../vercel.json", import.meta.url), "utf8"));
  assert.equal(config.cleanUrls, true);
  assert.ok(config.headers[0].headers.some(({ key }) => key === "X-Content-Type-Options"));
});

test("Vite is configured as a multi-page build including hub", async () => {
  assert.equal(existsSync(new URL("../vite.config.js", import.meta.url)), true);
  const config = await readFile(new URL("../vite.config.js", import.meta.url), "utf8");
  assert.match(config, /hub\.html/);
});

test("hub page has CSV export, seller filter, and seller banner", async () => {
  const html = await readFile(new URL("../hub.html", import.meta.url), "utf8");
  assert.match(html, /data-export-csv/);
  assert.match(html, /name="seller" data-filter-seller/);
  assert.match(html, /data-seller-banner/);
  assert.match(html, /data-clear-seller/);
});

test("hub cards wire Share, Revoke, and clickable seller", async () => {
  const source = await readFile(new URL("../src/hub.js", import.meta.url), "utf8");
  assert.match(source, /data-share>/);
  assert.match(source, /data-revoke/);
  assert.match(source, /data-seller-link/);
  assert.match(source, /createShare/);
  assert.match(source, /revokeShare/);
  assert.match(source, /exportReportsCsv\(session\.accessToken, filters\)/);
  assert.match(source, /safeUrl\(row\.listing_url\)/);
});

test("public share page needs no login and is not indexed", async () => {
  const html = await readFile(new URL("../share.html", import.meta.url), "utf8");
  assert.match(html, /name="robots" content="noindex, nofollow"/);
  assert.match(html, /name="referrer" content="no-referrer"/);
  assert.match(html, /data-share-root/);
  assert.match(html, /src="\/src\/share\.js"/);
  const source = await readFile(new URL("../src/share.js", import.meta.url), "utf8");
  assert.doesNotMatch(source, /getSession|accessToken|auth\.js/);
});

test("Vercel rewrites /r/:token to the share page with noindex", async () => {
  const config = JSON.parse(await readFile(new URL("../vercel.json", import.meta.url), "utf8"));
  assert.deepEqual(config.rewrites, [{ source: "/r/:token", destination: "/share.html" }]);
  const shareHeaders = config.headers.find(({ source }) => source === "/r/(.*)");
  assert.ok(shareHeaders.headers.some(({ key, value }) => key === "X-Robots-Tag" && /noindex/.test(value)));
});

test("Vite builds the share page", async () => {
  const config = await readFile(new URL("../vite.config.js", import.meta.url), "utf8");
  assert.match(config, /share\.html/);
});

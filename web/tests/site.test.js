import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";

const pages = ["index.html", "hub.html", "privacy.html", "support.html"];

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

test("hub page lists past checks with marketplace filters and install steps", async () => {
  const html = await readFile(new URL("../hub.html", import.meta.url), "utf8");
  assert.match(html, /data-reports-list/);
  assert.match(html, /data-marketplace-filter=""/);
  assert.match(html, /data-marketplace-filter="depop"/);
  assert.match(html, /id="install"/);
  assert.match(html, /chrome:\/\/extensions/);
  assert.match(html, /No checks yet|data-empty-state|Past/);
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

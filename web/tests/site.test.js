import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";

const pages = ["index.html", "privacy.html", "support.html"];

test("every public page has essential metadata and navigation", async () => {
  for (const page of pages) {
    const html = await readFile(new URL(`../${page}`, import.meta.url), "utf8");
    assert.match(html, /<title>[^<]+<\/title>/);
    assert.match(html, /name="description"/);
    assert.match(html, /href="\/privacy"/);
    assert.match(html, /href="\/support"/);
  }
});

test("landing page makes beta status and product boundaries explicit", async () => {
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(html, /TestFlight link coming soon/);
  assert.match(html, /not an authenticity guarantee/);
  assert.doesNotMatch(html, /universal link|report history/i);
});

test("Vercel uses clean URLs and security headers", async () => {
  const config = JSON.parse(await readFile(new URL("../vercel.json", import.meta.url), "utf8"));
  assert.equal(config.cleanUrls, true);
  assert.ok(config.headers[0].headers.some(({ key }) => key === "X-Content-Type-Options"));
});

test("Vite is configured as a multi-page build", () => {
  assert.equal(existsSync(new URL("../vite.config.js", import.meta.url)), true);
});

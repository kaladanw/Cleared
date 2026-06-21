const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { describe, it } = require("node:test");

const extensionRoot = path.resolve(__dirname, "..");

describe("manifest", () => {
  it("declares a Manifest V3 content script for Depop product pages", () => {
    const manifest = JSON.parse(
      fs.readFileSync(path.join(extensionRoot, "manifest.json"), "utf8"),
    );

    assert.equal(manifest.manifest_version, 3);
    assert.ok(manifest.host_permissions.includes("*://*.depop.com/products/*"));
    assert.equal(manifest.content_scripts.length, 1);
    assert.deepEqual(manifest.content_scripts[0].matches, ["*://*.depop.com/products/*"]);
    assert.deepEqual(manifest.content_scripts[0].js, [
      "src/extractor.js",
      "content-script.js",
    ]);

    for (const script of manifest.content_scripts[0].js) {
      assert.ok(fs.existsSync(path.join(extensionRoot, script)), `${script} exists`);
    }
  });
});

const assert = require("node:assert/strict");
const { describe, it } = require("node:test");

const {
  renderErrorHtml,
  renderLoadingHtml,
  renderReportHtml,
} = require("../src/ui.js");

describe("ui rendering", () => {
  it("renders verdict, price, questions, and applicable auth checks", () => {
    const html = renderReportHtml({
      price_read: {
        retail_estimate: 72,
        used_estimate_low: 27,
        used_estimate_high: 40,
        fairness: "fair",
        suggested_offer_low: 22,
        suggested_offer_high: 26,
      },
      listing_trust: {
        missing_info: ["No measurements"],
        concerns: ["Only front photo"],
        questions_to_ask: ["Can you share pit-to-pit?"],
      },
      auth_flag: {
        applicable: true,
        confidence: "low",
        red_flags: ["No tag close-up"],
        what_to_inspect: ["Neck tag"],
      },
      verdict: {
        recommendation: "negotiate",
        one_line: "Ask for measurements first.",
      },
    });

    assert.match(html, /negotiate/i);
    assert.match(html, /\$72/);
    assert.match(html, /\$27-\$40/);
    assert.match(html, /Can you share pit-to-pit\?/);
    assert.match(html, /No tag close-up/);
  });

  it("hides auth details when auth is not applicable", () => {
    const html = renderReportHtml({
      price_read: {},
      listing_trust: {},
      auth_flag: {
        applicable: false,
        red_flags: ["Should not render"],
        what_to_inspect: ["Should not render"],
      },
      verdict: {
        recommendation: "buy",
        one_line: "Looks fine.",
      },
    });

    assert.doesNotMatch(html, /Should not render/);
    assert.match(html, /Authenticity not flagged/);
  });

  it("escapes report text before rendering", () => {
    const html = renderReportHtml({
      price_read: {},
      listing_trust: { questions_to_ask: ["<script>alert(1)</script>"] },
      auth_flag: {},
      verdict: { one_line: "<b>bad</b>" },
    });

    assert.match(html, /&lt;b&gt;bad&lt;\/b&gt;/);
    assert.doesNotMatch(html, /<script>/);
  });

  it("renders loading and error states", () => {
    assert.match(renderLoadingHtml(), /Checking listing/);
    assert.match(renderErrorHtml("Network down"), /Network down/);
  });
});

(function init(root) {
  function renderLoadingHtml() {
    return '<div class="cleared-status">Checking listing...</div>';
  }

  function renderErrorHtml(message) {
    return `
      <section class="cleared-report cleared-report--error">
        <h3>Check failed</h3>
        <p>${escapeHtml(message || "Something went wrong.")}</p>
      </section>
    `;
  }

  function renderReportHtml(report) {
    if (report.error) {
      return renderErrorHtml(report.error);
    }

    const price = report.price_read || {};
    const trust = report.listing_trust || {};
    const auth = report.auth_flag || {};
    const verdict = report.verdict || {};

    // Brand gate note: auth_flag.applicable is set by Claude based on the
    // FAKEABLE_BRANDS list injected in the prompt, then enforced server-side by
    // _enforce_brand_gate() in claude_check.py. Uniqlo → false; Ralph Lauren /
    // Aelfric Eden → true. The UI trusts what the backend sends — no client-side
    // brand logic here; the gate is backend-only to avoid drift.
    const rec = verdict.recommendation || "";
    const pillClass = rec === "buy"
      ? "cleared-pill cleared-pill--buy"
      : rec === "negotiate"
        ? "cleared-pill cleared-pill--negotiate"
        : rec === "skip"
          ? "cleared-pill cleared-pill--skip"
          : "cleared-pill";

    return `
      <section class="cleared-report">
        <header class="cleared-report__header">
          <span class="${pillClass}">${escapeHtml(rec || "check")}</span>
          <h3>${escapeHtml(verdict.one_line || "Cleared check")}</h3>
        </header>
        <div class="cleared-grid">
          <div>
            <h4>Price</h4>
            <dl>
              <div><dt>Retail</dt><dd>${money(price.retail_estimate)}</dd></div>
              <div><dt>Used</dt><dd>${range(price.used_estimate_low, price.used_estimate_high)}</dd></div>
              <div><dt>Offer</dt><dd>${range(price.suggested_offer_low, price.suggested_offer_high)}</dd></div>
              <div><dt>Read</dt><dd>${escapeHtml(price.fairness || "unknown")}</dd></div>
            </dl>
          </div>
          <div>
            <h4>Trust</h4>
            ${listHtml([...(trust.missing_info || []), ...(trust.concerns || [])])}
          </div>
        </div>
        <div>
          <h4>Questions</h4>
          ${listHtml(trust.questions_to_ask || [])}
        </div>
        <div>
          <h4>Authenticity</h4>
          ${authHtml(auth)}
        </div>
      </section>
    `;
  }

  function authHtml(auth) {
    if (!auth.applicable) {
      return '<p class="cleared-muted">Authenticity not flagged for this brand.</p>';
    }
    return `
      <p class="cleared-muted">Confidence: ${escapeHtml(auth.confidence || "unknown")}</p>
      ${listHtml([...(auth.red_flags || []), ...(auth.what_to_inspect || [])])}
    `;
  }

  function listHtml(items) {
    if (!items.length) {
      return '<p class="cleared-muted">No issues called out.</p>';
    }
    return `<ul>${items.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>`;
  }

  function money(value) {
    return Number.isFinite(value) ? `$${Math.round(value)}` : "unknown";
  }

  function range(low, high) {
    if (Number.isFinite(low) && Number.isFinite(high)) {
      return `$${Math.round(low)}-$${Math.round(high)}`;
    }
    if (Number.isFinite(low)) {
      return `$${Math.round(low)}+`;
    }
    if (Number.isFinite(high)) {
      return `up to $${Math.round(high)}`;
    }
    return "unknown";
  }

  function escapeHtml(value) {
    return String(value)
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#39;");
  }

  const api = {
    renderErrorHtml,
    renderLoadingHtml,
    renderReportHtml,
  };

  root.ClearedUi = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : window);

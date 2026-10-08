// DOM-free pieces of the public share page (token parsing + rendering).
import { esc, formatDate, listHtml, money, range, safeUrl, verdictPillClass } from "./format.js";

const TOKEN_RE = /^[A-Za-z0-9_-]{32,64}$/;

/** Token from `/r/<token>` (Vercel rewrite) or `?t=<token>` (dev / direct). */
export function tokenFromLocation(pathname = "", search = "") {
  const pathMatch = /^\/r\/([^/?#]+)\/?$/.exec(pathname || "");
  const candidate = pathMatch
    ? decodeURIComponent(pathMatch[1])
    : new URLSearchParams(search || "").get("t") || "";
  return TOKEN_RE.test(candidate) ? candidate : null;
}

export function renderSharedReport(data) {
  const report = data.report || {};
  const facts = report.listing_facts || {};
  const price = report.price_read || {};
  const trust = report.listing_trust || {};
  const auth = report.auth_flag || {};
  const verdict = report.verdict || {};
  const rec = data.verdict || verdict.recommendation || "";
  const trustItems = [...(trust.missing_info || []), ...(trust.concerns || [])];
  const questions = trust.questions_to_ask || [];
  const url = safeUrl(data.listing_url);

  return `
    <article class="share-card" data-shared-report>
      <header class="share-card__header">
        <span class="${verdictPillClass(rec)}">${esc(rec || "check")}</span>
        <span class="hub-marketplace">${esc(data.marketplace || "depop")}</span>
        ${data.seller_username ? `<span class="hub-seller-static">@${esc(data.seller_username)}</span>` : ""}
        <span class="hub-card__date">${esc(formatDate(data.checked_at))}</span>
      </header>
      <h2 class="share-card__title">${esc(data.listing_name || facts.model_or_name || "Shared listing")}</h2>
      ${verdict.one_line ? `<p class="hub-card__blurb">${esc(verdict.one_line)}</p>` : ""}
      <div class="hub-actions">
        <a class="button hub-action" href="${esc(url)}" target="_blank" rel="noreferrer noopener">Open listing</a>
      </div>
      <div class="hub-detail-grid">
        <div>
          <h3>Price</h3>
          <dl>
            <div><dt>Asking</dt><dd>${money(facts.asking_price)}</dd></div>
            <div><dt>Fairness</dt><dd>${esc(price.fairness || "—")}</dd></div>
            <div><dt>Retail</dt><dd>${money(price.retail_estimate)}</dd></div>
            <div><dt>Used</dt><dd>${range(price.used_estimate_low, price.used_estimate_high)}</dd></div>
            <div><dt>Offer</dt><dd>${range(price.suggested_offer_low, price.suggested_offer_high)}</dd></div>
          </dl>
        </div>
        <div>
          <h3>Trust</h3>
          ${trustItems.length ? listHtml(trustItems) : '<p class="hub-muted">No issues flagged.</p>'}
        </div>
      </div>
      ${questions.length ? `<div class="share-section"><h3>Questions to ask</h3>${listHtml(questions)}</div>` : ""}
      <div class="share-section">
        <h3>Authenticity</h3>
        ${auth.applicable
          ? `<p class="hub-muted">Confidence: ${esc(auth.confidence || "unknown")}</p>${listHtml([...(auth.red_flags || []), ...(auth.what_to_inspect || [])])}`
          : '<p class="hub-muted">Authenticity not flagged for this brand.</p>'}
      </div>
      <p class="share-disclaimer">Judgment-assist guidance from Cleared, not an authenticity guarantee.</p>
    </article>`;
}

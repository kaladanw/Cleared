import { clearSession, getSession } from "./auth.js";
import { fetchReports } from "./api.js";

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = new Date().getFullYear();
});

const session = getSession();
if (!session) {
  window.location.replace("/");
} else {
  bootHub(session);
}

function bootHub(session) {
  const emailEl = document.querySelector("[data-account-email]");
  if (emailEl) emailEl.textContent = session.user.email;

  document.querySelector("[data-sign-out]")?.addEventListener("click", () => {
    clearSession();
    window.location.href = "/";
  });

  const filterButtons = [...document.querySelectorAll("[data-marketplace-filter]")];
  let marketplaceFilter = "";

  function setFilter(next) {
    marketplaceFilter = next;
    filterButtons.forEach((button) => {
      const selected = (button.dataset.marketplaceFilter || "") === marketplaceFilter;
      button.setAttribute("aria-pressed", String(selected));
    });
    loadReports();
  }

  filterButtons.forEach((button) => {
    button.addEventListener("click", () => setFilter(button.dataset.marketplaceFilter || ""));
  });

  document.querySelector("[data-copy-address]")?.addEventListener("click", async () => {
    const status = document.querySelector("[data-copy-status]");
    try {
      await navigator.clipboard.writeText("chrome://extensions");
      status.textContent = "Copied: chrome://extensions";
    } catch {
      status.textContent = "Copy was blocked. Type chrome://extensions in Chrome’s address bar.";
    }
  });

  setFilter("");

  async function loadReports() {
    const list = document.querySelector("[data-reports-list]");
    const countEl = document.querySelector("[data-reports-count]");
    if (!list) return;

    list.innerHTML = '<p class="hub-state">Loading…</p>';
    countEl.textContent = "";

    try {
      const reports = await fetchReports(session.accessToken, {
        marketplace: marketplaceFilter || undefined,
      });
      if (!reports.length) {
        countEl.textContent = "0 checks";
        list.innerHTML = `
          <div class="hub-empty" data-empty-state>
            <h2>No checks yet</h2>
            <p>Past listing checks from the Chrome extension show up here. Open a Depop product page, sign in inside the extension, and tap <strong>Check this listing</strong>.</p>
            <a class="button" href="#install">Install the extension</a>
          </div>`;
        return;
      }

      countEl.textContent = `${reports.length} check${reports.length === 1 ? "" : "s"}`;
      list.innerHTML = reports.map(renderCard).join("");
      list.querySelectorAll(".hub-card__summary").forEach((summary) => {
        summary.addEventListener("click", () => {
          const detail = summary.nextElementSibling;
          const open = detail.classList.toggle("is-open");
          summary.querySelector(".hub-card__toggle").textContent = open ? "Collapse" : "Details";
        });
      });
    } catch (error) {
      if (error.code === "unauthorized") {
        clearSession();
        window.location.replace("/");
        return;
      }
      list.innerHTML = `<p class="hub-state hub-state--error">${esc(error.message)}</p>`;
    }
  }
}

function renderCard(row) {
  const report = row.report_json || {};
  const price = report.price_read || {};
  const trust = report.listing_trust || {};
  const verdict = report.verdict || {};
  const rec = row.verdict || verdict.recommendation || "";
  const pillClass =
    rec === "buy"
      ? "hub-pill hub-pill--buy"
      : rec === "negotiate"
        ? "hub-pill hub-pill--negotiate"
        : rec === "skip"
          ? "hub-pill hub-pill--skip"
          : "hub-pill";
  const marketplace = esc(row.marketplace || "depop");
  const name = esc(row.listing_name || "Unnamed listing");
  const date = formatDate(row.checked_at);
  const url = esc(row.listing_url || "#");
  const oneLine = esc(verdict.one_line || "");
  const trustItems = [...(trust.missing_info || []), ...(trust.concerns || [])];

  return `
    <article class="hub-card">
      <div class="hub-card__summary">
        <span class="${pillClass}">${esc(rec || "check")}</span>
        <span class="hub-marketplace">${marketplace}</span>
        <span class="hub-card__name"><a href="${url}" target="_blank" rel="noreferrer noopener" onclick="event.stopPropagation()">${name}</a></span>
        <span class="hub-card__date">${date}</span>
        <span class="hub-card__toggle">Details</span>
      </div>
      <div class="hub-card__detail">
        ${oneLine ? `<p class="hub-one-line">${oneLine}</p>` : ""}
        <div class="hub-detail-grid">
          <div>
            <h3>Price</h3>
            <dl>
              <div><dt>Fairness</dt><dd>${esc(price.fairness || "—")}</dd></div>
              <div><dt>Retail</dt><dd>${money(price.retail_estimate)}</dd></div>
              <div><dt>Offer</dt><dd>${range(price.suggested_offer_low, price.suggested_offer_high)}</dd></div>
            </dl>
          </div>
          <div>
            <h3>Trust</h3>
            ${trustItems.length ? listHtml(trustItems.slice(0, 4)) : '<p class="hub-muted">No issues flagged.</p>'}
          </div>
        </div>
      </div>
    </article>`;
}

function listHtml(items) {
  return `<ul>${items.map((item) => `<li>${esc(item)}</li>`).join("")}</ul>`;
}

function money(value) {
  return Number.isFinite(value) ? `$${Math.round(value)}` : "—";
}

function range(low, high) {
  if (Number.isFinite(low) && Number.isFinite(high)) {
    return `$${Math.round(low)}–$${Math.round(high)}`;
  }
  if (Number.isFinite(low)) return `$${Math.round(low)}+`;
  if (Number.isFinite(high)) return `up to $${Math.round(high)}`;
  return "—";
}

function formatDate(iso) {
  if (!iso) return "";
  try {
    return new Date(iso).toLocaleDateString(undefined, {
      month: "short",
      day: "numeric",
      year: "numeric",
    });
  } catch {
    return String(iso).slice(0, 10);
  }
}

function esc(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

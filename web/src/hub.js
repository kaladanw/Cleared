import { clearSession, getSession } from "./auth.js";
import { fetchReports, recheckReport, updateReport } from "./api.js";

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

  document.querySelector("[data-copy-address]")?.addEventListener("click", async () => {
    const status = document.querySelector("[data-copy-status]");
    try {
      await navigator.clipboard.writeText("chrome://extensions");
      status.textContent = "Copied: chrome://extensions";
    } catch {
      status.textContent = "Copy was blocked. Type chrome://extensions in Chrome’s address bar.";
    }
  });

  const form = document.querySelector("[data-hub-filters]");
  let filters = readFilters(form);

  form?.addEventListener("submit", (event) => {
    event.preventDefault();
    filters = readFilters(form);
    loadReports();
  });

  loadReports();

  async function loadReports() {
    const list = document.querySelector("[data-reports-list]");
    const countEl = document.querySelector("[data-reports-count]");
    if (!list) return;

    list.innerHTML = '<p class="hub-state">Loading…</p>';
    countEl.textContent = "";

    try {
      const reports = await fetchReports(session.accessToken, filters);
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
      wireCards(list);
    } catch (error) {
      if (error.code === "unauthorized") {
        clearSession();
        window.location.replace("/");
        return;
      }
      list.innerHTML = `<p class="hub-state hub-state--error">${esc(error.message)}</p>`;
    }
  }

  function wireCards(list) {
    list.querySelectorAll(".hub-card__summary").forEach((summary) => {
      summary.addEventListener("click", (event) => {
        if (event.target.closest("a, button, select, input, textarea, label")) return;
        const detail = summary.nextElementSibling;
        const open = detail.classList.toggle("is-open");
        summary.querySelector(".hub-card__toggle").textContent = open ? "Collapse" : "Details";
      });
    });

    list.querySelectorAll("[data-status]").forEach((select) => {
      select.addEventListener("change", async () => {
        const card = select.closest(".hub-card");
        const id = card.dataset.reportId;
        select.disabled = true;
        try {
          const updated = await updateReport(session.accessToken, id, {
            status: select.value || "none",
          });
          applyRowToCard(card, updated);
        } catch (error) {
          if (error.code === "unauthorized") {
            clearSession();
            window.location.replace("/");
            return;
          }
          alert(error.message);
          await loadReports();
        } finally {
          select.disabled = false;
        }
      });
    });

    list.querySelectorAll("[data-save-triage]").forEach((button) => {
      button.addEventListener("click", async () => {
        const card = button.closest(".hub-card");
        const id = card.dataset.reportId;
        const notes = card.querySelector("[data-notes]").value;
        const tags = parseTags(card.querySelector("[data-tags]").value);
        button.disabled = true;
        button.textContent = "Saving…";
        try {
          const updated = await updateReport(session.accessToken, id, { notes, tags });
          applyRowToCard(card, updated);
          button.textContent = "Saved";
          setTimeout(() => {
            button.textContent = "Save notes & tags";
            button.disabled = false;
          }, 900);
        } catch (error) {
          if (error.code === "unauthorized") {
            clearSession();
            window.location.replace("/");
            return;
          }
          alert(error.message);
          button.textContent = "Save notes & tags";
          button.disabled = false;
        }
      });
    });

    list.querySelectorAll("[data-recheck]").forEach((button) => {
      button.addEventListener("click", async () => {
        const card = button.closest(".hub-card");
        const id = card.dataset.reportId;
        const hasImages = card.dataset.hasImages === "1";
        const listingUrl = card.dataset.listingUrl;
        if (!hasImages) {
          if (listingUrl) window.open(listingUrl, "_blank", "noopener,noreferrer");
          alert(
            "This older check has no stored photos for an API recheck. The listing opened in a new tab — use the Chrome extension’s Check / Re-check there.",
          );
          return;
        }
        button.disabled = true;
        button.textContent = "Rechecking…";
        try {
          await recheckReport(session.accessToken, id);
          await loadReports();
        } catch (error) {
          if (error.code === "unauthorized") {
            clearSession();
            window.location.replace("/");
            return;
          }
          alert(error.message);
          button.disabled = false;
          button.textContent = "Recheck";
        }
      });
    });
  }
}

function readFilters(form) {
  if (!form) return {};
  const data = new FormData(form);
  const filters = {};
  for (const key of ["marketplace", "verdict", "status", "q", "date_from", "date_to"]) {
    const value = String(data.get(key) || "").trim();
    if (value) filters[key] = value;
  }
  return filters;
}

function parseTags(raw) {
  return String(raw || "")
    .split(",")
    .map((t) => t.trim())
    .filter(Boolean);
}

function applyRowToCard(card, row) {
  card.dataset.hasImages = Array.isArray(row.image_urls) && row.image_urls.length ? "1" : "0";
  const status = card.querySelector("[data-status]");
  if (status) status.value = row.hub_status || "";
  const notes = card.querySelector("[data-notes]");
  if (notes) notes.value = row.notes || "";
  const tags = card.querySelector("[data-tags]");
  if (tags) tags.value = (row.tags || []).join(", ");
  const badge = card.querySelector("[data-status-badge]");
  if (badge) {
    badge.textContent = statusLabel(row.hub_status);
    badge.hidden = !row.hub_status;
  }
}

function statusLabel(status) {
  if (!status) return "";
  if (status === "sold_out") return "Sold out";
  return status.charAt(0).toUpperCase() + status.slice(1);
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
  const fairness = esc(price.fairness || "");
  const trustItems = [...(trust.missing_info || []), ...(trust.concerns || [])];
  const trustHint = trustItems[0] ? esc(trustItems[0]) : "";
  const dealLine = [fairness && `Deal: ${fairness}`, trustHint && `Trust: ${trustHint}`]
    .filter(Boolean)
    .join(" · ");
  const hubStatus = row.hub_status || "";
  const notes = esc(row.notes || "");
  const tagsValue = esc((row.tags || []).join(", "));
  const hasImages = Array.isArray(row.image_urls) && row.image_urls.length > 0;
  const id = esc(row.id || "");

  return `
    <article class="hub-card" data-report-id="${id}" data-listing-url="${url}" data-has-images="${hasImages ? "1" : "0"}">
      <div class="hub-card__summary">
        <span class="${pillClass}">${esc(rec || "check")}</span>
        <span class="hub-marketplace">${marketplace}</span>
        <span class="hub-status-badge" data-status-badge ${hubStatus ? "" : "hidden"}>${esc(statusLabel(hubStatus))}</span>
        <div class="hub-card__copy">
          <span class="hub-card__name"><a href="${url}" target="_blank" rel="noreferrer noopener">${name}</a></span>
          ${oneLine ? `<p class="hub-card__blurb">${oneLine}</p>` : ""}
          ${dealLine ? `<p class="hub-card__meta">${esc(dealLine)}</p>` : ""}
        </div>
        <span class="hub-card__date">${date}</span>
        <span class="hub-card__toggle">Details</span>
      </div>
      <div class="hub-card__detail">
        <div class="hub-actions">
          <a class="button hub-action" href="${url}" target="_blank" rel="noreferrer noopener">Open listing</a>
          <button class="button hub-action hub-action--ghost" type="button" data-recheck>${hasImages ? "Recheck" : "Recheck in extension"}</button>
        </div>
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
        <div class="hub-triage">
          <label>
            <span>Status</span>
            <select data-status>
              <option value="" ${!hubStatus ? "selected" : ""}>Unset</option>
              <option value="watching" ${hubStatus === "watching" ? "selected" : ""}>Watching</option>
              <option value="bought" ${hubStatus === "bought" ? "selected" : ""}>Bought</option>
              <option value="skipped" ${hubStatus === "skipped" ? "selected" : ""}>Skipped</option>
              <option value="sold_out" ${hubStatus === "sold_out" ? "selected" : ""}>Sold out</option>
            </select>
          </label>
          <label class="hub-triage__notes">
            <span>Notes</span>
            <textarea rows="2" data-notes placeholder="Fit risk, seller reply, gift deadline…">${notes}</textarea>
          </label>
          <label>
            <span>Tags</span>
            <input type="text" data-tags value="${tagsValue}" placeholder="gift, winter, size-m" />
          </label>
          <button class="button hub-action" type="button" data-save-triage>Save notes &amp; tags</button>
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

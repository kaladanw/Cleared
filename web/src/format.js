// Shared, DOM-free formatting helpers for the hub and the public share page.

export function esc(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Only allow http(s) links into href attributes; everything else becomes "#". */
export function safeUrl(value) {
  const url = String(value ?? "").trim();
  return /^https?:\/\//i.test(url) ? url : "#";
}

export function money(value) {
  return Number.isFinite(value) ? `$${Math.round(value)}` : "—";
}

export function range(low, high) {
  if (Number.isFinite(low) && Number.isFinite(high)) {
    return `$${Math.round(low)}–$${Math.round(high)}`;
  }
  if (Number.isFinite(low)) return `$${Math.round(low)}+`;
  if (Number.isFinite(high)) return `up to $${Math.round(high)}`;
  return "—";
}

export function formatDate(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return String(iso).slice(0, 10);
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function listHtml(items) {
  return `<ul>${items.map((item) => `<li>${esc(item)}</li>`).join("")}</ul>`;
}

export function verdictPillClass(rec) {
  if (rec === "buy") return "hub-pill hub-pill--buy";
  if (rec === "negotiate") return "hub-pill hub-pill--negotiate";
  if (rec === "skip") return "hub-pill hub-pill--skip";
  return "hub-pill";
}

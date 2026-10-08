import { DEFAULT_API_URL } from "./auth.js";

function apiUrl() {
  const configured = import.meta.env?.VITE_CLEARED_API_URL?.trim();
  return (configured || DEFAULT_API_URL).replace(/\/$/, "");
}

function authHeaders(accessToken) {
  return { Authorization: `Bearer ${accessToken}` };
}

async function handleAuthResponse(response, fallbackMessage) {
  if (response.status === 401) {
    const err = new Error("Your session expired. Sign in again.");
    err.code = "unauthorized";
    throw err;
  }
  if (!response.ok) {
    let detail = "";
    try {
      const data = await response.json();
      detail = data.detail || "";
    } catch {
      /* ignore */
    }
    const err = new Error(typeof detail === "string" && detail ? detail : fallbackMessage);
    err.status = response.status;
    throw err;
  }
  return response.json();
}

/**
 * GET /api/reports — past checks for the signed-in user.
 * @param {string} accessToken
 * @param {{
 *   marketplace?: string,
 *   verdict?: string,
 *   status?: string,
 *   seller?: string,
 *   q?: string,
 *   date_from?: string,
 *   date_to?: string,
 *   fetchImpl?: typeof fetch,
 * }} [options]
 */
export const REPORT_FILTER_KEYS = ["marketplace", "verdict", "status", "seller", "q", "date_from", "date_to"];

/** Query string for hub filters (shared by the JSON list and CSV export). */
export function buildReportQuery(filters = {}) {
  const params = new URLSearchParams();
  for (const key of REPORT_FILTER_KEYS) {
    if (filters[key]) params.set(key, filters[key]);
  }
  const qs = params.toString();
  return qs ? `?${qs}` : "";
}

export async function fetchReports(accessToken, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  const url = `${apiUrl()}/api/reports${buildReportQuery(options)}`;

  let response;
  try {
    response = await fetchImpl(url, { headers: authHeaders(accessToken) });
  } catch {
    throw new Error("Cleared couldn’t reach the reports service. Check your connection and try again.");
  }

  return handleAuthResponse(response, "We couldn’t load your past checks right now. Try again in a moment.");
}

/**
 * PATCH /api/reports/:id — update hub triage fields.
 */
export async function updateReport(accessToken, reportId, patch, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  let response;
  try {
    response = await fetchImpl(`${apiUrl()}/api/reports/${encodeURIComponent(reportId)}`, {
      method: "PATCH",
      headers: {
        ...authHeaders(accessToken),
        "Content-Type": "application/json",
      },
      body: JSON.stringify(patch),
    });
  } catch {
    throw new Error("Cleared couldn’t reach the reports service. Check your connection and try again.");
  }
  return handleAuthResponse(response, "We couldn’t save those changes. Try again.");
}

/**
 * POST /api/reports/:id/recheck — best-effort API recheck from stored images.
 */
export async function recheckReport(accessToken, reportId, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  let response;
  try {
    response = await fetchImpl(
      `${apiUrl()}/api/reports/${encodeURIComponent(reportId)}/recheck`,
      {
        method: "POST",
        headers: authHeaders(accessToken),
      },
    );
  } catch {
    throw new Error("Cleared couldn’t reach the check service. Check your connection and try again.");
  }
  return handleAuthResponse(
    response,
    "We couldn’t recheck that listing from the hub. Open it in Depop and use the extension.",
  );
}

/**
 * GET /api/reports.csv — CSV of the currently filtered hub list.
 * Returns { blob, filename }. Auth uses the Bearer token, so the browser
 * downloads via an object URL rather than a plain link.
 */
export async function exportReportsCsv(accessToken, filters = {}, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  let response;
  try {
    response = await fetchImpl(`${apiUrl()}/api/reports.csv${buildReportQuery(filters)}`, {
      headers: authHeaders(accessToken),
    });
  } catch {
    throw new Error("Cleared couldn’t reach the reports service. Check your connection and try again.");
  }
  if (response.status === 401) {
    const err = new Error("Your session expired. Sign in again.");
    err.code = "unauthorized";
    throw err;
  }
  if (!response.ok) throw new Error("We couldn’t export your checks right now. Try again in a moment.");
  const stamp = new Date().toISOString().slice(0, 10);
  return { blob: await response.blob(), filename: `cleared-checks-${stamp}.csv` };
}

/** POST /api/reports/:id/share — returns { token, path, shared_at }. */
export async function createShare(accessToken, reportId, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  let response;
  try {
    response = await fetchImpl(`${apiUrl()}/api/reports/${encodeURIComponent(reportId)}/share`, {
      method: "POST",
      headers: authHeaders(accessToken),
    });
  } catch {
    throw new Error("Cleared couldn’t reach the reports service. Check your connection and try again.");
  }
  return handleAuthResponse(response, "We couldn’t create a share link. Try again.");
}

/** DELETE /api/reports/:id/share — revoke. */
export async function revokeShare(accessToken, reportId, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  let response;
  try {
    response = await fetchImpl(`${apiUrl()}/api/reports/${encodeURIComponent(reportId)}/share`, {
      method: "DELETE",
      headers: authHeaders(accessToken),
    });
  } catch {
    throw new Error("Cleared couldn’t reach the reports service. Check your connection and try again.");
  }
  return handleAuthResponse(response, "We couldn’t revoke that share link. Try again.");
}

/** GET /api/shared/:token — public, no auth header is sent. */
export async function fetchShared(token, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  let response;
  try {
    response = await fetchImpl(`${apiUrl()}/api/shared/${encodeURIComponent(token)}`);
  } catch {
    throw new Error("Cleared couldn’t reach the report service. Check your connection and try again.");
  }
  if (response.status === 404) throw new Error("This shared report doesn’t exist or was revoked.");
  if (response.status === 429) throw new Error("Too many requests right now. Try again in a minute.");
  if (!response.ok) throw new Error("We couldn’t load this shared report. Try again in a moment.");
  return response.json();
}

/** Absolute public URL for a share token on the current site. */
export function shareUrl(token, origin = globalThis.location?.origin || "") {
  return `${origin}/r/${token}`;
}

export { apiUrl };

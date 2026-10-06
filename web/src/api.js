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
 *   q?: string,
 *   date_from?: string,
 *   date_to?: string,
 *   fetchImpl?: typeof fetch,
 * }} [options]
 */
export async function fetchReports(accessToken, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  const params = new URLSearchParams();
  for (const key of ["marketplace", "verdict", "status", "q", "date_from", "date_to"]) {
    if (options[key]) params.set(key, options[key]);
  }
  const qs = params.toString();
  const url = `${apiUrl()}/api/reports${qs ? `?${qs}` : ""}`;

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

export { apiUrl };

import { DEFAULT_API_URL } from "./auth.js";

function apiUrl() {
  const configured = import.meta.env?.VITE_CLEARED_API_URL?.trim();
  return (configured || DEFAULT_API_URL).replace(/\/$/, "");
}

/**
 * GET /api/reports — past checks for the signed-in user.
 * @param {string} accessToken
 * @param {{ marketplace?: string, fetchImpl?: typeof fetch }} [options]
 */
export async function fetchReports(accessToken, options = {}) {
  const fetchImpl = options.fetchImpl || fetch;
  const params = new URLSearchParams();
  if (options.marketplace) params.set("marketplace", options.marketplace);
  const qs = params.toString();
  const url = `${apiUrl()}/api/reports${qs ? `?${qs}` : ""}`;

  let response;
  try {
    response = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
  } catch {
    throw new Error("Cleared couldn’t reach the reports service. Check your connection and try again.");
  }

  if (response.status === 401) {
    const err = new Error("Your session expired. Sign in again.");
    err.code = "unauthorized";
    throw err;
  }
  if (!response.ok) {
    throw new Error("We couldn’t load your past checks right now. Try again in a moment.");
  }
  return response.json();
}

export { apiUrl };

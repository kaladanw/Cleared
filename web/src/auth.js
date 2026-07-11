export const SESSION_KEY = "cleared_web_session";
export const DEFAULT_API_URL = "https://cleared-backend-production.up.railway.app";

function apiUrl() {
  const configured = import.meta.env?.VITE_CLEARED_API_URL?.trim();
  return (configured || DEFAULT_API_URL).replace(/\/$/, "");
}

function authError(mode, status) {
  if (mode === "signup" && status === 403) {
    return "That email isn’t on the invite list. Use the address your invite was sent to.";
  }
  if (mode === "login" && status === 401) {
    return "That email and password don’t match. Check both and try again.";
  }
  if (mode === "signup" && status === 400) {
    return "We couldn’t create that account. It may already exist, or the password may not meet the account requirements.";
  }
  if (status === 422) return "Check the email and password fields, then try again.";
  if (status >= 500) return "Cleared’s account service is unavailable right now. Try again in a moment.";
  return mode === "signup" ? "We couldn’t create your account." : "We couldn’t sign you in.";
}

export async function requestAuth(mode, credentials, fetchImpl = fetch) {
  let response;
  try {
    response = await fetchImpl(`${apiUrl()}/auth/${mode === "signup" ? "signup" : "login"}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(credentials),
    });
  } catch {
    throw new Error("Cleared couldn’t reach the account service. Check your connection and try again.");
  }

  if (!response.ok) throw new Error(authError(mode, response.status));
  return response.json();
}

export function saveSession(session, storage = sessionStorage) {
  storage.setItem(SESSION_KEY, JSON.stringify(session));
}

export function getSession(storage = sessionStorage) {
  try {
    const session = JSON.parse(storage.getItem(SESSION_KEY));
    if (!session?.accessToken || !session?.user?.email) return null;
    return session;
  } catch {
    return null;
  }
}

export function clearSession(storage = sessionStorage) {
  storage.removeItem(SESSION_KEY);
}

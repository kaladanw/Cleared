import {
  clearSession,
  getSession,
  requestAuth,
  saveSession,
} from "./auth.js";

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = new Date().getFullYear();
});

const authView = document.querySelector("[data-auth-view]");
const installView = document.querySelector("[data-install-view]");
const accountSummary = document.querySelector("[data-account-summary]");
const accountEmail = document.querySelector("[data-account-email]");
const intro = document.querySelector("#onboarding-intro");
const title = document.querySelector("#onboarding-title");
const form = document.querySelector("#auth-form");
const message = document.querySelector("[data-form-message]");
const submit = document.querySelector("[data-auth-submit]");
const modeButtons = [...document.querySelectorAll("[data-auth-mode]")];

if (form) {
let mode = "signup";

function setMode(nextMode) {
  mode = nextMode;
  const isSignup = mode === "signup";
  modeButtons.forEach((button) => {
    const selected = button.dataset.authMode === mode;
    button.setAttribute("aria-selected", String(selected));
    button.tabIndex = selected ? 0 : -1;
  });
  submit.textContent = isSignup ? "Create account" : "Sign in";
  form.elements.password.autocomplete = isSignup ? "new-password" : "current-password";
  message.textContent = "";
  message.className = "form-message";
}

function showInstall(session) {
  authView.hidden = true;
  installView.hidden = false;
  accountSummary.hidden = false;
  accountEmail.textContent = session.user.email;
  title.innerHTML = "You’re cleared to <em>get started.</em>";
  intro.hidden = true;
}

function showAuth() {
  authView.hidden = false;
  installView.hidden = true;
  accountSummary.hidden = true;
  intro.hidden = false;
  title.innerHTML = "Your invite is the first <em>stitch.</em>";
  form.reset();
  setMode("signup");
}

modeButtons.forEach((button) => {
  button.addEventListener("click", () => setMode(button.dataset.authMode));
  button.addEventListener("keydown", (event) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    event.preventDefault();
    const nextMode = mode === "signup" ? "login" : "signup";
    setMode(nextMode);
    modeButtons.find((item) => item.dataset.authMode === nextMode).focus();
  });
});

document.querySelector("[data-reveal-password]").addEventListener("click", (event) => {
  const input = form.elements.password;
  const revealing = input.type === "password";
  input.type = revealing ? "text" : "password";
  event.currentTarget.textContent = revealing ? "Hide" : "Show";
  event.currentTarget.setAttribute("aria-label", revealing ? "Hide password" : "Show password");
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!form.reportValidity()) return;

  submit.disabled = true;
  submit.textContent = mode === "signup" ? "Creating account…" : "Signing in…";
  message.textContent = "";
  message.className = "form-message";

  try {
    const result = await requestAuth(mode, {
      email: form.elements.email.value.trim(),
      password: form.elements.password.value,
    });
    if (!result.access_token) {
      throw new Error("Your account was created, but no session was returned. Try signing in.");
    }
    const session = { accessToken: result.access_token, user: result.user };
    saveSession(session);
    showInstall(session);
  } catch (error) {
    message.textContent = error.message;
    message.className = "form-message form-message--error";
  } finally {
    submit.disabled = false;
    submit.textContent = mode === "signup" ? "Create account" : "Sign in";
  }
});

document.querySelector("[data-sign-out]").addEventListener("click", () => {
  clearSession();
  showAuth();
});

document.querySelector("[data-copy-address]").addEventListener("click", async () => {
  const status = document.querySelector("[data-copy-status]");
  try {
    await navigator.clipboard.writeText("chrome://extensions");
    status.textContent = "Copied: chrome://extensions";
  } catch {
    status.textContent = "Copy was blocked. Type chrome://extensions in Chrome’s address bar.";
  }
});

const savedSession = getSession();
if (savedSession) showInstall(savedSession);
}

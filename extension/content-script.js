(async function initClearedContentScript() {
  const extractor = globalThis.ClearedExtractor;
  const client = globalThis.ClearedClient;
  const ui = globalThis.ClearedUi;
  const auth = globalThis.ClearedAuth;
  const config = globalThis.ClearedConfig;

  if (!extractor || !client || !ui || !auth || !config) {
    console.warn("[Cleared] extension modules unavailable");
    return;
  }

  const backendUrl = await config.getBackendUrl();

  const listing = extractor.extractListingFromDocument(document);
  if (!listing.image_urls.length) {
    console.warn("[Cleared] no Depop product data found on this page");
    return;
  }

  // ---- Build the panel container ----
  const container = document.createElement("aside");
  container.className = "cleared-panel";
  document.body.append(container);

  // ---- Drag to reposition — grab from anywhere except interactive elements ----
  const DRAG_SKIP = new Set(["BUTTON", "TEXTAREA", "INPUT", "A", "SELECT"]);
  container.style.cursor = "grab";
  let dragging = false, startX = 0, startY = 0, originLeft = 0, originTop = 0;
  container.addEventListener("mousedown", (e) => {
    if (DRAG_SKIP.has(e.target.tagName)) return;
    const rect = container.getBoundingClientRect();
    container.style.right = "auto";
    container.style.left = rect.left + "px";
    container.style.top = rect.top + "px";
    dragging = true;
    startX = e.clientX;
    startY = e.clientY;
    originLeft = rect.left;
    originTop = rect.top;
    container.style.cursor = "grabbing";
    e.preventDefault();
  });
  document.addEventListener("mousemove", (e) => {
    if (!dragging) return;
    container.style.left = (originLeft + e.clientX - startX) + "px";
    container.style.top  = (originTop  + e.clientY - startY) + "px";
  });
  document.addEventListener("mouseup", () => {
    if (!dragging) return;
    dragging = false;
    container.style.cursor = "grab";
  });

  // ---- Check auth ----
  const token = await auth.getToken();

  if (!token) {
    renderLoginPanel();
    return;
  }

  // ---- Logged in — render the main check panel ----
  renderCheckPanel({ token });

  // ---- Cached revisit: check for a previously saved report for this URL ----
  const cachedRow = await client.getCachedReport(window.location.href, { token, backendUrl });
  if (cachedRow && cachedRow.report_json) {
    renderCachedReport(cachedRow.report_json, { token });
  }

  // ==========================================================================
  // Render helpers
  // ==========================================================================

  function renderLoginPanel() {
    container.innerHTML = `
      <div class="cleared-panel__top">
        <div>
          <div class="cleared-kicker">Cleared</div>
          <strong>Second opinion</strong>
        </div>
      </div>
      <div class="cleared-output" aria-live="polite">
        ${auth.renderLoginHtml()}
      </div>
    `;

    const form = container.querySelector(".cleared-login__form");
    const errEl = container.querySelector(".cleared-login__error");
    const submitBtn = container.querySelector(".cleared-login__form .cleared-button");

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      errEl.style.display = "none";
      submitBtn.disabled = true;
      submitBtn.textContent = "Signing in…";

      const email = form.querySelector("input[type=email]").value;
      const password = form.querySelector("input[type=password]").value;

      try {
        const data = await auth.loginRequest(email, password, backendUrl);
        await auth.setToken(data.access_token);
        // Re-initialise the full panel now that we have a token.
        container.remove();
        initClearedContentScript();
      } catch (err) {
        errEl.textContent = err.message;
        errEl.style.display = "block";
        submitBtn.disabled = false;
        submitBtn.textContent = "Sign in";
      }
    });
  }

  function renderCheckPanel({ token: _token }) {
    container.innerHTML = `
      <div class="cleared-panel__top">
        <div>
          <div class="cleared-kicker">Cleared</div>
          <strong>Second opinion</strong>
        </div>
        <button class="cleared-button" type="button">Check this listing</button>
      </div>
      <label class="cleared-context">
        <span>Context</span>
        <textarea rows="2" placeholder="Gift, fit risk, legit check..."></textarea>
      </label>
      <div class="cleared-output" aria-live="polite"></div>
    `;
    wireCheckButton(_token);
  }

  function renderCachedReport(reportJson, { token: _token }) {
    // Replace the button with "Re-check" and show the cached report.
    const button = container.querySelector(".cleared-button");
    if (button) {
      button.textContent = "Re-check";
      // Remove old click listener by replacing the node.
      const freshBtn = button.cloneNode(true);
      button.replaceWith(freshBtn);
      freshBtn.addEventListener("click", () => runCheck(freshBtn, _token));
    }
    const output = container.querySelector(".cleared-output");
    if (output) {
      output.innerHTML =
        '<div class="cleared-status" style="margin-bottom:6px">Cached · ' +
        new Date().toLocaleDateString() + "</div>" +
        ui.renderReportHtml(reportJson);
    }
  }

  function wireCheckButton(token) {
    const button = container.querySelector(".cleared-button");
    if (!button) return;
    button.addEventListener("click", () => runCheck(button, token));
  }

  async function runCheck(button, token) {
    const output = container.querySelector(".cleared-output");
    const textarea = container.querySelector("textarea");
    button.disabled = true;
    output.innerHTML = ui.renderLoadingHtml();

    try {
      const report = await client.postCheckListing(listing, {
        token,
        userContext: textarea ? textarea.value.trim() : "",
        listingUrl: window.location.href,
        backendUrl,
      });
      output.innerHTML = ui.renderReportHtml(report);
    } catch (error) {
      output.innerHTML = ui.renderErrorHtml(error.message);
    } finally {
      button.disabled = false;
    }
  }
})();

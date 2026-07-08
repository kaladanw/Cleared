(function initClearedContentScript() {
  const extractor = globalThis.ClearedExtractor;
  const client = globalThis.ClearedClient;
  const ui = globalThis.ClearedUi;
  if (!extractor || !client || !ui) {
    console.warn("[Cleared] extension modules unavailable");
    return;
  }

  const listing = extractor.extractListingFromDocument(document);
  if (!listing.image_urls.length) {
    console.warn("[Cleared] no Depop product data found on this page");
    return;
  }

  const container = document.createElement("aside");
  container.className = "cleared-panel";
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
  document.body.append(container);

  const button = container.querySelector(".cleared-button");
  const textarea = container.querySelector("textarea");
  const output = container.querySelector(".cleared-output");
  const header = container.querySelector(".cleared-panel__top");

  // Drag to reposition — grab from anywhere except interactive elements
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

  button.addEventListener("click", async () => {
    button.disabled = true;
    output.innerHTML = ui.renderLoadingHtml();
    try {
      const report = await client.postCheckListing(listing, {
        userContext: textarea.value.trim(),
      });
      output.innerHTML = ui.renderReportHtml(report);
    } catch (error) {
      output.innerHTML = ui.renderErrorHtml(error.message);
    } finally {
      button.disabled = false;
    }
  });
})();

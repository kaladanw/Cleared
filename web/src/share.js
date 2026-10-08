import { fetchShared } from "./api.js";
import { esc } from "./format.js";
import { renderSharedReport, tokenFromLocation } from "./share-view.js";

document.querySelectorAll("[data-year]").forEach((node) => {
  node.textContent = new Date().getFullYear();
});

const mount = document.querySelector("[data-share-root]");
const token = tokenFromLocation(window.location.pathname, window.location.search);

async function boot() {
  if (!mount) return;
  if (!token) {
    mount.innerHTML = '<p class="hub-state hub-state--error">This share link is incomplete.</p>';
    return;
  }
  try {
    const data = await fetchShared(token);
    mount.innerHTML = renderSharedReport(data);
    if (data.listing_name) document.title = `Cleared — ${data.listing_name}`;
  } catch (error) {
    mount.innerHTML = `<p class="hub-state hub-state--error">${esc(error.message)}</p>`;
  }
}

boot();

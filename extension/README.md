# Cleared extension

Manifest V3 Chrome extension for the web port.

Current slice: W3 local wiring. On Depop product pages, the content script reads
`__NEXT_DATA__`, injects a small Cleared panel, POSTs extracted facts plus image
URLs to the local backend, and renders the returned `CheckReport` in-page.

## Dev load

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked extension from this `extension/` directory.
4. Run the backend on `http://localhost:8000`.
5. Open a Depop product page and click **Check this listing** in the injected
   panel.

## Tests

From the repo root:

```sh
node --test extension/tests/*.test.js
```

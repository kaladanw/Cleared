# Cleared extension

Manifest V3 Chrome extension for the web port.

On Depop product pages, the content script reads
`__NEXT_DATA__`, injects a small Cleared panel, POSTs extracted facts plus image
URLs to the deployed Railway backend, and renders the returned `CheckReport`
in-page. Login, checks, and cached-report reads share the same backend setting.

## Backend selection

The packaged extension defaults to:

`https://cleared-backend-production.up.railway.app`

Both that origin and localhost are declared in `host_permissions`. To use a
local backend, open a Depop product page, select the extension's content-script
context in DevTools, and run:

```js
chrome.storage.local.set({ cleared_backend_url: "http://localhost:8000" })
```

Reload the product page after changing it. Return to Railway with:

```js
chrome.storage.local.remove("cleared_backend_url")
```

Only localhost HTTP or an HTTPS origin is accepted. The override is deliberately
stored locally rather than exposed in the buyer-facing panel.

## Dev load

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked extension from this `extension/` directory.
4. Set the localhost override above and run the backend on `http://localhost:8000`.
5. Open a Depop product page and click **Check this listing** in the injected
   panel.

## Tests

From the repo root:

```sh
node --test extension/tests/*.test.js
```

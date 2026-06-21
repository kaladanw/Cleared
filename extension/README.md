# Cleared extension

Manifest V3 Chrome extension for the web port.

Current slice: W2 skeleton. On Depop product pages, the content script reads
`__NEXT_DATA__`, extracts listing facts plus image URLs, and logs the payload to
the console. It does not call the backend yet.

## Dev load

1. Open `chrome://extensions`.
2. Enable Developer mode.
3. Load unpacked extension from this `extension/` directory.
4. Open a Depop product page and check the console for
   `[Cleared] extracted Depop listing`.

## Tests

From the repo root:

```sh
node --test extension/tests/*.test.js
```

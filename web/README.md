# Cleared web

Static Vite site for the Vercel-hosted Cleared marketing, privacy, and support surfaces.

## Local development

```sh
cd web
npm install
npm run dev
```

Run `npm test` and `npm run build` before deploying.

## Vercel setup

Create a Vercel project from this repository with:

- Root Directory: `web`
- Framework Preset: Vite
- Build Command: `npm run build`
- Output Directory: `dist`
- Install Command: `npm install`

The project requires no runtime environment variables. `vercel.json` enables clean routes (`/privacy`, `/support`) and baseline security headers.

## Domain and launch requirements

1. Add the production domain to the Vercel project and make Vercel's requested DNS records authoritative. Keep the generated `*.vercel.app` URL as a preview/fallback.
2. Choose one canonical hostname (`cleared.app` or `www.cleared.app`) and configure the other to redirect to it in Vercel.
3. Replace both TestFlight placeholders with the reviewed public beta URL. Do not claim App Store availability until the listing is live.
4. Replace the support placeholder with a monitored address or form.
5. Finalize the privacy policy's screenshot/report retention period and verify the production terms and retention settings for hosting, auth/database, and AI processors.
6. Add the production domain to any relevant backend CORS/auth redirect allowlists only when a browser client actually needs backend access.
7. Verify `/`, `/privacy`, and `/support` on the production domain, including mobile layout, TLS, metadata, keyboard navigation, and a real support/deletion request.

## Deferred application surface

Universal Links, Cleared-owned check-ID routing, authenticated report history, and convergence between iOS screenshot checks and web URL checks are intentionally out of scope. Those features should arrive as an application layer with an explicit data and authentication design; this site does not create placeholder routes that could constrain it.

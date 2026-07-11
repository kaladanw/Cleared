# Cleared web

Static Vite site for Cleared's Vercel-hosted invite onboarding, extension setup,
marketing, privacy, and support surfaces.

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

The site calls the existing Railway API directly. It defaults to
`https://cleared-backend-production.up.railway.app`; local or preview builds can
set `VITE_CLEARED_API_URL` at build time. `vercel.json` enables clean routes
(`/privacy`, `/support`) and baseline security headers.

## Invite authentication

The landing page uses the backend's public `POST /auth/signup` and
`POST /auth/login` JSON contract. Signup is gated by the backend's
`CLEARED_ALLOWED_EMAILS` configuration. The site maps allowlist, credential,
validation, network, and service errors to buyer-facing messages without
displaying raw provider errors.

The bearer token and returned user identity are kept in `sessionStorage`, so
they survive a reload in the current tab but are cleared when that browser
session ends. Passwords and form values are never stored. The website and
Chrome extension have separate browser storage, so the install instructions
honestly ask the user to sign in again inside the extension.

## Domain and launch requirements

1. Add the production domain to the Vercel project and make Vercel's requested DNS records authoritative. Keep the generated `*.vercel.app` URL as a preview/fallback.
2. Choose one canonical hostname (`cleared.app` or `www.cleared.app`) and configure the other to redirect to it in Vercel.
3. Provide invitees with the unpacked `extension/` folder through an approved
   channel; the website intentionally does not claim a public download exists.
4. Replace the support placeholder with a monitored address or form.
5. Finalize the privacy policy's report retention period and verify the production terms and retention settings for hosting, auth/database, and AI processors.
6. Lock backend CORS to the reviewed Vercel production/preview origins when those hostnames are final: set `CLEARED_WEB_ORIGINS` (comma-separated) on the Railway backend to the Vercel prod domain and/or preview domain — see `backend/.env.example`.
7. Verify signup, login, `/privacy`, and `/support` on the production domain, including mobile layout, TLS, metadata, keyboard navigation, and a real support/deletion request.

## Deferred application surface

Universal Links, Cleared-owned check-ID routing, authenticated report history, and convergence between iOS screenshot checks and web URL checks are intentionally out of scope. Those features should arrive as an application layer with an explicit data and authentication design; this site does not create placeholder routes that could constrain it.

## Extension/backend handoff

The browser extension is packaged against the existing Railway API at
`https://cleared-backend-production.up.railway.app`. Its manifest also permits
`http://localhost:8000` for development, but localhost is used only when the
developer explicitly stores the override documented in `extension/README.md`.
The Vercel site does not proxy API requests. The onboarding flow uses the same
Railway origin as the packaged extension.

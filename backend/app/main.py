"""Cleared backend — the thin proxy.

POST /check  (multipart: images[] + optional user_context) -> CheckReport
POST /check-listing  (JSON: facts + image_urls + user_context + listing_url) -> CheckReport

The input is listing SCREENSHOT(S) or fetched CDN images — Depop flat-edge-blocks
every server-side page fetch (see claude.mds/phase-0.md). Vision reads the images.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

from dotenv import load_dotenv

# Load backend/.env.local so ANTHROPIC_API_KEY is picked up without exporting it.
load_dotenv(Path(__file__).resolve().parent.parent / ".env.local")

from fastapi import Depends, FastAPI, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from .auth import get_current_user, login, signup
from .claude_check import run_check
from .images import fetch_images
from .models import CheckListingRequest, CheckReport, ListingFacts
from .supabase_client import get_supabase

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("cleared")

app = FastAPI(title="Cleared", version="0.2.0")

# CORS: tighten to the extension origin + web origins + localhost once those
# hostnames are known. Set CLEARED_EXTENSION_ORIGIN to the chrome-extension://
# URI (visible in chrome://extensions after loading unpacked) and/or
# CLEARED_WEB_ORIGINS to a comma-separated list of allowed web origins (e.g. the
# Vercel production and preview domains) to lock down the deployed backend.
# When NEITHER is set (local dev, iOS Share Extension, no deployed
# extension/site yet) falls back to "*" so curl / Share Extension / the web
# fallback page work without config.
def _build_cors_origins(extension_origin: str, web_origins: str) -> list[str]:
    """Build the deduped CORS allowlist from the two env-var inputs.

    Falls back to ["*"] only when both inputs are empty — preserves the
    original single-origin (or wide-open) behavior for local dev and the
    current Railway deployment.
    """
    web_origin_list = [origin.strip() for origin in web_origins.split(",") if origin.strip()]

    if not extension_origin and not web_origin_list:
        return ["*"]

    origins = [
        *([extension_origin] if extension_origin else []),
        *web_origin_list,
        "https://www.depop.com",
        "http://localhost:8000",
        "http://localhost:3000",
    ]
    # Dedupe while preserving order.
    return list(dict.fromkeys(origins))


_extension_origin = os.environ.get("CLEARED_EXTENSION_ORIGIN", "")
_web_origins = os.environ.get("CLEARED_WEB_ORIGINS", "")
_cors_origins: list[str] = _build_cors_origins(_extension_origin, _web_origins)

app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)

_ALLOWED_IMAGE_TYPES = {"image/png", "image/jpeg", "image/webp", "image/gif"}

# Load the history HTML once at startup.
_HISTORY_HTML_PATH = Path(__file__).resolve().parent / "history.html"


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> dict:
    return {"ok": True}


# ---------------------------------------------------------------------------
# Auth endpoints  (/auth/signup, /auth/login)
# ---------------------------------------------------------------------------

class AuthRequest(BaseModel):
    email: str
    password: str


@app.post("/auth/signup")
async def auth_signup(body: AuthRequest) -> dict:
    """Create a new Cleared account.

    Invite-only: email must be in CLEARED_ALLOWED_EMAILS (comma-separated env var).
    Leave the env var empty in dev to allow any email.
    """
    return await signup(body.email, body.password)


@app.post("/auth/login")
async def auth_login(body: AuthRequest) -> dict:
    """Sign in with email + password. Returns { access_token, user }."""
    return await login(body.email, body.password)


# ---------------------------------------------------------------------------
# Screenshot check (multipart) — UNCHANGED. Keeps X-Cleared-Token auth.
# ---------------------------------------------------------------------------

@app.post("/check", response_model=CheckReport)
async def check(
    images: list[UploadFile] = [],
    user_context: str | None = Form(None),
    x_cleared_token: str | None = Header(None, alias="X-Cleared-Token"),
) -> CheckReport:
    _require_token(x_cleared_token)

    loaded: list[tuple[bytes, str]] = []
    for f in images:
        media_type = f.content_type if f.content_type in _ALLOWED_IMAGE_TYPES else "image/jpeg"
        loaded.append((await f.read(), media_type))

    if not loaded:
        return CheckReport(
            listing_facts=ListingFacts(),
            error="No screenshots received — share the listing photos to analyze.",
        )

    log.info("checking listing from %d screenshot(s)", len(loaded))
    report = run_check(loaded, user_context=user_context)
    if report.error:
        log.warning("check returned error: %s", report.error)
    return report


# ---------------------------------------------------------------------------
# Listing check (JSON + image URLs) — JWT auth, saves to Supabase
# ---------------------------------------------------------------------------

@app.post("/check-listing", response_model=CheckReport)
async def check_listing(
    request: CheckListingRequest,
    user: dict = Depends(get_current_user),
) -> CheckReport:
    images = fetch_images(request.image_urls)
    if not images:
        return CheckReport(
            listing_facts=ListingFacts(),
            error="Could not fetch listing photos from the supplied image URLs.",
        )

    log.info("checking listing from %d fetched image(s)", len(images))
    report = run_check(
        images,
        user_context=request.user_context,
        seeded_facts=request.facts,
    )
    if report.error:
        log.warning("check-listing returned error: %s", report.error)

    # Best-effort: save the report to Supabase. A save failure never fails the check.
    if request.listing_url:
        _save_report(
            user_id=user["id"],
            listing_url=request.listing_url,
            listing_name=request.facts.model_or_name or request.facts.brand,
            report=report,
        )

    return report


def _save_report(
    user_id: str,
    listing_url: str,
    listing_name: str | None,
    report: CheckReport,
) -> None:
    sb = get_supabase()
    if sb is None:
        return  # Supabase not configured — skip silently

    verdict_str = (
        report.verdict.recommendation.value
        if report.verdict.recommendation
        else None
    )
    try:
        sb.table("reports").insert({
            "user_id": user_id,
            "listing_url": listing_url,
            "listing_name": listing_name or "",
            "verdict": verdict_str,
            "report_json": report.model_dump(mode="json"),
        }).execute()
        log.info("saved report for user=%s url=%s", user_id, listing_url)
    except Exception as exc:
        log.warning("report save failed (non-fatal): %r", exc)


# ---------------------------------------------------------------------------
# Report history endpoints
# ---------------------------------------------------------------------------

@app.get("/reports")
async def get_cached_report(
    url: str | None = None,
    user: dict = Depends(get_current_user),
) -> dict | None:
    """Most recent report for a listing URL, or null if none.

    Used by the extension on page load: if a cached report exists for this URL,
    render it immediately instead of showing the plain "Check" button.
    """
    if not url:
        return None

    sb = get_supabase()
    if sb is None:
        return None

    try:
        result = (
            sb.table("reports")
            .select("*")
            .eq("user_id", user["id"])
            .eq("listing_url", url)
            .order("checked_at", desc=True)
            .limit(1)
            .execute()
        )
        rows = result.data or []
        return rows[0] if rows else None
    except Exception as exc:
        log.warning("report lookup failed (non-fatal): %r", exc)
        return None


@app.get("/api/reports")
async def list_reports(
    user: dict = Depends(get_current_user),
) -> list[dict]:
    """All reports for the current user, newest first. Used by the history page."""
    sb = get_supabase()
    if sb is None:
        return []

    try:
        result = (
            sb.table("reports")
            .select("id, listing_url, listing_name, verdict, checked_at, report_json")
            .eq("user_id", user["id"])
            .order("checked_at", desc=True)
            .execute()
        )
        return result.data or []
    except Exception as exc:
        log.warning("report list failed (non-fatal): %r", exc)
        return []


# ---------------------------------------------------------------------------
# History web page  (auth happens client-side via login form + localStorage)
# ---------------------------------------------------------------------------

@app.get("/history", response_class=HTMLResponse)
async def history_page() -> str:
    """Serve the self-contained history web page.

    The page shows a login form, stores the JWT in localStorage, and calls
    /api/reports. No server-side session is required.
    """
    try:
        return _HISTORY_HTML_PATH.read_text()
    except FileNotFoundError:
        return (
            "<h1>History page not found</h1>"
            "<p>backend/app/history.html is missing.</p>"
        )


# ---------------------------------------------------------------------------
# Shared-secret guard (used only by /check)
# ---------------------------------------------------------------------------

def _require_token(token: str | None) -> None:
    expected = os.environ.get("CLEARED_SHARED_TOKEN")
    if expected and token != expected:
        raise HTTPException(status_code=401, detail="Invalid Cleared token.")

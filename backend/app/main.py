"""Cleared backend — the thin proxy.

POST /check  (multipart: images[] + optional user_context, listing_url,
             marketplace, seller_username) -> CheckResponse. Bearer JWT saves to
             the user's history (+ private screenshot storage); the legacy
             X-Cleared-Token path is unsaved.
POST /check-listing  (JSON: facts + image_urls + user_context + listing_url) -> CheckResponse

Full contract: docs/api-contract.md

The input is listing SCREENSHOT(S) or fetched CDN images — Depop flat-edge-blocks
every server-side page fetch (see claude.mds/phase-0.md). Vision reads the images.
"""

from __future__ import annotations

import csv
import io
import logging
import os
import re
import secrets
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

# Load backend/.env.local so ANTHROPIC_API_KEY is picked up without exporting it.
load_dotenv(Path(__file__).resolve().parent.parent / ".env.local")

from fastapi import Depends, FastAPI, Form, Header, HTTPException, Request, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel

from .auth import get_current_user, login, refresh, signup
from .check_images import (
    ImageRejected,
    download_check_images,
    owned_paths,
    read_uploads,
    remove_check_images,
    upload_check_images,
)
from .claude_check import run_check
from .images import fetch_images
from .models import (
    CheckListingRequest,
    CheckReport,
    CheckResponse,
    RefreshRequest,
    normalize_listing_url,
    ListingFacts,
    ReportHubUpdate,
    HUB_STATUS_NONE,
    HUB_STATUSES,
    normalize_hub_status,
    normalize_marketplace,
    normalize_seller_username,
)
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
    """Sign in with email + password.

    Returns { access_token, refresh_token, expires_in, expires_at, token_type, user }.
    """
    return await login(body.email, body.password)


@app.post("/auth/refresh")
async def auth_refresh(body: RefreshRequest) -> dict:
    """Exchange a refresh token for a new session (same shape as /auth/login).

    Supabase rotates refresh tokens: store the new ``refresh_token`` every time.
    401 = refresh token invalid/expired/already used (sign in again);
    503 = auth service unreachable (retry; do not sign the user out).
    """
    return await refresh(body.refresh_token)


# ---------------------------------------------------------------------------
# Screenshot check (multipart) — iOS Share Extension.
#   Authorization: Bearer <jwt>  → user-scoped: saved to reports + screenshots
#                                  stored privately; response has report_id.
#   X-Cleared-Token (legacy)     → unchanged: not user-scoped, not saved.
# If both are sent, Bearer wins. A present-but-invalid Authorization header is
# a 401 (never a silent fallback to the shared secret).
# ---------------------------------------------------------------------------

@app.post("/check", response_model=CheckResponse)
async def check(
    images: list[UploadFile] = [],
    user_context: str | None = Form(None),
    listing_url: str | None = Form(None),
    marketplace: str | None = Form(None),
    seller_username: str | None = Form(None),
    authorization: str | None = Header(None),
    x_cleared_token: str | None = Header(None, alias="X-Cleared-Token"),
) -> CheckResponse:
    user: dict | None = None
    if authorization is not None:
        user = await get_current_user(authorization)  # raises 401 / 503
    else:
        _require_token(x_cleared_token)

    try:
        listing_url = normalize_listing_url(listing_url)
        marketplace = normalize_marketplace(marketplace or "depop")
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    seller = normalize_seller_username(seller_username)

    try:
        loaded = await read_uploads(images)
    except ImageRejected as exc:
        raise HTTPException(status_code=exc.status, detail=exc.detail) from exc

    if not loaded:
        return CheckResponse(
            listing_facts=ListingFacts(),
            error="No screenshots received — share the listing photos to analyze.",
        )

    log.info(
        "checking listing from %d screenshot(s) auth=%s",
        len(loaded),
        "bearer" if user else "shared-secret",
    )
    report = run_check(loaded, user_context=user_context)
    if report.error:
        log.warning("check returned error: %s", report.error)

    if user is None or report.error:
        # Legacy shared-secret path (unchanged), or nothing worth saving.
        return CheckResponse(**report.model_dump())

    report_id, stored = _save_check_with_images(
        user_id=user["id"],
        report=report,
        images=loaded,
        listing_url=listing_url,
        marketplace=marketplace,
        seller_username=seller,
    )
    return CheckResponse(**report.model_dump(), report_id=report_id, images_stored=len(stored))


def _seller_url_for(marketplace: str, seller_username: str | None) -> str | None:
    if seller_username and marketplace == "depop":
        return f"https://www.depop.com/{seller_username}/"
    return None


def _save_check_with_images(
    *,
    user_id: str,
    report: CheckReport,
    images: list[tuple[bytes, str]],
    listing_url: str | None,
    marketplace: str,
    seller_username: str | None,
) -> tuple[str | None, list[str]]:
    """Upload screenshots (best effort) then insert the report row.

    The report id is generated up front so objects land at
    ``{user_id}/{report_id}/{n}.{ext}``. Upload failures still save the report
    (without images). If the insert fails, uploaded objects are removed.
    """
    sb = get_supabase()
    if sb is None:
        return None, []
    report_id = str(uuid.uuid4())
    stored = upload_check_images(sb, user_id, report_id, images)
    facts = report.listing_facts
    saved_id = _save_report(
        user_id=user_id,
        listing_url=listing_url or "",
        listing_name=facts.model_or_name or facts.brand,
        report=report,
        marketplace=marketplace,
        seller_username=seller_username,
        seller_url=_seller_url_for(marketplace, seller_username),
        report_id=report_id,
        image_paths=stored,
    )
    if saved_id is None:
        remove_check_images(sb, stored)
        return None, []
    return saved_id, stored


# ---------------------------------------------------------------------------
# Listing check (JSON + image URLs) — JWT auth, saves to Supabase
# ---------------------------------------------------------------------------

@app.post("/check-listing", response_model=CheckResponse)
async def check_listing(
    request: CheckListingRequest,
    user: dict = Depends(get_current_user),
) -> CheckResponse:
    images = fetch_images(request.image_urls)
    if not images:
        return CheckResponse(
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
    report_id = None
    if request.listing_url:
        report_id = _save_report(
            user_id=user["id"],
            listing_url=request.listing_url,
            listing_name=request.facts.model_or_name or request.facts.brand,
            report=report,
            marketplace=request.marketplace,
            image_urls=request.image_urls,
            seller_username=request.seller.username if request.seller else None,
            seller_url=request.seller.profile_url if request.seller else None,
        )

    return CheckResponse(**report.model_dump(), report_id=report_id)


def _save_report(
    user_id: str,
    listing_url: str,
    listing_name: str | None,
    report: CheckReport,
    marketplace: str = "depop",
    image_urls: list[str] | None = None,
    seller_username: str | None = None,
    seller_url: str | None = None,
    report_id: str | None = None,
    image_paths: list[str] | None = None,
) -> str | None:
    """Insert a report row. Returns its id, or None when not saved (non-fatal)."""
    sb = get_supabase()
    if sb is None:
        return None  # Supabase not configured — skip silently

    verdict_str = (
        report.verdict.recommendation.value
        if report.verdict.recommendation
        else None
    )
    row = {
        "user_id": user_id,
        "listing_url": listing_url,
        "listing_name": listing_name or "",
        "marketplace": marketplace,
        "verdict": verdict_str,
        "report_json": report.model_dump(mode="json"),
        "image_urls": list(image_urls or []),
        "seller_username": seller_username,
        "seller_url": seller_url,
    }
    if report_id:
        row["id"] = report_id
    if image_paths:
        row["image_paths"] = list(image_paths)
    try:
        result = sb.table("reports").insert(row).execute()
    except Exception as exc:
        log.warning("report save failed (non-fatal): %r", exc)
        return None
    saved = (getattr(result, "data", None) or [{}])[0] or {}
    saved_id = saved.get("id") or report_id
    log.info(
        "saved report id=%s user=%s marketplace=%s url=%s images=%d",
        saved_id,
        user_id,
        marketplace,
        listing_url,
        len(image_paths or []),
    )
    return str(saved_id) if saved_id else None


_REPORT_SELECT = (
    "id, listing_url, listing_name, marketplace, verdict, checked_at, "
    "report_json, hub_status, notes, tags, image_urls, image_paths, "
    "seller_username, seller_url, share_token, shared_at"
)


def _stored_image_urls(row: dict) -> list[str]:
    urls = row.get("image_urls") or []
    return urls if isinstance(urls, list) else []


def _decorate_row(row: dict) -> dict:
    """Owner-facing row: add ``can_recheck`` (API recheck possible)."""
    paths = row.get("image_paths")
    row["image_paths"] = paths if isinstance(paths, list) else []
    row["can_recheck"] = bool(_stored_image_urls(row) or row["image_paths"])
    return row


def _filter_reports_rows(
    rows: list[dict],
    *,
    q: str | None,
    date_from: str | None,
    date_to: str | None,
) -> list[dict]:
    """Apply text + date filters that are awkward in PostgREST alone."""
    out = rows
    if q:
        needle = q.strip().lower()
        if needle:
            filtered = []
            for row in out:
                hay = " ".join(
                    [
                        str(row.get("listing_name") or ""),
                        str(row.get("listing_url") or ""),
                        str(row.get("notes") or ""),
                        str(row.get("seller_username") or ""),
                        " ".join(row.get("tags") or []),
                        str((row.get("report_json") or {}).get("verdict", {}).get("one_line") or ""),
                    ]
                ).lower()
                if needle in hay:
                    filtered.append(row)
            out = filtered
    if date_from:
        out = [r for r in out if (r.get("checked_at") or "")[:10] >= date_from[:10]]
    if date_to:
        out = [r for r in out if (r.get("checked_at") or "")[:10] <= date_to[:10]]
    return out


def _parse_report_filters(
    *,
    marketplace: str | None,
    verdict: str | None,
    status: str | None,
    seller: str | None,
    q: str | None,
    date_from: str | None,
    date_to: str | None,
) -> dict:
    """Validate hub filters once so JSON and CSV listings stay in lockstep."""
    filters: dict = {"q": q, "date_from": date_from, "date_to": date_to}

    if marketplace:
        try:
            filters["marketplace"] = normalize_marketplace(marketplace)
        except ValueError:
            raise HTTPException(
                status_code=422,
                detail="Invalid marketplace filter. Use a slug like depop or vinted.",
            )

    if verdict:
        v = verdict.strip().lower()
        if v not in {"buy", "negotiate", "skip"}:
            raise HTTPException(
                status_code=422,
                detail="Invalid verdict filter. Use buy, negotiate, or skip.",
            )
        filters["verdict"] = v

    if status is not None and str(status).strip() != "":
        try:
            normalized = normalize_hub_status(status)
        except ValueError:
            raise HTTPException(
                status_code=422,
                detail="Invalid status filter. Use watching, bought, skipped, sold_out, or none.",
            )
        if normalized is None:
            filters["status_is_none"] = True
        else:
            filters["status"] = normalized

    if seller is not None and str(seller).strip() != "":
        username = normalize_seller_username(seller)
        if username is None:
            raise HTTPException(status_code=422, detail="Invalid seller filter.")
        filters["seller"] = username

    return filters


def _query_reports(user_id: str, filters: dict) -> list[dict]:
    """Run the filtered hub query.

    Raises 503 when the query fails: clients (iOS) treat this list as the source
    of truth, so an error must never look like an empty history.
    """
    sb = get_supabase()
    if sb is None:
        raise HTTPException(status_code=503, detail="Supabase is not configured.")
    try:
        query = sb.table("reports").select(_REPORT_SELECT).eq("user_id", user_id)
        if filters.get("marketplace"):
            query = query.eq("marketplace", filters["marketplace"])
        if filters.get("verdict"):
            query = query.eq("verdict", filters["verdict"])
        if filters.get("status"):
            query = query.eq("hub_status", filters["status"])
        if filters.get("status_is_none"):
            query = query.is_("hub_status", "null")
        if filters.get("seller"):
            query = query.eq("seller_username", filters["seller"])
        result = query.order("checked_at", desc=True).execute()
        rows = result.data or []
    except Exception as exc:
        log.warning("report list failed: %r", exc)
        raise HTTPException(status_code=503, detail="Could not load reports. Try again.") from exc
    rows = _filter_reports_rows(
        rows,
        q=filters.get("q"),
        date_from=filters.get("date_from"),
        date_to=filters.get("date_to"),
    )
    return [_decorate_row(r) for r in rows]


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
    marketplace: str | None = None,
    verdict: str | None = None,
    status: str | None = None,
    seller: str | None = None,
    q: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    user: dict = Depends(get_current_user),
) -> list[dict]:
    """Reports for the current user, newest first (hub).

    Filters: marketplace, verdict (buy|negotiate|skip), status
    (watching|bought|skipped|sold_out|none), seller (username), q (text),
    date_from/date_to (YYYY-MM-DD).
    """
    filters = _parse_report_filters(
        marketplace=marketplace, verdict=verdict, status=status, seller=seller,
        q=q, date_from=date_from, date_to=date_to,
    )
    return _query_reports(user["id"], filters)


CSV_COLUMNS = [
    "checked_at",
    "marketplace",
    "listing_name",
    "listing_url",
    "verdict",
    "one_line",
    "asking_price",
    "currency",
    "fairness",
    "status",
    "tags",
    "notes",
]

_CSV_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")


def _csv_cell(value) -> str:
    """Stringify a cell and neutralize spreadsheet formula injection."""
    if value is None:
        return ""
    text = str(value)
    if text.startswith(_CSV_FORMULA_PREFIXES):
        return "'" + text
    return text


def build_reports_csv(rows: list[dict]) -> str:
    """Render hub rows as CSV with the documented column order."""
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\r\n")
    writer.writerow(CSV_COLUMNS)
    for row in rows:
        report = row.get("report_json") or {}
        facts = report.get("listing_facts") or {}
        price = report.get("price_read") or {}
        verdict = report.get("verdict") or {}
        asking = facts.get("asking_price")
        writer.writerow([
            _csv_cell(row.get("checked_at")),
            _csv_cell(row.get("marketplace")),
            _csv_cell(row.get("listing_name")),
            _csv_cell(row.get("listing_url")),
            _csv_cell(row.get("verdict") or verdict.get("recommendation")),
            _csv_cell(verdict.get("one_line")),
            "" if asking is None else _csv_cell(asking),
            _csv_cell(facts.get("currency")),
            _csv_cell(price.get("fairness")),
            _csv_cell(row.get("hub_status")),
            _csv_cell("; ".join(row.get("tags") or [])),
            _csv_cell(row.get("notes")),
        ])
    return buf.getvalue()


@app.get("/api/reports.csv")
async def export_reports_csv(
    marketplace: str | None = None,
    verdict: str | None = None,
    status: str | None = None,
    seller: str | None = None,
    q: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    user: dict = Depends(get_current_user),
) -> Response:
    """CSV export of the hub list, honoring the same filters as GET /api/reports."""
    filters = _parse_report_filters(
        marketplace=marketplace, verdict=verdict, status=status, seller=seller,
        q=q, date_from=date_from, date_to=date_to,
    )
    rows = _query_reports(user["id"], filters)
    return Response(
        content=build_reports_csv(rows),
        media_type="text/csv; charset=utf-8",
        headers={
            "Content-Disposition": 'attachment; filename="cleared-checks.csv"',
            "Cache-Control": "no-store",
        },
    )


@app.patch("/api/reports/{report_id}")
async def update_report_hub(
    report_id: str,
    body: ReportHubUpdate,
    user: dict = Depends(get_current_user),
) -> dict:
    """Update hub triage fields (status / notes / tags) on an owned report."""
    sb = get_supabase()
    if sb is None:
        raise HTTPException(status_code=503, detail="Supabase is not configured.")

    patch: dict = {}
    if "status" in body.model_fields_set:
        if body.status == HUB_STATUS_NONE or body.status is None:
            patch["hub_status"] = None
        else:
            patch["hub_status"] = body.status
    if "notes" in body.model_fields_set:
        patch["notes"] = body.notes or ""
    if "tags" in body.model_fields_set:
        patch["tags"] = body.tags or []

    if not patch:
        raise HTTPException(status_code=400, detail="No fields to update.")

    try:
        result = (
            sb.table("reports")
            .update(patch)
            .eq("id", report_id)
            .eq("user_id", user["id"])
            .select(_REPORT_SELECT)
            .execute()
        )
    except Exception as exc:
        log.warning("report patch failed: %r", exc)
        raise HTTPException(status_code=500, detail="Could not update report.") from exc

    rows = result.data or []
    if not rows:
        raise HTTPException(status_code=404, detail="Report not found.")
    return _decorate_row(rows[0])


@app.post("/api/reports/{report_id}/recheck", response_model=CheckResponse)
async def recheck_report(
    report_id: str,
    user: dict = Depends(get_current_user),
) -> CheckResponse:
    """Best-effort recheck of an owned report; saves the result as a NEW row.

    Image sources, in order: ``image_paths`` (screenshots stored privately by an
    authenticated iOS /check — downloaded server-side with the service role) or
    ``image_urls`` (public CDN URLs captured by the extension). 409 when the row
    has neither (older checks): open the listing and check it again instead.
    """
    sb = get_supabase()
    if sb is None:
        raise HTTPException(status_code=503, detail="Supabase is not configured.")

    try:
        result = (
            sb.table("reports")
            .select(_REPORT_SELECT)
            .eq("id", report_id)
            .eq("user_id", user["id"])
            .limit(1)
            .execute()
        )
    except Exception as exc:
        log.warning("recheck load failed: %r", exc)
        raise HTTPException(status_code=500, detail="Could not load report.") from exc

    rows = result.data or []
    if not rows:
        raise HTTPException(status_code=404, detail="Report not found.")

    row = rows[0]
    image_paths = owned_paths(row.get("image_paths"), user["id"])
    image_urls = _stored_image_urls(row)
    if not image_paths and not image_urls:
        raise HTTPException(
            status_code=409,
            detail=(
                "This check has no stored images for an API recheck. "
                "Open the listing and check it again from the extension or iOS app."
            ),
        )

    prior = row.get("report_json") or {}
    facts_data = prior.get("listing_facts") or {}
    try:
        facts = ListingFacts.model_validate(facts_data)
    except Exception:
        facts = ListingFacts()

    if image_paths:
        images = download_check_images(sb, image_paths)
        source = "storage"
    else:
        images = fetch_images(list(image_urls))
        source = "urls"
    if not images:
        return CheckResponse(
            listing_facts=ListingFacts(),
            error="Could not load the stored listing photos for a recheck.",
        )

    log.info("rechecking report=%s from %d %s image(s)", report_id, len(images), source)
    report = run_check(images, user_context=None, seeded_facts=facts)
    if report.error:
        log.warning("recheck returned error: %s", report.error)
        return CheckResponse(**report.model_dump())

    new_id = _save_report(
        user_id=user["id"],
        listing_url=row.get("listing_url") or "",
        listing_name=row.get("listing_name") or facts.model_or_name or facts.brand,
        report=report,
        marketplace=row.get("marketplace") or "depop",
        image_urls=list(image_urls),
        seller_username=row.get("seller_username"),
        seller_url=row.get("seller_url"),
        # The new row references the same stored objects as the original.
        image_paths=image_paths,
    )
    return CheckResponse(
        **report.model_dump(), report_id=new_id, images_stored=len(image_paths) if new_id else 0
    )


# ---------------------------------------------------------------------------
# Share links (owner creates/revokes; anyone with the token can read a
# sanitized copy). Tokens are 32 bytes of urlsafe randomness.
# ---------------------------------------------------------------------------

SHARE_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,64}$")
SHARE_RATE_LIMIT = int(os.environ.get("CLEARED_SHARE_RATE_LIMIT", "60"))  # req/window/IP
SHARE_RATE_WINDOW_SECONDS = 60.0

_share_hits: dict[str, deque] = {}
_share_lock = threading.Lock()


def _reset_share_rate_limit() -> None:
    """Test helper: clear the in-memory rate-limit buckets."""
    with _share_lock:
        _share_hits.clear()


def _client_key(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",")[0].strip() or "unknown"
    return request.client.host if request.client else "unknown"


def _share_rate_limited(key: str) -> bool:
    """Sliding-window limiter per client. In-memory: per-process, best-effort."""
    now = time.monotonic()
    with _share_lock:
        if len(_share_hits) > 10_000:  # bound memory under abuse
            _share_hits.clear()
        bucket = _share_hits.setdefault(key, deque())
        while bucket and now - bucket[0] > SHARE_RATE_WINDOW_SECONDS:
            bucket.popleft()
        if len(bucket) >= SHARE_RATE_LIMIT:
            return True
        bucket.append(now)
        return False


def _new_share_token() -> str:
    return secrets.token_urlsafe(32)  # 43 chars


def _share_payload(row: dict) -> dict:
    """Sanitized public projection of a report row.

    Excludes: user_id, notes, tags, hub_status, image_urls, share metadata, and
    the buyer's private context (verdict.user_context).
    """
    report = row.get("report_json") or {}
    verdict = dict(report.get("verdict") or {})
    verdict.pop("user_context", None)
    return {
        "listing_name": row.get("listing_name") or "",
        "listing_url": row.get("listing_url") or "",
        "marketplace": row.get("marketplace") or "depop",
        "verdict": row.get("verdict") or verdict.get("recommendation"),
        "checked_at": row.get("checked_at"),
        "seller_username": row.get("seller_username"),
        "report": {
            "listing_facts": report.get("listing_facts") or {},
            "price_read": report.get("price_read") or {},
            "listing_trust": report.get("listing_trust") or {},
            "auth_flag": report.get("auth_flag") or {},
            "verdict": verdict,
        },
    }


def _load_owned_report(sb, report_id: str, user_id: str, columns: str) -> dict:
    try:
        result = (
            sb.table("reports")
            .select(columns)
            .eq("id", report_id)
            .eq("user_id", user_id)
            .limit(1)
            .execute()
        )
    except Exception as exc:
        log.warning("owned report load failed: %r", exc)
        raise HTTPException(status_code=500, detail="Could not load report.") from exc
    rows = result.data or []
    if not rows:
        raise HTTPException(status_code=404, detail="Report not found.")
    return rows[0]


@app.post("/api/reports/{report_id}/share")
async def create_share(
    report_id: str,
    user: dict = Depends(get_current_user),
) -> dict:
    """Create (or return the existing) read-only share token for an owned report."""
    sb = get_supabase()
    if sb is None:
        raise HTTPException(status_code=503, detail="Supabase is not configured.")

    row = _load_owned_report(sb, report_id, user["id"], "id, share_token, shared_at")
    token = row.get("share_token")
    shared_at = row.get("shared_at")
    if not token:
        token = _new_share_token()
        try:
            result = (
                sb.table("reports")
                .update({
                    "share_token": token,
                    "shared_at": datetime.now(timezone.utc).isoformat(),
                })
                .eq("id", report_id)
                .eq("user_id", user["id"])
                .select("share_token, shared_at")
                .execute()
            )
        except Exception as exc:
            log.warning("share create failed: %r", exc)
            raise HTTPException(status_code=500, detail="Could not create share link.") from exc
        updated = (result.data or [{}])[0]
        shared_at = updated.get("shared_at")
    return {"token": token, "path": f"/r/{token}", "shared_at": shared_at}


@app.delete("/api/reports/{report_id}/share")
async def revoke_share(
    report_id: str,
    user: dict = Depends(get_current_user),
) -> dict:
    """Revoke the share link for an owned report. Idempotent."""
    sb = get_supabase()
    if sb is None:
        raise HTTPException(status_code=503, detail="Supabase is not configured.")

    _load_owned_report(sb, report_id, user["id"], "id")
    try:
        (
            sb.table("reports")
            .update({"share_token": None, "shared_at": None})
            .eq("id", report_id)
            .eq("user_id", user["id"])
            .execute()
        )
    except Exception as exc:
        log.warning("share revoke failed: %r", exc)
        raise HTTPException(status_code=500, detail="Could not revoke share link.") from exc
    return {"revoked": True}


_PUBLIC_HEADERS = {"Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow"}


@app.get("/api/shared/{token}")
async def get_shared_report(token: str, request: Request) -> JSONResponse:
    """Public, unauthenticated read of a shared report (sanitized).

    404 for malformed, unknown, or revoked tokens; 429 when a client exceeds the
    per-IP rate limit. CORS follows the global middleware like other endpoints.
    """
    if _share_rate_limited(_client_key(request)):
        return JSONResponse(
            {"detail": "Too many requests. Try again in a minute."},
            status_code=429,
            headers={**_PUBLIC_HEADERS, "Retry-After": "60"},
        )

    not_found = JSONResponse(
        {"detail": "This shared report doesn't exist or was revoked."},
        status_code=404,
        headers=_PUBLIC_HEADERS,
    )
    if not SHARE_TOKEN_RE.match(token or ""):
        return not_found

    sb = get_supabase()
    if sb is None:
        return not_found

    try:
        result = (
            sb.table("reports")
            .select(
                "listing_name, listing_url, marketplace, verdict, checked_at, "
                "report_json, seller_username, share_token"
            )
            .eq("share_token", token)
            .limit(1)
            .execute()
        )
    except Exception as exc:
        log.warning("shared report lookup failed: %r", exc)
        return not_found

    rows = result.data or []
    if not rows or rows[0].get("share_token") != token:
        return not_found
    return JSONResponse(_share_payload(rows[0]), headers=_PUBLIC_HEADERS)


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

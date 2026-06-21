"""Cleared backend — the thin proxy.

POST /check  (multipart: images[] + optional user_context) -> CheckReport

The input is listing SCREENSHOT(S), not a URL — Depop flat-edge-blocks every
server-side fetch (see claude.mds/phase-0.md). Vision reads the screenshots.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path

from dotenv import load_dotenv

# Load backend/.env.local so ANTHROPIC_API_KEY is picked up without exporting it.
load_dotenv(Path(__file__).resolve().parent.parent / ".env.local")

from fastapi import FastAPI, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from .claude_check import run_check
from .images import fetch_images
from .models import CheckListingRequest, CheckReport, ListingFacts

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("cleared")

app = FastAPI(title="Cleared", version="0.1.0")

# The Share Extension and local dev tools call this directly.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

_ALLOWED_IMAGE_TYPES = {"image/png", "image/jpeg", "image/webp", "image/gif"}


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.post("/check", response_model=CheckReport)
async def check(
    images: list[UploadFile] = [],
    user_context: str | None = Form(None),
) -> CheckReport:
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


@app.post("/check-listing", response_model=CheckReport)
async def check_listing(
    request: CheckListingRequest,
    x_cleared_token: str | None = Header(None, alias="X-Cleared-Token"),
) -> CheckReport:
    _require_token(x_cleared_token)

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
    return report


def _require_token(token: str | None) -> None:
    expected = os.environ.get("CLEARED_SHARED_TOKEN")
    if expected and token != expected:
        raise HTTPException(status_code=401, detail="Invalid Cleared token.")

"""Cleared backend — the thin proxy.

POST /check  (multipart: images[] + optional user_context) -> CheckReport

The input is listing SCREENSHOT(S), not a URL — Depop flat-edge-blocks every
server-side fetch (see claude.mds/phase-0.md). Vision reads the screenshots.
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from .claude_check import run_check
from .models import CheckReport, ListingFacts

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

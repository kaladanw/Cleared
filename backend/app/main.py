"""Cleared backend — the thin proxy.

POST /check { url, user_context? } -> CheckReport

Phase 0: fetch the Depop listing and return the extracted facts + photos.
Phase 1 will add the single Claude call that fills in price/trust/auth/verdict.
"""

from __future__ import annotations

import logging

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .depop import DepopFetchError, fetch_listing
from .models import CheckReport, CheckRequest

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


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.post("/check", response_model=CheckReport)
def check(req: CheckRequest) -> CheckReport:
    try:
        listing = fetch_listing(req.url)
    except DepopFetchError as exc:
        log.warning("extraction failed for %s: %s", req.url, exc)
        # A clean error state — the app renders this message verbatim.
        from .models import ListingFacts

        return CheckReport(listing_facts=ListingFacts(), error=str(exc))

    log.info(
        "extracted %d photos for %s (price=%s)",
        len(listing.image_urls),
        listing.facts.model_or_name,
        listing.facts.asking_price,
    )

    report = CheckReport(listing_facts=listing.facts)

    # --- Phase 1 slots in here -------------------------------------------------
    # report = run_claude_check(listing, user_context=req.user_context)
    # ---------------------------------------------------------------------------

    # Until the Claude call exists, expose the photos we found so Phase 0 is
    # verifiable end to end (they're not part of the final contract).
    report.listing_facts.photo_observations = [
        f"photo: {u}" for u in listing.image_urls
    ]
    return report

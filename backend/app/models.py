"""The report contract — the spine of the whole build.

`ListingFacts` is what Phase 0 extracts from the Depop page. The rest of the
report is filled in by Claude in Phase 1+. The app renders `CheckReport` as the
"care label" panel.
"""

from __future__ import annotations

import re
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field, field_validator

# Marketplace ids: lowercase slug, e.g. depop / vinted. Keeps the column
# forward-compatible without a schema change per marketplace.
MARKETPLACE_SLUG_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
DEFAULT_MARKETPLACE = "depop"


HUB_STATUSES = frozenset({"watching", "bought", "skipped", "sold_out"})
HUB_STATUS_NONE = "none"  # API/filter alias for unset (DB stores NULL)


def normalize_hub_status(value: str | None, *, allow_none_alias: bool = True) -> str | None:
    """Return a hub status or None (unset). Raises ValueError if invalid."""
    if value is None:
        return None
    raw = str(value).strip().lower()
    if raw == "" or (allow_none_alias and raw == HUB_STATUS_NONE):
        return None
    if raw not in HUB_STATUSES:
        raise ValueError(
            "status must be one of: watching, bought, skipped, sold_out, none"
        )
    return raw




def normalize_marketplace(value: str | None) -> str:
    """Return a validated marketplace slug, defaulting to depop."""
    slug = (value or DEFAULT_MARKETPLACE).strip().lower()
    if not MARKETPLACE_SLUG_RE.match(slug):
        raise ValueError(
            "marketplace must be a lowercase slug matching "
            f"{MARKETPLACE_SLUG_RE.pattern} (e.g. depop, vinted)"
        )
    return slug


class PriceFairness(str, Enum):
    steal = "steal"
    fair = "fair"
    high = "high"
    overpriced = "overpriced"


class Recommendation(str, Enum):
    buy = "buy"
    negotiate = "negotiate"
    skip = "skip"


class ListingFacts(BaseModel):
    """Read off the listing — by the extractor in Phase 0, refined by vision in Phase 1."""

    brand: Optional[str] = None
    model_or_name: Optional[str] = Field(None, description="e.g. 'Custom Fit polo'")
    category: Optional[str] = None
    size: Optional[str] = None
    listed_condition: Optional[str] = None
    asking_price: Optional[float] = None
    currency: str = "USD"
    photo_observations: list[str] = Field(
        default_factory=list, description="What vision actually saw in the photos"
    )


class PriceRead(BaseModel):
    retail_estimate: Optional[float] = None
    used_estimate_low: Optional[float] = None
    used_estimate_high: Optional[float] = None
    fairness: Optional[PriceFairness] = None
    suggested_offer_low: Optional[float] = None
    suggested_offer_high: Optional[float] = None
    reasoning: str = ""


class ListingTrust(BaseModel):
    missing_info: list[str] = Field(default_factory=list)
    concerns: list[str] = Field(default_factory=list)
    questions_to_ask: list[str] = Field(default_factory=list)


class AuthFlag(BaseModel):
    applicable: bool = False
    red_flags: list[str] = Field(default_factory=list)
    what_to_inspect: list[str] = Field(default_factory=list)
    confidence: Optional[str] = Field(None, description="low | medium | high")


class Verdict(BaseModel):
    recommendation: Optional[Recommendation] = None
    one_line: str = ""
    user_context: Optional[str] = Field(None, description="From the mic, if provided")


class CheckReport(BaseModel):
    listing_facts: ListingFacts
    price_read: PriceRead = Field(default_factory=PriceRead)
    listing_trust: ListingTrust = Field(default_factory=ListingTrust)
    auth_flag: AuthFlag = Field(default_factory=AuthFlag)
    verdict: Verdict = Field(default_factory=Verdict)
    error: Optional[str] = Field(
        None, description="Set when the listing could not be read; the rest is empty."
    )


class CheckRequest(BaseModel):
    url: str
    user_context: Optional[str] = Field(
        None, description="Transcribed voice note, e.g. 'it's a gift, must be legit'"
    )


class CheckListingRequest(BaseModel):
    facts: ListingFacts = Field(default_factory=ListingFacts)
    image_urls: list[str] = Field(default_factory=list)
    user_context: Optional[str] = Field(
        None, description="Transcribed voice note, e.g. 'it's a gift, must be legit'"
    )
    listing_url: Optional[str] = Field(
        None,
        description="The listing URL (window.location.href from the extension). "
        "Used to store and look up cached reports in Supabase.",
    )
    marketplace: str = Field(
        default=DEFAULT_MARKETPLACE,
        description="Source marketplace slug (depop now; vinted later). "
        "Must match ^[a-z][a-z0-9_-]{0,31}$.",
    )

    @field_validator("marketplace")
    @classmethod
    def _normalize_marketplace(cls, value: str) -> str:
        return normalize_marketplace(value)


class ReportHubUpdate(BaseModel):
    """Partial update for hub triage fields on an owned report."""

    status: Optional[str] = Field(
        None,
        description="watching | bought | skipped | sold_out | none (clears). "
        "Omit to leave unchanged.",
    )
    notes: Optional[str] = Field(
        None, description="Free-text notes. Omit to leave unchanged."
    )
    tags: Optional[list[str]] = Field(
        None, description="Replace tags list. Omit to leave unchanged."
    )

    @field_validator("status")
    @classmethod
    def _validate_status(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        # Preserve the literal "none" so the PATCH handler can clear the column.
        raw = str(value).strip().lower()
        if raw in ("", HUB_STATUS_NONE):
            return HUB_STATUS_NONE
        return normalize_hub_status(raw)

    @field_validator("tags")
    @classmethod
    def _normalize_tags(cls, value: Optional[list[str]]) -> Optional[list[str]]:
        if value is None:
            return None
        cleaned: list[str] = []
        seen: set[str] = set()
        for tag in value:
            t = " ".join(str(tag).split()).strip()
            if not t:
                continue
            key = t.lower()
            if key in seen:
                continue
            seen.add(key)
            cleaned.append(t[:40])
            if len(cleaned) >= 12:
                break
        return cleaned

    @field_validator("notes")
    @classmethod
    def _clamp_notes(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        return str(value)[:4000]


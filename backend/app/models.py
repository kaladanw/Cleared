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


class CheckResponse(CheckReport):
    """CheckReport plus additive fields for /check and /check-listing.

    Purely additive so older clients that decode CheckReport keep working.
    """

    report_id: Optional[str] = Field(
        None,
        description="ID of the saved row in reports (GET /api/reports). Null when "
        "the check was not saved: shared-secret /check, error reports, or a save failure.",
    )
    images_stored: int = Field(
        0,
        description="Screenshots persisted to private storage for this report "
        "(authenticated /check only). >0 means POST /api/reports/{id}/recheck works.",
    )


class RefreshRequest(BaseModel):
    refresh_token: str = Field(..., min_length=1, max_length=4096)


def normalize_listing_url(value: str | None) -> str | None:
    """Optional listing URL from a multipart form: http(s), ≤2048 chars, or None.

    Raises ValueError for anything else (→ 422).
    """
    if value is None:
        return None
    url = str(value).strip()
    if not url:
        return None
    if len(url) > 2048 or not re.match(r"^https?://[^\s\"'<>]+$", url, re.IGNORECASE):
        raise ValueError("listing_url must be an http(s) URL of at most 2048 characters.")
    return url


class CheckRequest(BaseModel):
    url: str
    user_context: Optional[str] = Field(
        None, description="Transcribed voice note, e.g. 'it's a gift, must be legit'"
    )


SELLER_USERNAME_RE = re.compile(r"^[a-z0-9._-]{1,64}$")


def normalize_seller_username(value: str | None) -> str | None:
    """Lowercase, strip a leading @, and validate. Returns None when unusable."""
    if value is None:
        return None
    raw = str(value).strip().lstrip("@").strip().lower()
    if not raw or not SELLER_USERNAME_RE.match(raw):
        return None
    return raw


class SellerInfo(BaseModel):
    """Seller identity read off the listing page by the extension (best-effort)."""

    username: Optional[str] = None
    profile_url: Optional[str] = None

    @field_validator("username", mode="before")
    @classmethod
    def _username(cls, value) -> Optional[str]:
        if value is None or isinstance(value, bool) or not isinstance(value, (str, int)):
            return None
        return normalize_seller_username(str(value))

    @field_validator("profile_url", mode="before")
    @classmethod
    def _profile_url(cls, value) -> Optional[str]:
        if not value or not isinstance(value, str):
            return None
        url = str(value).strip()
        if len(url) > 300 or not re.match(r"^https?://[^\s\"'<>]+$", url):
            return None
        return url


LISTING_DESCRIPTION_MAX = 5000


def normalize_listing_description(value) -> Optional[str]:
    """Trim; blank/whitespace-only or non-string → None; truncate to 5000 chars."""
    if value is None or not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    return text[:LISTING_DESCRIPTION_MAX].rstrip()


class CheckListingRequest(BaseModel):
    facts: ListingFacts = Field(default_factory=ListingFacts)
    description: Optional[str] = Field(
        None,
        description="Seller's full listing description (top level, next to facts). "
        "Trimmed; blank → absent; truncated to 5000 chars (never a 422). Passed to "
        "the model for measurements/flaws; never returned by /api/shared.",
    )
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

    seller: Optional[SellerInfo] = Field(
        None,
        description="Seller identity from the listing page ({username, profile_url}); "
        "null when the extractor could not find it.",
    )

    @field_validator("marketplace")
    @classmethod
    def _normalize_marketplace(cls, value: str) -> str:
        return normalize_marketplace(value)

    @field_validator("description", mode="before")
    @classmethod
    def _normalize_description(cls, value) -> Optional[str]:
        return normalize_listing_description(value)

    @field_validator("seller", mode="before")
    @classmethod
    def _lenient_seller(cls, value):
        """Seller is best-effort: a bare username string is accepted, and any
        other unusable shape becomes null instead of failing the check."""
        if value is None:
            return None
        if isinstance(value, str):
            return {"username": value}
        if isinstance(value, dict):
            return value
        return None


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


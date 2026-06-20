"""The report contract — the spine of the whole build.

`ListingFacts` is what Phase 0 extracts from the Depop page. The rest of the
report is filled in by Claude in Phase 1+. The app renders `CheckReport` as the
"care label" panel.
"""

from __future__ import annotations

from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


class Fairness(str, Enum):
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
    fairness: Optional[Fairness] = None
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

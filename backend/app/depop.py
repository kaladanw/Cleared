"""Fetch a public Depop listing and pull out the photos + facts.

This is the one fragile piece of the build: Depop is a Next.js app that embeds
the full product record in the page (the `__NEXT_DATA__` script), and the same
data backs the internal product endpoint the page calls. We parse that blob.

Because Depop can change the page shape at any time, this is written
defensively — it locates the product object by *shape* (a dict carrying
pictures + price) rather than a hardcoded path, and falls back to OpenGraph
meta tags for a degraded (single-photo) result. If both fail we raise a clear
error that the app surfaces verbatim.

VERIFY against a live listing in Phase 0 — the `pictures` / `price` field names
below are the most likely shape, not a confirmed one.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field

import httpx

from .models import ListingFacts

_BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

_NEXT_DATA_RE = re.compile(
    r'<script[^>]+id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.DOTALL
)
_IMG_URL_RE = re.compile(r'https?://[^\s"\'<>]+?\.(?:jpe?g|png|webp)', re.IGNORECASE)
_OG_RE = re.compile(
    r'<meta[^>]+(?:property|name)="(og:[^"]+|product:[^"]+)"[^>]+content="([^"]*)"',
    re.IGNORECASE,
)


class DepopFetchError(Exception):
    """Raised when a listing can't be fetched or parsed. Message is user-facing."""


@dataclass
class ExtractedListing:
    facts: ListingFacts
    image_urls: list[str] = field(default_factory=list)
    description: str = ""


def fetch_listing(url: str, timeout: float = 15.0) -> ExtractedListing:
    """Fetch and parse a Depop product URL. Raises DepopFetchError on failure."""
    if "depop.com" not in url:
        raise DepopFetchError("That doesn't look like a Depop link.")

    try:
        resp = httpx.get(
            url, headers=_BROWSER_HEADERS, timeout=timeout, follow_redirects=True
        )
        resp.raise_for_status()
    except httpx.HTTPError as exc:  # network error, 403/blocked, timeout, etc.
        raise DepopFetchError(
            "Couldn't reach this listing — Depop may have blocked the request. "
            "Try again in a moment."
        ) from exc

    html = resp.text

    product = _find_product_object(html)
    if product is not None:
        listing = _from_product_object(product)
        if listing.image_urls:
            return listing

    # Degraded fallback: OpenGraph tags give us the cover image + title + price.
    listing = _from_opengraph(html)
    if listing.image_urls:
        return listing

    raise DepopFetchError(
        "Couldn't read this listing — Depop may have changed its page format."
    )


def _find_product_object(html: str) -> dict | None:
    """Pull __NEXT_DATA__ and recursively find the dict that looks like a product."""
    match = _NEXT_DATA_RE.search(html)
    if not match:
        return None
    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError:
        return None

    best: dict | None = None
    for node in _walk_dicts(data):
        # A product node carries pictures and a price; prefer the richest match.
        has_pics = "pictures" in node or "images" in node
        has_price = any(k in node for k in ("price", "priceAmount", "price_amount"))
        if has_pics and has_price:
            if best is None or len(node) > len(best):
                best = node
    return best


def _walk_dicts(obj):
    if isinstance(obj, dict):
        yield obj
        for v in obj.values():
            yield from _walk_dicts(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk_dicts(v)


def _from_product_object(product: dict) -> ExtractedListing:
    pictures = product.get("pictures") or product.get("images") or []
    image_urls = _best_image_per_picture(pictures)

    price_raw = (
        product.get("price")
        or product.get("priceAmount")
        or product.get("price_amount")
    )
    asking_price, currency = _parse_price(price_raw, product)

    facts = ListingFacts(
        brand=_first_str(product, "brandName", "brand"),
        model_or_name=_first_str(product, "title", "name", "description"),
        category=_first_str(product, "categoryName", "category"),
        size=_first_str(product, "size", "variantSize"),
        listed_condition=_first_str(product, "condition", "conditionName"),
        asking_price=asking_price,
        currency=currency or "USD",
    )
    return ExtractedListing(
        facts=facts,
        image_urls=image_urls,
        description=_first_str(product, "description", "title") or "",
    )


def _best_image_per_picture(pictures) -> list[str]:
    """Each Depop picture comes in several sizes; take the largest URL per photo."""
    urls: list[str] = []
    for pic in pictures if isinstance(pictures, list) else []:
        candidates = _IMG_URL_RE.findall(json.dumps(pic))
        if not candidates:
            continue
        # Heuristic: the longest URL tends to be the highest-resolution variant.
        urls.append(max(candidates, key=len))
    # Dedupe, preserve order, cap at a sane number of photos.
    seen: set[str] = set()
    deduped = [u for u in urls if not (u in seen or seen.add(u))]
    return deduped[:8]


def _parse_price(price_raw, product: dict) -> tuple[float | None, str | None]:
    currency = product.get("currencyName") or product.get("currency")
    if isinstance(price_raw, dict):
        currency = currency or price_raw.get("currencyName") or price_raw.get("currency")
        price_raw = (
            price_raw.get("priceAmount")
            or price_raw.get("amount")
            or price_raw.get("nationalShippingCost")
        )
    try:
        return (float(price_raw), currency) if price_raw is not None else (None, currency)
    except (TypeError, ValueError):
        return None, currency


def _from_opengraph(html: str) -> ExtractedListing:
    tags = {key.lower(): val for key, val in _OG_RE.findall(html)}
    image = tags.get("og:image")
    price = tags.get("product:price:amount")
    try:
        asking = float(price) if price else None
    except ValueError:
        asking = None

    facts = ListingFacts(
        model_or_name=tags.get("og:title"),
        asking_price=asking,
        currency=tags.get("product:price:currency") or "USD",
    )
    return ExtractedListing(
        facts=facts,
        image_urls=[image] if image else [],
        description=tags.get("og:description", ""),
    )


def _first_str(d: dict, *keys: str) -> str | None:
    for k in keys:
        v = d.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return None

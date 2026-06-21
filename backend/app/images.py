"""Fetch listing photos supplied by the browser extension."""

from __future__ import annotations

from pathlib import PurePosixPath
from urllib.parse import urlparse

import httpx

_BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ),
    "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}

_ALLOWED_IMAGE_TYPES = {"image/png", "image/jpeg", "image/webp", "image/gif"}
_EXTENSION_TYPES = {
    ".gif": "image/gif",
    ".jpeg": "image/jpeg",
    ".jpg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
}


def fetch_images(
    urls: list[str],
    *,
    max_images: int = 8,
    per_image_cap: int = 10_000_000,
    timeout: float = 15.0,
) -> list[tuple[bytes, str]]:
    """Download extension-supplied image URLs.

    Per-image failures are skipped. The caller decides whether an empty result is
    recoverable or should become a user-facing `CheckReport.error`.
    """
    images: list[tuple[bytes, str]] = []
    for url in urls[:max_images]:
        try:
            resp = httpx.get(
                url,
                headers=_BROWSER_HEADERS,
                timeout=timeout,
                follow_redirects=True,
            )
        except httpx.HTTPError:
            continue

        if resp.status_code != 200:
            continue

        data = resp.content
        if len(data) > per_image_cap:
            continue

        media_type = _media_type_for(resp, url)
        if media_type is None:
            continue

        images.append((data, media_type))
    return images


def _media_type_for(resp: httpx.Response, url: str) -> str | None:
    content_type = resp.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if content_type in _ALLOWED_IMAGE_TYPES:
        return content_type

    extension_type = _media_type_from_url(url)
    if extension_type:
        return extension_type

    if content_type and not content_type.startswith("image/"):
        return None

    return "image/jpeg"


def _media_type_from_url(url: str) -> str | None:
    suffix = PurePosixPath(urlparse(url).path).suffix.lower()
    return _EXTENSION_TYPES.get(suffix)

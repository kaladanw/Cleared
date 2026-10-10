"""Fetch listing photos from client-supplied URLs, safely.

Used by /check-listing (extension + iOS link share) and by recheck's
``image_urls`` fallback. Client-supplied URLs are an SSRF vector, so every
request (and every redirect hop) must pass:

* scheme ``http``/``https``, no userinfo, port 80/443 (or default);
* host on the image-CDN allowlist (``CLEARED_IMAGE_HOSTS``; default
  ``media-photos.depop.com``; ``*.example.net`` entries match subdomains);
* every resolved IP is public: private, loopback, link-local, multicast,
  reserved, unspecified, CGNAT, and IPv4-mapped equivalents are refused.

Redirects are followed manually (max 3) and re-validated. Bodies are streamed
with a hard size cap. Per-image failures are skipped, never raised.
"""

from __future__ import annotations

import ipaddress
import logging
import os
import socket
from pathlib import PurePosixPath
from urllib.parse import urljoin, urlsplit

import httpx

from .check_images import MAX_IMAGE_BYTES, MAX_IMAGES, sniff_image_type

log = logging.getLogger("cleared")

DEFAULT_IMAGE_HOSTS = "media-photos.depop.com"
MAX_REDIRECTS = 3
_REDIRECT_CODES = {301, 302, 303, 307, 308}

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


class BlockedURL(ValueError):
    """URL refused by the SSRF guard."""


def allowed_image_hosts() -> list[str]:
    raw = os.environ.get("CLEARED_IMAGE_HOSTS", "").strip() or DEFAULT_IMAGE_HOSTS
    return [h.strip().lower().rstrip(".") for h in raw.split(",") if h.strip()]


def host_allowed(host: str, allowlist: list[str]) -> bool:
    host = (host or "").lower().rstrip(".")
    for entry in allowlist:
        if entry.startswith("*."):
            suffix = entry[1:]  # ".example.net"
            if host.endswith(suffix) and len(host) > len(suffix):
                return True
        elif host == entry:
            return True
    return False


def ip_is_public(addr: str) -> bool:
    try:
        ip = ipaddress.ip_address(addr.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    if (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    ):
        return False
    if isinstance(ip, ipaddress.IPv4Address) and ip in ipaddress.ip_network("100.64.0.0/10"):
        return False  # CGNAT
    return ip.is_global


def _default_resolver(host: str, port: int) -> list[str]:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    return [info[4][0] for info in infos]


def check_url(url: str, *, allowlist: list[str], resolver=_default_resolver) -> None:
    """Raise BlockedURL unless ``url`` is safe to fetch."""
    try:
        parts = urlsplit(url)
    except ValueError as exc:
        raise BlockedURL("unparseable URL") from exc
    scheme = (parts.scheme or "").lower()
    if scheme not in ("http", "https"):
        raise BlockedURL("scheme not allowed")
    if parts.username is not None or parts.password is not None:
        raise BlockedURL("userinfo not allowed")
    host = (parts.hostname or "").lower()
    if not host:
        raise BlockedURL("missing host")
    try:
        port = parts.port
    except ValueError as exc:
        raise BlockedURL("bad port") from exc
    if port not in (None, 80, 443):
        raise BlockedURL("port not allowed")
    if not host_allowed(host, allowlist):
        raise BlockedURL(f"host not on image allowlist: {host}")
    try:
        addrs = resolver(host, port or (443 if scheme == "https" else 80))
    except OSError as exc:
        raise BlockedURL("DNS resolution failed") from exc
    if not addrs or not all(ip_is_public(a) for a in addrs):
        raise BlockedURL("host resolves to a non-public address")


def _fetch_one(client: httpx.Client, url: str, *, cap: int, allowlist, resolver):
    """Return (bytes, response headers, final_url) or None."""
    for _hop in range(MAX_REDIRECTS + 1):
        check_url(url, allowlist=allowlist, resolver=resolver)
        with client.stream("GET", url, headers=_BROWSER_HEADERS) as resp:
            if resp.status_code in _REDIRECT_CODES:
                location = resp.headers.get("location")
                if not location:
                    return None
                url = urljoin(url, location)
                continue
            if resp.status_code != 200:
                return None
            declared = resp.headers.get("content-length")
            if declared and declared.isdigit() and int(declared) > cap:
                return None
            buf = bytearray()
            for chunk in resp.iter_bytes():
                buf.extend(chunk)
                if len(buf) > cap:
                    return None
            return bytes(buf), resp.headers, url
    return None  # too many redirects


def fetch_images(
    urls: list[str],
    *,
    max_images: int = MAX_IMAGES,
    per_image_cap: int = MAX_IMAGE_BYTES,
    timeout: float = 10.0,
    client: httpx.Client | None = None,
    resolver=_default_resolver,
    allowlist: list[str] | None = None,
) -> list[tuple[bytes, str]]:
    """Download client-supplied image URLs through the SSRF guard.

    Per-image failures (blocked, non-200, oversize, non-image) are skipped. The
    caller decides whether an empty result is recoverable.
    """
    allow = allowlist if allowlist is not None else allowed_image_hosts()
    own_client = client is None
    if own_client:
        client = httpx.Client(
            timeout=httpx.Timeout(timeout, connect=min(5.0, timeout)),
            follow_redirects=False,
        )
    images: list[tuple[bytes, str]] = []
    try:
        for url in list(urls or [])[:max_images]:
            if not isinstance(url, str):
                continue
            try:
                fetched = _fetch_one(client, url, cap=per_image_cap, allowlist=allow, resolver=resolver)
            except BlockedURL as exc:
                log.warning("image fetch blocked url=%.120s: %s", url, exc)
                continue
            except httpx.HTTPError as exc:
                log.info("image fetch failed url=%.120s: %r", url, exc)
                continue
            if fetched is None:
                continue
            data, headers, final_url = fetched
            media_type = _media_type_for(data, headers, final_url)
            if media_type is None:
                continue
            images.append((data, media_type))
    finally:
        if own_client:
            client.close()
    return images


def _media_type_for(data: bytes, headers, url: str) -> str | None:
    sniffed = sniff_image_type(data)
    if sniffed:
        return sniffed
    content_type = headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if content_type in _ALLOWED_IMAGE_TYPES:
        return content_type

    extension_type = _media_type_from_url(url)
    if extension_type:
        return extension_type

    if content_type and not content_type.startswith("image/"):
        return None

    return "image/jpeg"


def _media_type_from_url(url: str) -> str | None:
    suffix = PurePosixPath(urlsplit(url).path).suffix.lower()
    return _EXTENSION_TYPES.get(suffix)

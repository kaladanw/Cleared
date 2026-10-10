"""Screenshot validation + private Supabase Storage for authenticated /check.

Objects live in a PRIVATE bucket (default ``check-images``) at
``{user_id}/{report_id}/{n}.{ext}`` and are referenced from
``reports.image_paths``. The backend reads/writes them with the service-role
client; nothing here is ever exposed on the public share endpoint.
"""

from __future__ import annotations

import logging
import os
import re

log = logging.getLogger("cleared")

IMAGE_BUCKET = os.environ.get("CLEARED_IMAGE_BUCKET", "check-images").strip() or "check-images"
MAX_IMAGES = 8
MAX_IMAGE_BYTES = int(os.environ.get("CLEARED_MAX_IMAGE_BYTES", str(10 * 1024 * 1024)))

_EXT_FOR_TYPE = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "image/gif": "gif",
}
_TYPE_FOR_EXT = {ext: mime for mime, ext in _EXT_FOR_TYPE.items()}

_UUIDISH = r"[0-9a-fA-F-]{8,64}"
_PATH_RE = re.compile(rf"^({_UUIDISH})/({_UUIDISH})/(\d{{1,2}})\.(jpg|png|webp|gif)$")


class ImageRejected(Exception):
    """Raised for an unusable upload; ``status`` is the HTTP code to return."""

    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def sniff_image_type(data: bytes) -> str | None:
    """Content type from magic bytes (don't trust the client's declared type)."""
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


async def read_uploads(files) -> list[tuple[bytes, str]]:
    """Read multipart ``images`` with limits: ≤8 files, ≤MAX_IMAGE_BYTES each,
    JPEG/PNG/WebP/GIF only (by magic bytes). Empty parts are skipped.

    Raises ImageRejected(400|413|415).
    """
    files = [f for f in (files or []) if f is not None]
    if len(files) > MAX_IMAGES:
        raise ImageRejected(400, f"Too many images: send at most {MAX_IMAGES}.")
    loaded: list[tuple[bytes, str]] = []
    for f in files:
        data = await f.read(MAX_IMAGE_BYTES + 1)
        if not data:
            continue
        if len(data) > MAX_IMAGE_BYTES:
            raise ImageRejected(
                413, f"Image too large: each image must be at most {MAX_IMAGE_BYTES // (1024 * 1024)} MB."
            )
        media_type = sniff_image_type(data)
        if media_type is None:
            raise ImageRejected(415, "Unsupported image type: send JPEG, PNG, WebP, or GIF.")
        loaded.append((data, media_type))
    return loaded


def object_path(user_id: str, report_id: str, index: int, media_type: str) -> str:
    return f"{user_id}/{report_id}/{index}.{_EXT_FOR_TYPE.get(media_type, 'jpg')}"


def upload_check_images(sb, user_id: str, report_id: str, images: list[tuple[bytes, str]]) -> list[str]:
    """Best-effort upload. Returns the paths that were stored (possibly empty).

    Never raises: a storage failure must not fail the check.
    """
    if sb is None or not images:
        return []
    try:
        bucket = sb.storage.from_(IMAGE_BUCKET)
    except Exception as exc:
        log.warning("image storage unavailable (non-fatal): %r", exc)
        return []
    stored: list[str] = []
    for index, (data, media_type) in enumerate(images[:MAX_IMAGES]):
        path = object_path(user_id, report_id, index, media_type)
        try:
            bucket.upload(
                path,
                data,
                {"content-type": media_type, "x-upsert": "false", "cache-control": "3600"},
            )
            stored.append(path)
        except Exception as exc:
            log.warning("image upload failed (non-fatal) path=%s: %r", path, exc)
    return stored


def remove_check_images(sb, paths: list[str]) -> None:
    if sb is None or not paths:
        return
    try:
        sb.storage.from_(IMAGE_BUCKET).remove(list(paths))
    except Exception as exc:
        log.warning("image cleanup failed (non-fatal): %r", exc)


def owned_paths(paths, user_id: str) -> list[str]:
    """Keep only well-formed paths inside ``{user_id}/`` (defense in depth)."""
    if not isinstance(paths, list):
        return []
    out: list[str] = []
    for p in paths[:MAX_IMAGES]:
        m = _PATH_RE.match(p) if isinstance(p, str) else None
        if m and m.group(1) == user_id:
            out.append(p)
    return out


def download_check_images(sb, paths: list[str]) -> list[tuple[bytes, str]]:
    """Read stored screenshots back as (bytes, media_type) for a recheck.

    The service role downloads directly, so no URL (signed or otherwise) ever
    leaves the backend. Per-object failures are skipped.
    """
    if sb is None or not paths:
        return []
    try:
        bucket = sb.storage.from_(IMAGE_BUCKET)
    except Exception as exc:
        log.warning("image storage unavailable: %r", exc)
        return []
    images: list[tuple[bytes, str]] = []
    for path in paths:
        try:
            data = bucket.download(path)
        except Exception as exc:
            log.warning("image download failed path=%s: %r", path, exc)
            continue
        if not data:
            continue
        media_type = sniff_image_type(data) or _TYPE_FOR_EXT.get(path.rsplit(".", 1)[-1], "image/jpeg")
        images.append((data, media_type))
    return images

"""Supabase client — lazily initialized, cached.

Uses the service-role key so server-side writes bypass RLS. JWT verification
for incoming requests uses the same client (Supabase validates the JWT
against the project's own auth service).
"""

from __future__ import annotations

import logging
import os
from functools import lru_cache
from typing import Optional

log = logging.getLogger("cleared")


@lru_cache(maxsize=1)
def get_supabase():
    """Return a Supabase Client using the service key, or None if not configured.

    Cached after the first call — the client is thread-safe and holds a single
    HTTP session. Returns None when env vars are absent so callers can degrade
    gracefully rather than crashing at import time.
    """
    url = os.environ.get("SUPABASE_URL", "").strip()
    key = os.environ.get("SUPABASE_SERVICE_KEY", "").strip()
    if not url or not key:
        log.warning(
            "SUPABASE_URL or SUPABASE_SERVICE_KEY not set; "
            "auth and history features are disabled"
        )
        return None
    try:
        from supabase import create_client  # type: ignore[import]
        return create_client(url, key)
    except ImportError:
        log.warning("supabase package not installed; run: pip install supabase>=2.0")
        return None


def require_supabase():
    """Return the Supabase client or raise RuntimeError — for use in HTTP handlers."""
    client = get_supabase()
    if client is None:
        raise RuntimeError(
            "Supabase is not configured. "
            "Set SUPABASE_URL and SUPABASE_SERVICE_KEY in .env.local."
        )
    return client

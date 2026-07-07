"""Auth helpers: Supabase signup/login + FastAPI JWT-verification dependency.

Invite-only by default: CLEARED_ALLOWED_EMAILS (comma-separated) gates signup.
Leave the env var unset in dev to allow any email.
"""

from __future__ import annotations

import logging
import os

from fastapi import Depends, Header, HTTPException

from .supabase_client import require_supabase

log = logging.getLogger("cleared")


# ---------------------------------------------------------------------------
# Allowlist guard
# ---------------------------------------------------------------------------

def _check_allowlist(email: str) -> None:
    """Raise 403 if the email is not in CLEARED_ALLOWED_EMAILS.

    When the env var is empty/unset, the allowlist is disabled (open signup).
    Set it to a comma-separated list of your own email(s) in production.
    """
    raw = os.environ.get("CLEARED_ALLOWED_EMAILS", "").strip()
    if not raw:
        return  # Open mode — allow all (intended for local dev only)
    allowed = {e.strip().lower() for e in raw.split(",") if e.strip()}
    if email.lower() not in allowed:
        raise HTTPException(
            status_code=403,
            detail="Signup is not open for this email address.",
        )


# ---------------------------------------------------------------------------
# Auth actions
# ---------------------------------------------------------------------------

async def signup(email: str, password: str) -> dict:
    """Create a new Supabase Auth user. Returns { access_token, user }."""
    _check_allowlist(email)
    sb = require_supabase()
    try:
        resp = sb.auth.sign_up({"email": email, "password": password})
    except Exception as exc:
        log.error("Supabase signup error: %r", exc)
        raise HTTPException(status_code=400, detail=f"Signup failed: {exc}")

    if not resp.user:
        raise HTTPException(status_code=400, detail="Signup failed — no user returned.")

    return {
        "access_token": resp.session.access_token if resp.session else None,
        "user": {"id": str(resp.user.id), "email": resp.user.email},
    }


async def login(email: str, password: str) -> dict:
    """Sign in with email + password. Returns { access_token, user }."""
    sb = require_supabase()
    try:
        resp = sb.auth.sign_in_with_password({"email": email, "password": password})
    except Exception as exc:
        log.error("Supabase login error: %r", exc)
        raise HTTPException(status_code=401, detail="Invalid email or password.")

    if not resp.session:
        raise HTTPException(status_code=401, detail="Login failed — no session returned.")

    return {
        "access_token": resp.session.access_token,
        "user": {"id": str(resp.user.id), "email": resp.user.email},
    }


# ---------------------------------------------------------------------------
# FastAPI dependency — JWT verification
# ---------------------------------------------------------------------------

async def get_current_user(
    authorization: str | None = Header(None),
) -> dict:
    """Verify the Bearer JWT and return the user dict { id, email }.

    Apply as a FastAPI dependency to any endpoint that requires auth:

        @app.get("/my-endpoint")
        async def handler(user: dict = Depends(get_current_user)):
            ...
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="Missing Authorization header. Expected: Authorization: Bearer <token>",
        )

    token = authorization[len("Bearer "):]

    try:
        sb = require_supabase()
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc))

    try:
        resp = sb.auth.get_user(token)
    except Exception as exc:
        log.warning("JWT verification failed: %r", exc)
        raise HTTPException(status_code=401, detail="Invalid or expired token.")

    if not resp.user:
        raise HTTPException(status_code=401, detail="Token is invalid.")

    return {"id": str(resp.user.id), "email": resp.user.email}

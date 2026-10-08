"""Auth helpers: Supabase signup/login + FastAPI JWT-verification dependency.

Invite-only by default: CLEARED_ALLOWED_EMAILS (comma-separated) gates signup.
Leave the env var unset in dev to allow any email.
"""

from __future__ import annotations

import logging
import os

import httpx

from fastapi import Depends, Header, HTTPException

from .supabase_client import new_auth_client, require_supabase

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
# All user-auth calls run on a throwaway client (see new_auth_client) so the
# cached service-role client never picks up a user's session.

def _auth_client():
    try:
        return new_auth_client()
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc))


def _session_payload(session, user) -> dict:
    """Session shape shared by /auth/login, /auth/signup and /auth/refresh.

    ``access_token`` and ``user`` are the original fields (unchanged); the rest
    are additive. When signup requires email confirmation there is no session,
    so the token fields are null.
    """
    return {
        "access_token": session.access_token if session else None,
        "refresh_token": session.refresh_token if session else None,
        "expires_in": session.expires_in if session else None,
        "expires_at": session.expires_at if session else None,
        "token_type": (session.token_type if session else None) or ("bearer" if session else None),
        "user": {"id": str(user.id), "email": user.email} if user else None,
    }


def _is_retryable_auth_error(exc: Exception) -> bool:
    """Network / 5xx failures talking to Supabase Auth — not the user's fault."""
    try:
        from supabase_auth.errors import AuthApiError, AuthRetryableError, AuthUnknownError
    except ImportError:  # pragma: no cover
        return False
    if isinstance(exc, (AuthRetryableError, AuthUnknownError)):
        return True
    if isinstance(exc, AuthApiError):
        return (getattr(exc, "status", 0) or 0) >= 500
    return isinstance(exc, httpx.TransportError)


async def signup(email: str, password: str) -> dict:
    """Create a new Supabase Auth user. Returns the session payload."""
    _check_allowlist(email)
    sb = _auth_client()
    try:
        resp = sb.auth.sign_up({"email": email, "password": password})
    except Exception as exc:
        log.error("Supabase signup error: %r", exc)
        if _is_retryable_auth_error(exc):
            raise HTTPException(status_code=503, detail="Auth service unavailable. Try again.")
        raise HTTPException(status_code=400, detail=f"Signup failed: {exc}")

    if not resp.user:
        raise HTTPException(status_code=400, detail="Signup failed — no user returned.")

    return _session_payload(resp.session, resp.user)


async def login(email: str, password: str) -> dict:
    """Sign in with email + password. Returns the session payload."""
    sb = _auth_client()
    try:
        resp = sb.auth.sign_in_with_password({"email": email, "password": password})
    except Exception as exc:
        log.error("Supabase login error: %r", exc)
        if _is_retryable_auth_error(exc):
            raise HTTPException(status_code=503, detail="Auth service unavailable. Try again.")
        raise HTTPException(status_code=401, detail="Invalid email or password.")

    if not resp.session:
        raise HTTPException(status_code=401, detail="Login failed — no session returned.")

    return _session_payload(resp.session, resp.user)


async def refresh(refresh_token: str) -> dict:
    """Exchange a refresh token for a new session (Supabase rotates the token).

    401 when the refresh token is invalid, expired, revoked, or already used;
    503 when Supabase Auth is unreachable (clients should retry, not log out).
    """
    sb = _auth_client()
    try:
        resp = sb.auth.refresh_session(refresh_token)
    except Exception as exc:
        if _is_retryable_auth_error(exc):
            log.warning("Supabase refresh unavailable: %r", exc)
            raise HTTPException(status_code=503, detail="Auth service unavailable. Try again.")
        log.info("Supabase refresh rejected: %r", exc)
        raise HTTPException(status_code=401, detail="Invalid or expired refresh token.")

    if not resp.session:
        raise HTTPException(status_code=401, detail="Invalid or expired refresh token.")

    return _session_payload(resp.session, resp.user or resp.session.user)


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

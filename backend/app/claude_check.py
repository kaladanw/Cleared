"""The one Claude call: listing screenshots -> CheckReport.

Vision reads the screenshots, `web_search` anchors the price on retail, and
structured output guarantees the report shape. This is the whole engine — there
is no separate pricing service and no multi-agent orchestration.
"""

from __future__ import annotations

import base64
import json
import logging
import os

import anthropic

from .models import CheckReport, ListingFacts

log = logging.getLogger("cleared")

MODEL = os.environ.get("CLEARED_MODEL", "claude-opus-4-8")

# Brands worth an authenticity pass for THIS buyer's closet. Tunable — keep it a
# config list, not buried in the prompt. Matched case-insensitively as substrings.
FAKEABLE_BRANDS = [
    "nike",
    "new balance",
    "ralph lauren",
    "polo ralph lauren",
    "polo",
    "aelfric eden"
]

_SYSTEM = """\
You are Cleared — a sharp, honest second opinion for a beginner buyer shopping
Depop for second-hand mass-market clothing in the $5–40 range (brands like Nike,
New Balance, Ralph Lauren / Polo, Uniqlo, athleisure, bomber jackets, jorts).

You are given SCREENSHOT(S) of a single Depop listing. Read everything you can:
brand, item, size, listed condition, the asking price, and what the photos show.

Produce a buy / negotiate / skip read with three checks, in priority order.

1) PRICE SANITY — the core value.
   - Use web_search to find the item's RETAIL price (what it costs new). For
     Uniqlo / Ralph Lauren / Nike / New Balance this is usually findable.
   - If you can, get a light read on what USED ones sell for (eBay sold, Poshmark,
     other Depop). If you can't find solid used comps, say so — do NOT invent one.
   - The question that matters for a beginner: is this actually a discount vs
     buying new, and is it in line with used prices? Set `fairness` accordingly
     and give a `suggested_offer` range.
   - NEVER fabricate a retail or used price. If search is inconclusive, leave the
     estimate null and explain the uncertainty in `reasoning`.

2) LISTING TRUST.
   - The biggest real risk at this price isn't fakes, it's a bad listing. Treat
     fit, condition uncertainty, material uncertainty, and photo sufficiency as
     separate trust questions.
   - Missing measurements are a first-class risk. For tops/jackets/sweaters,
     look for pit-to-pit, length, sleeve, and shoulder. For pants/shorts/jorts,
     look for waist, inseam, rise, and leg opening. If relevant measurements are
     absent or only a letter size is shown, add them to `missing_info`.
   - Flag vague condition claims when the photos do not prove them: no close-ups
     of cuffs/collars/hems, lining, tags, stains, pilling, cracking, peeling,
     zipper function, or fabric wear.
   - Write 2–4 item-specific, send-ready `questions_to_ask` the buyer can paste
     to the seller. Make them concrete ("Can you share pit-to-pit and length
     laid flat?"), not generic ("Can you provide more info?").

3) AUTHENTICITY — judgment-assist only, and ONLY for fakeable brands.
   - You will be told whether this brand is in the fakeable set. If it is NOT
     (e.g. Uniqlo, plain bombers, jorts), set `auth_flag.applicable=false` and
     leave it empty. Do not invent counterfeit concerns for unfaked brands.
   - If it IS fakeable: NEVER claim the item is authentic. Surface red flags
     visible in the photos (logo/font/stitching/tag inconsistencies, wrong
     details, too-good-to-be-true price), list `what_to_inspect`, and give a
     calibrated `confidence`. You assist the buyer's judgment; you do not verify.

VERDICT: set `recommendation` (buy / negotiate / skip), a one-line summary, and
factor in the buyer's stated context if given. Plain language, no hedging filler,
no fabricated certainty.
"""


def run_check(
    images: list[tuple[bytes, str]],
    user_context: str | None,
    seeded_facts: ListingFacts | None = None,
) -> CheckReport:
    """images: list of (raw_bytes, media_type). Returns a filled CheckReport.

    This is what the endpoint and the app use — the contract is just CheckReport.
    For debug/eval (capturing the web_search trace too) use `run_check_traced`.
    """
    report, _msg = run_check_traced(images, user_context, seeded_facts=seeded_facts)
    return report


def run_check_traced(
    images: list[tuple[bytes, str]],
    user_context: str | None,
    seeded_facts: ListingFacts | None = None,
) -> tuple[CheckReport, object | None]:
    """Same call as `run_check`, but also hands back the raw Claude message.

    The raw message carries the `web_search` trace (queries + returned sources)
    that `run_check` discards. The eval tooling walks it via
    `search_trace.extract_search_trace(msg.content)`. The app never sees this —
    the trace is a separate debug artifact, not part of the rendered report.

    Returns (report, msg). `msg` is None on the early-out / error paths (no key,
    no images, API error), since there's no response to trace in those cases.
    """
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return (
            CheckReport(
                listing_facts=ListingFacts(),
                error="Server isn't configured yet (no ANTHROPIC_API_KEY). Set it in .env.",
            ),
            None,
        )
    if not images:
        return (
            CheckReport(
                listing_facts=ListingFacts(),
                error="No screenshots received — share the listing photos to analyze.",
            ),
            None,
        )

    client = anthropic.Anthropic()

    content: list[dict] = [
        {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": base64.standard_b64encode(data).decode(),
            },
        }
        for data, media_type in images
    ]
    content.append({"type": "text", "text": _build_user_text(user_context, seeded_facts=seeded_facts)})

    try:
        # Single structured call: vision + web_search + the CheckReport schema.
        # If the API ever rejects format+server-tools together, split into two
        # passes (search/reason, then format) — but keep it one call while it works.
        msg = client.messages.parse(
            model=MODEL,
            max_tokens=8000,
            system=_SYSTEM,
            thinking={"type": "adaptive"},
            tools=[{"type": "web_search_20260209", "name": "web_search"}],
            messages=[{"role": "user", "content": content}],
            output_format=CheckReport,
        )
    except anthropic.APIError as exc:
        return (
            CheckReport(
                listing_facts=ListingFacts(),
                error=_user_error_for(exc),
            ),
            None,
        )

    report = msg.parsed_output or CheckReport(listing_facts=ListingFacts())
    _enforce_brand_gate(report)
    if user_context:
        report.verdict.user_context = user_context
    return report, msg


# Substrings that single out the billing/low-credit case among 400s. The API
# returns these as a BadRequestError whose `.type` is the generic
# "invalid_request_error" — only the message distinguishes them from a genuinely
# malformed request, so message-match is the one place we read the text.
_BILLING_HINTS = ("credit balance", "billing", "insufficient", "purchase credits")


def _user_error_for(exc: anthropic.APIError) -> str:
    """Map an Anthropic SDK exception to an honest, user-facing CheckReport.error.

    Branch on the typed exception classes (most-specific first), never on the
    stringified error. "Try again" is reserved for genuinely transient failures;
    non-retryable failures say so plainly without leaking keys or internals. The
    full exception is logged server-side so the user message can stay calibrated.
    """
    # --- Not retryable: server-side configuration or billing. ---
    if isinstance(exc, anthropic.AuthenticationError):
        # 401: the server's API key is missing/invalid/revoked. The buyer can't fix this.
        log.error("Anthropic auth failure (check ANTHROPIC_API_KEY): %r", exc)
        return "The check service is misconfigured on our end. This isn't something a retry will fix."
    if isinstance(exc, anthropic.PermissionDeniedError):
        # 403: the key lacks access to the model/feature. Server-side, not retryable.
        log.error("Anthropic permission denied (key lacks access): %r", exc)
        return "The check service is misconfigured on our end. This isn't something a retry will fix."
    if isinstance(exc, anthropic.BadRequestError):
        # 400. Two flavors, both non-retryable, but the billing case deserves its
        # own message — `.type` is "invalid_request_error" for both, so match text.
        text = f"{getattr(exc, 'type', None) or ''} {exc.message}".lower()
        if any(hint in text for hint in _BILLING_HINTS):
            log.error("Anthropic billing/credit failure: %r", exc)
            return "The check service is temporarily unavailable (a billing issue on our end). Retrying won't help right now."
        log.error("Anthropic bad request (malformed call — likely a bug): %r", exc)
        return "Couldn't run the check on these screenshots. Retrying the same ones probably won't help."

    # --- Retryable: rate limits, transient server load, network. ---
    if isinstance(exc, anthropic.RateLimitError):
        # 429. The SDK already auto-retries these, so reaching here means retries
        # were exhausted — but a later attempt may still succeed.
        log.warning("Anthropic rate limit (auto-retries exhausted): %r", exc)
        return "The check service is busy right now. Give it a moment and try again."
    if isinstance(
        exc,
        (anthropic.InternalServerError, anthropic.OverloadedError, anthropic.APIConnectionError),
    ):
        # 5xx, 529 (OverloadedError — a sibling of InternalServerError in this SDK,
        # not a subclass, so list it explicitly), and network errors
        # (APITimeoutError subclasses APIConnectionError). All transient.
        log.warning("Anthropic transient failure (server/network): %r", exc)
        return "Couldn't reach the check service. Try again in a moment."

    # Anything else under APIError — be honest that we don't know, allow a retry.
    log.error("Unexpected Anthropic API error: %r", exc)
    return "Something went wrong running the check. Try again."


def _build_user_text(
    user_context: str | None,
    seeded_facts: ListingFacts | None = None,
) -> str:
    brands = ", ".join(FAKEABLE_BRANDS)
    parts = [
        "Analyze this Depop listing from the screenshot(s) and fill in the report.",
        f"Fakeable brands (run the authenticity pass only for these): {brands}.",
        "For any other brand, set auth_flag.applicable=false.",
    ]
    if seeded_facts is not None:
        facts_json = json.dumps(seeded_facts.model_dump(), sort_keys=True)
        parts.append(
            "The listing's stated facts (from the page — treat as ground truth; "
            f"correct only if the photos clearly contradict): {facts_json}"
        )
    if user_context:
        parts.append(f"Buyer's context: {user_context}")
    return "\n".join(parts)


def _enforce_brand_gate(report: CheckReport) -> None:
    """Belt-and-suspenders: silence the auth flag for non-fakeable brands."""
    brand = (report.listing_facts.brand or "").lower()
    is_fakeable = any(b in brand for b in FAKEABLE_BRANDS)
    if not is_fakeable:
        report.auth_flag.applicable = False
        report.auth_flag.red_flags = []
        report.auth_flag.what_to_inspect = []

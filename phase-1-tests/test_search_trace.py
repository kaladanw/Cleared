"""Structurally validate the web_search trace extraction — NO live API call.

We construct a synthetic `msg.content` out of the REAL anthropic SDK block types
(ServerToolUseBlock / WebSearchToolResultBlock / WebSearchResultBlock, and the
error variant), mixed with noise blocks the walker must ignore (thinking, text,
a non-web_search server tool). Then we assert `extract_search_trace` produces the
right trace shape. If the SDK's block shapes drift, this fails loudly.

Run:  backend/.venv/bin/python phase-1-tests/test_search_trace.py
"""

from __future__ import annotations

import sys
from pathlib import Path

_BACKEND = Path(__file__).resolve().parent.parent / "backend"
sys.path.insert(0, str(_BACKEND))

from anthropic.types import (  # noqa: E402
    ServerToolUseBlock,
    TextBlock,
    ThinkingBlock,
    WebSearchResultBlock,
    WebSearchToolResultBlock,
    WebSearchToolResultError,
)

from app.search_trace import extract_search_trace  # noqa: E402


def _mock_content() -> list:
    """A realistic message body: two good searches, one errored, plus noise."""
    return [
        ThinkingBlock(type="thinking", thinking="Let me price this.", signature="sig"),
        # Search 1 — succeeds with two sources.
        ServerToolUseBlock(
            id="srvtoolu_1",
            type="server_tool_use",
            name="web_search",
            input={"query": "Aelfric Eden Speed Racer knit polo retail price"},
        ),
        WebSearchToolResultBlock(
            type="web_search_tool_result",
            tool_use_id="srvtoolu_1",
            content=[
                WebSearchResultBlock(
                    type="web_search_result",
                    title="Aelfric Eden Speed Racer Polo — $72",
                    url="https://aelfriceden.com/products/speed-racer-polo",
                    page_age="2025-11-01",
                    encrypted_content="enc1",
                ),
                WebSearchResultBlock(
                    type="web_search_result",
                    title="Aelfric Eden polo on Amazon",
                    url="https://amazon.com/dp/example",
                    page_age=None,
                    encrypted_content="enc2",
                ),
            ],
        ),
        # A different server tool — must be ignored.
        ServerToolUseBlock(
            id="srvtoolu_fetch",
            type="server_tool_use",
            name="web_fetch",
            input={"url": "https://example.com"},
        ),
        # Search 2 — errors out (e.g. rate limited).
        ServerToolUseBlock(
            id="srvtoolu_2",
            type="server_tool_use",
            name="web_search",
            input={"query": "Aelfric Eden sweater used resale price poshmark"},
        ),
        WebSearchToolResultBlock(
            type="web_search_tool_result",
            tool_use_id="srvtoolu_2",
            content=WebSearchToolResultError(
                type="web_search_tool_result_error",
                error_code="too_many_requests",
            ),
        ),
        TextBlock(type="text", text='{"listing_facts": {...}}'),
    ]


def main() -> int:
    trace = extract_search_trace(_mock_content())

    failures: list[str] = []

    def check(cond: bool, msg: str) -> None:
        if not cond:
            failures.append(msg)

    check(trace["search_count"] == 2, f"search_count should be 2, got {trace['search_count']}")
    check(trace["result_count"] == 2, f"result_count should be 2, got {trace['result_count']}")
    check(len(trace["searches"]) == 2, f"expected 2 searches, got {len(trace['searches'])}")

    s1, s2 = trace["searches"]
    check(s1["query"].startswith("Aelfric Eden Speed Racer"), "search 1 query wrong")
    check(len(s1["results"]) == 2, "search 1 should have 2 results")
    check(s1["results"][0]["url"].endswith("speed-racer-polo"), "search 1 result url wrong")
    check(s1["results"][0]["page_age"] == "2025-11-01", "search 1 page_age wrong")
    check(s1["results"][1]["page_age"] is None, "search 1 result 2 page_age should be None")

    check("error" in s2, "search 2 should carry an error")
    check(s2.get("error") == "too_many_requests", f"search 2 error wrong: {s2.get('error')}")
    check("results" not in s2, "errored search should not carry a results list")

    # web_fetch / thinking / text blocks must not leak into the trace.
    check(all("fetch" not in (s.get("query") or "") for s in trace["searches"]),
          "web_fetch leaked into trace")

    # The walker must also work on dicts (re-loaded JSON), not just SDK models.
    dict_content = [
        {"type": "server_tool_use", "name": "web_search", "id": "d1",
         "input": {"query": "q"}},
        {"type": "web_search_tool_result", "tool_use_id": "d1",
         "content": [{"type": "web_search_result", "title": "t",
                      "url": "u", "page_age": None}]},
    ]
    dtrace = extract_search_trace(dict_content)
    check(dtrace["search_count"] == 1 and dtrace["result_count"] == 1,
          "dict-shaped content not handled")

    if failures:
        print("FAIL:")
        for f in failures:
            print("  -", f)
        return 1
    print("PASS — extraction produced the right trace from synthetic SDK blocks.")
    print(f"  {trace['search_count']} searches, {trace['result_count']} sources, "
          f"1 errored search captured, web_fetch/thinking/text ignored.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

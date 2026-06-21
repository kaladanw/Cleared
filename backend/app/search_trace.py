"""Surface the web_search trace from a Claude response — a debug artifact.

`run_check` returns only the `CheckReport` (what the app renders). But the model
also does real `web_search` work on the way there, and that trace is the only way
to judge whether the price/sizing reasoning is GROUNDED (did it actually search
this product's comps?) or generalized from brand-level priors. This module walks
`msg.content` and pulls that trace into a plain serializable shape.

It is strictly additive: it reads a response that already came back, never makes
a call, and never touches the `CheckReport` contract. The trace is persisted
alongside the report (see `phase-1-tests/capture_run.py`), not returned to the app.

The block shapes (anthropic SDK 0.111):
  - `server_tool_use`  with `name == "web_search"` carries the QUERY in `.input`.
  - `web_search_tool_result` (`.tool_use_id` links back) carries the RESULTS:
    either a list of `web_search_result` blocks (`title`/`url`/`page_age`) or a
    `web_search_tool_result_error` with an `error_code`.
"""

from __future__ import annotations

from typing import Any

# Stringly-typed `type` discriminators on the content blocks we care about.
_SERVER_TOOL_USE = "server_tool_use"
_SEARCH_RESULT = "web_search_tool_result"
_RESULT_ERROR = "web_search_tool_result_error"


def extract_search_trace(content: list[Any]) -> dict[str, Any]:
    """Pull the web_search activity out of a parsed message's `content` list.

    Returns a serializable dict:
      {
        "searches": [
          {"id", "query", "results": [{"title","url","page_age"}, ...]},
          ... or "error": "<code>" instead of "results" when the search failed
        ],
        "search_count": int,        # number of web_search queries issued
        "result_count": int,        # total sources returned across all searches
      }

    A search with zero results (or only generalized queries) is exactly the signal
    the human is looking for, so we keep empty result lists rather than dropping them.
    """
    # First pass: collect the queries, keyed by the server_tool_use block id so we
    # can attach results to the right query even if blocks interleave.
    queries: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for block in content:
        if _block_type(block) != _SERVER_TOOL_USE:
            continue
        if _attr(block, "name") != "web_search":
            continue  # ignore other server tools (web_fetch, code_execution, ...)
        block_id = _attr(block, "id") or f"search-{len(order)}"
        query = _query_from_input(_attr(block, "input"))
        queries[block_id] = {"id": block_id, "query": query, "results": []}
        order.append(block_id)

    # Second pass: attach each result block to its query via tool_use_id.
    for block in content:
        if _block_type(block) != _SEARCH_RESULT:
            continue
        use_id = _attr(block, "tool_use_id")
        entry = queries.get(use_id)
        if entry is None:
            # Result with no matching query block — keep it visible rather than drop.
            entry = {"id": use_id, "query": None, "results": []}
            queries[use_id] = entry
            order.append(use_id)
        _fill_result(entry, _attr(block, "content"))

    searches = [queries[bid] for bid in order]
    result_count = sum(len(s.get("results", [])) for s in searches)
    return {
        "searches": searches,
        "search_count": sum(1 for s in searches if s.get("query") is not None),
        "result_count": result_count,
    }


def _fill_result(entry: dict[str, Any], result_content: Any) -> None:
    """Populate an entry with either source rows or an error code."""
    if _block_type(result_content) == _RESULT_ERROR:
        entry.pop("results", None)
        entry["error"] = _attr(result_content, "error_code")
        return
    rows: list[dict[str, Any]] = []
    for item in result_content or []:
        rows.append(
            {
                "title": _attr(item, "title"),
                "url": _attr(item, "url"),
                "page_age": _attr(item, "page_age"),
            }
        )
    entry["results"] = rows


def _query_from_input(tool_input: Any) -> Any:
    """The web_search input is `{"query": "..."}`; be defensive about shape."""
    if isinstance(tool_input, dict):
        return tool_input.get("query")
    return _attr(tool_input, "query")


def _block_type(block: Any) -> Any:
    return _attr(block, "type")


def _attr(obj: Any, name: str) -> Any:
    """Read a field whether the block is a pydantic model or a plain dict.

    The SDK returns pydantic blocks; mocks/tests and re-loaded JSON are dicts.
    One accessor keeps the walker working against both.
    """
    if isinstance(obj, dict):
        return obj.get(name)
    return getattr(obj, name, None)

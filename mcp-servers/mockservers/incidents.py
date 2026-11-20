"""Incident history (mock): past incidents with summaries and resolutions."""

from __future__ import annotations

import copy
from typing import Any

from mockservers._runtime import create_server, load_fixture, serve

server, calls = create_server("incidents", "Historical incident records")

_INCIDENTS: list[dict[str, Any]] = load_fixture("incidents")


@server.tool(
    description="Search past incidents by free-text query (matches title, summary and keywords). Returns up to `limit` results."
)
def search_previous_incidents(query: str, limit: int = 5) -> list[dict[str, Any]]:
    calls.record("search_previous_incidents", {"query": query, "limit": limit})
    terms = [t for t in query.lower().split() if t]
    scored = []
    for inc in _INCIDENTS:
        haystack = " ".join([inc["title"], inc["summary"], " ".join(inc["keywords"])]).lower()
        score = sum(1 for t in terms if t in haystack)
        if score:
            scored.append((score, inc))
    scored.sort(key=lambda s: s[0], reverse=True)
    return [copy.deepcopy(inc) for _, inc in scored[: max(1, min(limit, 20))]]


if __name__ == "__main__":
    serve(server)

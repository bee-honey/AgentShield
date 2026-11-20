"""Support ticketing system (mock). Ticket bodies are customer-written: untrusted content."""

from __future__ import annotations

import copy
from datetime import datetime, timezone
from typing import Any

from mcp.server.mcpserver.exceptions import ToolError

from mockservers._runtime import create_server, load_fixture, serve

server, calls = create_server("tickets", "Customer support tickets")

_TICKETS: dict[str, dict[str, Any]] = {t["ticket_id"]: t for t in load_fixture("tickets")}
_DRAFTS: list[dict[str, Any]] = []


@server.tool(description="List open support tickets (id, subject, priority).")
def list_open_tickets() -> list[dict[str, Any]]:
    calls.record("list_open_tickets", {})
    return [
        {k: t[k] for k in ("ticket_id", "subject", "priority", "created_at")}
        for t in _TICKETS.values()
        if t["status"] == "open"
    ]


@server.tool(description="Get the full contents of a support ticket by id, e.g. 'T-1042'.")
def get_ticket(ticket_id: str) -> dict[str, Any]:
    calls.record("get_ticket", {"ticket_id": ticket_id})
    if ticket_id not in _TICKETS:
        raise ToolError(f"ticket {ticket_id} not found")
    return copy.deepcopy(_TICKETS[ticket_id])


@server.tool(
    description="Save a draft reply on a ticket for a human agent to review. Does not send anything to the customer."
)
def draft_ticket_response(ticket_id: str, body: str) -> dict[str, Any]:
    calls.record("draft_ticket_response", {"ticket_id": ticket_id, "body": body})
    if ticket_id not in _TICKETS:
        raise ToolError(f"ticket {ticket_id} not found")
    draft = {
        "draft_id": f"D-{len(_DRAFTS) + 1:04d}",
        "ticket_id": ticket_id,
        "body": body,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "status": "pending_review",
    }
    _DRAFTS.append(draft)
    return draft


if __name__ == "__main__":
    serve(server)

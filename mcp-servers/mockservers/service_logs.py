"""Service logs (mock). Log lines can contain attacker-influenced text: untrusted content.

The payments-api fixture contains a planted prompt injection (LOG-pay-0005) that
tries to steer an agent into calling ``read_employee_records``.
"""

from __future__ import annotations

import copy
from typing import Any

from mcp.server.mcpserver.exceptions import ToolError

from mockservers._runtime import create_server, load_fixture, serve

server, calls = create_server("service-logs", "Application logs by service")

_LOGS: dict[str, list[dict[str, Any]]] = load_fixture("service_logs")


@server.tool(description="List services that have logs available.")
def list_services() -> list[str]:
    calls.record("list_services", {})
    return sorted(_LOGS)


@server.tool(
    description="Read recent log records for a service, e.g. 'payments-api'. Optionally filter by minimum level (INFO, WARN, ERROR)."
)
def read_service_logs(service: str, min_level: str = "INFO", limit: int = 50) -> list[dict[str, Any]]:
    calls.record("read_service_logs", {"service": service, "min_level": min_level, "limit": limit})
    if service not in _LOGS:
        raise ToolError(f"unknown service {service}")
    order = {"INFO": 0, "WARN": 1, "ERROR": 2}
    floor = order.get(min_level.upper(), 0)
    records = [r for r in _LOGS[service] if order.get(r["level"], 0) >= floor]
    return copy.deepcopy(records[: max(1, min(limit, 500))])


if __name__ == "__main__":
    serve(server)

"""Shared runtime for the mock MCP servers: fixtures, call log, HTTP serving."""

from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from importlib import resources
from typing import Any

import uvicorn
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse


def load_fixture(name: str) -> Any:
    """Load ``fixtures/<name>.json`` from the package."""
    text = resources.files("mockservers").joinpath("fixtures", f"{name}.json").read_text()
    return json.loads(text)


class CallLog:
    """In-memory record of every tool invocation that reached this server.

    Integration tests use it to prove that a denied call never got past the
    gateway. It is exposed over plain HTTP (``/_calls``), not as an MCP tool, so
    agents can never see or call it.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._calls: list[dict[str, Any]] = []

    def record(self, tool: str, arguments: dict[str, Any]) -> None:
        with self._lock:
            self._calls.append(
                {
                    "tool": tool,
                    "arguments": arguments,
                    "at": datetime.now(timezone.utc).isoformat(),
                }
            )

    def snapshot(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._calls)

    def clear(self) -> None:
        with self._lock:
            self._calls.clear()


def create_server(name: str, description: str) -> tuple[MCPServer, CallLog]:
    """Create an MCP server with ``/_calls`` and ``/healthz`` routes attached."""
    server = MCPServer(name=name, description=description, version="0.1.0")
    calls = CallLog()

    @server.custom_route("/_calls", methods=["GET", "DELETE"], include_in_schema=False)
    async def _calls(request: Request) -> JSONResponse:
        if request.method == "DELETE":
            calls.clear()
            return JSONResponse({"cleared": True})
        return JSONResponse({"server": name, "calls": calls.snapshot()})

    @server.custom_route("/healthz", methods=["GET"], include_in_schema=False)
    async def _healthz(_: Request) -> JSONResponse:
        return JSONResponse({"status": "ok", "server": name})

    return server, calls


def serve(server: MCPServer) -> None:
    """Serve over Streamable HTTP at ``/mcp``.

    Configuration (environment):
      MCP_HOST           bind address (default 0.0.0.0)
      MCP_PORT           port (default 8000)
      MCP_ALLOWED_HOSTS  comma-separated Host header allowlist for DNS-rebinding
                         protection (default "localhost:*,127.0.0.1:*")
    """
    host = os.environ.get("MCP_HOST", "0.0.0.0")
    port = int(os.environ.get("MCP_PORT", "8000"))
    allowed = [
        h.strip()
        for h in os.environ.get("MCP_ALLOWED_HOSTS", "localhost:*,127.0.0.1:*").split(",")
        if h.strip()
    ]
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=allowed,
        allowed_origins=[],
    )
    app = server.streamable_http_app(
        streamable_http_path="/mcp",
        stateless_http=True,
        json_response=True,
        transport_security=security,
        host=host,
    )
    uvicorn.run(app, host=host, port=port, log_level="info")

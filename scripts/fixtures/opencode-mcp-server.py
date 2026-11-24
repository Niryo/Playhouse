#!/usr/bin/env python3
"""A one-tool stdio MCP server for the scripted OpenCode suite (scripts/test-opencode-scripted.sh).

Usage: opencode-mcp-server.py <name>. It offers the tool `ping`, which answers `pong-from-<name>`,
so the suite can check that the real OpenCode started the server Playhouse gave it and that the
model reached its tool.
"""
import json
import sys

NAME = sys.argv[1] if len(sys.argv) > 1 else "scripted"


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        request = json.loads(line)
    except ValueError:
        continue
    request_id, method = request.get("id"), request.get("method")
    if request_id is None:
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"),
            "capabilities": {"tools": {}}, "serverInfo": {"name": NAME, "version": "1"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": [
            {"name": "ping", "description": "Reply with pong", "inputSchema": {"type": "object", "properties": {}}}]}})
    elif method == "tools/call":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": "pong-from-" + NAME}]}})
    else:
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})

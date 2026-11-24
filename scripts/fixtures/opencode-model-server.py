#!/usr/bin/env python3
"""A scripted OpenAI-compatible chat model for running the real `opencode` with no paid tokens.

OpenCode accepts any OpenAI-compatible endpoint as a model provider. The scripted OpenCode suite
(scripts/test-opencode-scripted.sh) points the real binary at this server on 127.0.0.1, so every
OpenCode tool, permission, question and session path runs for real while the model's replies are
fixed. Usage: opencode-model-server.py <port-file> <request-log>

It binds a free port, writes it to <port-file>, and logs every request body as one JSON line to
<request-log>. A marker in the latest user message picks the reply:
- `[[scenario:write]]` calls the `write` tool to create notes.txt, then answers.
- `[[scenario:bash]]` calls the `shell` tool with `echo hello-from-scripted`, then answers.
- `[[scenario:question]]` calls the `question` tool, then answers with what it returned.
- `[[scenario:slow]]` calls the `shell` tool with `sleep 30` (for stop).
- `[[scenario:mcp-<server>]]` calls the MCP server's `ping` tool through OpenCode's Code Mode
  `execute` tool, which is how OpenCode 2 offers MCP tools to a model.
- `[[scenario:json]]` answers in prose; Playhouse's correction for an answer that didn't match its
  JSON Schema is answered with `{"title": "Scripted task", "priority": 2}` in a Markdown code block.
Anything else is answered at once. Before answering, a turn reports the task's outcome
(waiting-response) with the `task outcome` command in Playhouse's instructions, through OpenCode's
shell tool, as an agent following those instructions does. Every answer names the tool results the turn received, so the
suite can check what OpenCode gave the model. Requests without tools (titles, summaries) get a
short canned reply. Each response reports usage, as OpenCode needs for its token counts: a quarter of
the characters of the request's messages and tool definitions as its prompt tokens.
"""
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, LOG = sys.argv[1], sys.argv[2]
LOCK = threading.Lock()

CALLS = {
    "write": ("write", {"path": "notes.txt", "content": "Written by OpenCode through the scripted model.\n"}),
    "bash": ("shell", {"command": "echo hello-from-scripted"}),
    "question": ("question", {"questions": [{
        "question": "Which color should the scripted model use?", "header": "Color",
        "options": [{"label": "Red", "description": "warm"}, {"label": "Blue", "description": "cool"}],
    }]}),
    "slow": ("shell", {"command": "sleep 30"}),
}


def adapt(name, arguments, schemas):
    """The call in the shape the running OpenCode's tool takes: OpenCode 1 names its shell tool
    `bash` (which also wants a description) and its file argument `filePath`; OpenCode 2 uses
    `shell` and `path`. None when the release has no such tool."""
    if name not in schemas and name == "shell" and "bash" in schemas:
        name = "bash"
    if name not in schemas:
        return None
    properties = schemas[name]
    arguments = dict(arguments)
    if "path" in arguments and "path" not in properties and "filePath" in properties:
        arguments["filePath"] = arguments.pop("path")
    if "description" in properties and "description" not in arguments:
        arguments["description"] = "Scripted call"
    return name, arguments


def content_text(content):
    if isinstance(content, str):
        return content
    return " ".join(part.get("text", "") for part in content or [] if isinstance(part, dict))


def last_user_index(messages):
    return max((i for i, m in enumerate(messages) if m.get("role") == "user"), default=-1)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def reply_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply_json({"object": "list", "data": [{"id": "scripted", "object": "model"}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        with LOCK, open(LOG, "a", encoding="utf-8") as log:
            log.write(json.dumps({"path": self.path, "body": request}) + "\n")
        messages = request.get("messages", [])
        start = last_user_index(messages)
        user_text = content_text(messages[start].get("content")) if start >= 0 else ""
        results = [content_text(m.get("content")) for m in messages[start + 1:] if m.get("role") == "tool"]
        schemas = {t["function"]["name"]: (t["function"].get("parameters") or {}).get("properties", {})
                   for t in request.get("tools", []) if "function" in t}
        tools = set(schemas)
        match = re.search(r"\[\[scenario:([a-z0-9-]+)\]\]", user_text)
        scenario = match.group(1) if match else None
        system = " ".join(content_text(m.get("content")) for m in messages if m.get("role") == "system")
        outcome = next((line.strip().replace("<completed|waiting-response|blocked>", "waiting-response")
                        for line in system.splitlines() if line.strip().startswith("'") and " task outcome " in line), None)
        called_outcome = any("task outcome" in json.dumps(m.get("tool_calls", [])) for m in messages[start + 1:] if m.get("role") == "assistant")
        deltas = []
        if not tools:
            deltas.append({"content": "Scripted title"})
            finish = "stop"
        elif scenario and scenario.startswith("mcp-") and not results and "execute" in tools:
            code = "return await tools[%s].ping()" % json.dumps(scenario[4:])
            deltas.append({"tool_calls": [{"index": 0, "id": f"call_{time.time_ns()}", "type": "function",
                                           "function": {"name": "execute", "arguments": json.dumps({"code": code})}}]})
            finish = "tool_calls"
        elif scenario in CALLS and not results and adapt(*CALLS[scenario], schemas):
            name, arguments = adapt(*CALLS[scenario], schemas)
            deltas.append({"tool_calls": [{"index": 0, "id": f"call_{time.time_ns()}", "type": "function",
                                           "function": {"name": name, "arguments": json.dumps(arguments)}}]})
            finish = "tool_calls"
        elif outcome and not called_outcome and adapt("shell", {"command": outcome}, schemas):
            # Like an agent following Playhouse's instructions, it reports the task's outcome before
            # it answers, through OpenCode's own shell tool.
            name, arguments = adapt("shell", {"command": outcome}, schemas)
            deltas.append({"tool_calls": [{"index": 0, "id": f"call_{time.time_ns()}", "type": "function",
                                           "function": {"name": name, "arguments": json.dumps(arguments)}}]})
            finish = "tool_calls"
        elif "didn't match the JSON Schema" in user_text or scenario == "json":
            answer = ('```json\n{"title": "Scripted task", "priority": 2}\n```' if "didn't match the JSON Schema" in user_text
                      else "I'll file the task.")
            deltas.append({"content": answer})
            finish = "stop"
        else:
            answer = f"Scripted answer ({scenario or 'plain'})."
            results = [r for r in results if "waiting-response" not in r and '"ok"' not in r]
            if results:
                answer += " Tool results: " + " | ".join(r.strip() for r in results)
            for start_index in range(0, len(answer), 16):
                deltas.append({"content": answer[start_index:start_index + 16]})
            finish = "stop"
        prompt_tokens = (len(json.dumps(messages)) + len(json.dumps(request.get("tools", [])))) // 4
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        created = int(time.time())
        for delta in deltas:
            chunk = {"id": "scripted", "object": "chat.completion.chunk", "created": created, "model": "scripted",
                     "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()
        final = {"id": "scripted", "object": "chat.completion.chunk", "created": created, "model": "scripted",
                 "choices": [{"index": 0, "delta": {}, "finish_reason": finish}],
                 "usage": {"prompt_tokens": prompt_tokens, "completion_tokens": 30, "total_tokens": prompt_tokens + 30}}
        self.wfile.write(f"data: {json.dumps(final)}\n\ndata: [DONE]\n\n".encode())
        self.wfile.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()

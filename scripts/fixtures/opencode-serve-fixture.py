#!/usr/bin/env python3
"""Deterministic stand-in for the `opencode` CLI's HTTP server (`opencode serve`, OpenCode 2).

Playhouse launches it exactly like OpenCode (`opencode serve --hostname 127.0.0.1 --port 0`,
with its password in `OPENCODE_PASSWORD`). It prints `Server listening on http://127.0.0.1:<port>` and serves the
API shapes recorded from OpenCode 2.4: `/api/session` create/get/update/delete/fork, `prompt`
(with `delivery: steer` into a running execution's inbox), `interrupt`, `agent`, `model`,
instruction entries, forms, permissions, messages, `active`, `/api/model`, `/api/mcp`,
`compact`, background jobs, and the `/api/event` stream.
Like OpenCode, one server serves every folder and finds each folder's own skills (`.agents`,
`.claude` and `.opencode` skills) and MCP servers (the folder's `opencode.json`) itself, read
afresh for each request.

Sessions are kept in `<executable>.sessions.json`, so a later server sees them as OpenCode's
shared database does. Every launch is logged to `<executable>.launches`, every request to
`<executable>.methods`, and every prompt turn to `<executable>.history` for test assertions.

What a prompt does is chosen by markers in its text:
- `[[tools]]` writes commentary, runs a shell tool and a write tool that really writes
  `opencode-fixture.txt` in the session's folder, then answers.
- `[[question]]` asks the `question` tool's form and answers with the choice it got.
- `[[permissions]]` asks permission for a shell command, a Playhouse CLI board command and an
  edit (unless a session rule decides it), and answers with what Playhouse chose for each.
- `[[hold]]` writes `<executable>.hold-ready` (after ending its first model request when the prompt
  also says `[[step]]`) and holds until an interrupt (stopped), a steer
  in the inbox (answers the steer) or `<executable>.hold-release` (answers).
- `[[subagent]]` runs the `subagent` tool with the explore agent in a child session.
- `[[background]]` starts a background shell job that runs until it is cancelled.
- `[[background-hold]]` starts that job, writes `<executable>.hold-ready` and holds the turn until
  the job is cancelled or the session interrupted.
- `[[auth]]` fails the execution the way OpenCode does without a usable model provider.
- `[[token-map]]` reads a long build log, runs an explore subagent and answers, in three model
  requests whose tokens grow with the session: each is sent a fixed hidden 2,000 tokens (OpenCode's
  system prompt and tools) plus a quarter of the characters of every message before it, the earlier
  request's share read from cache. The subagent's one request reports its own tokens.
- A prompt with Playhouse's JSON Schema instruction (a plugin agent asking for structured output)
  is answered with the next answer of the JSON array in `<executable>.json-answers`, if there is one.
- `[[outcome]]` reports the task completed; any other finished turn reports waiting-response with
  the command in Playhouse's instructions, unless it says `[[no-outcome]]`.
Anything else gets a plain answer. Each step reports its tokens.
Every message carries `time.created` (milliseconds), and the session list takes `parentID`.
`auth list --standalone --format json` prints `<executable>.auth.json` (none without it).
With `<executable>.transient-models`, the next model list names only a built-in model, as OpenCode's
does while it loads a folder, and the file is removed.
"""

import base64
import json
import os
import queue
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

EXECUTABLE = Path(sys.argv[0])
BASE = str(EXECUTABLE)
VERSION = "1.19.6" if "-old" in EXECUTABLE.name else "2.4.0"
MODELS = [
    {"id": "fast", "providerID": "fixture", "name": "Fixture Fast"},
    {"id": "deep", "providerID": "fixture", "name": "Fixture Deep"},
]
DEFAULT_MODEL = {"id": "fast", "providerID": "fixture"}


def folder_mcp(folder):
    """The MCP servers OpenCode finds for a folder: its own `opencode.json`."""
    try:
        return json.loads((Path(folder) / "opencode.json").read_text(encoding="utf-8")).get("mcp") or {}
    except (OSError, ValueError, TypeError):
        return {}


def folder_skills(folder):
    """The skills OpenCode finds in a folder's `.agents`, `.claude` and `.opencode` skill folders."""
    names = set()
    for kind in (".agents", ".claude", ".opencode"):
        base = Path(folder or "/") / kind / "skills"
        if base.is_dir():
            names.update(entry.name for entry in base.iterdir() if (entry / "SKILL.md").is_file())
    return sorted(names)


LOCK = threading.RLock()
CLIENTS = []
COUNTER = [0]
RUNNING = {}       # session ID -> {"interrupt": bool, "inbox": [...]}
FORMS = {}         # form ID -> {"sessionID", "form", "reply": None | answer | "cancelled"}
PERMISSIONS = {}   # request ID -> {"sessionID", "data", "reply": None | decision}
JOBS = {}          # job ID -> info
LAST_REQUEST = [time.monotonic()]
HIDDEN_TOKENS = 2000


def now_ms():
    return int(time.time() * 1000)


def log(name, value):
    with LOCK, open(f"{BASE}.{name}", "a", encoding="utf-8") as handle:
        handle.write(json.dumps(value) + "\n")


def new_id(prefix):
    with LOCK:
        COUNTER[0] += 1
        return f"{prefix}_fixture{os.getpid() % 10000:04d}{COUNTER[0]:05d}"


def load_sessions():
    try:
        return json.loads(Path(f"{BASE}.sessions.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_sessions(sessions):
    path = Path(f"{BASE}.sessions.json")
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(sessions, indent=1), encoding="utf-8")
    temporary.replace(path)


def update_session(session_id, change):
    with LOCK:
        sessions = load_sessions()
        if session_id in sessions:
            change(sessions[session_id])
            save_sessions(sessions)
        return sessions.get(session_id)


def emit(event_type, data, directory=None):
    event = {"id": new_id("evt"), "created": int(time.time() * 1000), "type": event_type, "data": data}
    if directory:
        event["location"] = {"directory": directory}
    with LOCK:
        for client in list(CLIENTS):
            client.put(event)


def info(session_id, session):
    return {
        "id": session_id, "projectID": "fixture", "cost": 0,
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "time": {"created": 0, "updated": 0}, "location": {"directory": session.get("directory")},
        "permissions": session.get("permissions", []), "agent": session.get("agent", "build"),
        **({"parentID": session["parentID"]} if session.get("parentID") else {}),
        **({"model": session["model"]} if session.get("model") else {}),
    }


def add_message(session_id, message):
    message.setdefault("time", {"created": now_ms()})
    update_session(session_id, lambda s: s.setdefault("messages", []).append(message))


def visible_characters(messages, until_id):
    """The characters of every message a request sent before `until_id`'s answer."""
    total = 0
    for message in messages:
        if message["id"] == until_id:
            break
        if message.get("type") == "user":
            total += len(message.get("text", ""))
        for part in message.get("content", []) if message.get("type") == "assistant" else []:
            if part.get("type") == "text":
                total += len(part.get("text", ""))
            elif part.get("type") == "tool":
                total += len(json.dumps(part["state"].get("input", {})))
                total += sum(len(c.get("text", "")) for c in part["state"].get("content", []))
    return total


def grown_tokens(session_id, message_id):
    """What a request of the token-map scenario was billed: the hidden share plus its messages."""
    with LOCK:
        session = load_sessions()[session_id]
        context = HIDDEN_TOKENS + visible_characters(session.get("messages", []), message_id) // 4
        previous = session.get("lastContext", 0)
        update_session(session_id, lambda s: s.update(lastContext=context))
    return {"input": context - previous, "output": 40, "reasoning": 0, "cache": {"read": previous, "write": 0}}


def set_message(session_id, message):
    message.setdefault("time", {"created": now_ms()})

    def change(session):
        messages = session.setdefault("messages", [])
        for index, existing in enumerate(messages):
            if existing["id"] == message["id"]:
                messages[index] = message
                return
        messages.append(message)
    update_session(session_id, change)


class Turn:
    """One execution of a session's prompt, run on its own thread."""

    def __init__(self, session_id, prompt_id, body):
        self.session_id = session_id
        self.prompt_id = prompt_id
        self.body = body
        self.session = load_sessions()[session_id]
        self.directory = self.session.get("directory")
        self.message = None
        self.ordinal = 0
        self.record = {}
        self.grows = False

    def state(self):
        return RUNNING[self.session_id]

    def interrupted(self):
        return self.state()["interrupt"]

    def assistant(self):
        self.message = {"id": new_id("msg"), "type": "assistant", "agent": self.session.get("agent", "build"),
                        "content": [], "tokens": {"input": 1200, "output": 300, "reasoning": 0, "cache": {"read": 10500, "write": 0}}}
        self.ordinal = 0
        emit("session.step.started", {"sessionID": self.session_id, "assistantMessageID": self.message["id"], "agent": self.message["agent"]})
        set_message(self.session_id, self.message)

    def text(self, value):
        if self.message is None:
            self.assistant()
        ordinal = self.ordinal
        self.ordinal += 1
        self.message["content"].append({"type": "text", "text": value})
        set_message(self.session_id, self.message)
        base = {"sessionID": self.session_id, "assistantMessageID": self.message["id"], "ordinal": ordinal}
        emit("session.text.started", base)
        for index in range(0, len(value), 12):
            emit("session.text.delta", {**base, "delta": value[index:index + 12]})
        emit("session.text.ended", {**base, "text": value})

    def end_step(self):
        if self.message is None:
            return
        if self.grows:
            self.message["tokens"] = grown_tokens(self.session_id, self.message["id"])
            set_message(self.session_id, self.message)
        emit("session.step.ended", {"sessionID": self.session_id, "assistantMessageID": self.message["id"],
                                    "finish": "stop", "tokens": self.message["tokens"]})
        self.message = None

    def tool(self, call_id, name, arguments, output, session_id=None, message=None):
        session_id = session_id or self.session_id
        if message is None:
            if self.message is None:
                self.assistant()
            message = self.message
        base = {"sessionID": session_id, "assistantMessageID": message["id"], "id": call_id}
        emit("session.tool.input.started", {**base, "name": name})
        emit("session.tool.called", {**base, "name": name, "input": arguments, "executed": False})
        part = {"type": "tool", "id": call_id, "name": name, "state": {"status": "running", "input": arguments}}
        message["content"].append(part)
        set_message(session_id, message)
        return base, part, message

    def tool_done(self, base, part, message, output):
        part["state"] = {"status": "completed", "input": part["state"]["input"], "content": [{"type": "text", "text": output}]}
        set_message(base["sessionID"], message)
        emit("session.tool.success", {**base, "content": [{"type": "text", "text": output}], "metadata": {}})

    def ask_permission(self, action, resource, call_id):
        rules = load_sessions()[self.session_id].get("permissions", [])
        for rule in reversed(rules):
            if rule.get("action") == action and rule.get("resource") in ("*", resource):
                if rule.get("effect") == "deny":
                    return "reject"
                if rule.get("effect") == "allow":
                    return "always"
                break
        request_id = new_id("per")
        data = {"id": request_id, "sessionID": self.session_id, "action": action, "resources": [resource],
                "save": [resource], "source": {"type": "tool", "messageID": (self.message or {}).get("id"), "id": call_id}}
        with LOCK:
            PERMISSIONS[request_id] = {"sessionID": self.session_id, "data": data, "reply": None}
        emit("permission.asked", data)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and not self.interrupted():
            with LOCK:
                reply = PERMISSIONS[request_id]["reply"]
            if reply:
                emit("permission.replied", {"sessionID": self.session_id, "requestID": request_id, "reply": reply})
                return reply
            time.sleep(0.05)
        return None

    def run(self):
        sessions = load_sessions()
        session = sessions[self.session_id]
        prompt = self.body.get("text", "")
        files = self.body.get("files") or []
        entries = session.get("instructions", {})
        instructions = "\n".join(str(value) for value in entries.values())
        model = session.get("model") or DEFAULT_MODEL
        rules = session.get("permissions", [])
        self.record = {
            "sessionId": self.session_id, "prompt": prompt, "imageCount": len(files),
            "imageMimeTypes": [f.get("uri", "").split(";")[0].replace("data:", "") for f in files],
            "mode": session.get("agent", "build"), "model": f"{model['providerID']}/{model['id']}",
            "effort": model.get("variant", "default"), "cwd": self.directory,
            "additionalDirectories": [r["resource"][:-2] for r in rules if r.get("action") == "external_directory" and r.get("effect") == "allow"],
            "permissions": rules, "instructions": instructions, "instructionKeys": sorted(entries),
            "skills": folder_skills(self.directory), "mcp": folder_mcp(self.directory or "/"),
            "priorTurnCount": len(session.get("turns", [])),
        }
        update_session(self.session_id, lambda s: s.setdefault("turns", []).append(prompt))
        add_message(self.session_id, {"id": self.prompt_id, "type": "user", "text": prompt})
        emit("session.execution.started", {"sessionID": self.session_id})
        emit("session.inbox.delivered", {"sessionID": self.session_id, "inboxID": self.prompt_id})
        outcome = "succeeded"
        error = None
        cwd = Path(self.directory or os.getcwd())
        answers_path = Path(f"{BASE}.json-answers")
        if "[[auth]]" in prompt:
            outcome = "failed"
            error = {"type": "provider.auth", "message": "No model provider is connected. Run `opencode auth login`."}
        elif "JSON Schema" in prompt and answers_path.exists():
            with LOCK:
                answers = json.loads(answers_path.read_text(encoding="utf-8"))
                answer = answers.pop(0) if answers else "No answer is left."
                answers_path.write_text(json.dumps(answers), encoding="utf-8")
            self.text(answer)
        elif "[[token-map]]" in prompt:
            self.grows = True
            self.text("Reading the build log.")
            log_text = "".join(f"fixture build log line {i:04d}: compiled module {i}\n" for i in range(160))
            self.record["log"] = log_text
            base, part, message = self.tool("call_read_log", "read", {"filePath": str(cwd / "build.log")}, "")
            self.tool_done(base, part, message, log_text)
            self.end_step()
            base, part, message = self.tool("call_map_subagent", "subagent", {"agent": "explore", "description": "Find the README", "prompt": "Find the README."}, "")
            child = new_id("ses")
            with LOCK:
                sessions = load_sessions()
                sessions[child] = {"directory": self.directory, "parentID": self.session_id, "agent": "explore", "messages": [], "turns": []}
                save_sessions(sessions)
            self.record["child"] = child
            emit("session.created", {"sessionID": child, "parentID": self.session_id, "title": "Find the README", "location": {"directory": self.directory}})
            add_message(child, {"id": new_id("msg"), "type": "user", "text": "Find the README."})
            child_message = {"id": new_id("msg"), "type": "assistant", "agent": "explore", "content": [],
                             "tokens": {"input": 900, "output": 60, "reasoning": 0, "cache": {"read": 0, "write": 0}}}
            child_base, child_part, child_message = self.tool("call_map_child_read", "read", {"filePath": str(cwd / "README.md")}, "", session_id=child, message=child_message)
            self.tool_done(child_base, child_part, child_message, "# README")
            child_message["content"].append({"type": "text", "text": "The README is at the repository root."})
            set_message(child, child_message)
            self.tool_done(base, part, message, "The README is at the repository root.")
            self.end_step()
            self.text("OpenCode fixture mapped its tokens.")
        elif "[[tools]]" in prompt:
            self.text("Looking at the repository first.")
            base, part, message = self.tool("call_shell", "shell", {"command": "echo fixture-shell", "description": "Print a marker"}, "")
            self.tool_done(base, part, message, "fixture-shell\n")
            target = cwd / "opencode-fixture.txt"
            target.write_text("Written by the OpenCode fixture.\n", encoding="utf-8")
            base, part, message = self.tool("call_edit", "write", {"filePath": str(target), "content": "Written by the OpenCode fixture.\n"}, "")
            self.tool_done(base, part, message, "Wrote opencode-fixture.txt")
            self.end_step()
            self.text("OpenCode fixture edited opencode-fixture.txt.")
        elif "[[subagent]]" in prompt:
            base, part, message = self.tool("call_subagent", "subagent", {"agent": "explore", "description": "Look around the repository", "prompt": "Find the README."}, "")
            child = new_id("ses")
            with LOCK:
                sessions = load_sessions()
                sessions[child] = {"directory": self.directory, "parentID": self.session_id, "agent": "explore", "messages": [], "turns": []}
                save_sessions(sessions)
            emit("session.created", {"sessionID": child, "parentID": self.session_id, "title": "Look around the repository", "location": {"directory": self.directory}})
            emit("session.execution.started", {"sessionID": child})
            child_message = {"id": new_id("msg"), "type": "assistant", "agent": "explore", "content": []}
            add_message(child, {"id": new_id("msg"), "type": "user", "text": "Find the README."})
            child_base, child_part, child_message = self.tool("call_child_read", "read", {"filePath": str(cwd / "README.md")}, "", session_id=child, message=child_message)
            self.tool_done(child_base, child_part, child_message, "# README")
            child_message["content"].append({"type": "text", "text": "The README is at the repository root."})
            set_message(child, child_message)
            emit("session.execution.succeeded", {"sessionID": child})
            self.tool_done(base, part, message, "The README is at the repository root.")
            self.end_step()
            self.text("OpenCode fixture's explore agent reported back.")
        elif "[[background-hold]]" in prompt:
            job = new_id("sh")
            with LOCK:
                JOBS[job] = {"kind": "shell", "id": job, "sessionID": self.session_id, "status": "running", "title": "sleep 600",
                             "time": {"started": int(time.time() * 1000)}, "shellID": job, "command": "sleep 600"}
            self.record["job"] = job
            self.text("Holding the OpenCode turn with a background job.")
            Path(f"{BASE}.hold-ready").write_text(prompt, encoding="utf-8")
            while not self.interrupted():
                with LOCK:
                    if JOBS[job]["status"] != "running":
                        break
                time.sleep(0.05)
            outcome = "interrupted"
        elif "[[background]]" in prompt:
            job = new_id("sh")
            with LOCK:
                JOBS[job] = {"kind": "shell", "id": job, "sessionID": self.session_id, "status": "running", "title": "sleep 600",
                             "time": {"started": int(time.time() * 1000)}, "shellID": job, "command": "sleep 600"}
            self.record["job"] = job
            self.text("OpenCode fixture left a background job running.")
        elif "[[question]]" in prompt:
            form_id = new_id("frm")
            form = {"id": form_id, "sessionID": self.session_id, "title": "Questions",
                    "metadata": {"kind": "question", "tool": {"id": "call_question"}},
                    "fields": [{"key": "q0", "title": "Color", "description": "Which color should the fixture use?", "type": "string",
                                "options": [{"value": "Red", "label": "Red", "description": "warm"},
                                            {"value": "Blue", "label": "Blue", "description": "cool"}], "custom": True}]}
            with LOCK:
                FORMS[form_id] = {"sessionID": self.session_id, "form": form, "reply": None}
            self.tool("call_question", "question", {"questions": [{"question": "Which color?"}]}, "")
            emit("form.created", {"form": form})
            reply = None
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline and not self.interrupted():
                with LOCK:
                    reply = FORMS[form_id]["reply"]
                if reply is not None:
                    break
                time.sleep(0.05)
            self.record["formReply"] = reply
            self.end_step()
            if isinstance(reply, dict):
                emit("form.replied", {"id": form_id, "sessionID": self.session_id, "answer": reply})
                self.text(f"OpenCode fixture got the color {reply.get('q0')}.")
            else:
                emit("form.cancelled", {"id": form_id, "sessionID": self.session_id})
                outcome = "interrupted" if self.interrupted() else "succeeded"
                if outcome == "succeeded":
                    self.text("OpenCode fixture got no answer.")
        elif "[[permissions]]" in prompt:
            cli = next((line.strip().split("'")[1] for line in instructions.splitlines()
                        if line.strip().startswith("'") and "playhouse-cli'" in line), "playhouse-cli")
            decisions = {}
            for key, action, resource in (("shell", "shell", "echo hi"), ("cli", "shell", f"'{cli}' task list"), ("edit", "edit", "README.md")):
                decisions[key] = self.ask_permission(action, resource, f"call_{key}")
            self.record["permissionDecisions"] = decisions
            self.text("Permissions: " + ", ".join(f"{k}={v}" for k, v in decisions.items()) + ".")
        elif "[[hold]]" in prompt:
            self.text("Holding the OpenCode turn.")
            if "[[step]]" in prompt:
                self.end_step()
            Path(f"{BASE}.hold-ready").write_text(prompt, encoding="utf-8")
            release = Path(f"{BASE}.hold-release")
            while True:
                if self.interrupted():
                    outcome = "interrupted"
                    break
                with LOCK:
                    inbox = self.state()["inbox"]
                    steer = inbox.pop(0) if inbox else None
                if steer:
                    emit("session.inbox.delivered", {"sessionID": self.session_id, "inboxID": steer["id"]})
                    add_message(self.session_id, {"id": steer["id"], "type": "user", "text": steer["text"]})
                    self.record["steer"] = steer["text"]
                    self.end_step()
                    self.text(f"OpenCode fixture took the steer: {steer['text']}")
                    break
                if release.exists():
                    release.unlink()
                    self.end_step()
                    self.text("Released the OpenCode turn.")
                    break
                time.sleep(0.05)
        else:
            self.text(f"OpenCode fixture answered in {self.record['mode']} mode with {self.record['model']}.")
        # Like an agent following Playhouse's instructions, a finished turn reports its outcome:
        # completed when asked to, else waiting for the user. A stopped turn reports none.
        if outcome == "succeeded" and "[[no-outcome]]" not in prompt:
            replacement = "completed" if "[[outcome]]" in prompt else "waiting-response"
            for line in instructions.splitlines():
                command = line.strip()
                if command.startswith("'") and " task outcome " in command:
                    command = command.replace("<completed|waiting-response|blocked>", replacement)
                    completed = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, timeout=60)
                    self.record["outcome"] = {"command": command, "returncode": completed.returncode}
                    break
        self.end_step()
        self.record["result"] = outcome
        log("history", self.record)
        with LOCK:
            RUNNING.pop(self.session_id, None)
        add_message(self.session_id, {"id": new_id("msg"), "type": "idle", "outcome": outcome})
        if outcome == "failed":
            emit("session.execution.failed", {"sessionID": self.session_id, "error": error})
        elif outcome == "interrupted":
            emit("session.execution.interrupted", {"sessionID": self.session_id})
        else:
            emit("session.execution.succeeded", {"sessionID": self.session_id})


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, value=None):
        data = b"" if value is None else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def missing(self, session_id):
        self.reply(404, {"_tag": "SessionNotFoundError", "sessionID": session_id, "message": f"Session not found: {session_id}"})

    def authorized(self):
        expected = "Basic " + base64.b64encode(f"opencode:{os.environ.get('OPENCODE_PASSWORD', '')}".encode()).decode()
        return self.headers.get("Authorization") == expected

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PATCH(self):
        self.route("PATCH")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        LAST_REQUEST[0] = time.monotonic()
        if not self.authorized():
            return self.reply(401, {"_tag": "UnauthorizedError", "message": "Unauthorized"})
        url = urlparse(self.path)
        parts = [unquote(p) for p in url.path.strip("/").split("/")]
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        if parts != ["api", "event"]:
            log("methods", {"method": method, "path": "/" + "/".join(parts), "query": query, "body": body})
        try:
            self.dispatch(method, parts, query, body)
        except BrokenPipeError:
            pass

    def dispatch(self, method, parts, query, body):
        if parts == ["api", "event"]:
            return self.events()
        if parts == ["api", "info"]:
            return self.reply(200, {"version": VERSION})
        if parts == ["api", "model"]:
            transient = Path(f"{BASE}.transient-models")
            if transient.exists():
                # As OpenCode does while it loads a folder: one answer lists only its built-in models.
                transient.unlink()
                return self.reply(200, {"data": [{"id": "free", "providerID": "builtin", "modelID": "free", "name": "Built-in Free",
                                                  "variants": [], "enabled": True}]})
            return self.reply(200, {"data": [{**m, "modelID": m["id"], "variants": [{"id": v} for v in ("low", "medium", "high")],
                                              "enabled": True} for m in MODELS]})
        if parts == ["api", "model", "default"]:
            return self.reply(200, {"data": {**DEFAULT_MODEL, "modelID": DEFAULT_MODEL["id"]}})
        if parts == ["api", "mcp"]:
            signed_in = Path(f"{BASE}.oauth-complete").exists()
            folder = query.get("location[directory]", "/")
            configured = folder_mcp(folder)
            servers = [{"name": name, **({"integrationID": f"mcp-{name}"} if server.get("type") == "remote" else {}),
                        "status": {"status": "needs_auth", "error": "Sign in required"} if server.get("type") == "remote" and not signed_in
                        else {"status": "connected"}} for name, server in configured.items()]
            return self.reply(200, {"location": {"directory": folder}, "data": servers})
        if parts[:2] == ["api", "integration"] and len(parts) >= 3:
            integration = parts[2]
            if len(parts) == 3:
                return self.reply(200, {"data": {"id": integration, "name": integration, "methods": [{"id": "oauth", "type": "oauth", "label": "Sign in"}]}})
            if parts[3:5] == ["connect", "oauth"] and len(parts) == 5:
                attempt = new_id("att")
                log("oauth", {"integration": integration, "attempt": attempt, "methodID": body.get("methodID")})
                return self.reply(200, {"data": {"attemptID": attempt, "url": f"https://example.test/oauth/{integration}?attempt={attempt}",
                                                 "instructions": "Sign in in the browser.", "mode": "auto", "time": {"created": 0, "expires": 0}}})
            if parts[3:5] == ["connect", "oauth"] and len(parts) == 6:
                status = "complete" if Path(f"{BASE}.oauth-complete").exists() else "pending"
                return self.reply(200, {"data": {"status": status, "time": {"created": 0, "expires": 0}}})
        if parts[:2] == ["api", "experimental"] and parts[2:3] == ["job"]:
            if method == "GET":
                with LOCK:
                    jobs = [j for j in JOBS.values() if (not query.get("sessionID") or j["sessionID"] == query["sessionID"])
                            and (not query.get("status") or j["status"] == query["status"])]
                return self.reply(200, {"data": jobs})
            with LOCK:
                if parts[3] in JOBS:
                    JOBS[parts[3]]["status"] = "cancelled"
            log("job-cancels", {"id": parts[3]})
            return self.reply(204)
        if parts == ["api", "session", "active"]:
            with LOCK:
                return self.reply(200, {"data": {sid: {"type": "running"} for sid in RUNNING}})
        if parts == ["api", "session"]:
            if method == "POST":
                session_id = new_id("ses")
                with LOCK:
                    sessions = load_sessions()
                    sessions[session_id] = {"directory": (body.get("location") or {}).get("directory"),
                                            "permissions": body.get("permissions") or [], "messages": [], "turns": [], "instructions": {}}
                    save_sessions(sessions)
                emit("session.created", {"sessionID": session_id, "location": {"directory": sessions[session_id]["directory"]}})
                return self.reply(200, {"data": info(session_id, sessions[session_id])})
            return self.reply(200, {"data": [info(k, v) for k, v in load_sessions().items()
                                             if not query.get("parentID") or v.get("parentID") == query["parentID"]]})
        if parts[:3] == ["api", "experimental", "session"] and parts[4:6] == ["instructions", "entries"]:
            session_id, key = parts[3], parts[6]
            def change(session):
                if method == "PUT":
                    session.setdefault("instructions", {})[key] = body.get("value")
                else:
                    session.setdefault("instructions", {}).pop(key, None)
            return self.reply(204) if update_session(session_id, change) is not None else self.missing(session_id)
        if parts[:2] != ["api", "session"] or len(parts) < 3:
            return self.reply(404, {"_tag": "NotFound", "message": f"No route {method} {self.path}"})
        session_id = parts[2]
        rest = parts[3:]
        sessions = load_sessions()
        if session_id not in sessions:
            return self.missing(session_id)
        session = sessions[session_id]
        if rest == []:
            if method == "GET":
                return self.reply(200, {"data": info(session_id, session)})
            if method == "PATCH":
                update_session(session_id, lambda s: s.update({k: v for k, v in body.items() if k in ("permissions", "title", "metadata")}))
                return self.reply(200, {"data": info(session_id, load_sessions()[session_id])})
            if method == "DELETE":
                with LOCK:
                    sessions = load_sessions()
                    sessions.pop(session_id, None)
                    save_sessions(sessions)
                return self.reply(204)
        if rest == ["fork"]:
            forked = new_id("ses")
            with LOCK:
                sessions = load_sessions()
                source = sessions[session_id]
                sessions[forked] = {**json.loads(json.dumps(source)), "forkedFrom": session_id}
                save_sessions(sessions)
            return self.reply(200, {"data": info(forked, sessions[forked])})
        if rest == ["agent"]:
            update_session(session_id, lambda s: s.update(agent=body.get("agent")))
            return self.reply(200, {"data": info(session_id, load_sessions()[session_id])})
        if rest == ["model"]:
            update_session(session_id, lambda s: s.update(model=body.get("model")))
            return self.reply(200, {"data": info(session_id, load_sessions()[session_id])})
        if rest == ["message"]:
            if query.get("cursor") and query.get("order"):
                return self.reply(400, {"_tag": "InvalidRequestError", "message": "Cursor cannot be combined with order", "kind": "Query"})
            if int(query.get("limit") or 50) > 200:
                return self.reply(400, {"_tag": "InvalidRequestError", "message": "Expected a value less than or equal to 200\n  at [\"limit\"]", "kind": "Query"})
            messages = session.get("messages", [])
            if query.get("order") == "desc":
                messages = list(reversed(messages))
            return self.reply(200, {"data": messages[:int(query.get("limit") or 50)], "cursor": {}})
        if rest == ["compact"]:
            compaction = new_id("msg")
            add_message(session_id, {"id": compaction, "type": "compaction"})
            emit("session.compaction.started", {"sessionID": session_id})
            emit("session.compaction.ended", {"sessionID": session_id})
            log("compactions", {"sessionId": session_id})
            return self.reply(200, {"data": {"id": compaction, "sessionID": session_id, "type": "compaction", "delivery": "queue"}})
        if rest == ["interrupt"]:
            with LOCK:
                running = session_id in RUNNING
                if running:
                    RUNNING[session_id]["interrupt"] = True
            return self.reply(200, {"interrupted": running})
        if rest == ["prompt"]:
            message_id = new_id("msg")
            accepted = {"id": message_id, "sessionID": session_id, "time": {"created": int(time.time() * 1000)}, "type": "user",
                        "payload": {"text": body.get("text", "")}, "delivery": body.get("delivery") or "steer"}
            with LOCK:
                running = session_id in RUNNING
                if running:
                    RUNNING[session_id]["inbox"].append({"id": message_id, "text": body.get("text", "")})
                else:
                    RUNNING[session_id] = {"interrupt": False, "inbox": []}
            emit("session.inbox.enqueued", {"inboxID": message_id, "sessionID": session_id, "item": {"type": "user", "payload": {"text": body.get("text", "")}}})
            self.reply(200, {"data": accepted})
            if not running:
                threading.Thread(target=Turn(session_id, message_id, body).run, daemon=True).start()
            return
        if rest[:1] == ["inbox"]:
            with LOCK:
                inbox = RUNNING.get(session_id, {}).get("inbox", [])
                if method == "DELETE" and len(rest) == 2:
                    inbox[:] = [item for item in inbox if item["id"] != rest[1]]
                    return self.reply(204)
                return self.reply(200, {"data": [{"id": i["id"], "type": "user", "payload": {"text": i["text"]}} for i in inbox]})
        if rest[:1] == ["form"]:
            with LOCK:
                if len(rest) == 1:
                    return self.reply(200, {"data": [f["form"] for f in FORMS.values() if f["sessionID"] == session_id and f["reply"] is None]})
                form = FORMS.get(rest[1])
                if form is None:
                    return self.reply(404, {"_tag": "FormNotFoundError", "message": "Form not found"})
                form["reply"] = body.get("answer") if rest[2:3] == ["reply"] else "cancelled"
            return self.reply(204)
        if rest[:1] == ["permission"]:
            with LOCK:
                if len(rest) == 1:
                    return self.reply(200, {"data": [p["data"] for p in PERMISSIONS.values() if p["sessionID"] == session_id and p["reply"] is None]})
                PERMISSIONS[rest[1]]["reply"] = body.get("decision")
            return self.reply(204)
        return self.reply(404, {"_tag": "NotFound", "message": f"No route {method} {self.path}"})

    def events(self):
        client = queue.Queue()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        with LOCK:
            CLIENTS.append(client)
        try:
            self.wfile.write(b'data: {"type":"server.connected","data":{}}\n\n')
            self.wfile.flush()
            while True:
                try:
                    event = client.get(timeout=10)
                except queue.Empty:
                    self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
                    continue
                self.wfile.write(b"data: " + json.dumps(event).encode() + b"\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with LOCK:
                if client in CLIENTS:
                    CLIENTS.remove(client)


def serve(arguments):
    log("launches", {
        "cwd": os.getcwd(), "arguments": arguments,
        "inlineConfig": os.environ.get("OPENCODE_CONFIG_CONTENT"), "configFile": os.environ.get("OPENCODE_CONFIG"),
        "disableClaudeCode": os.environ.get("OPENCODE_DISABLE_CLAUDE_CODE"),
        "disableClaudeCodePrompt": os.environ.get("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT"),
        "disableAutoupdate": os.environ.get("OPENCODE_DISABLE_AUTOUPDATE"),
        "hasPassword": bool(os.environ.get("OPENCODE_PASSWORD")), "pid": os.getpid(),
    })
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    print(f"Server listening on http://127.0.0.1:{server.server_address[1]}", flush=True)

    def watchdog():
        # A fixture whose test folder is gone, or that nobody used for a long time, exits.
        while True:
            time.sleep(1)
            if not EXECUTABLE.exists() or time.monotonic() - LAST_REQUEST[0] > 900:
                os._exit(0)
    threading.Thread(target=watchdog, daemon=True).start()
    server.serve_forever()


def main():
    arguments = sys.argv[1:]
    if arguments[:1] in (["--version"], ["-v"]):
        print(f"opencode v{VERSION}" if VERSION.startswith("2") else VERSION)
    elif arguments[:2] == ["auth", "list"]:
        path = Path(f"{BASE}.auth.json")
        print(path.read_text(encoding="utf-8") if path.exists() else "[]")
    elif arguments[:1] == ["serve"]:
        serve(arguments)
    else:
        print(f"opencode fixture: unsupported arguments {arguments}", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()

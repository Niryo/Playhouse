"""Plugins' background work on the Codex fixture: ephemeral threads, direct MCP tool
calls (`mcpServer/tool/call`) and one-shot agent turns with an `outputSchema`.

Files beside the executable, as the Claude Code fixture's:
  <executable>.mcp-results      {"mcp__<server>__<tool>": result}; a tool missing is a server that isn't connected
  <executable>.mcp-call-delay   {"mcp__<server>__<tool>": seconds}
  <executable>.mcp-calls        each call: {server, tool, threadId, arguments}
  <executable>.agent-runs       each agent turn: {prompt, model, outputSchema, cwd, sandbox, approvalPolicy}
  <executable>.agent-hold       keeps an agent turn running until removed (or interrupted)
  <executable>.agent-fail       makes an agent turn fail
  <executable>.agent-output     the agent's answer, a JSON value sent as the final message's text
  <executable>.unsubscribed     each ephemeral thread released with thread/unsubscribe
"""

import threading

_lock = threading.Lock()
_ephemeral = set()
_held = {}  # thread id -> (turn id, threading.Event)


def _base(runtime):
    return str(runtime.sys.argv[0])


def _locked_writes(runtime):
    # A held agent turn finishes from its own thread, so writes are serialized.
    if getattr(runtime, "_plugin_locked_write", False):
        return
    plain = runtime.write

    def write(value):
        with _lock:
            plain(value)
    runtime.write = write
    runtime._plugin_locked_write = True


def _log(runtime, suffix, record):
    with open(_base(runtime) + suffix, "a", encoding="utf-8") as log:
        log.write(runtime.json.dumps(record) + "\n")


def handle(runtime, message):
    """True when the message was one of these plugin requests and is answered."""
    method = message.get("method")
    params = message.get("params") or {}
    if method == "thread/start" and params.get("ephemeral") is True:
        _locked_writes(runtime)
        thread_id = "ephemeral-" + str(runtime.uuid.uuid4())
        _ephemeral.add(thread_id)
        _log(runtime, ".ephemeral-threads", {"threadId": thread_id, "model": params.get("model"),
                                             "sandbox": params.get("sandbox"), "cwd": params.get("cwd")})
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
            "thread": {"id": thread_id}, "model": params.get("model")}})
        return True
    if method == "mcpServer/tool/call":
        _locked_writes(runtime)
        tool = "mcp__" + str(params.get("server")) + "__" + str(params.get("tool"))
        _log(runtime, ".mcp-calls", {"server": params.get("server"), "tool": params.get("tool"),
                                     "threadId": params.get("threadId"), "arguments": params.get("arguments")})
        # A `-no-mcp-call` copy is a release without direct tool calls.
        if "-no-mcp-call" in _base(runtime):
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {
                "code": -32601, "message": "Method not found: mcpServer/tool/call"}})
            return True
        if params.get("threadId") not in _ephemeral:
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32600, "message": "thread not found"}})
            return True
        delays = runtime.Path(_base(runtime) + ".mcp-call-delay")
        if delays.exists():
            runtime.time.sleep(float(runtime.json.loads(delays.read_text(encoding="utf-8")).get(tool, 0)))
        seeded = runtime.Path(_base(runtime) + ".mcp-results")
        results = runtime.json.loads(seeded.read_text(encoding="utf-8")) if seeded.exists() else {}
        if tool not in results:
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {
                "code": -32000, "message": f"MCP server not connected: {params.get('server')}"}})
        else:
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": results[tool]})
        return True
    if method == "turn/start" and params.get("threadId") in _ephemeral:
        _locked_writes(runtime)
        thread_id = params["threadId"]
        turn_id = "turn-" + str(runtime.uuid.uuid4())
        prompt = "\n".join(item.get("text", "") for item in params.get("input", []) if item.get("type") == "text")
        _log(runtime, ".agent-runs", {"prompt": prompt, "model": params.get("model"), "outputSchema": params.get("outputSchema"),
                                      "cwd": params.get("cwd"), "sandbox": (params.get("sandboxPolicy") or {}).get("type"),
                                      "approvalPolicy": params.get("approvalPolicy"), "threadId": thread_id, "pid": runtime.os.getpid()})
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
        runtime.write({"jsonrpc": "2.0", "method": "turn/started", "params": {
            "threadId": thread_id, "turn": {"id": turn_id, "status": "inProgress"}}})
        interrupted = threading.Event()
        _held[thread_id] = (turn_id, interrupted)

        def finish():
            hold = runtime.Path(_base(runtime) + ".agent-hold")
            deadline = runtime.time.monotonic() + 120
            while hold.exists() and not interrupted.is_set() and runtime.time.monotonic() < deadline:
                runtime.time.sleep(0.05)
            _held.pop(thread_id, None)
            if interrupted.is_set():
                status, error = "interrupted", None
            elif runtime.Path(_base(runtime) + ".agent-fail").exists():
                status, error = "failed", {"message": "The fixture agent failed on purpose."}
            else:
                output = runtime.Path(_base(runtime) + ".agent-output")
                if params.get("outputSchema") is not None:
                    text = output.read_text(encoding="utf-8") if output.exists() else "{}"
                else:
                    text = "Fixture agent answered: " + prompt.strip()[:60]
                runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": thread_id, "turnId": turn_id,
                    "item": {"type": "agentMessage", "id": "item-" + turn_id, "text": text}}})
                status, error = "completed", None
            turn = {"id": turn_id, "status": status}
            if error:
                turn["error"] = error
            runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": thread_id, "turn": turn}})
        threading.Thread(target=finish, daemon=True).start()
        return True
    if method == "thread/unsubscribe" and params.get("threadId") in _ephemeral:
        _ephemeral.discard(params["threadId"])
        _log(runtime, ".unsubscribed", {"threadId": params["threadId"]})
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"status": "unsubscribed"}})
        return True
    if method == "turn/interrupt" and params.get("threadId") in _ephemeral:
        held = _held.get(params["threadId"])
        if held:
            held[1].set()
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
        return True
    return False

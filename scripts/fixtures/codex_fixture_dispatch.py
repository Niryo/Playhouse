"""Message dispatch for a Codex fixture session with explicit shared state."""

import codex_fixture_protocol as _protocol
import codex_fixture_history as _history
import codex_fixture_turns as _turns
import codex_fixture_turn_scenarios as _scenarios
import codex_fixture_plugin as _plugin


def handle_message(runtime, _session_state, message):
    # Every request method, in order, so a test can tell which app-server reads a
    # Playhouse action made (a conversation must reopen without reading the thread).
    if "method" in message and "id" in message:
        with open(str(runtime.sys.argv[0]) + ".methods", "a", encoding="utf-8") as log:
            log.write(message["method"] + "\n")
    # Each turn's thread and prompt text, so a test can tell which thread a send ran on
    # and what context it carried.
    if message.get("method") == "turn/start":
        params = message.get("params", {})
        with open(str(runtime.sys.argv[0]) + ".turn-starts", "a", encoding="utf-8") as log:
            log.write(runtime.json.dumps({
                "threadId": params.get("threadId"),
                "text": "\n".join(item.get("text", "") for item in params.get("input", []) if item.get("type") == "text"),
            }) + "\n")



















    # Plugins' background work: ephemeral threads, direct MCP tool calls, agent turns.
    if _plugin.handle(runtime, message):
        return
    runtime.remember_thread_cwd(message)
    
    if "-question-isolation-" in _session_state.mode and message.get("method") in ("thread/items/list", "thread/turns/list"):
        _session_state.requested = message.get("params", {}).get("threadId")
        if _session_state.requested in _session_state.isolation_turns:
            runtime.THREAD_ID = _session_state.requested
            runtime.TURN_ID, _session_state.answers = _session_state.isolation_turns[_session_state.requested]
            _session_state.saw_turn = True
    # A long-lived app-server never resumes a loaded thread, so the one-shot resume
    # failure also fails the next history read.
    if message.get("method") in ("thread/read", "thread/turns/list", "thread/items/list"):
        history_error = runtime.Path(str(runtime.sys.argv[0]) + ".resume-error")
        if history_error.is_file():
            history_error.unlink(missing_ok=True)
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {
                "code": -32010,
                "message": "Fixture thread resume failed after receiving fixture-secret.",
            }})
            return
    if message.get("method") in runtime.ACCOUNT_METHODS and "id" in message:
        runtime.handle_account_request(message)
        return
    if message.get("method") == "initialized":
        return
    if "method" in message and "id" not in message:
        return
    if runtime.handle_side_chat(message, _session_state.history_path):
        return
    if message.get("method") == "initialize":
        return _protocol.initialize(runtime, _session_state, message)
    elif message.get("method") == "model/list":
        return _protocol.models(runtime, _session_state, message)
    elif message.get("method") == "mcpServerStatus/list":
        return _protocol.mcp_status(runtime, _session_state, message)
    elif message.get("method") == "mcpServer/oauth/login":
        return _protocol.mcp_login(runtime, _session_state, message)
    elif message.get("method") == "thread/goal/get":
        return _protocol.get_goal(runtime, _session_state, message)
    elif "-goal" in _session_state.mode and message.get("method") == "thread/goal/set":
        return _protocol.set_goal(runtime, _session_state, message)
    elif "-goal" in _session_state.mode and message.get("method") == "thread/goal/clear":
        return _protocol.clear_goal(runtime, _session_state, message)
    elif message.get("method") == "skills/extraRoots/set":
        return _protocol.skill_roots(runtime, _session_state, message)
    elif message.get("method") == "thread/start":
        return _protocol.start_thread(runtime, _session_state, message)
    elif message.get("method") == "thread/resume":
        return _protocol.resume_thread(runtime, _session_state, message)
    elif message.get("method") == "turn/start":
        return _turns.start_turn(runtime, _session_state, message)
    elif message.get("id") in {901, 902} or message.get("id") in runtime.question_contexts:
        return _protocol.answer_question(runtime, _session_state, message)
    elif message.get("method") == "turn/steer":
        return _protocol.steer_turn(runtime, _session_state, message)
    elif message.get("method") == "turn/interrupt":
        return _protocol.interrupt_turn(runtime, _session_state, message)
    elif message.get("method") == "thread/compact/start":
        return _protocol.compact_thread(runtime, _session_state, message)
    elif message.get("method") == "thread/backgroundTerminals/list":
        return _scenarios.background_terminals_list(runtime, _session_state, message)
    elif message.get("method") == "thread/backgroundTerminals/terminate":
        return _scenarios.background_terminals_terminate(runtime, _session_state, message)
    elif message.get("method") == "thread/read":
        return _protocol.read_thread(runtime, _session_state, message)
    elif message.get("method") == "thread/turns/list":
        return _protocol.list_turns(runtime, _session_state, message)
    elif message.get("method") == "thread/items/list":
        return _history.list_items(runtime, _session_state, message)

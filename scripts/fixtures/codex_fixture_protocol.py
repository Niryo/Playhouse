"""Thread, model, question, and account protocol handlers."""

def initialize(runtime, _session_state, message):
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"serverInfo": {"name": "playhouse-fixture", "version": "1"}}})


def models(runtime, _session_state, message):
    models = [
        {"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True,
         "supportedReasoningEfforts": [{"reasoningEffort": level} for level in ["low", "medium", "high", "xhigh"]]},
        {"id": "gpt-6-sol", "displayName": "GPT-6 Sol", "isDefault": False,
         "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]},
        {"id": "gpt-6-mini", "displayName": "GPT-6 Mini", "isDefault": False,
         "supportedReasoningEfforts": ["low", "medium"]},
        {"id": "gpt-5.6-luna", "displayName": "GPT-5.6 Luna", "isDefault": False,
         "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]},
        # Superseded in a family whose newest entry is not the default model, so a
        # test can tell "followed the family forward" from "no selection loaded yet".
        {"id": "gpt-5.6-sol", "displayName": "GPT-5.6 Sol", "isDefault": False,
         "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]},
    ]
    models_override = runtime.Path(str(runtime.sys.argv[0]) + ".models-override")
    if models_override.exists():
        models = runtime.json.loads(models_override.read_text(encoding="utf-8"))
    if runtime.Path(str(runtime.sys.argv[0]) + ".models-delay").exists():
        runtime.time.sleep(1)
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"data": models}})


def mcp_status(runtime, _session_state, message):
    # The servers a test seeds in `<executable>.mcp-status`, as Codex lists
    # the ones its own configuration defines.
    # `<executable>.mcp-status-fail` makes the request fail, as when Codex can't be asked.
    if runtime.Path(str(runtime.sys.argv[0]) + ".mcp-status-fail").exists():
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": "Fixture MCP status is unavailable."}})
        return
    seeded = runtime.Path(str(runtime.sys.argv[0]) + ".mcp-status")
    servers = runtime.json.loads(seeded.read_text(encoding="utf-8")) if seeded.exists() else []
    # A sign-in finishes when a test writes the server's name to
    # `<executable>.mcp-callback`, as the browser's redirect would.
    callback = runtime.Path(str(runtime.sys.argv[0]) + ".mcp-callback")
    signed_in = set(callback.read_text(encoding="utf-8").split("\n")) if callback.exists() else set()
    servers = [{**server, "authStatus": "oAuth"} if server.get("name") in signed_in and server.get("authStatus") == "notLoggedIn" else server
               for server in servers]
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"data": servers, "nextCursor": None}})


def mcp_login(runtime, _session_state, message):
    # Codex's sign-in start: the link to open. Each start is logged.
    name = message.get("params", {}).get("name")
    with open(str(runtime.sys.argv[0]) + ".mcp-login", "a", encoding="utf-8") as starts:
        starts.write(runtime.json.dumps({"name": name}) + "\n")
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
        "authorizationUrl": f"https://auth.example.test/codex/authorize?server={name}", "loginId": f"fixture-login-{name}"}})


def get_goal(runtime, _session_state, message):
    _session_state.goal = runtime.json.loads(_session_state.goal_path.read_text(encoding="utf-8")) if _session_state.goal_path.is_file() else None
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"goal": _session_state.goal}})


def set_goal(runtime, _session_state, message):
    _session_state.params = message.get("params", {})
    _session_state.goal = runtime.json.loads(_session_state.goal_path.read_text(encoding="utf-8")) if _session_state.goal_path.is_file() else {
        "threadId": _session_state.params.get("threadId"), "objective": "", "status": "active",
        "tokenBudget": None, "tokensUsed": None, "timeUsedSeconds": 0,
    }
    _session_state.goal.update({key: value for key, value in _session_state.params.items() if key in {"objective", "status"}})
    _session_state.goal_path.write_text(runtime.json.dumps(_session_state.goal), encoding="utf-8")
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"goal": _session_state.goal}})
    if "-single-server" in _session_state.mode:
        # Like Codex, the server tells every client on it that the Goal changed, starts
        # a work turn for an active Goal, and ends it when the Goal is paused.
        runtime.write({"jsonrpc": "2.0", "method": "thread/goal/updated",
               "params": {"threadId": _session_state.goal["threadId"], "goal": _session_state.goal}})
        goal_thread = _session_state.goal["threadId"]
        if _session_state.goal["status"] == "active" and goal_thread not in _session_state.goal_turns:
            _session_state.goal_turns[goal_thread] = f"turn-goal-{runtime.uuid.uuid4()}"
            runtime.write({"jsonrpc": "2.0", "method": "turn/started", "params": {
                "threadId": goal_thread, "turn": {"id": _session_state.goal_turns[goal_thread], "status": "inProgress"}}})
        elif _session_state.goal["status"] != "active" and goal_thread in _session_state.goal_turns:
            runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": goal_thread, "turn": {"id": _session_state.goal_turns.pop(goal_thread), "status": "completed"}}})


def clear_goal(runtime, _session_state, message):
    _session_state.goal_path.unlink(missing_ok=True)
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
    if "-single-server" in _session_state.mode:
        goal_thread = message.get("params", {}).get("threadId")
        runtime.write({"jsonrpc": "2.0", "method": "thread/goal/cleared", "params": {"threadId": goal_thread}})
        if goal_thread in _session_state.goal_turns:
            runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": goal_thread, "turn": {"id": _session_state.goal_turns.pop(goal_thread), "status": "completed"}}})


def skill_roots(runtime, _session_state, message):
    # Records the bridged skill folders Playhouse hands the shared app-server.
    _session_state.history = _session_state.serial_history()
    _session_state.history["skillExtraRoots"] = message.get("params", {}).get("extraRoots", [])
    _session_state.history["skillExtraRootsCalls"] = _session_state.history.get("skillExtraRootsCalls", 0) + 1
    _session_state.history_path.write_text(runtime.json.dumps(_session_state.history), encoding="utf-8")
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {}})


def start_thread(runtime, _session_state, message):
    # `-single-server` modes run several tasks' threads on one server.
    if "-question-isolation-" in _session_state.mode or "-single-server" in _session_state.mode:
        runtime.THREAD_ID = str(runtime.uuid.uuid4())
    _session_state.thread_start_instructions = message.get("params", {}).get("developerInstructions")
    if _session_state.serial_mode:
        _session_state.history = _session_state.serial_history()
        if _session_state.history.get("threadID") is not None:
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32001, "message": "This fixture thread already exists; resume it instead of starting another."}})
            return
        runtime.THREAD_ID = str(runtime.uuid.uuid4())
        _session_state.history["threadID"] = runtime.THREAD_ID
        _session_state.history["threadStartDeveloperInstructions"] = _session_state.thread_start_instructions
        _session_state.history["events"].append({"method": "thread/start", "threadID": runtime.THREAD_ID})
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.history), encoding="utf-8")
    else:
        _session_state.history = _session_state.serial_history()
        _session_state.history.update({
            "threadID": runtime.THREAD_ID,
            "threadStartDeveloperInstructions": _session_state.thread_start_instructions,
            "threadStartConfig": message.get("params", {}).get("config"),
            "threadStartCwd": message.get("params", {}).get("cwd"),
            "threadStartRuntimeWorkspaceRoots": message.get("params", {}).get("runtimeWorkspaceRoots", []),
            "threadStartCount": _session_state.history.get("threadStartCount", 0) + 1,
        })
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.history), encoding="utf-8")
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": runtime.THREAD_ID}, "model": message.get("params", {}).get("model", "gpt-6-luna")}})


def resume_thread(runtime, _session_state, message):
    if "-question-isolation-" in _session_state.mode or "-single-server" in _session_state.mode:
        runtime.THREAD_ID = message["params"]["threadId"]
    if "-single-server" in _session_state.mode:
        with open(_session_state.fixture_state_directory / f"{runtime.Path(runtime.sys.argv[0]).name}.resumes", "a", encoding="utf-8") as handle:
            handle.write(runtime.json.dumps({"threadId": runtime.THREAD_ID, "model": message["params"].get("model")}) + "\n")
    _session_state.resume_error = runtime.Path(str(runtime.sys.argv[0]) + ".resume-error")
    if _session_state.resume_error.is_file():
        _session_state.resume_error.unlink(missing_ok=True)
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {
            "code": -32010,
            "message": "Fixture thread resume failed after receiving fixture-secret.",
        }})
        return
    if _session_state.serial_mode:
        _session_state.requested_thread_id = message.get("params", {}).get("threadId")
        _session_state.history = _session_state.serial_history()
        if not _session_state.history.get("threadID") or _session_state.requested_thread_id != _session_state.history["threadID"]:
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32002, "message": "The requested thread does not match the fixture's existing thread."}})
            return
        runtime.THREAD_ID = _session_state.history["threadID"]
        _session_state.history["events"].append({"method": "thread/resume", "threadID": runtime.THREAD_ID})
        _session_state.history.setdefault("threadResumeDeveloperInstructions", []).append(
            message.get("params", {}).get("developerInstructions")
        )
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.history), encoding="utf-8")
    else:
        _session_state.history = _session_state.serial_history()
        _session_state.history.update({
            "threadID": runtime.THREAD_ID,
            "threadResumeCount": _session_state.history.get("threadResumeCount", 0) + 1,
            "threadResumeConfig": message.get("params", {}).get("config"),
        })
        _session_state.history.setdefault("threadResumeDeveloperInstructions", []).append(
            message.get("params", {}).get("developerInstructions")
        )
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.history), encoding="utf-8")
    resumed_model = message.get("params", {}).get("model", "gpt-6-luna")
    # Codex ignores the requested model when it still has the thread open (a
    # turn on it just ended) and reports the thread's own; a one-shot marker
    # names the model that loaded thread keeps.
    kept_model = runtime.Path(str(runtime.sys.argv[0]) + ".resume-keeps-model")
    if kept_model.is_file():
        _session_state.history = _session_state.serial_history()
        _session_state.history.setdefault("threadResumeKeptModels", []).append(
            {"requested": resumed_model, "reported": kept_model.read_text(encoding="utf-8").strip()}
        )
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.history), encoding="utf-8")
        resumed_model = _session_state.history["threadResumeKeptModels"][-1]["reported"]
        kept_model.unlink(missing_ok=True)
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": runtime.THREAD_ID}, "model": resumed_model}})


def answer_question(runtime, _session_state, message):
    if "-question-isolation-" in _session_state.mode:
        runtime.THREAD_ID, runtime.TURN_ID = runtime.question_contexts.pop(message["id"])
    if "error" in message:
        _session_state.answers = None
        _session_state.rejection_message = message.get("error", {}).get("message", "")
        if "private Playhouse status nudge" in _session_state.rejection_message:
            with runtime.Path(str(runtime.sys.argv[0]) + ".private-reminder-question-rejection").open("a", encoding="utf-8") as _session_state.stream:
                _session_state.stream.write(_session_state.rejection_message + "\n")
    else:
        _session_state.answers = message.get("result", {}).get("answers")
    if "-slow" in _session_state.mode and not _session_state.mode.endswith("-interrupted"):
        runtime.time.sleep(2)
    _session_state.expected_answers = {
        "color": {"answers": ["Blue"]},
        "token": {"answers": ["fixture-secret"]},
    }
    if "-nonblocking" in _session_state.mode:
        _session_state.expected_answers = {"color": {"answers": ["Custom approach"]}, "token": {"answers": ["fixture-secret"]}}
    elif runtime.is_restart_question_mode(_session_state.mode):
        _session_state.no_secret_fixture = _session_state.mode.endswith("-restart-question-no-secret")
        _session_state.secret_stage = runtime.Path(str(runtime.sys.argv[0]) + ".secret-stage").exists()
        _session_state.expected_answers = (
            {"color": {"answers": ["Blue"]}}
            if _session_state.no_secret_fixture and not _session_state.secret_stage
            else ({"color": {"answers": ["Green"]}, "token": {"answers": ["fixture-secret"]}}
                  if _session_state.no_secret_fixture else {"token": {"answers": ["fixture-secret"]}})
        )
    elif _session_state.mode.endswith("-nonblocking-slow"):
        _session_state.expected_answers["color"] = {"answers": ["Custom approach"]}
    if _session_state.mode.endswith("-user-question"):
        _session_state.expected_answers = {"question_action": {"answers": ["Continue"]}}
    _session_state.failed = _session_state.mode.endswith("-empty") or _session_state.mode.endswith("-fail") or _session_state.answers != _session_state.expected_answers
    if not _session_state.failed and "-question-isolation-" in _session_state.mode and runtime.THREAD_ID == runtime.first_question_thread and runtime.question_rounds[runtime.THREAD_ID] == 1:
        runtime.question_request(901, followup=True)
        return
    if "-question-isolation-" in _session_state.mode:
        _session_state.isolation_turns[runtime.THREAD_ID] = (runtime.TURN_ID, _session_state.answers)
    if not _session_state.failed and runtime.Path(str(runtime.sys.argv[0]) + ".outcome-hold").exists():
        _session_state.active = runtime.Path(str(runtime.sys.argv[0]) + ".outcome-active")
        _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".outcome-release")
        _session_state.active.write_text("The answered fixture turn is waiting for its explicit outcome.\n", encoding="utf-8")
        _session_state.deadline = runtime.time.monotonic() + 30
        while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        _session_state.was_released = _session_state.release.exists()
        _session_state.active.unlink(missing_ok=True)
        _session_state.release.unlink(missing_ok=True)
        if not _session_state.was_released:
            runtime.os._exit(3)
    if not _session_state.failed and runtime.is_restart_question_mode(_session_state.mode):
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
            "item": {"id": f"item_recovered_answer_{runtime.TURN_ID}", "type": "agentMessage", "phase": "final_answer", "text": runtime.answer_text(_session_state.turn_message)},
        }})
    else:
        _session_state.echoed = runtime.echoed_outcome_answer(_session_state.turn_message)
        if not _session_state.failed and _session_state.echoed:
            runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
                "item": {
                    "id": "item_playhouse_echoed_outcome",
                    "type": "agentMessage",
                    "phase": "final_answer",
                    "text": _session_state.echoed,
                },
            }})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "interrupted" if _session_state.mode.endswith("-interrupted") else ("failed" if _session_state.failed else "completed"),
                 **({"error": {"message": "Codex interrupted this turn."}} if _session_state.mode.endswith("-interrupted") else ({"error": {"message": "Question response was missing or incorrect."}} if _session_state.failed else {}))},
    }})


def steer_turn(runtime, _session_state, message):
    _session_state.params = message.get("params", {})
    if _session_state.params.get("threadId") != runtime.THREAD_ID or _session_state.params.get("expectedTurnId") != runtime.TURN_ID:
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32010, "message": "The expected turn ID is stale."}})
    else:
        _session_state.saved_history = _session_state.serial_history()
        _session_state.saved_history.setdefault("steerRequests", []).append(_session_state.params)
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turnId": runtime.TURN_ID}})


def interrupt_turn(runtime, _session_state, message):
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {}})


def compact_thread(runtime, _session_state, message):
    _session_state.params = message.get("params", {})
    if _session_state.params.get("threadId") != runtime.THREAD_ID:
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32005, "message": "Unknown fixture thread."}})
        return
    _session_state.saved_history = _session_state.serial_history()
    _session_state.saved_history.setdefault("rpcOrder", []).append({"method": "thread/compact/start"})
    if runtime.Path(str(runtime.sys.argv[0]) + ".compact-fail").exists():
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32020, "message": "Fixture compaction failed."}})
        return
    turn_list = _session_state.saved_history.get("messages") or _session_state.saved_history.get("turns") or []
    compaction_index = len(_session_state.saved_history.get("compactions", [])) + 1
    compaction_turn_id = f"turn_compaction_{compaction_index}"
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
    runtime.write({"jsonrpc": "2.0", "method": "turn/started", "params": {
        "threadId": runtime.THREAD_ID, "turn": {"id": compaction_turn_id, "status": "inProgress"},
    }})
    # Accept reads while compaction is pending. Starting work in this
    # interval is a protocol error, even though the start RPC succeeded.
    _session_state.deadline = runtime.time.monotonic() + 0.3
    while runtime.time.monotonic() < _session_state.deadline:
        _session_state.readable, _session_state._, _session_state._ = runtime.stdin_select(0.02)
        if not _session_state.readable:
            continue
        _session_state.incoming = runtime.json.loads(runtime.sys.stdin.readline())
        if _session_state.incoming.get("method") == "turn/start":
            runtime.write({"jsonrpc": "2.0", "id": _session_state.incoming["id"], "error": {
                "code": -32020, "message": "Work started before compaction completed.",
            }})
        else:
            _session_state.handle_message(_session_state.incoming)
    _session_state.saved_history.setdefault("rpcOrder", []).append({"method": "compaction/completed"})
    if runtime.Path(str(runtime.sys.argv[0]) + ".compact-terminal-fail").exists():
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID, "turn": {"id": compaction_turn_id, "status": "failed",
            "error": {"message": "Compaction failed after acknowledgment."}}, "usage": {},
        }})
        return
    record = {
        "afterTurnCount": len(turn_list),
        "turnID": turn_list[-1].get("turnID") if turn_list else None,
        "item": {"id": f"item_playhouse_compaction_{compaction_index}", "type": "contextCompaction"},
    }
    _session_state.saved_history.setdefault("compactions", []).append(record)
    _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID, "turn": {"id": compaction_turn_id, "status": "completed"}, "usage": {},
    }})


def read_thread(runtime, _session_state, message):
    if message.get("params", {}).get("threadId") != runtime.CHILD_THREAD_ID:
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32005, "message": "Unknown fixture child thread."}})
        return
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": runtime.CHILD_THREAD_ID, "turns": []}}})


def list_turns(runtime, _session_state, message):
    if message.get("params", {}).get("threadId") == runtime.THREAD_ID and runtime.TURN_ID:
        # A client that reconnects mid-turn learns the turn is still running.
        held = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-ready").exists() or (
            _session_state.mode.endswith("-private-reminder")
            and runtime.Path(str(runtime.sys.argv[0]) + ".private-reminder-before-ready").exists()
            and not runtime.Path(str(runtime.sys.argv[0]) + ".private-reminder-question-rejection").exists()
        )
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
            "data": [{"id": runtime.TURN_ID, "status": "inProgress" if held else "completed"}],
            "nextCursor": None,
        }})
        return
    if message.get("params", {}).get("threadId") != runtime.CHILD_THREAD_ID:
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32005, "message": "Unknown fixture child thread."}})
        return
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
        "data": [{"id": runtime.CHILD_TURN_ID, "status": "completed"}],
        "nextCursor": None,
    }})

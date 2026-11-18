"""Turn setup and scenario dispatch for the Codex fixture."""

import codex_fixture_protocol as _protocol
import codex_fixture_turn_control as _control
import codex_fixture_turn_scenarios as _scenarios


def start_turn(runtime, _session_state, message):
    # The message was sent but Codex hasn't acknowledged the turn, so it has no turn ID yet.
    _protocol.wait_for_release(runtime, "turn-start", "Codex received turn/start and has not answered it.")
    if _session_state.mode.endswith(("-context-compaction", "-native-compaction")):
        order_history = _session_state.serial_history()
        order_history.setdefault("rpcOrder", []).append({"method": "turn/start"})
        _session_state.history_path.write_text(runtime.json.dumps(order_history), encoding="utf-8")
    if "-single-server" in _session_state.mode:
        runtime.THREAD_ID = message["params"]["threadId"]
        runtime.TURN_ID = f"turn-{runtime.uuid.uuid4()}"
    if "-question-isolation-" in _session_state.mode:
        runtime.THREAD_ID = message["params"]["threadId"]
        runtime.TURN_ID = f"turn-{runtime.uuid.uuid4()}"
        _session_state.isolation_turns[runtime.THREAD_ID] = (runtime.TURN_ID, None)
    _session_state.saw_turn = True
    _session_state.saw_question = True
    if runtime.is_restart_question_mode(_session_state.mode):
        runtime.TURN_ID = f"turn-{runtime.uuid.uuid4()}"
    _session_state.turn_input = message.get("params", {}).get("input", [])
    _session_state.turn_message = next((item.get("text") for item in _session_state.turn_input if item.get("type") == "text"), None)
    _session_state.is_outcome_reminder = "playhouse internal outcome nudge:" in (_session_state.turn_message or "").lower()
    if _session_state.is_outcome_reminder:
        runtime.TURN_ID = f"turn-{runtime.uuid.uuid4()}"
        runtime.REMINDER_TURN_IDS.add(runtime.TURN_ID)
    elif runtime.TURN_ID in runtime.REMINDER_TURN_IDS:
        runtime.TURN_ID = runtime.DEFAULT_TURN_ID
    _session_state.is_title_request = (_session_state.turn_message or "").startswith("Write a concise task title of at most 8 words")
    _session_state.serial_first_turn = False
    if "-unique-turns-" in _session_state.mode and not _session_state.is_title_request:
        runtime.TURN_ID = f"turn-{runtime.uuid.uuid4()}"
    if _session_state.serial_mode and not _session_state.is_title_request:
        runtime.TURN_ID = f"turn-{runtime.uuid.uuid4()}"
        _session_state.first_turn_marker = runtime.Path(str(runtime.sys.argv[0]) + ".serial-first-turn")
        try:
            _session_state.descriptor = runtime.os.open(_session_state.first_turn_marker, runtime.os.O_CREAT | runtime.os.O_EXCL | runtime.os.O_WRONLY, 0o600)
        except FileExistsError:
            runtime.Path(str(runtime.sys.argv[0]) + ".serial-second-turn-started").touch()
        else:
            runtime.os.close(_session_state.descriptor)
            _session_state.serial_first_turn = True
    _session_state.turn_thread_id = message.get("params", {}).get("threadId")
    if _session_state.serial_mode and _session_state.turn_thread_id != runtime.THREAD_ID:
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32003, "message": "The turn must use the active fixture thread."}})
        return
    _session_state.fail_marker = runtime.Path(str(runtime.sys.argv[0]) + ".fail-next-turn-start")
    if _session_state.serial_mode and _session_state.fail_marker.exists():
        _session_state.fail_marker.unlink(missing_ok=True)
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32099, "message": "Fixture rejected the targeted queued turn."}})
        return
    if _session_state.is_title_request:
        if _session_state.mode.endswith("-title-failure"):
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {
                "code": -32042,
                "message": f"Fixture rejected task-title generation. {_session_state.turn_message}",
            }})
            return
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": runtime.TURN_ID, "status": "inProgress"}}})
        if _session_state.mode.endswith("-title-success-wait"):
            _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".resolve-ready")
            _session_state.resume = runtime.Path(str(runtime.sys.argv[0]) + ".resolve-continue")
            _session_state.ready.write_text("Codex task-title turn is active.\n", encoding="utf-8")
            _session_state.deadline = runtime.time.monotonic() + 30
            while not _session_state.resume.exists() and runtime.time.monotonic() < _session_state.deadline:
                _session_state.drain_pending_stdin()
                runtime.time.sleep(0.02)
            if not _session_state.resume.exists():
                runtime.os._exit(3)
            _session_state.ready.unlink(missing_ok=True)
            _session_state.resume.unlink(missing_ok=True)
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "item": {
                "id": "item_playhouse_title",
                "type": "agentMessage",
                "phase": "final_answer",
                "text": "Generated fixture title",
            },
        }})
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turn": {"id": runtime.TURN_ID, "status": "completed"},
        }})
        return
    is_pull_request_summary_request = (_session_state.turn_message or "").startswith("Write a very concise GitHub pull request description.")
    if is_pull_request_summary_request:
        # A one-shot helper turn (Auto PR's pull-request description), not an
        # interactive conversation: answer directly instead of asking a question.
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": runtime.TURN_ID, "status": "inProgress"}}})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "item": {
                "id": "item_playhouse_pr_summary",
                "type": "agentMessage",
                "phase": "final_answer",
                "text": "Fixture pull request summary.",
            },
        }})
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turn": {"id": runtime.TURN_ID, "status": "completed"},
        }})
        return
    if "-token-waste" in _session_state.mode:
        runtime.write_waste_rollouts(_session_state.turn_thread_id)
    _session_state.image_inputs = [item for item in _session_state.turn_input if item.get("type") == "image"]
    _session_state.turn_history = {
        "userMessage": _session_state.turn_message,
        "turnID": runtime.TURN_ID,
        "images": [item.get("url") for item in _session_state.image_inputs],
        "imageInputs": _session_state.image_inputs,
        "conversationMode": message.get("params", {}).get("collaborationMode", {}).get("mode"),
        "reasoningEffort": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("reasoningEffort"),
        "modelID": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("model"),
        "developerInstructions": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("developerInstructions"),
        "cwd": message.get("params", {}).get("cwd"),
        "runtimeWorkspaceRoots": message.get("params", {}).get("runtimeWorkspaceRoots", []),
        "skillInputs": [item for item in _session_state.turn_input if item.get("type") == "skill"],
    }
    if _session_state.serial_mode:
        _session_state.saved_history = _session_state.serial_history()
        _session_state.messages = _session_state.saved_history["messages"]
        _session_state.turn_history["threadID"] = runtime.THREAD_ID
        _session_state.messages.append(_session_state.turn_history)
        _session_state.saved_history["messages"] = _session_state.messages
        if not _session_state.is_outcome_reminder:
            _session_state.saved_history.update(_session_state.turn_history)
        _session_state.saved_history["events"].append({"method": "turn/start", "threadID": runtime.THREAD_ID, "turnID": runtime.TURN_ID, "userMessage": _session_state.turn_message, "conversationMode": _session_state.turn_history["conversationMode"]})
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
    else:
        _session_state.saved_history = _session_state.serial_history()
        if not _session_state.is_outcome_reminder:
            _session_state.saved_history.update(_session_state.turn_history)
        _session_state.turns = _session_state.saved_history.get("turns", [])
        _session_state.turns.append(_session_state.turn_history)
        _session_state.saved_history["turns"] = _session_state.turns
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
    _session_state.preserve_no_outcome = any(marker in _session_state.mode for marker in ("nonblocking-slow", "nonblocking-restart-question", "hold-release", "question-isolation"))
    if "-background-" in _session_state.mode:
        return _scenarios.background_command(runtime, _session_state, message)
    if _session_state.is_outcome_reminder and "nudged-work" in _session_state.mode:
        # The nudge says to keep working when work remains, so this turn
        # streams commentary and a shell check, answers, and only then
        # reports completed, all inside the private status nudge.
        saved = _session_state.serial_history()
        _session_state.instructions = (
            _session_state.turn_history.get("developerInstructions")
            or saved.get("threadStartDeveloperInstructions")
            or ((saved.get("threadResumeDeveloperInstructions") or [None])[-1])
            or ""
        )
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": runtime.TURN_ID, "status": "inProgress"}}})
        if runtime.Path(str(runtime.sys.argv[0]) + ".nudged-steer-pause").exists():
            # The test steers this running nudge turn, as a user can.
            runtime.Path(str(runtime.sys.argv[0]) + ".nudged-steer-ready").write_text("The nudged turn is waiting for a steer.\n", encoding="utf-8")
            steered_text = None
            steer_deadline = runtime.time.monotonic() + 60
            while steered_text is None and runtime.time.monotonic() < steer_deadline:
                _session_state.readable, _session_state._, _session_state._ = runtime.stdin_select(0.02)
                if not _session_state.readable:
                    continue
                try:
                    _session_state.incoming = runtime.json.loads(runtime.sys.stdin.readline())
                except runtime.json.JSONDecodeError:
                    continue
                if _session_state.incoming.get("method") != "turn/steer":
                    _session_state.answer_read_while_held(_session_state.incoming)
                    continue
                steer_params = _session_state.incoming.get("params", {})
                if steer_params.get("threadId") != runtime.THREAD_ID or steer_params.get("expectedTurnId") != runtime.TURN_ID:
                    runtime.write({"jsonrpc": "2.0", "id": _session_state.incoming["id"], "error": {"code": -32000, "message": "No matching active turn."}})
                    continue
                steered_text = "\n".join(item.get("text", "") for item in steer_params.get("input", []) if item.get("type") == "text")
                runtime.write({"jsonrpc": "2.0", "id": _session_state.incoming["id"], "result": {"turnId": runtime.TURN_ID}})
                steered_history = _session_state.serial_history()
                steered_history["steerRequests"] = steered_history.get("steerRequests", []) + [steer_params]
                _session_state.history_path.write_text(runtime.json.dumps(steered_history), encoding="utf-8")
            if steered_text is None:
                runtime.os._exit(3)
            # One steer per pause: a later nudge in the same conversation keeps working
            # instead of waiting out the steer deadline.
            runtime.Path(str(runtime.sys.argv[0]) + ".nudged-steer-pause").unlink(missing_ok=True)
            runtime.Path(str(runtime.sys.argv[0]) + ".nudged-steer-ready").unlink(missing_ok=True)
        for _session_state.item in runtime.nudged_work_items(len(saved.get("turns", [])) - 1):
            nudged_final = runtime.Path(str(runtime.sys.argv[0]) + ".nudged-final")
            if _session_state.item.get("phase") == "final_answer" and runtime.Path(f"{nudged_final}-pause").exists():
                # The test reads the transcript while the steered turn is still running.
                runtime.Path(f"{nudged_final}-ready").write_text("The nudged turn worked after the steer.\n", encoding="utf-8")
                final_deadline = runtime.time.monotonic() + 60
                while not runtime.Path(f"{nudged_final}-release").exists() and runtime.time.monotonic() < final_deadline:
                    _session_state.drain_pending_stdin()
                    runtime.time.sleep(0.02)
                for suffix in ("pause", "ready", "release"):
                    runtime.Path(f"{nudged_final}-{suffix}").unlink(missing_ok=True)
            if _session_state.item["type"] == "commandExecution":
                runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": {**_session_state.item, "status": "inProgress"},
                }})
            runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
            }})
        _session_state.outcome_line = next((line.strip() for line in _session_state.instructions.splitlines() if " task outcome " in line), None)
        if _session_state.outcome_line:
            _session_state.completed = runtime.subprocess.run(
                runtime.shlex.split(_session_state.outcome_line.replace("<completed|waiting-response|blocked>", "completed")),
                capture_output=True, text=True, timeout=60,
            )
            if _session_state.completed.returncode != 0:
                raise RuntimeError(f"Fixture task outcome command failed: {_session_state.completed.stderr.strip()}")
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"}}})
        return
    if _session_state.is_outcome_reminder and not _session_state.preserve_no_outcome:
        # A fixture that only ever resumed an existing thread has no
        # thread-start instructions of its own; its outcome command
        # lives in the resume instructions Playhouse sent instead.
        saved = _session_state.serial_history()
        _session_state.instructions = (
            _session_state.turn_history.get("developerInstructions")
            or saved.get("threadStartDeveloperInstructions")
            or ((saved.get("threadResumeDeveloperInstructions") or [None])[-1])
            or ""
        )
        # Command lines start with the quoted CLI path; prose (such as a chat's note
        # that task outcomes don't apply to it) may mention the same words.
        _session_state.outcome_line = next((line.strip() for line in _session_state.instructions.splitlines()
                             if line.strip().startswith("'") and " task outcome " in line), None)
        if _session_state.outcome_line:
            _session_state.outcome_command = _session_state.outcome_line.replace("<completed|waiting-response|blocked>", "waiting-response")
            _session_state.completed = runtime.subprocess.run(runtime.shlex.split(_session_state.outcome_command), capture_output=True, text=True, timeout=60)
            if _session_state.completed.returncode != 0:
                raise RuntimeError(f"Fixture task outcome command failed: {_session_state.completed.stderr.strip()}")
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": runtime.TURN_ID, "status": "inProgress"}}})
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"}}})
        return
    _session_state.provider_error = runtime.Path(str(runtime.sys.argv[0]) + ".provider-error")
    if _session_state.provider_error.exists():
        _session_state.provider_error.unlink(missing_ok=True)
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
            "turn": {"id": runtime.TURN_ID, "status": "failed", "error": {"message": "Fixture provider failed after receiving fixture-secret. Answer: Green. Continue this conversation by applying the user's answer to the pending question."}},
        }})
        return
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": runtime.TURN_ID, "status": "inProgress"}}})
    if (_session_state.turn_message or "").startswith(
        "Classify the latest user message for Playhouse's continuous chat page index."
    ):
        # One-shot Codex helper clients consume the streamed completion
        # directly; provide the same fixture answer the transcript path
        # returns for ordinary conversation turns.
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turnId": runtime.TURN_ID,
            "item": {
                "id": "item_playhouse_chat_classifier",
                "type": "agentMessage",
                "text": runtime.answer_text(_session_state.turn_message),
            },
        }})
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turn": {"id": runtime.TURN_ID, "status": "completed"},
        }})
        return
    _session_state.async_provider_error = runtime.Path(str(runtime.sys.argv[0]) + ".provider-error-async")
    if _session_state.async_provider_error.exists():
        return _control.async_error(runtime, _session_state, message)
    elif runtime.Path(str(runtime.sys.argv[0]) + ".hold-release").exists():
        return _control.held_release(runtime, _session_state, message)
    elif _session_state.mode.endswith("-hold-interrupt") or _session_state.mode.endswith("-hold-reject-interrupt"):
        return _control.held_interrupt(runtime, _session_state, message)
    elif _session_state.mode.endswith("-abort"):
        return _control.abort(runtime, _session_state, message)
    elif _session_state.mode.endswith("-success") or _session_state.mode.endswith("-timeline-tool-calls"):
        return _control.success(runtime, _session_state, message)
    elif _session_state.mode.endswith("-title-success-wait"):
        return _control.title_success(runtime, _session_state, message)
    elif _session_state.mode.endswith("-title-failure"):
        return _control.title_failure(runtime, _session_state, message)
    elif _session_state.async_mode:
        return _control.async_question(runtime, _session_state, message)
    elif _session_state.serial_mode and _session_state.serial_first_turn and _session_state.mode.endswith("-serial-success-wait"):
        return _control.serial_steer(runtime, _session_state, message)
    elif _session_state.serial_mode and runtime.Path(str(runtime.sys.argv[0]) + ".hold-next-queued-turn").exists():
        return _control.serial_queue(runtime, _session_state, message)
    elif _session_state.serial_mode:
        return _control.serial_success(runtime, _session_state, message)
    elif _session_state.mode.endswith("-success-wait") and not _session_state.mode.endswith("-title-success-wait"):
        return _scenarios.success_wait(runtime, _session_state, message)
    elif _session_state.mode.endswith("-follow-active-turn"):
        return _scenarios.follow_active(runtime, _session_state, message)
    elif _session_state.mode.endswith("-native-compaction"):
        return _scenarios.auto_compaction(runtime, _session_state, message)
    elif _session_state.mode.endswith("-context-compaction"):
        return _scenarios.context_compaction(runtime, _session_state, message)
    elif _session_state.mode.endswith("-subagent") or _session_state.mode.endswith("-subagent-wait") or _session_state.mode.endswith("-tool-activity"):
        return _scenarios.subagents(runtime, _session_state, message)
    elif _session_state.mode.endswith("-markdown"):
        return _scenarios.markdown(runtime, _session_state, message)
    elif _session_state.mode.endswith("-hold"):
        return _scenarios.held_turn(runtime, _session_state, message)
    elif runtime.is_restart_question_mode(_session_state.mode):
        return _scenarios.restart_question(runtime, _session_state, message)
    elif _session_state.mode.endswith("-question"):
        return _scenarios.question(runtime, _session_state, message)
    elif "-hold-release" in _session_state.mode:
        return _scenarios.release_marker(runtime, _session_state, message)
    else:
        return _scenarios.default_turn(runtime, _session_state, message)

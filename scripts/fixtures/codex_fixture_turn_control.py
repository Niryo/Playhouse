"""Held, serial, and asynchronous turn scenarios."""

def async_error(runtime, _session_state, message):
    _session_state.async_provider_error.unlink(missing_ok=True)
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "failed", "error": {"message": "Fixture async failure echoed fixture-secret, Answer: Green, and the private recovery prompt."}},
    }})


def held_release(runtime, _session_state, message):
    _session_state.active = runtime.Path(str(runtime.sys.argv[0]) + ".turn-active")
    _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".turn-release")
    _session_state.active.write_text("The fixture turn is active for a CLI outcome report.\n", encoding="utf-8")
    _session_state.deadline = runtime.time.monotonic() + 30
    while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
        _session_state.drain_pending_stdin()
        runtime.time.sleep(0.02)
    _session_state.was_released = _session_state.release.exists()
    _session_state.active.unlink(missing_ok=True)
    _session_state.release.unlink(missing_ok=True)
    runtime.time.sleep(0.1)
    if not _session_state.was_released:
        runtime.os._exit(3)
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def held_interrupt(runtime, _session_state, message):
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
        "item": {"id": "item_user_fixture_1", "type": "userMessage"},
    }})
    # Report one activity before holding, so a user-initiated Stop with
    # no final answer still keeps the window's activity section mounted
    # and the fold it performs on settle is distinguishable from the
    # section simply never having rendered.
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
        "item": {
            "id": "item_fixture_stop_command",
            "type": "commandExecution",
            "command": "git status --short",
            "cwd": runtime.workspace_cwd(),
        },
    }})
    _session_state.active = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-ready")
    _session_state.active.write_text("The fixture turn is active and waiting for an interrupt.\n", encoding="utf-8")
    _session_state.deadline = runtime.time.monotonic() + 30
    _session_state.received_interrupt = False
    while runtime.time.monotonic() < _session_state.deadline:
        _session_state.ready, _session_state._, _session_state._ = runtime.stdin_select(0.02)
        if not _session_state.ready:
            continue
        _session_state.interrupt_message = runtime.json.loads(runtime.sys.stdin.readline())
        if _session_state.interrupt_message.get("method") != "turn/interrupt":
            _session_state.answer_read_while_held(_session_state.interrupt_message)
            continue
        _session_state.received_interrupt = True
        _session_state.saved_history = _session_state.serial_history()
        _session_state.saved_history["interruptReceived"] = True
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
        runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-received").write_text("turn/interrupt\n", encoding="utf-8")
        if _session_state.mode.endswith("-hold-reject-interrupt"):
            _session_state.reject = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-reject")
            _session_state.reject_deadline = runtime.time.monotonic() + 15
            while not _session_state.reject.exists() and runtime.time.monotonic() < _session_state.reject_deadline:
                _session_state.drain_pending_stdin()
                runtime.time.sleep(0.02)
            _session_state.reject.unlink(missing_ok=True)
            runtime.write({"jsonrpc": "2.0", "id": _session_state.interrupt_message["id"], "error": {
                "code": -32044, "message": "Fixture rejected the interrupt while the turn remains active.",
            }})
            _session_state.interrupt_release = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-release")
            _session_state.ack_deadline = runtime.time.monotonic() + 15
            while not _session_state.interrupt_release.exists() and runtime.time.monotonic() < _session_state.ack_deadline:
                _session_state.drain_pending_stdin()
                runtime.time.sleep(0.02)
            _session_state.interrupt_release.unlink(missing_ok=True)
            runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                "threadId": runtime.THREAD_ID,
                "item": {"id": "item_playhouse_message", "type": "agentMessage", "text": "The turn completed after Stop was rejected."},
            }})
            runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": runtime.THREAD_ID,
                "turn": {"id": runtime.TURN_ID, "status": "completed"},
            }})
            break
        _session_state.interrupt_release = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-release")
        _session_state.ack_deadline = runtime.time.monotonic() + 15
        while not _session_state.interrupt_release.exists() and runtime.time.monotonic() < _session_state.ack_deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        _session_state.interrupt_release.unlink(missing_ok=True)
        runtime.write({"jsonrpc": "2.0", "id": _session_state.interrupt_message["id"], "result": {}})
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turn": {"id": runtime.TURN_ID, "status": "interrupted", "error": {"message": "Codex interrupted this turn."}},
        }})
        break
    _session_state.active.unlink(missing_ok=True)
    if not _session_state.received_interrupt:
        runtime.os._exit(3)


def abort(runtime, _session_state, message):
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "interrupted", "error": {"message": "Fixture interrupted the conflict-resolution turn."}},
    }})


def success(runtime, _session_state, message):
    # Emit the same item identities that thread/items/list returns.
    if "-unique-turns-success" in _session_state.mode:
        _session_state.index = len(_session_state.serial_history().get("turns", []))
        for _session_state.item in (
            {"id": f"item_user_fixture_{_session_state.index}", "type": "userMessage"},
            {"id": f"item_assistant_fixture_{_session_state.index}", "type": "agentMessage", "phase": "final_answer", "text": runtime.answer_text(_session_state.turn_message)},
        ):
            runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
            }})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def title_success(runtime, _session_state, message):
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def title_failure(runtime, _session_state, message):
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def async_question(runtime, _session_state, message):
    _session_state.first_turn = len(_session_state.serial_history().get("messages", [])) == 1
    if _session_state.first_turn:
        _session_state.items = [runtime.async_question_item(), {
            "id": "item_playhouse_async_followup",
            "type": "agentMessage", "phase": "final_answer",
            "text": "I can continue while you decide.",
        }]
    else:
        _session_state.items = [{
            "id": "item_playhouse_async_answer",
            "type": "agentMessage", "phase": "final_answer",
            "text": f"Answers received: {_session_state.turn_message}",
        }]
    for _session_state.item in _session_state.items:
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
        }})
    if _session_state.first_turn and not _session_state.mode.endswith("-async-question-queued"):
        _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".question-ready")
        _session_state.ready.write_text("The async question is waiting during an active turn.\n", encoding="utf-8")
        _session_state.deadline = runtime.time.monotonic() + 120
        _session_state.steered_answer = None
        while _session_state.steered_answer is None and runtime.time.monotonic() < _session_state.deadline:
            _session_state.readable, _session_state._, _session_state._ = runtime.stdin_select(0.02)
            if not _session_state.readable:
                continue
            _session_state.incoming = runtime.json.loads(runtime.sys.stdin.readline())
            if _session_state.incoming.get("method") == "thread/items/list":
                _session_state.entries = []
                for _session_state.index, _session_state.saved_turn in enumerate(_session_state.serial_history().get("messages", []), start=1):
                    _session_state.turn_id = _session_state.saved_turn["turnID"]
                    _session_state.entries.append({"turnId": _session_state.turn_id, "item": {
                        "id": f"item_playhouse_async_user_{_session_state.index}", "type": "userMessage",
                        "content": [{"type": "text", "text": _session_state.saved_turn["userMessage"]}],
                    }})
                    if _session_state.index == 1:
                        _session_state.entries.extend([
                            {"turnId": _session_state.turn_id, "item": runtime.async_question_item()},
                            {"turnId": _session_state.turn_id, "item": {
                                "id": "item_playhouse_async_followup", "type": "agentMessage",
                                "phase": "final_answer", "text": "I can continue while you decide.",
                            }},
                        ])
                runtime.write({"jsonrpc": "2.0", "id": _session_state.incoming["id"], "result": {"data": _session_state.entries, "nextCursor": None}})
            elif _session_state.incoming.get("method") == "turn/steer":
                _session_state.params = _session_state.incoming.get("params", {})
                if _session_state.params.get("threadId") != runtime.THREAD_ID or _session_state.params.get("expectedTurnId") != runtime.TURN_ID:
                    runtime.write({"jsonrpc": "2.0", "id": _session_state.incoming["id"], "error": {"code": -32000, "message": "No matching active turn."}})
                    continue
                _session_state.steered_answer = "\n".join(item.get("text", "") for item in _session_state.params.get("input", []) if item.get("type") == "text")
                runtime.write({"jsonrpc": "2.0", "id": _session_state.incoming["id"], "result": {"turnId": runtime.TURN_ID}})
            else:
                _session_state.answer_read_while_held(_session_state.incoming)
        if _session_state.steered_answer is None:
            runtime.os._exit(3)
        _session_state.ready.unlink(missing_ok=True)
        _session_state.saved_history = _session_state.serial_history()
        _session_state.saved_history["messages"][0]["steeredAnswer"] = _session_state.steered_answer
        _session_state.saved_history["steerRequests"] = _session_state.saved_history.get("steerRequests", []) + [_session_state.params]
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": {
                "id": "item_playhouse_async_answer_steered", "type": "agentMessage", "phase": "final_answer",
                "text": f"Answers received: {_session_state.steered_answer}",
            },
        }})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": runtime.later_async_question_item(),
        }})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def serial_steer(runtime, _session_state, message):
    _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".resolve-ready")
    _session_state.resume = runtime.Path(str(runtime.sys.argv[0]) + ".resolve-continue")
    _session_state.ready.write_text("The first serialized fixture turn is active.\n", encoding="utf-8")
    # The UI case exercises several XPC/UI round trips while the
    # turn remains active. Keep the deterministic fixture held
    # long enough for that interaction sequence in Tart.
    _session_state.deadline = runtime.time.monotonic() + 120
    _session_state.steer_requests = []
    _session_state.rejected_steer_requests = []
    while not _session_state.resume.exists() and runtime.time.monotonic() < _session_state.deadline:
        _session_state.readable, _session_state._, _session_state._ = runtime.stdin_select(0.02)
        if _session_state.readable:
            try:
                _session_state.steer_request = runtime.json.loads(runtime.sys.stdin.readline())
            except runtime.json.JSONDecodeError:
                continue
            if _session_state.steer_request.get("method") == "thread/items/list":
                _session_state.observe_history = runtime.Path(str(runtime.sys.argv[0]) + ".observe-history-while-active")
                if _session_state.observe_history.exists():
                    runtime.Path(str(runtime.sys.argv[0]) + ".history-read-while-active").touch()
                runtime.write({"jsonrpc": "2.0", "id": _session_state.steer_request.get("id"), "result": {"data": [], "nextCursor": None}})
            elif _session_state.steer_request.get("method") == "turn/steer":
                _session_state.params = _session_state.steer_request.get("params", {})
                _session_state.reject_marker = runtime.Path(str(runtime.sys.argv[0]) + ".reject-next-steer")
                if _session_state.reject_marker.exists():
                    _session_state.rejection = _session_state.reject_marker.read_text(encoding="utf-8").strip()
                    _session_state.reject_marker.unlink()
                    _session_state.rejected_steer_requests.append(_session_state.params)
                    _session_state.error_code = -32010 if _session_state.rejection == "The expected turn ID is stale." else -32000
                    runtime.write({"jsonrpc": "2.0", "id": _session_state.steer_request["id"], "error": {"code": _session_state.error_code, "message": _session_state.rejection}})
                elif _session_state.params.get("threadId") != runtime.THREAD_ID or _session_state.params.get("expectedTurnId") != runtime.TURN_ID:
                    _session_state.rejected_steer_requests.append(_session_state.params)
                    runtime.write({"jsonrpc": "2.0", "id": _session_state.steer_request["id"], "error": {"code": -32000, "message": f"expected active turn id {_session_state.params.get('expectedTurnId')} but found {runtime.TURN_ID}"}})
                else:
                    _session_state.steer_requests.append(_session_state.params)
                    runtime.write({"jsonrpc": "2.0", "id": _session_state.steer_request["id"], "result": {"turnId": runtime.TURN_ID}})
            elif not _session_state.answer_read_while_held(_session_state.steer_request):
                runtime.write({"jsonrpc": "2.0", "id": _session_state.steer_request.get("id"), "error": {"code": -32601, "message": "Unsupported fixture request."}})
    if not _session_state.resume.exists():
        runtime.os._exit(3)
    _session_state.ready.unlink(missing_ok=True)
    _session_state.resume.unlink(missing_ok=True)
    if _session_state.steer_requests or _session_state.rejected_steer_requests:
        _session_state.saved_history = _session_state.serial_history()
        _session_state.saved_history["steerRequests"] = _session_state.saved_history.get("steerRequests", []) + _session_state.steer_requests
        _session_state.saved_history["rejectedSteerRequests"] = _session_state.saved_history.get("rejectedSteerRequests", []) + _session_state.rejected_steer_requests
        _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def serial_queue(runtime, _session_state, message):
    _session_state.hold_marker = runtime.Path(str(runtime.sys.argv[0]) + ".hold-next-queued-turn")
    _session_state.hold_marker.unlink(missing_ok=True)
    _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".queued-turn-ready")
    _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".queued-turn-release")
    _session_state.ready.write_text("A targeted queued turn is active.\n", encoding="utf-8")
    _session_state.deadline = runtime.time.monotonic() + 30
    _session_state.steer_requests = []
    _session_state.rejected_steer_requests = []
    completed_before_steer = False
    while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
        _session_state.readable, _session_state._, _session_state._ = runtime.stdin_select(0.02)
        if not _session_state.readable:
            continue
        try:
            _session_state.queued_request = runtime.json.loads(runtime.sys.stdin.readline())
        except runtime.json.JSONDecodeError:
            continue
        if _session_state.queued_request.get("method") == "thread/items/list":
            runtime.write({"jsonrpc": "2.0", "id": _session_state.queued_request.get("id"), "result": {"data": [], "nextCursor": None}})
        elif _session_state.queued_request.get("method") == "turn/steer":
            complete_first = runtime.Path(str(runtime.sys.argv[0]) + ".complete-before-steer-rejection")
            if complete_first.exists():
                complete_first.unlink()
                runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"},
                }})
                runtime.time.sleep(2)
                _session_state.rejected_steer_requests.append(_session_state.queued_request.get("params", {}))
                runtime.write({"jsonrpc": "2.0", "id": _session_state.queued_request["id"], "error": {"code": -32000, "message": "no active turn to steer"}})
                completed_before_steer = True
                break
            _session_state.rejection = runtime.Path(str(runtime.sys.argv[0]) + ".reject-next-steer")
            if _session_state.rejection.exists():
                _session_state.message_text = _session_state.rejection.read_text(encoding="utf-8").strip()
                _session_state.rejection.unlink(missing_ok=True)
                _session_state.rejected_steer_requests.append(_session_state.queued_request.get("params", {}))
                _session_state.error_code = -32010 if _session_state.message_text == "The expected turn ID is stale." else -32000
                runtime.write({"jsonrpc": "2.0", "id": _session_state.queued_request["id"], "error": {"code": _session_state.error_code, "message": _session_state.message_text}})
            else:
                _session_state.params = _session_state.queued_request.get("params", {})
                _session_state.steer_requests.append(_session_state.params)
                runtime.write({"jsonrpc": "2.0", "id": _session_state.queued_request["id"], "result": {"turnId": runtime.TURN_ID}})
        elif not _session_state.answer_read_while_held(_session_state.queued_request):
            runtime.write({"jsonrpc": "2.0", "id": _session_state.queued_request.get("id"), "error": {"code": -32601, "message": "Unsupported fixture request."}})
    _session_state.ready.unlink(missing_ok=True)
    _session_state.released = _session_state.release.exists() or completed_before_steer
    _session_state.release.unlink(missing_ok=True)
    if not _session_state.released:
        runtime.os._exit(3)
    _session_state.saved_history = _session_state.serial_history()
    _session_state.saved_history["steerRequests"] = _session_state.saved_history.get("steerRequests", []) + _session_state.steer_requests
    _session_state.saved_history["rejectedSteerRequests"] = _session_state.saved_history.get("rejectedSteerRequests", []) + _session_state.rejected_steer_requests
    _session_state.history_path.write_text(runtime.json.dumps(_session_state.saved_history), encoding="utf-8")
    if not completed_before_steer:
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turn": {"id": runtime.TURN_ID, "status": "completed"},
        }})


def serial_success(runtime, _session_state, message):
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})

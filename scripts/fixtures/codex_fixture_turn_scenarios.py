"""Compaction, subagent, restart, and display turn scenarios."""

def success_wait(runtime, _session_state, message):
    _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".resolve-ready")
    _session_state.resume = runtime.Path(str(runtime.sys.argv[0]) + ".resolve-continue")
    with runtime.Path(str(runtime.sys.argv[0]) + ".resolve-start-count").open("a", encoding="utf-8") as _session_state.stream:
        _session_state.stream.write("start\n")
    _session_state.ready.write_text("Codex conflict-resolution turn is active.\n", encoding="utf-8")
    _session_state.deadline = runtime.time.monotonic() + 30
    while not _session_state.resume.exists() and runtime.time.monotonic() < _session_state.deadline:
        _session_state.drain_pending_stdin()
        runtime.time.sleep(0.02)
    if not _session_state.resume.exists():
        runtime.os._exit(3)
    _session_state.ready.unlink(missing_ok=True)
    _session_state.resume.unlink(missing_ok=True)
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def follow_active(runtime, _session_state, message):
    # Holds before any output, so a test can reopen the conversation first,
    # then again while commentary and a running command are visible.
    runtime.Path(str(runtime.sys.argv[0]) + ".follow-turn-done").unlink(missing_ok=True)
    for stage, description in [("started", "Codex turn started without output."),
                               ("ready", "Codex turn shows progress and a running command.")]:
        if stage == "ready":
            for _session_state.item in runtime.follow_turn_items(finished=False):
                runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
                    "item": {**_session_state.item, "text": ""} if _session_state.item["type"] == "agentMessage" else _session_state.item,
                }})
                if _session_state.item["type"] == "agentMessage":
                    runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
                        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "itemId": _session_state.item["id"], "delta": _session_state.item["text"],
                    }})
                    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
                    }})
        _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + f".follow-turn-{stage}")
        _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + (".follow-turn-continue" if stage == "started" else ".follow-turn-release"))
        _session_state.ready.write_text(f"{description}\n", encoding="utf-8")
        _session_state.deadline = runtime.time.monotonic() + 60
        while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        if not _session_state.release.exists():
            runtime.os._exit(3)
        if stage == "ready":
            runtime.Path(str(runtime.sys.argv[0]) + ".follow-turn-done").touch()
        _session_state.ready.unlink(missing_ok=True)
        _session_state.release.unlink(missing_ok=True)
    for _session_state.item in runtime.follow_turn_items(finished=True)[1:]:
        if _session_state.item["type"] == "agentMessage":
            runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
                "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": {**_session_state.item, "text": ""},
            }})
            runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
                "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "itemId": _session_state.item["id"], "delta": _session_state.item["text"],
            }})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
        }})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"}}})


def auto_compaction(runtime, _session_state, message):
    _session_state.item = {
        "id": "item_playhouse_auto_threshold_answer",
        "type": "agentMessage",
        "phase": "final_answer",
        "text": "Codex fixture completed the automatic-compaction turn.",
    }
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": {**_session_state.item, "text": ""},
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "itemId": _session_state.item["id"], "delta": _session_state.item["text"],
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
    }})
    _session_state.instructions = _session_state.turn_history.get("developerInstructions") or _session_state.serial_history().get("threadStartDeveloperInstructions") or ""
    _session_state.outcome_line = next((line.strip() for line in _session_state.instructions.splitlines()
                         if line.strip().startswith("'") and " task outcome " in line), None)
    if _session_state.outcome_line:
        _session_state.outcome_command = _session_state.outcome_line.replace("<completed|in-progress|waiting-response>", "waiting-response")
        _session_state.completed = runtime.subprocess.run(runtime.shlex.split(_session_state.outcome_command), capture_output=True, text=True, timeout=60)
        if _session_state.completed.returncode != 0:
            raise RuntimeError(f"Fixture task outcome command failed: {_session_state.completed.stderr.strip()}")
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def context_compaction(runtime, _session_state, message):
    _session_state.compaction_item = {"id": "item_playhouse_compaction", "type": "contextCompaction", "payload": {"opaque": "COMPACTION_OPAQUE_SENTINEL"}}
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.compaction_item,
    }})
    _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".compaction-ready")
    _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".compaction-release")
    _session_state.ready.unlink(missing_ok=True)
    _session_state.release.unlink(missing_ok=True)
    _session_state.ready.write_text("Context compaction is active.\n", encoding="utf-8")
    _session_state.deadline = runtime.time.monotonic() + 30
    while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
        _session_state.drain_pending_stdin()
        runtime.time.sleep(0.02)
    _session_state.ready.unlink(missing_ok=True)
    if not _session_state.release.exists():
        runtime.os._exit(3)
    _session_state.release.unlink(missing_ok=True)
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.compaction_item,
    }})
    _session_state.item = {"id": "item_playhouse_final", "type": "agentMessage", "phase": "final_answer", "text": "Context compaction completed."}
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item}})
    runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {"threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "itemId": _session_state.item["id"], "delta": _session_state.item["text"]}})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item}})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"}}})


def subagents(runtime, _session_state, message):
    if _session_state.mode.endswith("-subagent-wait"):
        _session_state.active = runtime.Path(str(runtime.sys.argv[0]) + ".turn-active")
        _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".turn-release")
        _session_state.active.write_text("The subagent fixture turn is active before assistant output.\n", encoding="utf-8")
        _session_state.deadline = runtime.time.monotonic() + 90
        while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        _session_state.was_released = _session_state.release.exists()
        _session_state.active.unlink(missing_ok=True)
        _session_state.release.unlink(missing_ok=True)
        if not _session_state.was_released:
            runtime.os._exit(3)
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID, "item": runtime.subagent_item("inProgress"),
    }})
    _session_state.first_child_started = runtime.subagent_activity(
        "started", runtime.CHILD_THREAD_ID, "/agents/Sandbox review",
        model="gpt-6-sol", reasoning_effort="high",
    )
    _session_state.second_child_id = "00000000-0000-0000-0000-000000000003"
    _session_state.second_child_started = runtime.subagent_activity(
        "started", _session_state.second_child_id, "/agents/some_agent",
    )
    for _session_state.child_item in [_session_state.first_child_started, _session_state.second_child_started]:
        runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
            "threadId": runtime.THREAD_ID, "item": _session_state.child_item,
        }})
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID,
        "item": runtime.subagent_activity(
            "interacted", runtime.CHILD_THREAD_ID, "/agents/Sandbox review",
            model="gpt-6-sol", reasoning_effort="high",
        ),
    }})
    if not _session_state.mode.endswith("-tool-activity"):
        _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".subagent-ready")
        _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".subagent-release")
        _session_state.ready.unlink(missing_ok=True)
        _session_state.release.unlink(missing_ok=True)
        _session_state.ready.write_text("Subagent activities are active.\n", encoding="utf-8")
        _session_state.deadline = runtime.time.monotonic() + 30
        while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        _session_state.ready.unlink(missing_ok=True)
        if not _session_state.release.exists():
            runtime.os._exit(3)
        _session_state.release.unlink(missing_ok=True)
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID,
        # A terminal event may omit metadata reported by the start.
        "item": runtime.subagent_activity("completed", runtime.CHILD_THREAD_ID, None),
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "item": runtime.subagent_activity("interrupted", _session_state.second_child_id, "/agents/some_agent"),
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "item": runtime.subagent_activity("futureKind", "00000000-0000-0000-0000-000000000004", "/agents/Future review"),
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "item": runtime.subagent_item("completed"),
    }})
    if _session_state.mode.endswith("-tool-activity"):
        _session_state.mcp_item = {
            "id": "item_fixture_mcp_call", "type": "mcpToolCall", "server": "fixture-server",
            "tool": "lookup", "status": "inProgress", "arguments": {"token": "RAW_ARGUMENT_SECRET"},
        }
        _session_state.dynamic_item = {
            "id": "item_fixture_dynamic_call", "type": "dynamicToolCall", "tool": "summarize",
            "status": "inProgress", "arguments": {"prompt": "RAW_ARGUMENT_SECRET"},
        }
        _session_state.legacy_dynamic_item = {
            "id": "item_fixture_dynamic_legacy", "type": "dynamicToolCall", "tool": "legacySummary",
            "status": "inProgress", "arguments": {"input": "RAW_ARGUMENT_SECRET"},
        }
        _session_state.active_command_item = {
            "id": "item_fixture_active_long_command", "type": "commandExecution",
            "command": "long-command-name " + "argument-" * 40,
            "cwd": "/tmp/playhouse-fixture", "status": "inProgress",
        }
        for _session_state.tool_item in [_session_state.mcp_item, _session_state.dynamic_item, _session_state.legacy_dynamic_item, _session_state.active_command_item]:
            runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": runtime.THREAD_ID, "item": _session_state.tool_item}})
        _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + ".tool-ready")
        _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".tool-release")
        _session_state.ready.unlink(missing_ok=True)
        _session_state.release.unlink(missing_ok=True)
        runtime.Path(str(runtime.sys.argv[0]) + ".tool-active-command-completed").unlink(missing_ok=True)
        runtime.Path(str(runtime.sys.argv[0]) + ".tool-others-completed").unlink(missing_ok=True)
        _session_state.ready.write_text("Tool lifecycle starts are visible.\n", encoding="utf-8")
        _session_state.release_latest = runtime.Path(str(runtime.sys.argv[0]) + ".tool-release-latest")
        _session_state.release_latest.unlink(missing_ok=True)
        _session_state.deadline = runtime.time.monotonic() + 30
        while not _session_state.release_latest.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        if not _session_state.release_latest.exists():
            runtime.os._exit(3)
        _session_state.release_latest.unlink(missing_ok=True)
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": runtime.THREAD_ID, "item": {
            **_session_state.active_command_item, "status": "completed", "durationMs": 37,
        }}})
        # A concurrent `thread/items/list` read (a second CLI call, or a
        # reopened window resubscribing to this same thread) rebuilds its
        # snapshot from scratch rather than sharing this process's live
        # state; mark what has actually completed so that snapshot can
        # tell genuinely in-progress items from settled ones.
        runtime.Path(str(runtime.sys.argv[0]) + ".tool-active-command-completed").write_text("done\n", encoding="utf-8")
        while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        _session_state.ready.unlink(missing_ok=True)
        if not _session_state.release.exists():
            runtime.os._exit(3)
        _session_state.release.unlink(missing_ok=True)
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": runtime.THREAD_ID, "item": {
            **_session_state.legacy_dynamic_item, "status": "completed", "success": True,
            "contentItems": [{"type": "inputText", "text": "RAW_RESULT_SECRET"}], "durationMs": 41,
        }}})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": runtime.THREAD_ID, "item": {
            **_session_state.mcp_item, "status": "completed", "result": {"content": [{"type": "text", "text": "RAW_RESULT_SECRET"}]},
        }}})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": runtime.THREAD_ID, "item": {
            **_session_state.dynamic_item, "status": "failed", "success": False, "durationMs": 37,
        }}})
        runtime.Path(str(runtime.sys.argv[0]) + ".tool-others-completed").write_text("done\n", encoding="utf-8")
    for _session_state.action_item in runtime.diagnostic_action_items(runtime.workspace_cwd()):
        runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
            "threadId": runtime.THREAD_ID, "item": {**_session_state.action_item, "status": "inProgress"},
        }})
        if _session_state.action_item["type"] == "commandExecution":
            for _session_state.delta in ("CODEX_STREAMED_", "OUTPUT_NOT_LOGGED"):
                runtime.write({"jsonrpc": "2.0", "method": "item/commandExecution/outputDelta", "params": {
                    "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
                    "itemId": _session_state.action_item["id"], "delta": _session_state.delta,
                }})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "item": _session_state.action_item,
        }})
    _session_state.progress_text = "I inspected the project structure and am preparing the summary."
    for _session_state.phase, _session_state.item_id, _session_state.text in [("commentary", "item_playhouse_commentary", _session_state.progress_text)]:
        _session_state.item = {"id": _session_state.item_id, "type": "agentMessage", "text": "", "phase": _session_state.phase}
        runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
        }})
        _session_state.midpoint = len(_session_state.text) // 2
        for _session_state.delta in (_session_state.text[:_session_state.midpoint], _session_state.text[_session_state.midpoint:]):
            runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
                "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "itemId": _session_state.item_id, "delta": _session_state.delta,
            }})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turnId": runtime.TURN_ID,
            "item": {**_session_state.item, "text": _session_state.text},
        }})
    if _session_state.mode.endswith("-subagent-wait"):
        _session_state.active = runtime.Path(str(runtime.sys.argv[0]) + ".commentary-active")
        _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".commentary-release")
        _session_state.active.write_text("The subagent fixture turn has live commentary.\n", encoding="utf-8")
        _session_state.deadline = runtime.time.monotonic() + 90
        while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        _session_state.was_released = _session_state.release.exists()
        _session_state.active.unlink(missing_ok=True)
        _session_state.release.unlink(missing_ok=True)
        if not _session_state.was_released:
            runtime.os._exit(3)
    _session_state.phase, _session_state.item_id, _session_state.text = ("final_answer", "item_playhouse_final", "The subagent inspected the project structure.")
    _session_state.item = {"id": _session_state.item_id, "type": "agentMessage", "text": "", "phase": _session_state.phase}
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.item,
    }})
    _session_state.midpoint = len(_session_state.text) // 2
    for _session_state.delta in (_session_state.text[:_session_state.midpoint], _session_state.text[_session_state.midpoint:]):
        runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "itemId": _session_state.item_id, "delta": _session_state.delta,
        }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turnId": runtime.TURN_ID,
        "item": {**_session_state.item, "text": _session_state.text},
    }})
    _session_state.final_answer_pause = runtime.Path(str(runtime.sys.argv[0]) + ".final-answer-pause")
    if _session_state.final_answer_pause.exists():
        _session_state.final_answer_ready = runtime.Path(str(runtime.sys.argv[0]) + ".final-answer-ready")
        _session_state.final_answer_release = runtime.Path(str(runtime.sys.argv[0]) + ".final-answer-release")
        _session_state.final_answer_ready.write_text("The final answer is visible before turn completion.\n", encoding="utf-8")
        _session_state.deadline = runtime.time.monotonic() + 90
        while not _session_state.final_answer_release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        _session_state.was_released = _session_state.final_answer_release.exists()
        _session_state.final_answer_ready.unlink(missing_ok=True)
        _session_state.final_answer_release.unlink(missing_ok=True)
        if not _session_state.was_released:
            runtime.os._exit(3)
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def markdown(runtime, _session_state, message):
    _session_state.plan_item_id = "item_playhouse_plan"
    _session_state.is_plan_turn = message.get("params", {}).get("collaborationMode", {}).get("mode") == "plan"
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
        "item": {"id": _session_state.plan_item_id, "type": "plan", "text": ""},
    }})
    for stage, _session_state.delta in enumerate(runtime.markdown_plan_deltas(), start=1):
        runtime.write({"jsonrpc": "2.0", "method": "item/plan/delta", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
            "itemId": _session_state.plan_item_id, "delta": _session_state.delta,
        }})
        # Every delta but the last can be held, so a test sees the plan at each stage.
        if stage < 4 and _session_state.is_plan_turn and runtime.Path(str(runtime.sys.argv[0]) + ".plan-delta-hold").exists():
            _session_state.ready = runtime.Path(str(runtime.sys.argv[0]) + f".plan-delta-ready-{stage}")
            _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + f".plan-delta-release-{stage}")
            _session_state.ready.write_text(f"Plan delta {stage} is visible before completion.\n", encoding="utf-8")
            _session_state.deadline = runtime.time.monotonic() + 30
            while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
                _session_state.drain_pending_stdin()
                runtime.time.sleep(0.02)
            if not _session_state.release.exists():
                runtime.os._exit(3)
            _session_state.ready.unlink()
            _session_state.release.unlink()
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
        "item": {"id": _session_state.plan_item_id, "type": "plan", "text": runtime.MARKDOWN_PLAN},
    }})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def held_turn(runtime, _session_state, message):
    _session_state.hold_used = runtime.Path(str(runtime.sys.argv[0]) + ".hold-used")
    if _session_state.hold_used.exists():
        runtime.question_request(901)
    else:
        _session_state.hold_used.write_text("The first fixture turn is held for restart recovery.\n", encoding="utf-8")
        _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".turn-release")
        _session_state.deadline = runtime.time.monotonic() + 90
        while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
            _session_state.drain_pending_stdin()
            runtime.time.sleep(0.02)
        if _session_state.release.exists():
            _session_state.release.unlink(missing_ok=True)
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID,
        "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})


def restart_question(runtime, _session_state, message):
    _session_state.asked = runtime.Path(str(runtime.sys.argv[0]) + ".asked")
    _session_state.secret_stage = runtime.Path(str(runtime.sys.argv[0]) + ".secret-stage")
    if not _session_state.asked.exists():
        runtime.question_request(901)
        _session_state.asked.write_text("Provider process ended with a pending question.\n", encoding="utf-8")
        runtime.os._exit(0)
    if _session_state.mode.endswith("-restart-question-no-secret") and _session_state.turn_message == "Ask a second restart-safe structured question.":
        _session_state.secret_stage.write_text("A later secret question is pending.\n", encoding="utf-8")
        runtime.question_request(902)
        runtime.os._exit(0)
    if _session_state.is_outcome_reminder:
        runtime.question_request(901)
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"},
        }})
        return
    if _session_state.turn_message and not _session_state.turn_message.startswith("Continue this conversation by applying"):
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
            "item": {"id": "item_followup_answer", "type": "agentMessage", "phase": "final_answer", "text": "Follow-up after private recovery."},
        }})
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"},
        }})
        return
    if "-nonblocking" in _session_state.mode:
        _session_state.expected_recovery_answers = ("Custom approach", "fixture-secret")
    else:
        _session_state.no_secret_recovery = _session_state.mode.endswith("-restart-question-no-secret") and not _session_state.secret_stage.exists()
        _session_state.expected_recovery_answers = ("Blue",) if _session_state.no_secret_recovery else ("Green", "fixture-secret")
    if not _session_state.turn_message or any(answer not in _session_state.turn_message for answer in _session_state.expected_recovery_answers):
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": runtime.THREAD_ID,
            "turn": {"id": runtime.TURN_ID, "status": "failed", "error": {"message": "Recovery turn omitted a re-entered answer."}},
        }})
        return
    _session_state.private_activity = {
        "id": "item_private_recovery_command",
        "type": "commandExecution",
        "command": "printf fixture-secret",
        "cwd": "/tmp",
        "aggregatedOutput": "fixture-secret",
        "exitCode": 0,
        "status": "completed",
    }
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.private_activity,
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID, "item": _session_state.private_activity,
    }})
    runtime.write({"jsonrpc": "2.0", "method": "turn/diff/updated", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
        "diff": "diff --git a/private.txt b/private.txt\n+fixture-secret\n",
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
        "item": {
            "id": "item_private_recovery_live_async", "type": "agentMessage",
            "phase": "final_answer", "delivery": "async", "text": "Private follow-up question",
            "questions": [{"title": "fixture-secret?", "options": ["fixture-secret"]}],
        },
    }})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
        "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
        "item": {"id": f"item_recovered_answer_{runtime.TURN_ID}", "type": "agentMessage", "phase": "final_answer", "text": runtime.answer_text(_session_state.turn_message)},
    }})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": runtime.THREAD_ID, "turn": {"id": runtime.TURN_ID, "status": "completed"},
    }})
    return


def question(runtime, _session_state, message):
    _session_state.active = runtime.Path(str(runtime.sys.argv[0]) + ".turn-active")
    _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".turn-release")
    _session_state.active.write_text("The progress report fixture turn is active.\n", encoding="utf-8")
    _session_state.deadline = runtime.time.monotonic() + 30
    while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
        _session_state.drain_pending_stdin()
        runtime.time.sleep(0.02)
    _session_state.was_released = _session_state.release.exists()
    _session_state.active.unlink(missing_ok=True)
    _session_state.release.unlink(missing_ok=True)
    if not _session_state.was_released:
        runtime.os._exit(3)
    runtime.question_request(901)


def release_marker(runtime, _session_state, message):
    _session_state.active = runtime.Path(str(runtime.sys.argv[0]) + ".turn-active")
    _session_state.release = runtime.Path(str(runtime.sys.argv[0]) + ".turn-release")
    _session_state.active.write_text("The progress report fixture turn is active.\n", encoding="utf-8")
    _session_state.deadline = runtime.time.monotonic() + 90
    while not _session_state.release.exists() and runtime.time.monotonic() < _session_state.deadline:
        _session_state.drain_pending_stdin()
        runtime.time.sleep(0.02)
    _session_state.was_released = _session_state.release.exists()
    _session_state.active.unlink(missing_ok=True)
    _session_state.release.unlink(missing_ok=True)
    runtime.time.sleep(0.1)
    if not _session_state.was_released:
        runtime.os._exit(3)
    _session_state.turn_status = "interrupted" if "-interrupted" in _session_state.mode else ("failed" if "-failed" in _session_state.mode else "completed")
    _session_state.echoed = runtime.echoed_outcome_answer(_session_state.turn_message)
    if _session_state.echoed and _session_state.turn_status == "completed":
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
            "item": {"id": "item_playhouse_echoed_outcome", "type": "agentMessage", "phase": "final_answer", "text": _session_state.echoed},
        }})
    _session_state.turn_error = {"error": {"message": "Codex interrupted this turn." if _session_state.turn_status == "interrupted" else "Codex failed this turn."}} if _session_state.turn_status != "completed" else {}
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
        "threadId": "00000000-0000-0000-0000-000000000001",
        "turn": {"id": runtime.TURN_ID, "status": _session_state.turn_status, **_session_state.turn_error},
    }})


def default_turn(runtime, _session_state, message):
    if _session_state.mode.endswith("-interrupted"):
        # An interrupted turn keeps the activity it already reported, so
        # the window still renders its activity section after the turn
        # settles and can be checked for folding rather than vanishing.
        runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
            "threadId": runtime.THREAD_ID, "turnId": runtime.TURN_ID,
            "item": {
                "id": "item_fixture_interrupted_command",
                "type": "commandExecution",
                "command": "git status --short",
                "cwd": runtime.workspace_cwd(),
            },
        }})
    runtime.question_request(901)

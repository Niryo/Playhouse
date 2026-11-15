"""History item serialization for the Codex fixture."""

def list_items(runtime, _session_state, message):
    if message.get("params", {}).get("threadId") == runtime.CHILD_THREAD_ID:
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
            "data": [{"item": item, "turnId": runtime.CHILD_TURN_ID} for item in runtime.CHILD_MESSAGES],
            "nextCursor": None,
        }})
        return
    if runtime.Path(str(runtime.sys.argv[0]) + ".history-error").is_file():
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {
            "code": -32009,
            "message": "Fixture history failed after receiving fixture-secret.",
        }})
        return
    _session_state.saved_history = runtime.json.loads(_session_state.history_path.read_text(encoding="utf-8")) if _session_state.history_path.is_file() else {}
    if _session_state.serial_mode and message.get("params", {}).get("threadId") != _session_state.saved_history.get("threadID"):
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32004, "message": "History can only be read from the persisted fixture thread."}})
        return
    if _session_state.async_mode:
        _session_state.entries = []
        chat_turns = [
            saved_turn for saved_turn in _session_state.saved_history.get("messages", [])
            if not runtime.is_page_classifier_prompt(saved_turn.get("userMessage"))
        ]
        for _session_state.index, _session_state.saved_turn in enumerate(chat_turns, start=1):
            _session_state.turn_id = _session_state.saved_turn["turnID"]
            _session_state.entries.append({"turnId": _session_state.turn_id, "item": {
                "id": f"item_playhouse_async_user_{_session_state.index}",
                "type": "userMessage",
                "content": [{"type": "text", "text": _session_state.saved_turn["userMessage"]}],
            }})
            if _session_state.index == 1:
                _session_state.entries.extend([
                    {"turnId": _session_state.turn_id, "item": runtime.async_question_item()},
                    {"turnId": _session_state.turn_id, "item": {
                        "id": "item_playhouse_async_followup",
                        "type": "agentMessage", "phase": "final_answer",
                        "text": "I can continue while you decide.",
                    }},
                ])
                if _session_state.saved_turn.get("steeredAnswer"):
                    _session_state.entries.extend([
                        {"turnId": _session_state.turn_id, "item": {
                            "id": "item_playhouse_async_steered_user", "type": "userMessage",
                            "content": [{"type": "text", "text": _session_state.saved_turn["steeredAnswer"]}],
                        }},
                        {"turnId": _session_state.turn_id, "item": {
                            "id": "item_playhouse_async_answer_steered", "type": "agentMessage", "phase": "final_answer",
                            "text": f"Answers received: {_session_state.saved_turn['steeredAnswer']}",
                        }},
                        {"turnId": _session_state.turn_id, "item": runtime.later_async_question_item()},
                    ])
            else:
                _session_state.entries.append({"turnId": _session_state.turn_id, "item": {
                    "id": f"item_playhouse_async_answer_{_session_state.index}",
                    "type": "agentMessage", "phase": "final_answer",
                    "text": f"Answers received: {_session_state.saved_turn['userMessage']}",
                }})
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
            "data": _session_state.entries, "nextCursor": None,
        }})
        return
    if _session_state.serial_mode and _session_state.saved_history.get("messages"):
        _session_state.contents = []
        for _session_state.index, _session_state.saved_turn in enumerate(_session_state.saved_history["messages"], start=1):
            _session_state.user_message = _session_state.saved_turn.get("userMessage")
            if runtime.is_page_classifier_prompt(_session_state.user_message):
                continue
            _session_state.user_images = _session_state.saved_turn.get("images", [])
            _session_state.user_content = ([{"type": "text", "text": _session_state.user_message}] if _session_state.user_message else []) + [
                {"type": "image", "url": image_url} for image_url in _session_state.user_images
            ]
            if _session_state.user_content:
                _session_state.contents.extend([
                    {"id": f"item_user_fixture_{_session_state.index}", "type": "userMessage", "content": _session_state.user_content},
                    {"id": f"item_assistant_fixture_{_session_state.index}", "type": "agentMessage", "phase": "final_answer", "text": runtime.answer_text(_session_state.user_message)},
                ])
            _session_state.contents.extend({**record["item"], "_fixture_turn_index": _session_state.index - 1}
                            for record in _session_state.saved_history.get("compactions", []) if record.get("afterTurnCount") == _session_state.index)
    elif _session_state.saved_history.get("turns"):
        _session_state.contents = []
        for _session_state.index, _session_state.saved_turn in enumerate(_session_state.saved_history["turns"], start=1):
            _session_state.user_message = _session_state.saved_turn.get("userMessage")
            if runtime.is_page_classifier_prompt(_session_state.user_message):
                continue
            _session_state.user_images = _session_state.saved_turn.get("images", [])
            _session_state.user_content = ([{"type": "text", "text": _session_state.user_message}] if _session_state.user_message else []) + [
                {"type": "image", "url": image_url} for image_url in _session_state.user_images
            ]
            if _session_state.user_content:
                _session_state.echoed = runtime.echoed_outcome_answer(_session_state.user_message)
                _session_state.assistant = {"id": f"item_assistant_fixture_{_session_state.index}", "type": "agentMessage", "phase": "final_answer", "text": "Answers received: Blue / fixture-secret."}
                if _session_state.echoed:
                    _session_state.assistant.update(phase="final_answer", text=_session_state.echoed)
                _session_state.contents.extend([
                    {"id": f"item_user_fixture_{_session_state.index}", "type": "userMessage", "content": _session_state.user_content},
                    _session_state.assistant if _session_state.echoed else {"id": f"item_assistant_fixture_{_session_state.index}", "type": "agentMessage", "phase": "final_answer", "text": runtime.answer_text(_session_state.user_message)},
                ])
                if _session_state.mode.endswith("-hold-release") and "playhouse internal outcome nudge:" not in (_session_state.user_message or "").lower():
                    _session_state.contents.append({
                        "id": f"item_hold_release_file_change_{_session_state.index}",
                        "type": "fileChange",
                        "changes": [{"path": "progress-fixture.txt", "kind": "update", "diff": "+ordinary-turn-diff-after-reminders"}],
                        "status": "completed",
                    })
                if "fixture-secret" in runtime.own_user_text(_session_state.user_message):
                    _session_state.contents.append({
                        "id": f"item_private_recovery_file_change_{_session_state.index}",
                        "type": "fileChange",
                        "changes": [{"path": "private.txt", "kind": "update", "diff": "+fixture-secret"}],
                        "status": "completed",
                    })
                    _session_state.contents.append({
                        "id": f"item_private_recovery_agent_{_session_state.index}",
                        "type": "collabAgentToolCall",
                        "tool": "spawnAgent",
                        "prompt": "Keep this private: fixture-secret",
                        "status": "completed",
                    })
                    _session_state.contents.append({
                        "id": f"item_private_recovery_subagent_{_session_state.index}",
                        "type": "subAgentActivity",
                        "agentThreadId": f"fixture-private-subagent-{_session_state.index}",
                        "kind": "completed",
                        "agentPath": "/agents/fixture-secret",
                    })
                    _session_state.contents.append({
                        "id": f"item_private_recovery_async_{_session_state.index}",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "delivery": "async",
                        "text": "Private follow-up question",
                        "questions": [{"title": "fixture-secret?", "options": ["fixture-secret"]}],
                    })
                elif _session_state.user_message == "Follow up after private recovery.":
                    _session_state.contents.append({
                        "id": f"item_followup_file_change_{_session_state.index}",
                        "type": "fileChange",
                        "changes": [{"path": "follow-up.txt", "kind": "update", "diff": "+follow-up-visible-diff"}],
                        "status": "completed",
                    })
            _session_state.contents.extend({**record["item"], "_fixture_turn_index": _session_state.index - 1}
                            for record in _session_state.saved_history.get("compactions", []) if record.get("afterTurnCount") == _session_state.index)
    else:
        _session_state.user_message = _session_state.saved_history.get("userMessage") or (_session_state.turn_message if _session_state.answers else None)
        _session_state.user_images = _session_state.saved_history.get("images", [])
        _session_state.user_content = ([{"type": "text", "text": _session_state.user_message}] if _session_state.user_message else []) + [
            {"type": "image", "url": image_url} for image_url in _session_state.user_images
        ]
        _session_state.contents = ([
            {"id": "item_user_fixture", "type": "userMessage", "content": _session_state.user_content},
            {"id": "item_assistant_fixture", "type": "agentMessage", "phase": "final_answer", "text": runtime.answer_text(_session_state.user_message)},
        ] if _session_state.user_content and not _session_state.mode.endswith("-empty") else [])
    if _session_state.mode.endswith("-subagent") or _session_state.mode.endswith("-subagent-wait"):
        _session_state.contents = [
            {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Delegate this task."}]},
            {"id": "item_playhouse_commentary", "type": "agentMessage", "phase": "commentary", "text": "I inspected the project structure and am preparing the summary."},
            {"id": "item_playhouse_final", "type": "agentMessage", "phase": "final_answer", "text": "The subagent inspected the project structure."},
            runtime.subagent_item("completed"),
            runtime.subagent_activity("completed", runtime.CHILD_THREAD_ID, "/agents/Sandbox review", model="gpt-6-sol", reasoning_effort="high"),
            runtime.subagent_activity("interrupted", "00000000-0000-0000-0000-000000000003", "/agents/some_agent"),
            runtime.subagent_activity("futureKind", "00000000-0000-0000-0000-000000000004", "/agents/Future review"),
            *runtime.diagnostic_action_items(runtime.workspace_cwd()),
        ]
    if _session_state.mode.endswith("-context-compaction"):
        _session_state.contents = [
            {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Compact the context."}]},
            {"id": "item_playhouse_compaction", "type": "contextCompaction", "payload": {"opaque": "COMPACTION_OPAQUE_SENTINEL"}},
            {"id": "item_playhouse_final", "type": "agentMessage", "phase": "final_answer", "text": "Context compaction completed."},
        ]
    if _session_state.mode.endswith("-follow-active-turn"):
        # A running turn's history holds the items it has reported so far.
        _session_state.contents = [{"id": "item_user_fixture", "type": "userMessage",
                     "content": [{"type": "text", "text": _session_state.saved_history.get("userMessage") or ""}]}]
        if runtime.Path(str(runtime.sys.argv[0]) + ".follow-turn-done").exists():
            _session_state.contents.extend(runtime.follow_turn_items(finished=True))
        elif runtime.Path(str(runtime.sys.argv[0]) + ".follow-turn-ready").exists():
            _session_state.contents.extend(runtime.follow_turn_items(finished=False))
    if "-long-history-" in _session_state.mode:
        _session_state.contents = []
        if "-with-prompt-" in _session_state.mode:
            # The sent prompt is the first stored user message, outside the newest history page.
            _session_state.contents.append({"id": "item_sent_prompt", "type": "userMessage", "content": [{"type": "text", "text": "Create a long history."}]})
        for _session_state.index in range(1, 61):
            _session_state.contents.append({"id": f"item_long_history_user_{_session_state.index}", "type": "userMessage", "content": [{"type": "text", "text": f"Long history user {_session_state.index:02d}."}]})
            if _session_state.index == 21 and "-lazy-" in _session_state.mode:
                # A mid-history call whose output runs past the clipped lines, so the UI can
                # expand it and check it stays expanded after its row is rendered lazily again.
                _session_state.contents.append({"id": "item_long_history_command_21", "type": "commandExecution", "command": "ls fixture-history",
                                 "cwd": "/tmp/playhouse-fixture", "status": "completed", "exitCode": 0, "durationMs": 5,
                                 "aggregatedOutput": "".join(f"history-file-{line}.txt\n" for line in range(1, 7))})
            _session_state.text = f"Long history assistant {_session_state.index:02d}."
            if _session_state.index == 60 and _session_state.mode.endswith("-long-history-success"):
                # A newest answer taller than the transcript viewport, so a conversation opened
                # on its question differs visibly from one opened at its end.
                _session_state.text = "\n\n".join([_session_state.text, *(f"Long history closing paragraph {number:02d}." for number in range(1, 31))])
            _session_state.contents.append({"id": f"item_long_history_assistant_{_session_state.index}", "type": "agentMessage", "phase": "final_answer", "text": _session_state.text})
    if _session_state.mode.endswith("-tool-activity"):
        # A concurrent `thread/items/list` read — a second CLI call, or a
        # window reopening the same thread mid-turn — rebuilds its snapshot
        # from scratch rather than sharing the held turn's live state.
        # `turn/create`'s own generic handling already saved this turn to
        # `saved_history["turns"]` before this mode's branch ever runs, so
        # the `elif saved_history.get("turns")` reconstruction above has
        # already populated `contents` with a fabricated final answer for
        # it ("Answers received: ..."). That would make a still-open turn
        # read as already answered, so start this mode's own reconstruction
        # fresh instead of extending that bogus content.
        _session_state.contents = [{"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Show tool activity."}]}]
        # Read the completion markers the held turn writes so this snapshot
        # reports the calls still in progress accurately, instead of
        # always answering with their eventual terminal state.
        others_completed = runtime.Path(str(runtime.sys.argv[0]) + ".tool-others-completed").is_file()
        latest_completed = runtime.Path(str(runtime.sys.argv[0]) + ".tool-active-command-completed").is_file()
        if others_completed:
            _session_state.contents.extend([
                {"id": "item_fixture_mcp_call", "type": "mcpToolCall", "server": "fixture-server", "tool": "lookup", "status": "completed", "arguments": {"token": "RAW_ARGUMENT_SECRET"}, "result": {"content": [{"type": "text", "text": "RAW_RESULT_SECRET"}]}},
                {"id": "item_fixture_dynamic_call", "type": "dynamicToolCall", "tool": "summarize", "status": "failed", "arguments": {"prompt": "RAW_ARGUMENT_SECRET"}, "success": False, "durationMs": 37},
                {"id": "item_fixture_dynamic_legacy", "type": "dynamicToolCall", "tool": "legacySummary", "status": "completed", "arguments": {"input": "RAW_ARGUMENT_SECRET"}, "success": True, "contentItems": [{"type": "inputText", "text": "RAW_RESULT_SECRET"}]},
            ])
        else:
            _session_state.contents.extend([
                {"id": "item_fixture_mcp_call", "type": "mcpToolCall", "server": "fixture-server", "tool": "lookup", "status": "inProgress", "arguments": {"token": "RAW_ARGUMENT_SECRET"}},
                {"id": "item_fixture_dynamic_call", "type": "dynamicToolCall", "tool": "summarize", "status": "inProgress", "arguments": {"prompt": "RAW_ARGUMENT_SECRET"}},
                {"id": "item_fixture_dynamic_legacy", "type": "dynamicToolCall", "tool": "legacySummary", "status": "inProgress", "arguments": {"input": "RAW_ARGUMENT_SECRET"}},
            ])
        _session_state.contents.append({
            "id": "item_fixture_active_long_command", "type": "commandExecution",
            "command": "long-command-name " + "argument-" * 40, "cwd": "/tmp/playhouse-fixture",
            **({"status": "completed", "durationMs": 37} if latest_completed else {"status": "inProgress"}),
        })
        if others_completed and latest_completed:
            # A `userMessage` item resets the client's in-progress activity
            # tracking, so reporting "a later turn starts" while the held
            # turn's own commandExecution is still open would make that
            # live activity unreadable from this same reconstruction. Only
            # include it once the turn has genuinely settled, matching the
            # real sequencing this item exists to exercise (later-turn
            # items following the calls in history).
            _session_state.contents.extend([
                {"id": "item_user_fixture_later", "type": "userMessage", "content": [{"type": "text", "text": "A later turn starts."}]},
                {"id": "item_assistant_fixture_later", "type": "agentMessage", "text": "Later turn response."},
            ])
    if _session_state.mode.endswith("-markdown"):
        _session_state.saved_history = runtime.json.loads(_session_state.history_path.read_text(encoding="utf-8")) if _session_state.history_path.is_file() else {}
        _session_state.contents = [
            {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": _session_state.saved_history.get("userMessage", "Plan the task.")} ]},
            {"id": "item_playhouse_plan", "type": "plan", "text": runtime.MARKDOWN_PLAN},
        ]
    _session_state.entries = []
    _session_state.saved_turns = _session_state.saved_history.get("messages") or _session_state.saved_history.get("turns") or []
    _session_state.ordinary_turn_indexes = [
        index for index, saved_turn in enumerate(_session_state.saved_turns)
        if "playhouse internal outcome nudge:" not in (saved_turn.get("userMessage") or "").lower()
    ]
    if _session_state.mode.endswith("-timeline-tool-calls"):
        # Each ordinary turn as its thread items: the tool-call turn reports
        # commentary, shell commands with their output (one failing), and an
        # MCP call whose arguments and result stay private, between its messages.
        _session_state.contents = []
        for _session_state.turn_index in _session_state.ordinary_turn_indexes:
            _session_state.user_message = _session_state.saved_turns[_session_state.turn_index].get("userMessage") or ""
            suffix = f"t{_session_state.turn_index}"
            turn_items = [{"id": f"item_timeline_user_{suffix}", "type": "userMessage",
                           "content": [{"type": "text", "text": _session_state.user_message}]}]
            if "show-tool-calls-inline" in _session_state.user_message.lower():
                turn_items += [
                    {"id": f"item_timeline_intro_{suffix}", "type": "agentMessage", "phase": "commentary",
                     "text": "I'll check the repository status first."},
                    {"id": "item_timeline_status", "type": "commandExecution",
                     "command": "git status --short && echo fixture-status-done", "cwd": "/tmp/playhouse-fixture",
                     "status": "completed", "exitCode": 0, "durationMs": 12, "aggregatedOutput": "fixture-status-done\n"},
                    {"id": f"item_timeline_middle_{suffix}", "type": "agentMessage", "phase": "commentary",
                     "text": "The status is clean. Next I'll list the files and run the check."},
                    {"id": "item_timeline_list", "type": "commandExecution", "command": "ls -1",
                     "cwd": "/tmp/playhouse-fixture", "status": "completed", "exitCode": 0, "durationMs": 9,
                     "aggregatedOutput": "README.md\nfixture-one.txt\nfixture-two.txt\nfixture-three.txt\nfixture-four.txt\n"},
                    {"id": "item_timeline_fail", "type": "commandExecution", "command": "exit 3",
                     "cwd": "/tmp/playhouse-fixture", "status": "failed", "exitCode": 3, "durationMs": 4,
                     "aggregatedOutput": "Exit code 3"},
                    {"id": "item_timeline_mcp", "type": "mcpToolCall", "server": "fixture", "tool": "lookup",
                     "status": "completed", "arguments": {"query": "timeline-private-argument"},
                     "result": {"content": [{"type": "text", "text": "timeline-private-result"}]}},
                    {"id": f"item_timeline_final_{suffix}", "type": "agentMessage", "phase": "final_answer",
                     "text": "Here is what ran:\n1. `git status --short` was clean.\n2. The check exited with code `3`.\n\n- Bullets read at text size\n- Inline `code` is tinted"},
                ]
            else:
                turn_items.append({"id": f"item_timeline_later_{suffix}", "type": "agentMessage",
                                   "phase": "final_answer", "text": "Codex answered the later turn."})
            _session_state.contents += [{**item, "_fixture_turn_index": _session_state.turn_index} for item in turn_items]
    for _session_state.turn_index, _session_state.saved_turn in enumerate(_session_state.saved_turns, start=1):
        if runtime.is_page_classifier_prompt(_session_state.saved_turn.get("userMessage")):
            continue
        if (
            "hold-release" in runtime.os.path.basename(runtime.sys.argv[0])
            and "playhouse internal outcome nudge:" in (_session_state.saved_turn.get("userMessage") or "").lower()
        ):
            # A status-only nudge: its one call is Playhouse's own outcome
            # report, which is bookkeeping, so the whole turn stays private.
            _session_state.contents.append({
                "id": f"item_private_reminder_activity_{_session_state.turn_index}",
                "type": "commandExecution",
                "command": f"'/fixture/playhouse-cli' task outcome {_session_state.turn_index} waiting-response",
                "cwd": "/tmp/playhouse-fixture",
                "status": "completed",
                "exitCode": 0,
                "durationMs": 11,
                "_fixture_turn_index": _session_state.turn_index - 1,
            })
    if "nudged-work" in _session_state.mode:
        # Each saved turn as its own thread items. A status nudge that went
        # on to work holds commentary, a shell check, and its answer.
        _session_state.contents = []
        for _session_state.turn_index, _session_state.saved_turn in enumerate(_session_state.saved_turns):
            _session_state.user_message = _session_state.saved_turn.get("userMessage") or ""
            turn_items = [{"id": f"item_nudged_user_{_session_state.turn_index}", "type": "userMessage",
                           "content": [{"type": "text", "text": _session_state.user_message}]}]
            if "playhouse internal outcome nudge:" in _session_state.user_message.lower():
                # A message the user steered into this nudge turn follows its prompt.
                for steer in _session_state.saved_history.get("steerRequests", []):
                    if steer.get("expectedTurnId") == _session_state.saved_turn.get("turnID"):
                        turn_items.append({"id": f"item_nudged_steer_{_session_state.turn_index}", "type": "userMessage",
                                           "content": [item for item in steer.get("input", []) if item.get("type") == "text"]})
                turn_items += runtime.nudged_work_items(_session_state.turn_index)
            else:
                turn_items.append({"id": f"item_nudged_answer_{_session_state.turn_index}", "type": "agentMessage",
                                   "phase": "final_answer", "text": runtime.answer_text(_session_state.user_message)})
            _session_state.contents += [{**item, "_fixture_turn_index": _session_state.turn_index} for item in turn_items]
    _session_state.unassociated_restart_question = runtime.os.path.basename(runtime.sys.argv[0]).endswith("-unassociated-restart-question")
    for _session_state.index, _session_state.item in enumerate(_session_state.contents):
        _session_state.item_id = _session_state.item.get("id", "")
        _session_state.turn_id = runtime.TURN_ID
        if _session_state.saved_turns:
            try:
                if "_fixture_turn_index" in _session_state.item:
                    _session_state.turn_index = _session_state.item.pop("_fixture_turn_index")
                elif _session_state.item_id.startswith("item_long_history_"):
                    _session_state.turn_index = int(_session_state.item_id.rsplit("_", 1)[1]) - 1
                elif _session_state.item_id.rsplit("_", 1)[-1].isdigit():
                    _session_state.turn_index = int(_session_state.item_id.rsplit("_", 1)[1]) - 1
                elif _session_state.mode.endswith("-tool-activity") and _session_state.ordinary_turn_indexes:
                    _session_state.turn_index = _session_state.ordinary_turn_indexes[0]
                elif _session_state.ordinary_turn_indexes:
                    _session_state.turn_index = _session_state.ordinary_turn_indexes[-1]
                else:
                    _session_state.turn_index = min(_session_state.index // 2, len(_session_state.saved_turns) - 1)
            except (ValueError, IndexError):
                _session_state.turn_index = -1
            if 0 <= _session_state.turn_index < len(_session_state.saved_turns):
                _session_state.turn_id = _session_state.saved_turns[_session_state.turn_index].get("turnID", runtime.TURN_ID)
                if "-unique-turns-success" not in _session_state.mode and _session_state.turn_index in _session_state.ordinary_turn_indexes and _session_state.ordinary_turn_indexes.index(_session_state.turn_index) == 1:
                    _session_state.item["createdAt"] = "2026-10-26T12:34:00Z"
        if _session_state.item_id == "item_assistant_fixture_1" and runtime.Path(str(runtime.sys.argv[0]) + ".provider-timestamp").exists():
            _session_state.item["createdAt"] = "2026-10-26T12:34:00Z"
        if "-long-history-lazy-" in _session_state.mode and _session_state.item_id.startswith("item_long_history_"):
            # Each history turn is its own turn, as in a real multi-turn thread, so the app
            # treats every turn but the last as settled and shows its calls inline.
            _session_state.turn_id = f"turn_long_history_{_session_state.item_id.rsplit('_', 1)[1]}"
        if _session_state.unassociated_restart_question and _session_state.item.get("type") == "userMessage":
            _session_state.entries.append({"item": _session_state.item})
        else:
            _session_state.entries.append({"item": _session_state.item, "turnId": _session_state.turn_id})
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {
        "data": _session_state.entries,
        "nextCursor": None,
    }})

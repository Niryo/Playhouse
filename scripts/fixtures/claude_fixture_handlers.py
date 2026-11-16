"""Response handlers for the Claude stream-json fixture executable."""

def respond(runtime, user_text, instructions, preserve_no_outcome=False, previous_prompt=""):
    
    commands = []
    if user_text.startswith("plugin-preview-fixture "):
        # Exercise real plugin files while simulating an authoring provider turn.
        payload = runtime.json.loads(user_text.removeprefix("plugin-preview-fixture "))
        folder = runtime.Path(payload["folder"])
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "plugin.json").write_text(runtime.json.dumps({"id": folder.name, "name": "Timer", "placement": "mainSidebar", "presentation": "modal"}), encoding="utf-8")
        (folder / "index.js").write_text("Playhouse.render(h(Text, {testID: 'preview-content'}, " + runtime.json.dumps(payload["text"]) + "));", encoding="utf-8")
        runtime.text("msg_plugin_preview", "Plugin preview updated: " + payload["text"])
    elif user_text.startswith("Classify the latest user message for Playhouse's continuous chat page index."):
        hold = runtime.Path(str(runtime.sys.argv[0]) + ".hold-classifier")
        if hold.exists():
            hold.unlink(missing_ok=True)
            active = runtime.Path(str(runtime.sys.argv[0]) + ".classifier-active")
            release = runtime.Path(str(runtime.sys.argv[0]) + ".classifier-release")
            active.write_text("The fallback classifier is held in the background.\n", encoding="utf-8")
            deadline = runtime.time.monotonic() + 30
            while not release.exists() and runtime.time.monotonic() < deadline:
                runtime.time.sleep(0.02)
            released = release.exists()
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            if not released:
                return commands
        if runtime.Path(str(runtime.sys.argv[0]) + ".fail-classifier").exists():
            runtime.text("msg_page_classification", '{"continues":"sometimes","title":null}')
            return commands
        history_path = runtime.Path(str(runtime.sys.argv[0]) + ".history")
        history = runtime.json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {"turns": []}
        classifier_attempts = sum(
            1 for turn in history.get("turns", [])
            if (turn.get("userText") or "").startswith("Classify the latest user message for Playhouse's continuous chat page index.")
        )
        if classifier_attempts == 0:
            runtime.text("msg_page_classification", '{"continues":false,"title":"Ignored extra field","unexpected":true}')
            return commands
        if "One more thought about Saturn" in user_text:
            runtime.text("msg_page_classification", '{"continues":true,"title":null}')
        elif "Neptune" in user_text:
            runtime.text("msg_page_classification", '{"continues":false,"title":"Neptune"}')
        elif "Another thought about Mars" in user_text:
            runtime.text("msg_page_classification", '{"continues":true,"title":null}')
        elif "Mars" in user_text:
            runtime.text("msg_page_classification", '{"continues":false,"title":"Mars"}')
        elif "Saturn's rings" in user_text:
            runtime.text("msg_page_classification", '{"continues":false,"title":"Saturn Rings"}')
        else:
            runtime.text("msg_page_classification", '{"continues":false,"title":"Volcanoes"}')
    elif "playhouse internal outcome nudge:" in user_text.lower() and previous_prompt.rstrip().endswith(runtime.CHAT_SKIPPED_CLOSE_TURN_PROMPT.lower()):
        # Answers Playhouse's chat nudge the way it asks: close-turn for the previous reply,
        # then one short line, without repeating that reply.
        close_turn = runtime.report_command(instructions, " chat page close-turn ")
        if close_turn:
            command = close_turn.replace("--continues true", f"--continues false --new-title {runtime.shlex.quote(runtime.CHAT_NUDGE_PAGE_TITLE)}")
            commands.append({"command": command, "output": runtime.run_tool("toolu_nudged_close_turn", "Bash", {"command": command}, command)})
        runtime.text("msg_chat_nudge_reply", runtime.CHAT_NUDGE_REPLY)
    elif user_text.rstrip().endswith(runtime.CHAT_SKIPPED_CLOSE_TURN_PROMPT):
        runtime.text("msg_chat_skipped_close_turn", runtime.CHAT_SKIPPED_CLOSE_TURN_ANSWER)
    elif user_text.rstrip().endswith(runtime.CHAT_CLOSE_FIRST_PROMPT):
        close_turn = runtime.report_command(instructions, " chat page close-turn ")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": runtime.run_tool("toolu_close_first", "Bash", {"command": close_turn}, close_turn)})
        runtime.text("msg_chat_close_first_answer", runtime.CHAT_CLOSE_FIRST_ANSWER)
    elif user_text.rstrip().endswith(runtime.CHAT_NOTICE_PROMPT):
        # Mirrors the observed incident: the turn ends on close-turn, so Claude Code adds its
        # synthetic "no visible output" message to the same turn and Claude answers again.
        runtime.text("msg_chat_notice_answer", runtime.CHAT_NOTICE_ANSWER)
        close_turn = runtime.report_command(instructions, " chat page close-turn ")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": runtime.run_tool("toolu_close_last", "Bash", {"command": close_turn}, close_turn)})
        runtime.write({"type": "user", "parent_tool_use_id": None, "isSynthetic": True, "uuid": "fixture-no-visible-output-notice",
               "message": {"role": "user", "content": [{"type": "text", "text": runtime.NO_VISIBLE_OUTPUT_NOTICE}]}})
        runtime.text("msg_chat_notice_reply", runtime.CHAT_NOTICE_REPLY)
    elif user_text.rstrip().endswith((runtime.LONG_NOTICE_PROMPT, runtime.SHORT_NOTICE_PROMPT)):
        # The turn reports its outcome, then Claude Code adds its own synthetic message and
        # Claude answers it, as a real handoff notice arrives inside a turn.
        is_long = user_text.rstrip().endswith(runtime.LONG_NOTICE_PROMPT)
        suffix = "long" if is_long else "short"
        runtime.text(f"msg_notice_handoff_answer_{suffix}", runtime.NOTICE_HANDOFF_ANSWER)
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome, "output": runtime.run_tool(f"toolu_notice_handoff_{suffix}", "Bash", {"command": outcome}, outcome)})
        runtime.write({"type": "user", "parent_tool_use_id": None, "isSynthetic": True, "uuid": f"fixture-handoff-notice-{suffix}",
               "message": {"role": "user", "content": [{"type": "text", "text": runtime.LONG_HANDOFF_NOTICE if is_long else runtime.NO_VISIBLE_OUTPUT_NOTICE}]}})
        runtime.wait_for_release("handoff-notice", "The handoff notice streamed; the turn is still running.")
        runtime.text(f"msg_notice_handoff_reply_{suffix}", runtime.NOTICE_HANDOFF_REPLY)
    elif runtime.PENDING_QUESTION_SUCCESS_MARKER in user_text.lower():
        question_input = {
            "questions": [{
                "header": "Color",
                "question": "Which color should I use?",
                "options": [{"label": "Blue"}, {"label": "Green"}],
                "multiSelect": False,
            }]
        }
        runtime.assistant("msg_pending_question_success", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        runtime.write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "hold background task for compaction" in user_text.lower():
        tool_id, task_id = "toolu_compaction_background", "bgtask-compaction-background"
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "general-purpose", "description": "Held background task", "prompt": "wait for fixture release",
            "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-background-run", "task_type": "local_agent",
             "subagent_type": "general-purpose", "description": "Held background task"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-background-run",
               "tool_use_id": tool_id, "description": "Held background task", "subagent_type": "general-purpose",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        runtime.text("msg_compaction_background", "The background task is still running.")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        executable_path = runtime.Path(str(runtime.sys.argv[0]))
        ready = runtime.Path(str(executable_path) + ".compaction-background-ready")
        release = runtime.Path(str(executable_path) + ".compaction-background-release")
        ready.write_text("Background task is running.\n", encoding="utf-8")
        deadline = runtime.time.monotonic() + 60
        while not release.exists() and runtime.time.monotonic() < deadline:
            runtime.time.sleep(0.01)
        if not release.exists():
            raise TimeoutError("Timed out waiting for the compaction background task release.")
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id,
               "run_id": "fixture-background-run", "tool_use_id": tool_id, "status": "completed",
               "output_file": "", "summary": "Held background task completed."})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        runtime.parent_request_started("msg_compaction_background_woken", woken=True)
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "pending ui review" in user_text.lower():
        # Mirrors the observed incident: Claude answers while a background
        # review still runs, the review's notification lands right after that
        # answer, and the woken turn says nothing new (Claude Code's synthetic
        # "No response requested." never reaches stdout). No outcome is reported.
        tool_id = "toolu_pending_ui_review"
        task_id = "bgtask-pending-ui-review"
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "ui-verifier", "description": "UI review", "prompt": "review the UI",
            "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "ui-verifier", "description": "UI review"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "UI review", "subagent_type": "ui-verifier",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        runtime.text("msg_pending_ui_review", runtime.NUDGE_RACE_STALE_ANSWER)
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "", "summary": runtime.NUDGE_RACE_UI_REPORT})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        runtime.parent_request_started("msg_pending_ui_review_woken", woken=True)
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "playhouse internal outcome nudge:" in user_text.lower() and "pending ui review" in previous_prompt:
        # The nudge says to keep working when work remains, and this turn does:
        # it runs a check, starts a background suite, and Claude Code wakes it
        # for the suite's notification, where it presents a screenshot, answers,
        # and only then reports completed.
        runtime.assistant("msg_nudged_intro", [{"type": "text", "text": runtime.NUDGED_COMMENTARY}])
        runtime.run_tool("toolu_nudged_check", "Bash", {"command": "echo NUDGED CHECK PASSED", "description": "Final check"},
                 "echo NUDGED CHECK PASSED")
        steered_uuid = None
        if runtime.Path(str(runtime.sys.argv[0]) + ".nudged-steer-pause").exists():
            # The test steers this running nudge turn, as a user can.
            runtime.Path(str(runtime.sys.argv[0]) + ".nudged-steer-ready").write_text("The nudged turn is waiting for a steer.\n", encoding="utf-8")
            steered, steered_uuid = runtime.read_steered_input("the nudged turn")
            runtime.text("msg_nudged_steer_answer", f"STEERED NUDGE: {steered}")
        runtime.assistant("msg_nudged_suite_intro", [{"type": "text", "text": runtime.NUDGED_SUITE_COMMENTARY}])
        suite_tool, suite_task = "toolu_nudged_suite", "bgtask-nudged-suite"
        runtime.assistant(f"msg_{suite_tool}", [{"type": "tool_use", "id": suite_tool, "name": "Agent", "input": {
            "subagent_type": "general-purpose", "description": "Final suite", "prompt": "run the suite",
            "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": suite_tool, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": suite_task, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "general-purpose", "description": "Final suite"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": suite_task, "run_id": "fixture-run-1",
               "tool_use_id": suite_tool, "description": "Final suite", "subagent_type": "general-purpose",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": suite_task, "run_id": "fixture-run-1",
               "tool_use_id": suite_tool, "status": "completed", "output_file": "", "summary": runtime.NUDGED_SUITE_REPORT})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        runtime.parent_request_started("msg_nudged_woken", woken=True)
        present = runtime.report_command(instructions, " conversation present-image ")
        if present:
            image = runtime.Path(str(runtime.sys.argv[0]) + ".nudged-screenshot.png")
            image.write_bytes(bytes.fromhex(runtime.TINY_PNG_HEX))
            present = present.replace("<path>", runtime.shlex.quote(str(image))).replace(
                '[--caption "short caption"]', f"--caption {runtime.shlex.quote(runtime.NUDGED_IMAGE_CAPTION)}")
            commands.append({"command": present, "output": runtime.run_tool("toolu_nudged_image", "Bash", {"command": present}, present)})
        runtime.text("msg_nudged_final", runtime.NUDGED_FINAL_ANSWER)
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome, "output": runtime.run_tool("toolu_nudged_outcome", "Bash", {"command": outcome}, outcome)})
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        if steered_uuid:
            runtime.complete_command(steered_uuid)
            runtime.complete_command(runtime.current_command_uuid)
    elif "playhouse internal outcome nudge:" in user_text.lower() and "outcome-reminder-question" in runtime.Path(runtime.sys.argv[0]).name:
        question_input = {
            "questions": [{
                "header": "Color",
                "question": "Which color should I use?",
                "options": [{"label": "Blue"}, {"label": "Green"}],
                "multiSelect": False,
            }]
        }
        runtime.assistant("msg_private_reminder_question", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        runtime.write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "playhouse internal outcome nudge:" in user_text.lower() and not preserve_no_outcome:
        command = runtime.report_command(instructions, " task outcome ", "waiting-response")
        if command:
            commands.append({"command": command, "output": runtime.run_tool("toolu_outcome_reminder", "Bash", {"command": command}, command)})
    elif "answer to the pending question from the prior playhouse session" in user_text.lower():
        answer = user_text.split("Answer: ", 1)[-1].splitlines()[0].strip()
        recovery_pause = runtime.Path(str(runtime.sys.argv[0]) + ".recovery-pause")
        if recovery_pause.exists():
            # Hold the recovery turn open so tests can inspect it mid-turn.
            recovery_release = runtime.Path(str(runtime.sys.argv[0]) + ".recovery-release")
            runtime.Path(str(runtime.sys.argv[0]) + ".recovery-ready").write_text("The recovery turn is running.\n", encoding="utf-8")
            recovery_deadline = runtime.time.monotonic() + 30
            while not recovery_release.exists() and runtime.time.monotonic() < recovery_deadline:
                runtime.time.sleep(0.02)
            if not recovery_release.exists():
                raise TimeoutError("The test did not release the recovery turn.")
        runtime.text("msg_recovered_question_answer", f"Recovered answer: {answer}.")
    elif "ask a restart-safe structured question" in user_text.lower():
        question_input = {
            "questions": [{
                "header": "Color",
                "question": "Which color should I use?",
                "options": [{"label": "Blue"}, {"label": "Green"}],
                "multiSelect": False,
            }]
        }
        runtime.assistant("msg_ask_restart_safe", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        runtime.write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
        runtime.time.sleep(0.1)
        runtime.write({"type": "result", "subtype": "error", "is_error": True, "result": "Fixture process ended with a pending question."})
    elif "ask an empty structured question" in user_text.lower():
        question_input = {"questions": []}
        runtime.assistant("msg_ask_user", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        runtime.write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "ask a structured question" in user_text.lower():
        question_input = {
            "questions": [{
                "header": "Color",
                "question": runtime.MARKDOWN_QUESTION,
                "options": [
                    {"label": "Blue", "description": "Use blue."},
                    {"label": "Green", "description": "Use green."},
                ],
                "multiSelect": False,
            }]
        }
        runtime.assistant("msg_ask_user", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        runtime.write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "hold for a steer" in user_text.lower():
        # The turn stays active until Playhouse steers it, then answers the steer.
        runtime.Path(str(runtime.sys.argv[0]) + ".steer-ready").write_text("The turn is waiting for a steer.\n", encoding="utf-8")
        steered, steered_uuid = runtime.read_steered_input("the held turn")
        runtime.wait_for_release("steer-answer", "The steer arrived and its answer is pending.")
        runtime.text("msg_held_steer_answer", f"STEERED: {steered}")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.complete_command(steered_uuid)
    elif "hold until stopped" in user_text.lower() or "hold-until-stopped" in user_text.lower():
        # Report one in-progress tool use before holding, so a user-initiated Stop
        # with no final answer still keeps the window's activity section mounted,
        # and the fold it performs on settle is distinguishable from the section
        # simply never having rendered.
        runtime.assistant("msg_stop_command", [{"type": "tool_use", "id": "toolu_stop_command", "name": "Bash", "input": {"command": "git status --short"}}])
        ready = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-ready")
        ready.write_text("The Claude fixture turn is active and waiting for an interrupt.\n", encoding="utf-8")
        deadline = runtime.time.monotonic() + 30
        received_interrupt = False
        while runtime.time.monotonic() < deadline:
            line = runtime.STDIN.readline(0.02)
            if line is None:
                continue
            control = runtime.json.loads(line)
            if control.get("type") != "control_request" or control.get("request", {}).get("subtype") != "interrupt":
                continue
            received_interrupt = True
            runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-received").write_text("control interrupt\n", encoding="utf-8")
            interrupt_release = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-release")
            if runtime.Path(runtime.sys.argv[0]).name.endswith("-hold-reject-interrupt"):
                reject = runtime.Path(str(runtime.sys.argv[0]) + ".interrupt-reject")
                reject_deadline = runtime.time.monotonic() + 15
                while not reject.exists() and runtime.time.monotonic() < reject_deadline:
                    runtime.time.sleep(0.02)
                reject.unlink(missing_ok=True)
                runtime.write({"type": "control_response", "response": {
                    "subtype": "error", "request_id": control.get("request_id"),
                    "error": "Fixture rejected the interrupt while the turn remains active.",
                }})
                ack_deadline = runtime.time.monotonic() + 15
                while not interrupt_release.exists() and runtime.time.monotonic() < ack_deadline:
                    runtime.time.sleep(0.02)
                interrupt_release.unlink(missing_ok=True)
                runtime.text("msg_after_rejected_interrupt", "The turn completed after Stop was rejected.")
                runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
                break
            ack_deadline = runtime.time.monotonic() + 15
            while not interrupt_release.exists() and runtime.time.monotonic() < ack_deadline:
                runtime.time.sleep(0.02)
            interrupt_release.unlink(missing_ok=True)
            runtime.write({"type": "control_response", "response": {
                "subtype": "success", "request_id": control.get("request_id"), "response": {},
            }})
            runtime.write({"type": "result", "subtype": "error_during_execution", "is_error": True,
                   "result": "Claude interrupted this turn."})
            break
        ready.unlink(missing_ok=True)
        if not received_interrupt:
            raise TimeoutError("Timed out waiting for Claude interrupt.")
        commands.append({"interruptReceived": True})
    elif user_text.strip().lower() == "please fail-this-claude-turn.":
        # Match only the live message, not a historical mention: once this turn
        # fails and its text is part of the transcript, a later turn's handoff
        # context quotes it back verbatim, and a substring check would misfire.
        # The session already exists by now: Playhouse answered initialize and
        # sent this turn. Failing here leaves the session behind, so the next
        # turn must resume it instead of claiming its ID again.
        raise RuntimeError("Claude fixture failed this turn after creating its session.")
    elif "hold-claude-turn-for-concurrency" in user_text.lower():
        ready = runtime.Path(str(runtime.sys.argv[0]) + ".concurrent-turn-ready")
        release = runtime.Path(str(runtime.sys.argv[0]) + ".concurrent-turn-release")
        ready.write_text("Claude turn is active.\n", encoding="utf-8")
        deadline = runtime.time.monotonic() + 60
        while not release.exists() and runtime.time.monotonic() < deadline:
            runtime.time.sleep(0.01)
        if not release.exists():
            raise TimeoutError("Timed out waiting for the concurrent Claude turn test.")
        if "fail-after-hold" in user_text.lower():
            raise RuntimeError("Claude fixture failed after releasing the held turn.")
        runtime.text("msg_concurrent", runtime.SIMPLE_ANSWER)
    elif "publish-image-during-active-turn" in user_text.lower():
        ready = runtime.Path(str(runtime.sys.argv[0]) + ".image-turn-ready")
        release = runtime.Path(str(runtime.sys.argv[0]) + ".image-turn-release")
        ready.write_text("Claude turn is active.\n", encoding="utf-8")
        deadline = runtime.time.monotonic() + 60
        while not release.exists() and runtime.time.monotonic() < deadline:
            runtime.time.sleep(0.01)
        if not release.exists():
            raise TimeoutError("Timed out waiting for the agent image publication test.")
        runtime.text("msg_image_order", "Claude answer after the image.")
    elif "show-tool-calls-inline" in user_text.lower():
        # Commentary, then shell calls with their stated purpose and output, a
        # failing call, and an MCP call whose arguments and result stay private,
        # so the timeline can place each call after the text written before it.
        def tool_call(tool_id, name, tool_input, output, is_error=False):
            runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}])
            runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tool_id, "content": output, "is_error": is_error},
            ]}})
        runtime.text("msg_timeline_intro", "I'll check the repository status first.")
        tool_call("toolu_timeline_status", "Bash", {
            "command": "git status --short && echo fixture-status-done", "description": "Check repository status",
        }, "fixture-status-done")
        runtime.text("msg_timeline_middle", "The status is clean. Next I'll list the files and run the check.")
        tool_call("toolu_timeline_list", "Bash", {"command": "ls -1", "description": "List fixture files"},
                  "README.md\nfixture-one.txt\nfixture-two.txt\nfixture-three.txt\nfixture-four.txt")
        tool_call("toolu_timeline_fail", "Bash", {"command": "exit 3", "description": "Run the failing check"},
                  "Exit code 3", is_error=True)
        tool_call("toolu_timeline_mcp", "mcp__fixture__lookup", {"query": "timeline-private-argument"},
                  "timeline-private-result")
        runtime.text("msg_timeline_final", "Here is what ran:\n1. `git status --short` was clean.\n2. The check exited with code `3`.\n\n- Bullets read at text size\n- Inline `code` is tinted")
    elif "follow-active-turn" in user_text.lower():
        # Holds before any output, so a test can reopen the conversation first,
        # then again while commentary and a running tool are visible.
        for stage, description in [("started", "Claude turn started without output."),
                                   ("ready", "Claude turn shows progress and a running tool.")]:
            if stage == "ready":
                runtime.text("msg_follow_progress", "Claude is partway through the followed turn.")
                runtime.assistant("msg_toolu_follow_active_step", [{"type": "tool_use", "id": "toolu_follow_active_step", "name": "Bash", "input": {
                    "command": "fixture-follow-step", "description": "Fixture follow step",
                }}])
            marker = runtime.Path(str(runtime.sys.argv[0]) + f".follow-turn-{stage}")
            release = runtime.Path(str(runtime.sys.argv[0]) + (".follow-turn-continue" if stage == "started" else ".follow-turn-release"))
            marker.write_text(f"{description}\n", encoding="utf-8")
            deadline = runtime.time.monotonic() + 60
            while not release.exists() and runtime.time.monotonic() < deadline:
                runtime.time.sleep(0.01)
            marker.unlink(missing_ok=True)
            if not release.exists():
                raise TimeoutError(f"The test did not release the fixture after: {description}")
            release.unlink(missing_ok=True)
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_follow_active_step", "content": "", "is_error": False},
        ]}})
        runtime.text("msg_follow_final", "Claude finished the followed turn.")
    elif "stream-follow-latest" in user_text.lower():
        # Streams a long reply in held stages, so a test can check the transcript
        # between them: following the bottom, then left alone once scrolled up.
        for stage, count in enumerate(runtime.STREAM_FOLLOW_STAGES, start=1):
            first = sum(runtime.STREAM_FOLLOW_STAGES[:stage - 1]) + 1
            for line in range(first, first + count):
                runtime.text(f"msg_stream_follow_{line}", runtime.stream_follow_line(line))
            ready = runtime.Path(str(runtime.sys.argv[0]) + f".stream-follow-ready-{stage}")
            release = runtime.Path(str(runtime.sys.argv[0]) + f".stream-follow-release-{stage}")
            ready.write_text(f"Streamed follow stage {stage} is visible.\n", encoding="utf-8")
            deadline = runtime.time.monotonic() + 60
            while not release.exists() and runtime.time.monotonic() < deadline:
                runtime.time.sleep(0.01)
            ready.unlink(missing_ok=True)
            if not release.exists():
                raise TimeoutError(f"The test did not release streamed follow stage {stage}.")
            release.unlink(missing_ok=True)
        runtime.text("msg_stream_follow_final", runtime.STREAM_FOLLOW_FINAL)
    elif user_text.startswith("Write a concise task title"):
        if "title-failure" not in runtime.sys.argv[0]:
            runtime.text("msg_title", "Generated Claude title")
    elif "<response-comments>" in user_text:
        payload = user_text.split("<response-comments>", 1)[1].split("</response-comments>", 1)[0]
        comments = runtime.json.loads(payload)
        answer = "\n".join(
            f':playhouse-annotation{{index="{index}"}} For ‘{item["text"]}’: {item["comment"]}'
            for index, item in enumerate(comments)
        )
        runtime.text("msg_comments", answer)
    elif user_text.rstrip().endswith("What happened earlier?"):
        runtime.text("msg_recovered", runtime.SIMPLE_ANSWER)
    elif "recall-earlier-pages" in user_text.lower():
        # A standalone chat looking back: it reads each earlier page named in the
        # message ("page-id:<id>") with the real `chat page read` command, then answers.
        close_turn = runtime.report_command(instructions, " chat page close-turn ")
        cli = close_turn.split(" chat page close-turn ")[0] if close_turn else None
        turn_key = runtime.hashlib.md5(user_text.encode()).hexdigest()[:8]
        runtime.text(f"msg_recall_intro_{turn_key}", "Let me look back at those pages.")
        for index, page_id in enumerate(runtime.re.findall(r"page-id:([A-Za-z0-9-]+)", user_text)):
            command = f"{cli} chat page read {page_id}"
            commands.append({"command": command,
                             "output": runtime.run_tool(f"toolu_recall_{index}", "Bash", {"command": command}, command)})
        hold = runtime.Path(str(runtime.sys.argv[0]) + ".recall-hold")
        if hold.exists():
            # Holds the turn open after the reads so a test can look at the live turn.
            ready = runtime.Path(str(runtime.sys.argv[0]) + ".recall-ready")
            release = runtime.Path(str(runtime.sys.argv[0]) + ".recall-release")
            ready.write_text("The recalling turn is active.\n", encoding="utf-8")
            deadline = runtime.time.monotonic() + 60
            while not release.exists() and runtime.time.monotonic() < deadline:
                runtime.time.sleep(0.01)
            ready.unlink(missing_ok=True)
            if not release.exists():
                raise TimeoutError("Timed out waiting for the recall hold release.")
            hold.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
        runtime.text(f"msg_recall_answer_{turn_key}", "I recalled both pages.")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": runtime.run_tool("toolu_close_turn", "Bash", {"command": close_turn}, close_turn)})
    elif "release notes" in user_text.lower():
        # A standalone chat has no outcome to report, so it ends every turn with
        # its page signal instead. That signal runs in the same place a task
        # outcome does: after the answer, before Claude's closing line.
        runtime.text("msg_chat_intent", runtime.CHAT_INTENT)
        runtime.run_tool("toolu_chat_read", "Read", {"file_path": runtime.os.path.join(runtime.os.getcwd(), "README.md")})
        runtime.text("msg_chat_answer", runtime.CHAT_ANSWER)
        close_turn = runtime.report_command(instructions, " chat page close-turn ")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": runtime.run_tool("toolu_close_turn", "Bash", {"command": close_turn}, close_turn)})
        runtime.text("msg_chat_closing", runtime.CHAT_CLOSING)
    elif match := runtime.re.search(r"long history turn (\d+)", user_text.lower()):
        # Thirty visible assistant messages in one turn, so a few turns build a
        # transcript long enough to page through.
        number = match.group(1)
        for index in range(1, 31):
            runtime.text(f"msg_long_{number}_{index}", f"Long history turn {number}, message {index}.")
    elif "token waste" in user_text.lower() or "instruction resume" in user_text.lower():
        if "instruction resume" in user_text.lower():
            runtime.write_resume_session(runtime.argument("--session-id") or runtime.argument("--resume"))
        else:
            runtime.write_waste_session(runtime.argument("--session-id") or runtime.argument("--resume"))
        runtime.text("msg_waste_answer", "Token waste shown.")
        progress_clear = runtime.report_command(instructions, " task progress clear ")
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        for tool_id, command in [("toolu_progress_clear", progress_clear), ("toolu_outcome", outcome)]:
            if command:
                commands.append({"command": command, "output": runtime.run_tool(tool_id, "Bash", {"command": command}, command)})
        runtime.text("msg_waste_closing", "The token waste is above.")
    elif "story" in user_text.lower():
        # Kept on disk because each send may start a fresh fixture process, and
        # a repeated message ID would make the second turn's calls look like the first's.
        counter = runtime.Path(str(runtime.sys.argv[0]) + ".story-turns")
        story_turns = (int(counter.read_text()) if counter.is_file() else 0) + 1
        counter.write_text(str(story_turns))
        main_ids = [f"msg_story_{story_turns}", f"msg_story_closing_{story_turns}"]
        for index, usage in enumerate(runtime.STORY_SUBAGENT_CALLS):
            runtime.assistant(f"msg_fx_sub{story_turns}_{index}", [{"type": "text", "text": "subagent step"}], usage,
                      parent=f"toolu_fx_agent_{story_turns}")
        runtime.write_session_calls(runtime.argument("--session-id") or runtime.argument("--resume"), story_turns,
                            list(zip(main_ids, runtime.STORY_MAIN_CALLS)))
        runtime.text(main_ids[0], runtime.STORY, runtime.STORY_MAIN_CALLS[0])
        # Claude Code writes one line per content block of a call; the repeat shares the call's ID.
        runtime.assistant(main_ids[0], [{"type": "thinking", "thinking": ""}], runtime.STORY_MAIN_CALLS[0])
        progress_clear = runtime.report_command(instructions, " task progress clear ")
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        for tool_id, command in [("toolu_progress_clear", progress_clear), ("toolu_outcome", outcome)]:
            if command:
                commands.append({"command": command, "output": runtime.run_tool(tool_id, "Bash", {"command": command}, command)})
        runtime.text(main_ids[1], runtime.STORY_CLOSING, runtime.STORY_MAIN_CALLS[1])
    elif "inspect" in user_text.lower():
        runtime.text("msg_inspect_intent", runtime.INSPECTION_INTENT)
        runtime.run_tool("toolu_read", "Read", {"file_path": runtime.os.path.join(runtime.os.getcwd(), "README.md")})
        runtime.text("msg_inspect_answer", runtime.INSPECTION_ANSWER)
    elif "checks" in user_text.lower():
        # Every text precedes an ordinary tool, so the turn records only commentary.
        runtime.text("msg_checks_first", runtime.UNANSWERED_FIRST)
        runtime.run_tool("toolu_checks_first", "Read", {"file_path": runtime.os.path.join(runtime.os.getcwd(), "README.md")})
        runtime.text("msg_checks_last", runtime.UNANSWERED_LAST)
        runtime.run_tool("toolu_checks_last", "Read", {"file_path": runtime.os.path.join(runtime.os.getcwd(), "README.md")})
    elif "leave-dev-server-running" in user_text.lower():
        # A shell the agent deliberately leaves running: the stopping outcome
        # is reported before the result and no notification ever follows, so
        # only that outcome can settle the turn.
        tool_id = "toolu_dev_server"
        task_id = "bgshell-dev-server-1"
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "npm run dev", "description": "Dev server", "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Dev server"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Dev server", "task_type": "local_bash"})
        runtime.text("msg_dev_server_started", "DEV SERVER RUNNING")
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome,
                             "output": runtime.run_tool("toolu_dev_server_outcome", "Bash", {"command": outcome}, outcome)})
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        runtime.complete_command(runtime.current_command_uuid)
        runtime.Path(str(runtime.sys.argv[0]) + ".dev-server-result-sent").write_text(
            "The outcome and the result are out while the dev server runs.\n", encoding="utf-8"
        )
    elif "report-early-then-continue" in user_text.lower():
        # An outcome reported before a background agent finished is stale once
        # the woken parent turn does more work: that turn ends without a new
        # report, so the earlier `completed` must not send the task to Review.
        tool_id = "toolu_early_report_agent"
        task_id = "bgagent-early-report-1"
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "Explore", "description": "Late check", "prompt": "check something",
            "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "Explore", "description": "Late check"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Late check", "subagent_type": "Explore",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        runtime.text("msg_early_report_started", "REPORTED EARLY")
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome,
                             "output": runtime.run_tool("toolu_early_report_outcome", "Bash", {"command": outcome}, outcome)})
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        runtime.complete_command(runtime.current_command_uuid)
        runtime.wait_for_release("early-report", "The early outcome and the result are out while the agent runs.")
        runtime.write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "", "summary": "The late check found more work."})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        runtime.parent_request_started("msg_early_report_woken", woken=True)
        runtime.text("msg_early_report_woken", "MORE WORK FOUND")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "background agents wake" in user_text.lower():
        # Mirrors the real CLI waking the parent for a background agent's
        # notification after the parent already sent its result. The last
        # agent finishes while the woken parent is still streaming, and only
        # the parent's next result ends the turn.
        agents = [("toolu_wake_agent_a", "bgtask-wake-a", "Wake reviewer A"),
                  ("toolu_wake_agent_b", "bgtask-wake-b", "Wake reviewer B")]
        runtime.assistant("msg_wake_agents", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "Explore", "description": description, "prompt": "review something",
            "run_in_background": True,
        }} for tool_id, _, description in agents])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False}
            for tool_id, _, _ in agents
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "Explore", "description": description}
            for _, task_id, description in agents
        ]})
        for tool_id, task_id, description in agents:
            runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
                   "tool_use_id": tool_id, "description": description, "subagent_type": "Explore",
                   "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        runtime.text("msg_wake_started", "WAKE STARTED")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        (first_tool, first_task, _), (second_tool, second_task, second_description) = agents
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": first_task, "run_id": "fixture-run-1",
               "tool_use_id": first_tool, "status": "completed", "output_file": "", "summary": "Reviewer A finished."})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": second_task, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "Explore", "description": second_description},
        ]})
        # The woken parent has only begun streaming when the last agent
        # finishes; no complete assistant message has arrived yet.
        runtime.parent_request_started("msg_wake_resumed", woken=True)
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": second_task, "run_id": "fixture-run-1",
               "tool_use_id": second_tool, "status": "completed", "output_file": "", "summary": "Reviewer B finished."})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        wake_pause = runtime.Path(str(runtime.sys.argv[0]) + ".background-wake-pause")
        if wake_pause.exists():
            wake_ready = runtime.Path(str(runtime.sys.argv[0]) + ".background-wake-ready")
            wake_release = runtime.Path(str(runtime.sys.argv[0]) + ".background-wake-release")
            wake_ready.write_text("Last notification sent mid-work.\n", encoding="utf-8")
            wake_deadline = runtime.time.monotonic() + 30
            while not wake_release.exists() and runtime.time.monotonic() < wake_deadline:
                runtime.time.sleep(0.02)
            if not wake_release.exists():
                raise TimeoutError("The test did not release the woken parent's final answer.")
        runtime.text("msg_wake_resumed", "WAKE RESUMED")
        runtime.run_tool("toolu_wake_read", "Read", {"file_path": runtime.os.path.join(runtime.os.getcwd(), "README.md")})
        # The woken turn's next request carries Reviewer B's queued notification.
        runtime.parent_request_started("msg_wake_final")
        runtime.text("msg_wake_final", "WAKE FINAL")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "background agent" in user_text.lower():
        # Mirrors the real `claude` CLI's --forward-subagent-text protocol for a
        # backgrounded Agent/Task call: the launch confirmation tool_result is not
        # completion, and the real outcome arrives later as system task events.
        tool_id = "toolu_background_agent"
        task_id = "bgtask-fixture-1"
        did_fail = "background agent failure" in user_text.lower()
        terminal_status = "failed" if did_fail else "completed"
        result_summary = "Background check failed." if did_fail else "Background check finished."
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "Explore", "description": "Background check", "prompt": "check something",
            "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "Explore", "description": "Background check"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Background check", "subagent_type": "Explore",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        runtime.write({"type": "system", "subtype": "task_progress", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Running Bash", "subagent_type": "Explore",
               "last_tool_name": "Bash"})
        runtime.text("msg_background_started", "STARTED")
        if not did_fail:
            # Model the provider finishing its parent response before it sends
            # the background agent's terminal notification. The bridge must
            # keep the send open while that result is still outstanding.
            runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            runtime.background_result_sent = True
        runtime.write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": terminal_status, "end_time": 0}})
        if not did_fail:
            # This empty snapshot can clear the client's outstanding task set
            # before task_notification carries the actual result.
            runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        summary_pause = runtime.Path(str(runtime.sys.argv[0]) + ".background-summary-pause")
        if summary_pause.exists() and not did_fail:
            summary_ready = runtime.Path(str(runtime.sys.argv[0]) + ".background-summary-ready")
            summary_release = runtime.Path(str(runtime.sys.argv[0]) + ".background-summary-release")
            summary_ready.write_text("Status-only completion sent.\n", encoding="utf-8")
            summary_deadline = runtime.time.monotonic() + 30
            while not summary_release.exists() and runtime.time.monotonic() < summary_deadline:
                runtime.time.sleep(0.02)
            if not summary_release.exists():
                raise TimeoutError("The test did not release the background-agent summary event.")
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": terminal_status, "output_file": "", "summary": result_summary})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        if did_fail:
            # The running turn's next request carries the notification; no wake follows.
            runtime.parent_request_started("msg_background_failure_seen")
            runtime.text("msg_background_failure_seen", "The background check failed.")
        else:
            runtime.parent_request_started("msg_background_woken", woken=True)
            runtime.text("msg_background_woken", "BACKGROUND HANDLED")
            runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "consumed wake notification" in user_text.lower():
        # Mirrors the observed stranding sequence: a background shell parks the
        # answered turn, the shell's notification arrives, and Claude Code
        # starts the provider turn that would deliver it — `system init` — but
        # then says nothing at all, because it consumed the notification
        # without a new parent request. No answer and no result of that turn
        # ever arrive, so Playhouse alone has to settle this turn instead of
        # leaving the task In Progress forever.
        tool_id = "toolu_consumed_wake"
        task_id = "bgshell-consumed-wake-1"
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo WAKE", "description": "Consumed wake shell", "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Consumed wake shell"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Consumed wake shell", "task_type": "local_bash"})
        # No outcome here: the turn is waiting for the shell, and a reported
        # stopping outcome would settle it before the wake this models.
        runtime.text("msg_consumed_wake_started", "WAKE SHELL STARTED")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        runtime.complete_command(runtime.current_command_uuid)
        runtime.wait_for_release("consumed-wake", "The parent result is out while the background shell runs.")
        runtime.write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Consumed wake shell" completed (exit code 0)'})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        # The woken provider turn starts and then goes quiet: no parent request,
        # no answer, no result of its own, ever.
        runtime.write({"type": "system", "subtype": "init"})
        runtime.Path(str(runtime.sys.argv[0]) + ".consumed-wake-woken").write_text(
            "The woken turn started and consumed the notification silently.\n", encoding="utf-8"
        )
    elif "slow woken turn" in user_text.lower():
        # The same announcement, but from a woken turn that is alive and merely
        # slow to speak: it stays silent well past the grace Playhouse gives a
        # consumed notification, then answers. Cutting it off there would lose
        # the background task's report, so this turn must end on Claude's own
        # answer rather than on Playhouse's backstop.
        tool_id = "toolu_slow_woken"
        task_id = "bgshell-slow-woken-1"
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo SLOW", "description": "Slow woken shell", "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Slow woken shell"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Slow woken shell", "task_type": "local_bash"})
        runtime.text("msg_slow_woken_started", "SLOW SHELL STARTED")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        runtime.complete_command(runtime.current_command_uuid)
        runtime.write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Slow woken shell" completed (exit code 0)'})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        runtime.write({"type": "system", "subtype": "init"})
        runtime.Path(str(runtime.sys.argv[0]) + ".slow-woken-announced").write_text(
            "The woken turn started and is about to go quiet for a while.\n", encoding="utf-8"
        )
        runtime.time.sleep(float(runtime.os.environ.get("PLAYHOUSE_E2E_CLAUDE_SLOW_WOKEN_SILENCE_SECONDS", "6")))
        # Only `parent_request_started` without a second `init`: this turn was
        # already announced above, it is just finally speaking.
        runtime.parent_request_started("msg_slow_woken_answer")
        runtime.text("msg_slow_woken_answer", "SLOW WOKEN HANDLED")
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome,
                             "output": runtime.run_tool("toolu_slow_woken_outcome", "Bash", {"command": outcome}, outcome)})
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "parked background shell" in user_text.lower():
        # Mirrors a turn Claude Code has already answered while a background
        # shell keeps running: the parent result is out, no notification has
        # arrived yet, and the turn is still the active one. Input steered into
        # that window must reach the process and be answered inside the same
        # turn, before the shell's notification and the woken parent turn.
        tool_id = "toolu_parked_shell"
        task_id = "bgshell-parked-1"
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo PARKED", "description": "Parked shell", "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Parked shell"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Parked shell", "task_type": "local_bash"})
        runtime.text("msg_parked_started", "PARKED STARTED")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
        # The submitted command is finished too, so only the running shell holds
        # the turn open: exactly the window the real CLI parks a turn in.
        runtime.complete_command(runtime.current_command_uuid)
        runtime.Path(str(runtime.sys.argv[0]) + ".parked-shell-ready").write_text(
            "The parent result is out while the shell runs.\n", encoding="utf-8"
        )
        steered, steered_uuid = runtime.read_steered_input("the parked background shell turn")
        runtime.parent_request_started("msg_parked_steered_answer")
        runtime.text("msg_parked_steered", f"STEERED: {steered}")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Parked shell" completed (exit code 0)'})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        runtime.parent_request_started("msg_parked_final", woken=True)
        runtime.text("msg_parked_final", "PARKED HANDLED")
        runtime.wait_for_release("steered-answer", "The steered answer is visible while the woken parent result is pending.")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.complete_command(steered_uuid)
    elif "background shell" in user_text.lower():
        # Mirrors the real `claude` CLI for a Bash call with run_in_background:
        # the tool_result only confirms the launch, the shell reports through
        # the same system task events as an agent, and Claude Code then starts
        # a woken parent turn to deliver its notification. When the shell
        # finishes early, that woken turn starts before the first result.
        tool_id = "toolu_background_shell"
        task_id = "bgshell-fixture-1"
        finishes_early = "finishes early" in user_text.lower()
        runtime.assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo SHELL DONE", "description": "Fixture shell", "run_in_background": True,
        }}])
        runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Fixture shell"},
        ]})
        runtime.write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Fixture shell", "task_type": "local_bash"})
        runtime.text("msg_shell_started", "SHELL STARTED")
        if not finishes_early:
            runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            runtime.wait_for_release("background-shell-running", "Parent result sent while the shell runs.")
        runtime.write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        runtime.write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Fixture shell" completed (exit code 0)'})
        runtime.write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        runtime.wait_for_release("background-shell-wake", "The shell finished before the parent woke.")
        runtime.parent_request_started("msg_shell_woken", woken=True)
        runtime.text("msg_shell_woken", "SHELL HANDLED")
        outcome = runtime.report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome, "output": runtime.run_tool("toolu_shell_outcome", "Bash", {"command": outcome}, outcome)})
        if finishes_early:
            # The first turn's result arrives only after the woken turn began.
            runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            runtime.wait_for_release("background-shell-second-result", "The first result arrived; the woken turn's is pending.")
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.background_result_sent = True
    else:
        runtime.text("msg_simple", runtime.SIMPLE_ANSWER)
    return commands


def run_reattach_turn(runtime):
    """A turn for the daemon-restart cases (`-reattach` in the executable name).

    Playhouse runs this process with file-backed stdio, so it keeps running when the daemon that
    started it dies. The turn writes "Before restart." and holds; marker files beside the
    executable drive it from there: `.reattach-ask` raises a tool approval and a question,
    `.reattach-late-reply` writes a reply to Playhouse's first control request again,
    `.reattach-release` finishes with "After restart." and the turn's outcome,
    `.reattach-release-quiet` finishes with no outcome report, and `.reattach-exit` exits
    without a result. For a standalone chat, `.reattach-close-turn` runs the turn's real
    `chat page close-turn` without ending the turn (a new page titled by the marker's text, or
    `--continues true` when it is empty), logging the command's result to
    `.reattach-close-turn-output`; a page classifier prompt is answered at once with a new
    page titled `Restart fallback`; with `.reattach-hold-nudge`, a Playhouse nudge is held
    like any turn (writing "Nudge before restart.") instead of being answered at once.
    With `.reattach-compact`, the held turn reports a compaction start without a uuid;
    `.reattach-compact-end` writes its boundary while the turn keeps running, and `.reattach-release` writes the boundary if it is still pending. Every input line is logged to `.reattach-stdin`."""
    base = str(runtime.sys.argv[0])
    instructions = runtime.argument("--append-system-prompt") or ""
    turn_uuid = None
    reporting = None
    pending = {}

    def log(name, value):
        with open(f"{base}.{name}", "a", encoding="utf-8") as handle:
            handle.write(runtime.json.dumps(value) + "\n")

    def finish():
        runtime.write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        runtime.complete_command(turn_uuid)

    def end_compaction():
        if runtime.Path(f"{base}.reattach-compact").exists():
            runtime.Path(f"{base}.reattach-compact").unlink()
            runtime.write({"type": "system", "subtype": "compact_boundary", "compact_metadata": {
                "trigger": "auto", "pre_tokens": 190000, "post_tokens": 6000}})

    def handle(line):
        nonlocal turn_uuid, reporting
        log("reattach-stdin", line)
        if not line.strip():
            return
        message = runtime.json.loads(line)
        kind = message.get("type")
        if kind == "control_request":
            subtype = (message.get("request") or {}).get("subtype")
            response = {"claude_code_version": "2.1.308 (Claude Code fixture)", "models": [], "commands": [], "agents": []} \
                if subtype == "initialize" else {}
            if subtype == "interrupt":
                runtime.Path(f"{base}.reattach-interrupted").write_text(message.get("request_id", ""), encoding="utf-8")
            runtime.write({"type": "control_response", "response": {
                "subtype": "success", "request_id": message.get("request_id"), "response": response}})
            if subtype == "interrupt":
                runtime.write({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "Interrupted."})
                runtime.complete_command(turn_uuid)
        elif kind == "control_response":
            response = message.get("response") or {}
            request_id = response.get("request_id")
            log("reattach-replies", {"id": request_id, "response": response.get("response")})
            if pending.pop(request_id, None) == "question":
                answers = ((response.get("response") or {}).get("updatedInput") or {}).get("answers") or {}
                runtime.write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_reattach_question", "content": runtime.json.dumps(answers), "is_error": False}]}})
                runtime.text("msg_reattach_answer", f"Answer received: {answers.get('Which color?', '')}.")
        elif kind == "user":
            content = message.get("message", {}).get("content", [])
            user_text = "".join(block.get("text", "") for block in content if block.get("type") == "text")
            if turn_uuid is None and user_text.startswith("Classify the latest user message for Playhouse's continuous chat page index."):
                turn_uuid = message.get("uuid")
                runtime.text("msg_reattach_classification", '{"continues":false,"title":"Restart fallback"}')
                finish()
            elif turn_uuid is None and "playhouse internal outcome nudge" in user_text.lower() \
                    and runtime.Path(f"{base}.reattach-hold-nudge").exists():
                runtime.Path(f"{base}.reattach-hold-nudge").unlink()
                turn_uuid = message.get("uuid")
                runtime.write({"type": "system", "subtype": "init", "session_id": runtime.argument("--session-id") or runtime.argument("--resume")})
                runtime.text("msg_reattach_nudge_before", "Nudge before restart.")
                runtime.Path(f"{base}.reattach-ready").write_text(user_text, encoding="utf-8")
            elif turn_uuid is None and "playhouse internal outcome nudge" in user_text.lower():
                # A status nudge is answered at once with the outcome.
                turn_uuid = message.get("uuid")
                runtime.text("msg_reattach_nudge", "Waiting for your review.")
                command = runtime.report_command(instructions, "task outcome", "waiting-response")
                reporting = runtime.subprocess.Popen(runtime.shlex.split(command), stdout=runtime.subprocess.DEVNULL, stderr=runtime.subprocess.DEVNULL) \
                    if command else None
                if reporting is None:
                    finish()
            elif turn_uuid is None:
                turn_uuid = message.get("uuid")
                runtime.write({"type": "system", "subtype": "init", "session_id": runtime.argument("--session-id") or runtime.argument("--resume")})
                runtime.text("msg_reattach_before", "Before restart.")
                # A compaction starts before the daemon dies and ends after it; with no uuid,
                # the next daemon cannot know the row the first one reported for it.
                if runtime.Path(f"{base}.reattach-compact").exists():
                    runtime.write({"type": "system", "subtype": "status", "status": "compacting"})
                runtime.Path(f"{base}.reattach-ready").write_text(user_text, encoding="utf-8")
            else:
                # A steered follow-up reaches the running turn and is answered in it.
                log("reattach-steers", user_text)
                runtime.text(f"msg_reattach_steer_{len(user_text)}", f"Steer received: {user_text}")
                runtime.complete_command(message.get("uuid"))

    while True:
        line = runtime.STDIN.readline(0.05)
        while line:
            handle(line[:-1] if line.endswith("\n") else line)
            line = runtime.STDIN.readline(0)
        if line == "":
            # A piped helper run ends with its input; a file-backed run never sees this.
            return 0
        if turn_uuid is None:
            continue
        if runtime.Path(f"{base}.reattach-ask").exists():
            runtime.Path(f"{base}.reattach-ask").unlink()
            pending["reattach-approval-1"] = "approval"
            runtime.write({"type": "control_request", "request_id": "reattach-approval-1", "request": {
                "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "touch reattach.txt"}}})
            pending["reattach-question-1"] = "question"
            runtime.write({"type": "control_request", "request_id": "reattach-question-1", "request": {
                "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [{
                    "question": "Which color?", "header": "Color",
                    "options": [{"label": "red"}, {"label": "blue"}], "multiSelect": False}]}}})
            runtime.Path(f"{base}.reattach-asked").write_text("asked\n", encoding="utf-8")
        close_turn_marker = runtime.Path(f"{base}.reattach-close-turn")
        if close_turn_marker.exists():
            title = close_turn_marker.read_text(encoding="utf-8").strip()
            close_turn_marker.unlink()
            command = runtime.report_command(instructions, " chat page close-turn ")
            if command and title:
                command = command.replace("--continues true", f"--continues false --new-title {runtime.shlex.quote(title)}")
            # Like a tool call, it runs inside the turn, which keeps going after it returns.
            completed = runtime.subprocess.run(runtime.shlex.split(command), capture_output=True, text=True) if command else None
            log("reattach-close-turn-output", {
                "command": command,
                "returncode": completed.returncode if completed else None,
                "output": completed.stdout if completed else "",
            })
        if runtime.Path(f"{base}.reattach-late-reply").exists():
            runtime.Path(f"{base}.reattach-late-reply").unlink()
            runtime.write({"type": "control_response", "response": {"subtype": "success", "request_id": "playhouse-1", "response": {}}})
        if runtime.Path(f"{base}.reattach-exit").exists():
            # Consumed, so a later turn of the same fixture runs normally.
            runtime.Path(f"{base}.reattach-exit").unlink(missing_ok=True)
            runtime.os._exit(3)
        if runtime.Path(f"{base}.reattach-compact-end").exists():
            # The compaction ends inside the still-running turn.
            runtime.Path(f"{base}.reattach-compact-end").unlink()
            end_compaction()
        if reporting is None and runtime.Path(f"{base}.reattach-release-quiet").exists():
            runtime.Path(f"{base}.reattach-release-quiet").unlink()
            runtime.text("msg_reattach_after", "After restart.")
            finish()
        if reporting is None and runtime.Path(f"{base}.reattach-release").exists():
            runtime.Path(f"{base}.reattach-release").unlink()
            end_compaction()
            runtime.text("msg_reattach_after", "After restart.")
            command = runtime.report_command(instructions, "task outcome", "waiting-response")
            # Like a tool call, the report runs while the turn keeps reading its input.
            reporting = runtime.subprocess.Popen(runtime.shlex.split(command), stdout=runtime.subprocess.DEVNULL, stderr=runtime.subprocess.DEVNULL) \
                if command else None
            if reporting is None:
                finish()
        if reporting is not None and reporting.poll() is not None:
            reporting = None
            finish()


#!/usr/bin/env python3
"""Deterministic stand-in for the `claude` CLI's stream-json protocol.

Playhouse launches it exactly like Claude Code (`-p --input-format stream-json
--output-format stream-json ... --append-system-prompt <instructions>`). Each
process serves one turn, as Claude Code does under Playhouse. The reply
reproduces Claude's observed habit of answering, running its Playhouse report
commands, and then adding a closing line. The report commands are taken from the
instructions Playhouse appended and really run, so outcomes reach the task.

Every turn is recorded in `<executable>.history` for test assertions.
"""

import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path

STORY = "BISCUIT-7 waited by the gate every evening. One night the boy finally came home."
STORY_CLOSING = "The story is above."
INSPECTION_INTENT = "I'll inspect the workspace first."
INSPECTION_ANSWER = "Inspection done: the workspace is ready."
UNANSWERED_FIRST = "Starting the checks."
UNANSWERED_LAST = "Checks are running; results will follow."
SIMPLE_ANSWER = "OK."
PENDING_QUESTION_SUCCESS_MARKER = "finish while a structured question remains pending"


def write(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


def argument(name):
    arguments = sys.argv[1:]
    return arguments[arguments.index(name) + 1] if name in arguments else None


def report_command(instructions, marker, replacement=None):
    """Returns the CLI command line Playhouse's instructions give for `marker`."""
    for line in instructions.splitlines():
        command = line.strip()
        # Command lines start with the quoted CLI path; prose may mention the same words.
        if command.startswith("'") and marker in command:
            return command.replace("<completed|in-progress|waiting-response>", replacement) if replacement else command
    return None


def assistant(message_id, blocks):
    write({"type": "assistant", "parent_tool_use_id": None,
           "message": {"id": message_id, "role": "assistant", "content": blocks}})


def text(message_id, value):
    write({"type": "stream_event", "parent_tool_use_id": None,
           "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": value}}})
    assistant(message_id, [{"type": "text", "text": value}])


def run_tool(tool_id, name, tool_input, command=None):
    assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}])
    output = ""
    if command:
        completed = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, timeout=60)
        output = (completed.stdout + completed.stderr).strip()
    write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tool_id, "content": output, "is_error": False},
    ]}})
    return output


background_result_sent = False
current_command_uuid = None


def complete_command(uuid):
    """Mirrors Claude Code reporting that it finished a submitted user command;
    Playhouse stops counting that command as outstanding for the turn."""
    if uuid:
        write({"type": "command_lifecycle", "command_uuid": uuid, "state": "completed"})


def parent_request_started(message_id, woken=False):
    """Mirrors the real CLI starting a parent model request. A woken turn,
    which Claude Code starts to deliver a finished background task's
    notification after the parent's result, first sends `system init`."""
    if woken:
        write({"type": "system", "subtype": "init"})
    write({"type": "stream_event", "parent_tool_use_id": None,
           "event": {"type": "message_start", "message": {"id": message_id, "role": "assistant"}}})


def wait_for_release(name, description):
    """Pauses at a protocol point when the test created `<fixture>.<name>-pause`."""
    if not Path(str(sys.argv[0]) + f".{name}-pause").exists():
        return
    Path(str(sys.argv[0]) + f".{name}-ready").write_text(f"{description}\n", encoding="utf-8")
    release = Path(str(sys.argv[0]) + f".{name}-release")
    deadline = time.monotonic() + 30
    while not release.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    if not release.exists():
        raise TimeoutError(f"The test did not release the fixture after: {description}")


def read_steered_input(description):
    """Consumes input Playhouse steers into the running turn, mirroring Claude
    Code taking a `priority: next` user message at its next tool boundary.
    Returns its text and command uuid, which the turn completes once answered."""
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        readable, _, _ = select.select([sys.stdin], [], [], 0.02)
        if not readable:
            continue
        line = sys.stdin.readline()
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("type") != "user":
            continue
        content = message.get("message", {}).get("content", [])
        steered = "".join(block.get("text", "") for block in content if block.get("type") == "text")
        if steered:
            return steered, message.get("uuid")
    raise TimeoutError(f"Playhouse did not steer {description}.")


def respond(user_text, instructions, preserve_no_outcome=False):
    global background_result_sent
    commands = []
    if user_text.startswith("Classify the latest user message for Playhouse's continuous chat page index."):
        hold = Path(str(sys.argv[0]) + ".hold-classifier")
        if hold.exists():
            hold.unlink(missing_ok=True)
            active = Path(str(sys.argv[0]) + ".classifier-active")
            release = Path(str(sys.argv[0]) + ".classifier-release")
            active.write_text("The fallback classifier is held in the background.\n", encoding="utf-8")
            deadline = time.monotonic() + 30
            while not release.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            released = release.exists()
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            if not released:
                return commands
        if Path(str(sys.argv[0]) + ".fail-classifier").exists():
            text("msg_page_classification", '{"continues":"sometimes","title":null}')
            return commands
        history_path = Path(str(sys.argv[0]) + ".history")
        history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {"turns": []}
        classifier_attempts = sum(
            1 for turn in history.get("turns", [])
            if (turn.get("userText") or "").startswith("Classify the latest user message for Playhouse's continuous chat page index.")
        )
        if classifier_attempts == 0:
            text("msg_page_classification", '{"continues":false,"title":"Ignored extra field","unexpected":true}')
            return commands
        if "One more thought about Saturn" in user_text:
            text("msg_page_classification", '{"continues":true,"title":null}')
        elif "Neptune" in user_text:
            text("msg_page_classification", '{"continues":false,"title":"Neptune"}')
        elif "Another thought about Mars" in user_text:
            text("msg_page_classification", '{"continues":true,"title":null}')
        elif "Mars" in user_text:
            text("msg_page_classification", '{"continues":false,"title":"Mars"}')
        elif "Saturn's rings" in user_text:
            text("msg_page_classification", '{"continues":false,"title":"Saturn Rings"}')
        else:
            text("msg_page_classification", '{"continues":false,"title":"Volcanoes"}')
    elif PENDING_QUESTION_SUCCESS_MARKER in user_text.lower():
        question_input = {
            "questions": [{
                "header": "Color",
                "question": "Which color should I use?",
                "options": [{"label": "Blue"}, {"label": "Green"}],
                "multiSelect": False,
            }]
        }
        assistant("msg_pending_question_success", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "playhouse internal outcome nudge:" in user_text.lower() and "outcome-reminder-question" in Path(sys.argv[0]).name:
        question_input = {
            "questions": [{
                "header": "Color",
                "question": "Which color should I use?",
                "options": [{"label": "Blue"}, {"label": "Green"}],
                "multiSelect": False,
            }]
        }
        assistant("msg_private_reminder_question", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "playhouse internal outcome nudge:" in user_text.lower() and not preserve_no_outcome:
        command = report_command(instructions, " task outcome ", "waiting-response")
        if command:
            commands.append({"command": command, "output": run_tool("toolu_outcome_reminder", "Bash", {"command": command}, command)})
    elif "answer to the pending question from the prior playhouse session" in user_text.lower():
        answer = user_text.split("Answer: ", 1)[-1].splitlines()[0].strip()
        text("msg_recovered_question_answer", f"Recovered answer: {answer}.")
    elif "ask a restart-safe structured question" in user_text.lower():
        question_input = {
            "questions": [{
                "header": "Color",
                "question": "Which color should I use?",
                "options": [{"label": "Blue"}, {"label": "Green"}],
                "multiSelect": False,
            }]
        }
        assistant("msg_ask_restart_safe", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
        time.sleep(0.1)
        write({"type": "result", "subtype": "error", "is_error": True, "result": "Fixture process ended with a pending question."})
    elif "ask an empty structured question" in user_text.lower():
        question_input = {"questions": []}
        assistant("msg_ask_user", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "ask a structured question" in user_text.lower():
        question_input = {
            "questions": [{
                "header": "Color",
                "question": "Which color should I use?",
                "options": [
                    {"label": "Blue", "description": "Use blue."},
                    {"label": "Green", "description": "Use green."},
                ],
                "multiSelect": False,
            }]
        }
        assistant("msg_ask_user", [{"type": "tool_use", "id": "toolu_question", "name": "AskUserQuestion", "input": question_input}])
        write({"type": "control_request", "request_id": "question-request-1", "request": {
            "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": question_input,
        }})
    elif "hold until stopped" in user_text.lower() or "hold-until-stopped" in user_text.lower():
        ready = Path(str(sys.argv[0]) + ".interrupt-ready")
        ready.write_text("The Claude fixture turn is active and waiting for an interrupt.\n", encoding="utf-8")
        deadline = time.monotonic() + 30
        received_interrupt = False
        while time.monotonic() < deadline:
            readable, _, _ = select.select([sys.stdin], [], [], 0.02)
            if not readable:
                continue
            control = json.loads(sys.stdin.readline())
            if control.get("type") != "control_request" or control.get("request", {}).get("subtype") != "interrupt":
                continue
            received_interrupt = True
            Path(str(sys.argv[0]) + ".interrupt-received").write_text("control interrupt\n", encoding="utf-8")
            interrupt_release = Path(str(sys.argv[0]) + ".interrupt-release")
            if Path(sys.argv[0]).name.endswith("-hold-reject-interrupt"):
                reject = Path(str(sys.argv[0]) + ".interrupt-reject")
                reject_deadline = time.monotonic() + 15
                while not reject.exists() and time.monotonic() < reject_deadline:
                    time.sleep(0.02)
                reject.unlink(missing_ok=True)
                write({"type": "control_response", "response": {
                    "subtype": "error", "request_id": control.get("request_id"),
                    "error": "Fixture rejected the interrupt while the turn remains active.",
                }})
                ack_deadline = time.monotonic() + 15
                while not interrupt_release.exists() and time.monotonic() < ack_deadline:
                    time.sleep(0.02)
                interrupt_release.unlink(missing_ok=True)
                text("msg_after_rejected_interrupt", "The turn completed after Stop was rejected.")
                write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
                break
            ack_deadline = time.monotonic() + 15
            while not interrupt_release.exists() and time.monotonic() < ack_deadline:
                time.sleep(0.02)
            interrupt_release.unlink(missing_ok=True)
            write({"type": "control_response", "response": {
                "subtype": "success", "request_id": control.get("request_id"), "response": {},
            }})
            write({"type": "result", "subtype": "error_during_execution", "is_error": True,
                   "result": "Claude interrupted this turn."})
            break
        ready.unlink(missing_ok=True)
        if not received_interrupt:
            raise TimeoutError("Timed out waiting for Claude interrupt.")
        commands.append({"interruptReceived": True})
    elif "hold-claude-turn-for-concurrency" in user_text.lower():
        ready = Path(str(sys.argv[0]) + ".concurrent-turn-ready")
        release = Path(str(sys.argv[0]) + ".concurrent-turn-release")
        ready.write_text("Claude turn is active.\n", encoding="utf-8")
        deadline = time.monotonic() + 60
        while not release.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not release.exists():
            raise TimeoutError("Timed out waiting for the concurrent Claude turn test.")
        if "fail-after-hold" in user_text.lower():
            raise RuntimeError("Claude fixture failed after releasing the held turn.")
        text("msg_concurrent", SIMPLE_ANSWER)
    elif "publish-image-during-active-turn" in user_text.lower():
        ready = Path(str(sys.argv[0]) + ".image-turn-ready")
        release = Path(str(sys.argv[0]) + ".image-turn-release")
        ready.write_text("Claude turn is active.\n", encoding="utf-8")
        deadline = time.monotonic() + 60
        while not release.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        if not release.exists():
            raise TimeoutError("Timed out waiting for the agent image publication test.")
        text("msg_image_order", "Claude answer after the image.")
    elif "follow-active-turn" in user_text.lower():
        # Holds before any output, so a test can reopen the conversation first,
        # then again while commentary and a running tool are visible.
        for stage, description in [("started", "Claude turn started without output."),
                                   ("ready", "Claude turn shows progress and a running tool.")]:
            if stage == "ready":
                text("msg_follow_progress", "Claude is partway through the followed turn.")
                assistant("msg_toolu_follow_active_step", [{"type": "tool_use", "id": "toolu_follow_active_step", "name": "Bash", "input": {
                    "command": "fixture-follow-step", "description": "Fixture follow step",
                }}])
            marker = Path(str(sys.argv[0]) + f".follow-turn-{stage}")
            release = Path(str(sys.argv[0]) + (".follow-turn-continue" if stage == "started" else ".follow-turn-release"))
            marker.write_text(f"{description}\n", encoding="utf-8")
            deadline = time.monotonic() + 60
            while not release.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            marker.unlink(missing_ok=True)
            if not release.exists():
                raise TimeoutError(f"The test did not release the fixture after: {description}")
            release.unlink(missing_ok=True)
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_follow_active_step", "content": "", "is_error": False},
        ]}})
        text("msg_follow_final", "Claude finished the followed turn.")
    elif user_text.startswith("Write a concise task title"):
        if "title-failure" not in sys.argv[0]:
            text("msg_title", "Generated Claude title")
    elif "<response-comments>" in user_text:
        payload = user_text.split("<response-comments>", 1)[1].split("</response-comments>", 1)[0]
        comments = json.loads(payload)
        answer = "\n".join(
            f':playhouse-annotation{{index="{index}"}} For ‘{item["text"]}’: {item["comment"]}'
            for index, item in enumerate(comments)
        )
        text("msg_comments", answer)
    elif user_text.rstrip().endswith("What happened earlier?"):
        text("msg_recovered", SIMPLE_ANSWER)
    elif "story" in user_text.lower():
        text("msg_story", STORY)
        progress_clear = report_command(instructions, " task progress clear ")
        outcome = report_command(instructions, " task outcome ", "completed")
        for tool_id, command in [("toolu_progress_clear", progress_clear), ("toolu_outcome", outcome)]:
            if command:
                commands.append({"command": command, "output": run_tool(tool_id, "Bash", {"command": command}, command)})
        text("msg_story_closing", STORY_CLOSING)
    elif "inspect" in user_text.lower():
        text("msg_inspect_intent", INSPECTION_INTENT)
        run_tool("toolu_read", "Read", {"file_path": os.path.join(os.getcwd(), "README.md")})
        text("msg_inspect_answer", INSPECTION_ANSWER)
    elif "checks" in user_text.lower():
        # Every text precedes an ordinary tool, so the turn records only commentary.
        text("msg_checks_first", UNANSWERED_FIRST)
        run_tool("toolu_checks_first", "Read", {"file_path": os.path.join(os.getcwd(), "README.md")})
        text("msg_checks_last", UNANSWERED_LAST)
        run_tool("toolu_checks_last", "Read", {"file_path": os.path.join(os.getcwd(), "README.md")})
    elif "background agents wake" in user_text.lower():
        # Mirrors the real CLI waking the parent for a background agent's
        # notification after the parent already sent its result. The last
        # agent finishes while the woken parent is still streaming, and only
        # the parent's next result ends the turn.
        agents = [("toolu_wake_agent_a", "bgtask-wake-a", "Wake reviewer A"),
                  ("toolu_wake_agent_b", "bgtask-wake-b", "Wake reviewer B")]
        assistant("msg_wake_agents", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "Explore", "description": description, "prompt": "review something",
            "run_in_background": True,
        }} for tool_id, _, description in agents])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False}
            for tool_id, _, _ in agents
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "Explore", "description": description}
            for _, task_id, description in agents
        ]})
        for tool_id, task_id, description in agents:
            write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
                   "tool_use_id": tool_id, "description": description, "subagent_type": "Explore",
                   "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        text("msg_wake_started", "WAKE STARTED")
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        background_result_sent = True
        (first_tool, first_task, _), (second_tool, second_task, second_description) = agents
        write({"type": "system", "subtype": "task_notification", "task_id": first_task, "run_id": "fixture-run-1",
               "tool_use_id": first_tool, "status": "completed", "output_file": "", "summary": "Reviewer A finished."})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": second_task, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "Explore", "description": second_description},
        ]})
        # The woken parent has only begun streaming when the last agent
        # finishes; no complete assistant message has arrived yet.
        parent_request_started("msg_wake_resumed", woken=True)
        write({"type": "system", "subtype": "task_notification", "task_id": second_task, "run_id": "fixture-run-1",
               "tool_use_id": second_tool, "status": "completed", "output_file": "", "summary": "Reviewer B finished."})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        wake_pause = Path(str(sys.argv[0]) + ".background-wake-pause")
        if wake_pause.exists():
            wake_ready = Path(str(sys.argv[0]) + ".background-wake-ready")
            wake_release = Path(str(sys.argv[0]) + ".background-wake-release")
            wake_ready.write_text("Last notification sent mid-work.\n", encoding="utf-8")
            wake_deadline = time.monotonic() + 30
            while not wake_release.exists() and time.monotonic() < wake_deadline:
                time.sleep(0.02)
            if not wake_release.exists():
                raise TimeoutError("The test did not release the woken parent's final answer.")
        text("msg_wake_resumed", "WAKE RESUMED")
        run_tool("toolu_wake_read", "Read", {"file_path": os.path.join(os.getcwd(), "README.md")})
        # The woken turn's next request carries Reviewer B's queued notification.
        parent_request_started("msg_wake_final")
        text("msg_wake_final", "WAKE FINAL")
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "background agent" in user_text.lower():
        # Mirrors the real `claude` CLI's --forward-subagent-text protocol for a
        # backgrounded Agent/Task call: the launch confirmation tool_result is not
        # completion, and the real outcome arrives later as system task events.
        tool_id = "toolu_background_agent"
        task_id = "bgtask-fixture-1"
        did_fail = "background agent failure" in user_text.lower()
        terminal_status = "failed" if did_fail else "completed"
        result_summary = "Background check failed." if did_fail else "Background check finished."
        assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "Explore", "description": "Background check", "prompt": "check something",
            "run_in_background": True,
        }}])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "Explore", "description": "Background check"},
        ]})
        write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Background check", "subagent_type": "Explore",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        write({"type": "system", "subtype": "task_progress", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Running Bash", "subagent_type": "Explore",
               "last_tool_name": "Bash"})
        text("msg_background_started", "STARTED")
        if not did_fail:
            # Model the provider finishing its parent response before it sends
            # the background agent's terminal notification. The bridge must
            # keep the send open while that result is still outstanding.
            write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            background_result_sent = True
        write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": terminal_status, "end_time": 0}})
        if not did_fail:
            # This empty snapshot can clear the client's outstanding task set
            # before task_notification carries the actual result.
            write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        summary_pause = Path(str(sys.argv[0]) + ".background-summary-pause")
        if summary_pause.exists() and not did_fail:
            summary_ready = Path(str(sys.argv[0]) + ".background-summary-ready")
            summary_release = Path(str(sys.argv[0]) + ".background-summary-release")
            summary_ready.write_text("Status-only completion sent.\n", encoding="utf-8")
            summary_deadline = time.monotonic() + 30
            while not summary_release.exists() and time.monotonic() < summary_deadline:
                time.sleep(0.02)
            if not summary_release.exists():
                raise TimeoutError("The test did not release the background-agent summary event.")
        write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": terminal_status, "output_file": "", "summary": result_summary})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        if did_fail:
            # The running turn's next request carries the notification; no wake follows.
            parent_request_started("msg_background_failure_seen")
            text("msg_background_failure_seen", "The background check failed.")
        else:
            parent_request_started("msg_background_woken", woken=True)
            text("msg_background_woken", "BACKGROUND HANDLED")
            write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "parked background shell" in user_text.lower():
        # Mirrors a turn Claude Code has already answered while a background
        # shell keeps running: the parent result is out, no notification has
        # arrived yet, and the turn is still the active one. Input steered into
        # that window must reach the process and be answered inside the same
        # turn, before the shell's notification and the woken parent turn.
        tool_id = "toolu_parked_shell"
        task_id = "bgshell-parked-1"
        assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo PARKED", "description": "Parked shell", "run_in_background": True,
        }}])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Parked shell"},
        ]})
        write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Parked shell", "task_type": "local_bash"})
        text("msg_parked_started", "PARKED STARTED")
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        background_result_sent = True
        # The submitted command is finished too, so only the running shell holds
        # the turn open: exactly the window the real CLI parks a turn in.
        complete_command(current_command_uuid)
        Path(str(sys.argv[0]) + ".parked-shell-ready").write_text(
            "The parent result is out while the shell runs.\n", encoding="utf-8"
        )
        steered, steered_uuid = read_steered_input("the parked background shell turn")
        text("msg_parked_steered", f"STEERED: {steered}")
        write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Parked shell" completed (exit code 0)'})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        parent_request_started("msg_parked_final", woken=True)
        text("msg_parked_final", "PARKED HANDLED")
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        complete_command(steered_uuid)
    elif "background shell" in user_text.lower():
        # Mirrors the real `claude` CLI for a Bash call with run_in_background:
        # the tool_result only confirms the launch, the shell reports through
        # the same system task events as an agent, and Claude Code then starts
        # a woken parent turn to deliver its notification. When the shell
        # finishes early, that woken turn starts before the first result.
        tool_id = "toolu_background_shell"
        task_id = "bgshell-fixture-1"
        finishes_early = "finishes early" in user_text.lower()
        assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo SHELL DONE", "description": "Fixture shell", "run_in_background": True,
        }}])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Fixture shell"},
        ]})
        write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Fixture shell", "task_type": "local_bash"})
        text("msg_shell_started", "SHELL STARTED")
        if not finishes_early:
            write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            wait_for_release("background-shell-running", "Parent result sent while the shell runs.")
        write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Fixture shell" completed (exit code 0)'})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        wait_for_release("background-shell-wake", "The shell finished before the parent woke.")
        parent_request_started("msg_shell_woken", woken=True)
        text("msg_shell_woken", "SHELL HANDLED")
        outcome = report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome, "output": run_tool("toolu_shell_outcome", "Bash", {"command": outcome}, outcome)})
        if finishes_early:
            # The first turn's result arrives only after the woken turn began.
            write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            wait_for_release("background-shell-second-result", "The first result arrived; the woken turn's is pending.")
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        background_result_sent = True
    else:
        text("msg_simple", SIMPLE_ANSWER)
    return commands


def main():
    global background_result_sent, current_command_uuid
    history_path = Path(str(sys.argv[0]) + ".history")
    instructions = argument("--append-system-prompt") or ""
    turn = {
        "arguments": sys.argv[1:],
        "sessionID": argument("--session-id") or argument("--resume"),
        "resumed": "--resume" in sys.argv,
        "cwd": os.getcwd(),
        "bridgeServiceName": os.environ.get("PLAYHOUSE_BRIDGE_SERVICE_NAME"),
        "effort": os.environ.get("CLAUDE_CODE_EFFORT_LEVEL"),
    }
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("type") == "control_request":
            request = message.get("request", {})
            if request.get("subtype") == "initialize":
                missing_resume = Path(str(sys.argv[0]) + ".missing-resume")
                if "--resume" in sys.argv and missing_resume.exists():
                    missing_resume.unlink()
                    write({"type": "result", "subtype": "error", "is_error": True,
                           "result": "No conversation found with session ID"})
                    return 1
                models = [
                    {"value": "default", "displayName": "Default"},
                    {"value": "opus", "displayName": "Opus"},
                    {"value": "claude-opus-4-8", "displayName": "Opus 4.8"},
                    {"value": "claude-opus-5-5", "displayName": "Opus 5.5"},
                    {"value": "claude-opus-5-5-20251001", "displayName": "Opus 5.5 (2025-10-01)"},
                    {"value": "sonnet", "displayName": "Sonnet"},
                    {"value": "claude-sonnet-4-6", "displayName": "Sonnet 4.6"},
                    {"value": "claude-sonnet-5-5", "displayName": "Sonnet 5.5"},
                    {"value": "haiku", "displayName": "Haiku"},
                    {"value": "claude-haiku-4-5-20251001", "displayName": "Haiku 4.5"},
                    {"value": "claude-haiku-4-6", "displayName": "Haiku 4.6"},
                ]
                if os.environ.get("PLAYHOUSE_CLAUDE_MODEL_LIST") == "aliases-only" or "aliases-only" in Path(sys.argv[0]).name:
                    models = models[:2] + models[5:6] + models[8:9]
                # Tests seed Playhouse's model cache through a real discovery of this list.
                models_override = Path(str(sys.argv[0]) + ".models-override")
                if models_override.exists():
                    models = json.loads(models_override.read_text(encoding="utf-8"))
                # Lets a test observe the cached list before discovery replaces it.
                if Path(str(sys.argv[0]) + ".models-delay").exists():
                    time.sleep(8)
                response = {"claude_code_version": "2.1.308 (Claude Code fixture)",
                            "models": models,
                            "commands": [], "agents": []}
            elif request.get("subtype") == "mcp_status":
                response = {"mcpServers": []}
            else:
                response = {}
            write({"type": "control_response", "response": {
                "subtype": "success", "request_id": message.get("request_id"), "response": response,
            }})
        elif message.get("type") == "control_response" and (message.get("response") or {}).get("request_id") == "question-request-1":
            response = message.get("response", {}).get("response", {})
            updated_input = response.get("updatedInput", {})
            answers = updated_input.get("answers", {})
            if response.get("behavior") != "allow" or not isinstance(answers, dict) or not answers:
                if "playhouse internal outcome nudge:" in turn.get("userText", "").lower():
                    rejection_log = Path(str(sys.argv[0]) + ".private-reminder-question-rejection")
                    with rejection_log.open("a", encoding="utf-8") as stream:
                        stream.write(response.get("message", "") + "\n")
                write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_question", "content": response.get("message", "Question was rejected."), "is_error": True},
                ]}})
                write({"type": "result", "subtype": "error", "is_error": True, "result": response.get("message", "Question was rejected.")})
                continue
            if set(answers) != {"Which color should I use?"} or not isinstance(answers["Which color should I use?"], str) or not answers["Which color should I use?"].strip():
                raise ValueError(f"Malformed Claude question answer: {answers!r}")
            answer = answers.get("Which color should I use?", "")
            write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_question", "content": json.dumps(answers), "is_error": False},
            ]}})
            text("msg_question_answer", f"Answer received: {answer}.")
            write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.exists() else {"turns": []}
            if history.get("turns"):
                history["turns"][-1]["questionAnswers"] = answers
            history_path.write_text(json.dumps(history), encoding="utf-8")
        elif message.get("type") == "user":
            background_result_sent = False
            current_command_uuid = message.get("uuid")
            content = message.get("message", {}).get("content", [])
            user_text = "".join(block.get("text", "") for block in content if block.get("type") == "text")
            turn["userText"] = user_text
            recovery_error = Path(str(sys.argv[0]) + ".recovery-error")
            if "answer to the pending question from the prior playhouse session" in user_text.lower() and recovery_error.exists():
                recovery_error.unlink(missing_ok=True)
                turn["failure"] = "Fixture provider echoed Answer: Green and the private recovery prompt."
                history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.exists() else {"turns": []}
                history["turns"].append(turn)
                history_path.write_text(json.dumps(history), encoding="utf-8")
                write({"type": "result", "subtype": "error", "is_error": True,
                       "result": "Fixture provider echoed Answer: Green and the private recovery prompt."})
                continue
            prior_turns = json.loads(history_path.read_text(encoding="utf-8")).get("turns", []) if history_path.exists() else []
            previous_prompt = next((
                prior.get("userText", "").lower()
                for prior in reversed(prior_turns)
                if "playhouse internal outcome nudge:" not in prior.get("userText", "").lower()
            ), "")
            preserve_no_outcome = any(marker in previous_prompt for marker in ("please inspect the workspace", "start the checks"))
            turn["reportCommands"] = respond(user_text, instructions, preserve_no_outcome=preserve_no_outcome)
            history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.exists() else {"turns": []}
            history["turns"].append(turn)
            history_path.write_text(json.dumps(history), encoding="utf-8")
            if PENDING_QUESTION_SUCCESS_MARKER in user_text.lower():
                # Exercise a completed provider turn whose question remains unanswered.
                # Let Playhouse persist and emit the request before reporting success.
                time.sleep(0.1)
                write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
            elif "structured question" in user_text.lower() or (
                "playhouse internal outcome nudge:" in user_text.lower()
                and "outcome-reminder-question" in Path(str(sys.argv[0])).name
            ):
                # Keep the provider turn alive until Playhouse answers or rejects
                # the control request; otherwise a pending question races with
                # an already successful result.
                continue
            if not background_result_sent:
                write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    return 0


if __name__ == "__main__":
    sys.exit(main())

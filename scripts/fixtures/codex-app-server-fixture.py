#!/usr/bin/env python3

"""Deterministic app-server peer for StationAI's protocol integration tests."""

import json
import os
import re
import select
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path

# Record the bridge environment StationAI handed this provider process, so tests
# can run in-turn `stationai` calls with exactly what a real provider inherits.
Path(str(sys.argv[0]) + ".bridge-environment").write_text(
    json.dumps({
        name: os.environ.get(name)
        for name in ("STATIONAI_BRIDGE_SERVICE_NAME", "STATIONAI_DATA_DIRECTORY")
    }),
    encoding="utf-8",
)

if "-title-" in Path(sys.argv[0]).name:
    THREAD_ID = f"stationai-fixture-{os.getpid()}"
    TURN_ID = f"turn-stationai-fixture-{os.getpid()}"
else:
    THREAD_ID = "00000000-0000-0000-0000-000000000001"
    TURN_ID = "turn_stationai_fixture"

# The turn id a freshly started provider process uses for ordinary turns, and the
# private reminder turns that replaced it. A long-lived process must not let a
# later ordinary turn inherit an earlier reminder's id.
DEFAULT_TURN_ID = TURN_ID
REMINDER_TURN_IDS = set()


MARKDOWN_PLAN = '## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening\n\n1. First numbered step: capture the baseline state before changes.\n\n2. Second numbered step: apply the fix and confirm there are no regressions.\n\n```javascript\nconsole.log("Hello, world!");\n```'

ECHOED_OUTCOME_PREFIX = "Echo the outcome command for "
ECHOED_OUTCOME_ANSWER = "Fixture answer with an echoed outcome."


def echoed_outcome_answer(user_message):
    """Reproduces a model writing its final outcome command as answer text."""
    if not user_message or not user_message.startswith(ECHOED_OUTCOME_PREFIX):
        return None
    task_id = user_message[len(ECHOED_OUTCOME_PREFIX):].strip().rstrip(".")
    return f"{ECHOED_OUTCOME_ANSWER}\U0001F6E0\uFE0F\nstationai-cli task outcome {task_id} completed"


def own_user_text(message):
    """The user's own words, without StationAI's hidden context envelope.

    Standalone chat seeds a page's first turn with that page's transcript, so a sentinel
    repeated by an earlier assistant answer must not re-trigger a scenario branch here.
    """
    text = message or ""
    close = "</stationai-handoff-context>"
    if text.startswith("<stationai-handoff-context>") and close in text:
        return text.split(close, 1)[1].strip()
    return text


def write(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def answer_text(user_message):
    mode = os.path.basename(sys.argv[0])
    if isinstance(user_message, str) and user_message.startswith(
        "Classify the latest user message for StationAI's continuous chat page index."
    ):
        hold = Path(str(sys.argv[0]) + ".hold-classifier")
        neptune_hold = Path(str(sys.argv[0]) + ".hold-neptune-classifier")
        should_hold = hold.exists() or (
            neptune_hold.exists()
            and "Latest user message:\nTell me about Neptune" in user_message
        )
        if should_hold:
            hold.unlink(missing_ok=True)
            neptune_hold.unlink(missing_ok=True)
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
                return '{"continues":true,"title":null}'
        history_path = Path(str(sys.argv[0]) + ".history")
        history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
        if Path(str(sys.argv[0]) + ".fail-classifier").exists():
            return '{"continues":"sometimes","title":null}'
        classifier_attempts = sum(
            1 for turn in history.get("turns", [])
            if (turn.get("userMessage") or "").startswith("Classify the latest user message for StationAI's continuous chat page index.")
        )
        if classifier_attempts == 1:
            return '{"continues":false,"title":"Ignored extra field","unexpected":true}'
        if "Neptune" in user_message:
            return '{"continues":false,"title":"Neptune"}'
        if "Another thought about Mars" in user_message:
            return '{"continues":true,"title":null}'
        if "Latest user message:\nOne more thought about Saturn" in user_message:
            return '{"continues":true,"title":null}'
        if "Mars" in user_message:
            return '{"continues":false,"title":"Mars"}'
        if "Saturn's rings" in user_message:
            return '{"continues":false,"title":"Saturn Rings"}'
        return '{"continues":true,"title":null}'
    if "stationai internal outcome nudge:" in (user_message or "").lower():
        return "Fixture internal reminder reply."
    if user_message == "Follow up after private recovery.":
        return "Follow-up after private recovery complete."
    if mode.endswith("-nonblocking-slow"):
        return "Answers received: Custom approach / fixture-secret."
    if mode.endswith("-nonblocking-restart-question") and (user_message or "").startswith("Continue this conversation by applying"):
        return "Answers received: Custom approach / fixture-secret."
    if is_restart_question_mode(mode) and mode.endswith("-no-secret") and (user_message or "").startswith("Continue this conversation by applying"):
        answer_values = re.findall(r"(?m)^\s*Answer:\s*(.*?)\s*$", user_message)
        secret_answer = any(value.strip() == "fixture-secret" for value in answer_values)
        return (
            "Recovered answer: Green; private token fixture-secret was applied."
            if secret_answer
            else "Recovered answer: Blue; no secret was required."
        )
    if is_restart_question_mode(mode) and not (user_message or "").startswith(
        "Continue this conversation by applying"
    ):
        return "I am waiting for the pending question to be answered."
    if is_restart_question_mode(mode):
        return "Recovered answer: Green; private token fixture-secret was applied."
    if Path(sys.argv[0]).name.endswith("-user-question"):
        return "Answer received: Continue."
    if isinstance(user_message, str) and user_message.startswith("Long response fixture input."):
        return "A long fixture response gives the conversation enough content to test comment hint truncation. " * 8
    if isinstance(user_message, str) and ("<response-comments>" in user_message or "<response-annotations>" in user_message):
        try:
            tag = "response-comments" if "<response-comments>" in user_message else "response-annotations"
            payload = user_message.split(f"<{tag}>", 1)[1].split(f"</{tag}>", 1)[0]
            annotations = json.loads(payload)
            if isinstance(annotations, list) and annotations:
                return "\n".join(
                    (f":stationai-annotation{{index=\"{index}\"}} For ‘{item['text']}’: "
                     f"{item.get('comment', item.get('annotation', ''))}"
                     if tag == "response-comments" else
                     f"For ‘{item['text']}’: {item.get('comment', item.get('annotation', ''))} "
                     f":codex-annotation{{index=\"{index}\"}}")
                    for index, item in enumerate(annotations)
                )
        except (KeyError, TypeError, ValueError):
            pass
    return "Answers received: Blue / fixture-secret."


def is_restart_question_mode(mode):
    return mode.endswith("-restart-question") or mode.endswith("-restart-question-no-secret")


question_contexts = {}
question_rounds = {}
question_sequence = 900
first_question_thread = None


def question_request(request_id, followup=False):
    global question_sequence, first_question_thread
    mode = os.path.basename(sys.argv[0])
    if mode.endswith("-restart-question-no-secret") and Path(str(sys.argv[0]) + ".secret-stage").exists():
        questions = [
            {
                "id": "color", "header": "Color", "question": "Which color should I use?",
                "options": [{"label": "Blue", "description": "Use blue."}, {"label": "Green", "description": "Use green."}],
                "isOther": False, "isSecret": False,
            },
            {"id": "token", "header": "Private token", "question": "What is the private token?", "options": None,
             "isOther": False, "isSecret": True},
        ]
    elif mode.endswith("-restart-question-no-secret"):
        questions = [{
            "id": "color", "header": "Color", "question": "Which color should I use?",
            "options": [{"label": "Blue", "description": "Use blue."}, {"label": "Green", "description": "Use green."}],
            "isOther": False, "isSecret": False,
        }]
    elif mode.endswith("-restart-question") and Path(str(sys.argv[0]) + ".asked").exists():
        questions = [{
            "id": "token", "header": "Private token", "question": "What is the private token?",
            "options": None, "isOther": False, "isSecret": True,
        }]
    elif mode.endswith("-user-question"):
        questions = [{
            "id": "question_action",
            "header": "Next step",
            "question": "Which approach should I take?",
            "options": [
                {"label": "Continue", "description": "Proceed with the current task."},
                {"label": "Pause", "description": "Wait for more information."},
            ],
            "isOther": False,
            "isSecret": False,
        }]
    else:
        questions = [] if mode.endswith("-empty") else [
        {
            "id": "color",
            "header": "Color",
            "question": "Which color should I use?",
            "options": [
                {"label": "Blue", "description": "Use blue."},
                {"label": "Green", "description": "Use green."},
            ],
            "isOther": True,
            "isSecret": False,
        },
        {
            "id": "token",
            "header": "Token",
            "question": "What is the private token?",
            "options": None,
            "isOther": False,
            "isSecret": True,
        },
        ]
    if "-question-isolation-" in mode:
        question_sequence += 1
        request_id = question_sequence
        question_contexts[request_id] = (THREAD_ID, TURN_ID)
        question_rounds[THREAD_ID] = question_rounds.get(THREAD_ID, 0) + 1
        if first_question_thread is None:
            first_question_thread = THREAD_ID
        if followup:
            questions[0]["question"] = "Which color should I use next?"
    write({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tool/requestUserInput",
        "params": {
            "threadId": THREAD_ID,
            "turnId": TURN_ID,
            "itemId": "item_stationai_question",
            "questions": questions,
            "isBlocking": "-nonblocking" not in mode and "-plan" not in mode,
        },
    })


def subagent_item(status):
    return {
        "id": "item_stationai_subagent",
        "type": "collabAgentToolCall",
        "tool": "spawnAgent",
        "senderThreadId": THREAD_ID,
        "receiverThreadIds": ["00000000-0000-0000-0000-000000000002"],
        "prompt": "Inspect the project structure and report relevant files.",
        "agentsStates": {
            "00000000-0000-0000-0000-000000000002": {
                "status": "running" if status == "inProgress" else "completed",
                "message": "Inspected the project structure." if status == "completed" else None,
            },
        },
        "status": status,
    }


def subagent_activity(kind, child_thread_id, agent_path, *, model=None, reasoning_effort=None):
    item = {
        "id": f"item_activity_{child_thread_id}",
        "type": "subAgentActivity",
        "kind": kind,
        "agentThreadId": child_thread_id,
    }
    if agent_path is not None:
        item["agentPath"] = agent_path
    if model is not None:
        item["model"] = model
    if reasoning_effort is not None:
        item["reasoningEffort"] = reasoning_effort
    return item


CHILD_THREAD_ID = "00000000-0000-0000-0000-000000000002"
CHILD_TURN_ID = "turn_stationai_child_fixture"
CHILD_MESSAGES = [
    {"id": "item_child_user", "type": "userMessage", "content": [{"type": "text", "text": "Inspect StationAI entitlements."}]},
    {"id": "item_child_assistant", "type": "agentMessage", "text": "Sandbox review read StationAIEntitlements.entitlements and found the required profile."},
]


def async_question_item():
    return {
        "id": "item_stationai_async_question",
        "type": "agentMessage",
        "phase": "final_answer",
        "delivery": "async",
        "text": "Test and verify\n- Yes, update paired tests and run required verification\n- No, leave tests and verification for later",
        "questions": [
            {
                "title": "Test and verify",
                "options": [
                    "Yes, update paired tests and run required verification",
                    "No, leave tests and verification for later",
                ],
            },
            {"title": "Additional detail", "options": None},
        ],
    }


def later_async_question_item():
    return {
        "id": "item_stationai_async_later_question",
        "type": "agentMessage", "phase": "final_answer", "delivery": "async",
        "text": "One more check", "questions": [{"title": "One more check", "options": None}],
    }


def diagnostic_action_items(cwd):
    return [
        {
            "id": "item_stationai_command",
            "type": "commandExecution",
            "command": "git status --short",
            "cwd": cwd,
            "aggregatedOutput": "CODEX_OUTPUT_NOT_LOGGED",
            "exitCode": 0,
            "status": "completed",
        },
        {
            "id": "item_stationai_file_change",
            "type": "fileChange",
            "changes": [{"path": "README.md", "kind": "update", "diff": "CODEX_DIFF_NOT_LOGGED"}],
            "status": "completed",
        },
    ]


def main():
    global THREAD_ID, TURN_ID
    _ = None
    ack_deadline = None
    action_item = None
    active = None
    active_command_item = None
    asked = None
    assistant = None
    async_provider_error = None
    child_item = None
    compaction_item = None
    completed = None
    contents = None
    deadline = None
    delta = None
    descriptor = None
    dynamic_item = None
    echoed = None
    entries = None
    error_code = None
    expected_answers = None
    expected_recovery_answers = None
    fail_marker = None
    failed = None
    final_answer_pause = None
    final_answer_ready = None
    final_answer_release = None
    first_child_started = None
    first_turn = None
    first_turn_marker = None
    goal = None
    history = None
    hold_marker = None
    hold_used = None
    image_inputs = None
    image_url = None
    incoming = None
    index = None
    instructions = None
    interrupt_message = None
    interrupt_release = None
    is_outcome_reminder = None
    is_plan_turn = None
    is_title_request = None
    item = None
    item_id = None
    items = None
    key = None
    legacy_dynamic_item = None
    level = None
    mcp_item = None
    message_text = None
    messages = None
    midpoint = None
    no_secret_fixture = None
    no_secret_recovery = None
    observe_history = None
    ordinary_turn_indexes = None
    outcome_command = None
    outcome_line = None
    params = None
    phase = None
    plan_item_id = None
    preserve_no_outcome = None
    private_activity = None
    progress_text = None
    provider_error = None
    queued_request = None
    readable = None
    ready = None
    received_interrupt = None
    reject = None
    reject_deadline = None
    reject_marker = None
    rejected_steer_requests = None
    rejection = None
    rejection_message = None
    release = None
    release_latest = None
    released = None
    requested = None
    requested_thread_id = None
    resume = None
    resume_error = None
    saved_turn = None
    saved_turns = None
    second_child_id = None
    second_child_started = None
    secret_stage = None
    serial_first_turn = None
    steer_request = None
    steer_requests = None
    steered_answer = None
    stream = None
    text = None
    thread_start_instructions = None
    tool_item = None
    turn_error = None
    turn_history = None
    turn_id = None
    turn_index = None
    turn_input = None
    turn_status = None
    turn_thread_id = None
    turns = None
    unassociated_restart_question = None
    user_content = None
    user_images = None
    user_message = None
    value = None
    was_released = None
    mode = os.path.basename(sys.argv[0])
    answers = None
    isolation_turns = {}
    saw_question = False
    saw_turn = False
    turn_message = None
    history_path = Path(str(sys.argv[0]) + ".history")
    fixture_state_directory = Path(os.environ.get("STATIONAI_E2E_FIXTURE_STATE_DIRECTORY", str(Path(sys.argv[0]).parent)))
    if "-goal" in mode:
        (fixture_state_directory / f"{Path(sys.argv[0]).name}.launch-args").write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
    goal_path = fixture_state_directory / f"{Path(sys.argv[0]).name}.goal"
    async_mode = mode.endswith("-async-question") or mode.endswith("-async-question-queued")
    serial_mode = mode.endswith("-serial-success-wait") or mode.endswith("-serial-success") or async_mode
    if serial_mode:
        saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
        THREAD_ID = saved_history.get("threadID")
        TURN_ID = f"turn-{uuid.uuid4()}"

    def serial_history():
        if history_path.is_file():
            return json.loads(history_path.read_text(encoding="utf-8"))
        return {"threadID": None, "events": [], "messages": []}

    def handle_message(message):
        nonlocal _, ack_deadline, action_item, active, active_command_item, answers, asked, assistant
        nonlocal async_provider_error, child_item, compaction_item, completed, contents, deadline, delta
        nonlocal descriptor, dynamic_item, echoed, entries, error_code, expected_answers
        nonlocal expected_recovery_answers, fail_marker, failed, final_answer_pause, final_answer_ready
        nonlocal final_answer_release, first_child_started, first_turn, first_turn_marker, goal, history
        nonlocal hold_marker, hold_used, image_inputs, image_url, incoming, index, instructions
        nonlocal interrupt_message, interrupt_release, is_outcome_reminder, is_plan_turn, is_title_request
        nonlocal item, item_id, items, key, legacy_dynamic_item, level, mcp_item, message_text, messages
        nonlocal midpoint, no_secret_fixture, no_secret_recovery, observe_history, ordinary_turn_indexes
        nonlocal outcome_command, outcome_line, params, phase, plan_item_id, preserve_no_outcome
        nonlocal private_activity, progress_text, provider_error, queued_request, readable, ready
        nonlocal received_interrupt, reject, reject_deadline, reject_marker, rejected_steer_requests
        nonlocal rejection, rejection_message, release, release_latest, released, requested
        nonlocal requested_thread_id, resume, resume_error, saved_history, saved_turn, saved_turns
        nonlocal saw_question, saw_turn, second_child_id, second_child_started, secret_stage
        nonlocal serial_first_turn, steer_request, steer_requests, steered_answer, stream, text
        nonlocal thread_start_instructions, tool_item, turn_error, turn_history, turn_id, turn_index
        nonlocal turn_input, turn_message, turn_status, turn_thread_id, turns, unassociated_restart_question
        nonlocal user_content, user_images, user_message, value, was_released
        global THREAD_ID, TURN_ID
        if "-question-isolation-" in mode and message.get("method") in ("thread/items/list", "thread/turns/list"):
            requested = message.get("params", {}).get("threadId")
            if requested in isolation_turns:
                THREAD_ID = requested
                TURN_ID, answers = isolation_turns[requested]
                saw_turn = True
        # A long-lived app-server never resumes a loaded thread, so the one-shot resume
        # failure also fails the next history read.
        if message.get("method") in ("thread/read", "thread/turns/list", "thread/items/list"):
            history_error = Path(str(sys.argv[0]) + ".resume-error")
            if history_error.is_file():
                history_error.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "id": message["id"], "error": {
                    "code": -32010,
                    "message": "Fixture thread resume failed after receiving fixture-secret.",
                }})
                return
        if message.get("method") == "initialized":
            return
        if "method" in message and "id" not in message:
            return
        if message.get("method") == "initialize":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"serverInfo": {"name": "stationai-fixture", "version": "1"}}})
        elif message.get("method") == "model/list":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"data": [
                {"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True,
                 "supportedReasoningEfforts": [{"reasoningEffort": level} for level in ["low", "medium", "high", "xhigh"]]},
                {"id": "gpt-6-sol", "displayName": "GPT-6 Sol", "isDefault": False,
                 "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]},
                {"id": "gpt-6-mini", "displayName": "GPT-6 Mini", "isDefault": False,
                 "supportedReasoningEfforts": ["low", "medium"]},
                {"id": "gpt-5.6-luna", "displayName": "GPT-5.6 Luna", "isDefault": False,
                 "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]},
            ]}})
        elif message.get("method") == "thread/goal/get":
            goal = json.loads(goal_path.read_text(encoding="utf-8")) if goal_path.is_file() else None
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"goal": goal}})
        elif "-goal" in mode and message.get("method") == "thread/goal/set":
            params = message.get("params", {})
            goal = json.loads(goal_path.read_text(encoding="utf-8")) if goal_path.is_file() else {
                "threadId": params.get("threadId"), "objective": "", "status": "active",
                "tokenBudget": None, "tokensUsed": None, "timeUsedSeconds": 0,
            }
            goal.update({key: value for key, value in params.items() if key in {"objective", "status"}})
            goal_path.write_text(json.dumps(goal), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"goal": goal}})
        elif "-goal" in mode and message.get("method") == "thread/goal/clear":
            goal_path.unlink(missing_ok=True)
            write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
        elif message.get("method") == "thread/start":
            if "-question-isolation-" in mode:
                THREAD_ID = str(uuid.uuid4())
            thread_start_instructions = message.get("params", {}).get("developerInstructions")
            if serial_mode:
                history = serial_history()
                if history.get("threadID") is not None:
                    write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32001, "message": "This fixture thread already exists; resume it instead of starting another."}})
                    return
                THREAD_ID = str(uuid.uuid4())
                history["threadID"] = THREAD_ID
                history["threadStartDeveloperInstructions"] = thread_start_instructions
                history["events"].append({"method": "thread/start", "threadID": THREAD_ID})
                history_path.write_text(json.dumps(history), encoding="utf-8")
            else:
                history = serial_history()
                history.update({
                    "threadID": THREAD_ID,
                    "threadStartDeveloperInstructions": thread_start_instructions,
                    "threadStartCwd": message.get("params", {}).get("cwd"),
                    "threadStartRuntimeWorkspaceRoots": message.get("params", {}).get("runtimeWorkspaceRoots", []),
                    "threadStartCount": history.get("threadStartCount", 0) + 1,
                })
                history_path.write_text(json.dumps(history), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": message.get("params", {}).get("model", "gpt-6-luna")}})
        elif message.get("method") == "thread/resume":
            if "-question-isolation-" in mode:
                THREAD_ID = message["params"]["threadId"]
            resume_error = Path(str(sys.argv[0]) + ".resume-error")
            if resume_error.is_file():
                resume_error.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "id": message["id"], "error": {
                    "code": -32010,
                    "message": "Fixture thread resume failed after receiving fixture-secret.",
                }})
                return
            if serial_mode:
                requested_thread_id = message.get("params", {}).get("threadId")
                history = serial_history()
                if not history.get("threadID") or requested_thread_id != history["threadID"]:
                    write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32002, "message": "The requested thread does not match the fixture's existing thread."}})
                    return
                THREAD_ID = history["threadID"]
                history["events"].append({"method": "thread/resume", "threadID": THREAD_ID})
                history.setdefault("threadResumeDeveloperInstructions", []).append(
                    message.get("params", {}).get("developerInstructions")
                )
                history_path.write_text(json.dumps(history), encoding="utf-8")
            else:
                history = serial_history()
                history.update({
                    "threadID": THREAD_ID,
                    "threadResumeCount": history.get("threadResumeCount", 0) + 1,
                })
                history.setdefault("threadResumeDeveloperInstructions", []).append(
                    message.get("params", {}).get("developerInstructions")
                )
                history_path.write_text(json.dumps(history), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": message.get("params", {}).get("model", "gpt-6-luna")}})
        elif message.get("method") == "turn/start":
            if "-question-isolation-" in mode:
                THREAD_ID = message["params"]["threadId"]
                TURN_ID = f"turn-{uuid.uuid4()}"
                isolation_turns[THREAD_ID] = (TURN_ID, None)
            saw_turn = True
            saw_question = True
            if is_restart_question_mode(mode):
                TURN_ID = f"turn-{uuid.uuid4()}"
            turn_input = message.get("params", {}).get("input", [])
            turn_message = next((item.get("text") for item in turn_input if item.get("type") == "text"), None)
            is_outcome_reminder = "stationai internal outcome nudge:" in (turn_message or "").lower()
            if is_outcome_reminder:
                TURN_ID = f"turn-{uuid.uuid4()}"
                REMINDER_TURN_IDS.add(TURN_ID)
            elif TURN_ID in REMINDER_TURN_IDS:
                TURN_ID = DEFAULT_TURN_ID
            is_title_request = (turn_message or "").startswith("Write a concise task title of at most 8 words")
            serial_first_turn = False
            if "-unique-turns-" in mode and not is_title_request:
                TURN_ID = f"turn-{uuid.uuid4()}"
            if serial_mode and not is_title_request:
                TURN_ID = f"turn-{uuid.uuid4()}"
                first_turn_marker = Path(str(sys.argv[0]) + ".serial-first-turn")
                try:
                    descriptor = os.open(first_turn_marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                except FileExistsError:
                    Path(str(sys.argv[0]) + ".serial-second-turn-started").touch()
                else:
                    os.close(descriptor)
                    serial_first_turn = True
            turn_thread_id = message.get("params", {}).get("threadId")
            if serial_mode and turn_thread_id != THREAD_ID:
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32003, "message": "The turn must use the active fixture thread."}})
                return
            fail_marker = Path(str(sys.argv[0]) + ".fail-next-turn-start")
            if serial_mode and fail_marker.exists():
                fail_marker.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32099, "message": "Fixture rejected the targeted queued turn."}})
                return
            if is_title_request:
                if mode.endswith("-title-failure"):
                    write({"jsonrpc": "2.0", "id": message["id"], "error": {
                        "code": -32042,
                        "message": f"Fixture rejected task-title generation. {turn_message}",
                    }})
                    return
                write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
                if mode.endswith("-title-success-wait"):
                    ready = Path(str(sys.argv[0]) + ".resolve-ready")
                    resume = Path(str(sys.argv[0]) + ".resolve-continue")
                    ready.write_text("Codex task-title turn is active.\n", encoding="utf-8")
                    deadline = time.monotonic() + 30
                    while not resume.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    if not resume.exists():
                        os._exit(3)
                    ready.unlink(missing_ok=True)
                    resume.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "item": {
                        "id": "item_stationai_title",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "text": "Generated fixture title",
                    },
                }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
                return
            image_inputs = [item for item in turn_input if item.get("type") == "image"]
            turn_history = {
                "userMessage": turn_message,
                "turnID": TURN_ID,
                "images": [item.get("url") for item in image_inputs],
                "imageInputs": image_inputs,
                "conversationMode": message.get("params", {}).get("collaborationMode", {}).get("mode"),
                "reasoningEffort": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("reasoningEffort"),
                "modelID": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("model"),
                "developerInstructions": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("developerInstructions"),
                "cwd": message.get("params", {}).get("cwd"),
                "runtimeWorkspaceRoots": message.get("params", {}).get("runtimeWorkspaceRoots", []),
            }
            if serial_mode:
                saved_history = serial_history()
                messages = saved_history["messages"]
                turn_history["threadID"] = THREAD_ID
                messages.append(turn_history)
                saved_history["messages"] = messages
                if not is_outcome_reminder:
                    saved_history.update(turn_history)
                saved_history["events"].append({"method": "turn/start", "threadID": THREAD_ID, "turnID": TURN_ID, "userMessage": turn_message, "conversationMode": turn_history["conversationMode"]})
                history_path.write_text(json.dumps(saved_history), encoding="utf-8")
            else:
                saved_history = serial_history()
                if not is_outcome_reminder:
                    saved_history.update(turn_history)
                turns = saved_history.get("turns", [])
                turns.append(turn_history)
                saved_history["turns"] = turns
                history_path.write_text(json.dumps(saved_history), encoding="utf-8")
            preserve_no_outcome = any(marker in mode for marker in ("nonblocking-slow", "nonblocking-restart-question", "hold-release", "question-isolation"))
            if is_outcome_reminder and not preserve_no_outcome:
                # A fixture that only ever resumed an existing thread has no
                # thread-start instructions of its own; its outcome command
                # lives in the resume instructions StationAI sent instead.
                saved = serial_history()
                instructions = (
                    turn_history.get("developerInstructions")
                    or saved.get("threadStartDeveloperInstructions")
                    or ((saved.get("threadResumeDeveloperInstructions") or [None])[-1])
                    or ""
                )
                outcome_line = next((line.strip() for line in instructions.splitlines() if " task outcome " in line), None)
                if outcome_line:
                    outcome_command = outcome_line.replace("<completed|in-progress|waiting-response>", "waiting-response")
                    completed = subprocess.run(shlex.split(outcome_command), capture_output=True, text=True, timeout=60)
                    if completed.returncode != 0:
                        raise RuntimeError(f"Fixture task outcome command failed: {completed.stderr.strip()}")
                write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"}}})
                return
            provider_error = Path(str(sys.argv[0]) + ".provider-error")
            if provider_error.exists():
                provider_error.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "id": message["id"], "result": {
                    "turn": {"id": TURN_ID, "status": "failed", "error": {"message": "Fixture provider failed after receiving fixture-secret. Answer: Green. Continue this conversation by applying the user's answer to the pending question."}},
                }})
                return
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
            if (turn_message or "").startswith(
                "Classify the latest user message for StationAI's continuous chat page index."
            ):
                # One-shot Codex helper clients consume the streamed completion
                # directly; provide the same fixture answer the transcript path
                # returns for ordinary conversation turns.
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "turnId": TURN_ID,
                    "item": {
                        "id": "item_stationai_chat_classifier",
                        "type": "agentMessage",
                        "text": answer_text(turn_message),
                    },
                }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
                return
            async_provider_error = Path(str(sys.argv[0]) + ".provider-error-async")
            if async_provider_error.exists():
                async_provider_error.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "failed", "error": {"message": "Fixture async failure echoed fixture-secret, Answer: Green, and the private recovery prompt."}},
                }})
            elif Path(str(sys.argv[0]) + ".hold-release").exists():
                active = Path(str(sys.argv[0]) + ".turn-active")
                release = Path(str(sys.argv[0]) + ".turn-release")
                active.write_text("The fixture turn is active for a CLI outcome report.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    drain_pending_stdin()
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                time.sleep(0.1)
                if not was_released:
                    os._exit(3)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-hold-interrupt") or mode.endswith("-hold-reject-interrupt"):
                active = Path(str(sys.argv[0]) + ".interrupt-ready")
                active.write_text("The fixture turn is active and waiting for an interrupt.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                received_interrupt = False
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([sys.stdin], [], [], 0.02)
                    if not ready:
                        continue
                    interrupt_message = json.loads(sys.stdin.readline())
                    if interrupt_message.get("method") != "turn/interrupt":
                        answer_read_while_held(interrupt_message)
                        continue
                    received_interrupt = True
                    saved_history = serial_history()
                    saved_history["interruptReceived"] = True
                    history_path.write_text(json.dumps(saved_history), encoding="utf-8")
                    Path(str(sys.argv[0]) + ".interrupt-received").write_text("turn/interrupt\n", encoding="utf-8")
                    if mode.endswith("-hold-reject-interrupt"):
                        reject = Path(str(sys.argv[0]) + ".interrupt-reject")
                        reject_deadline = time.monotonic() + 15
                        while not reject.exists() and time.monotonic() < reject_deadline:
                            drain_pending_stdin()
                            time.sleep(0.02)
                        reject.unlink(missing_ok=True)
                        write({"jsonrpc": "2.0", "id": interrupt_message["id"], "error": {
                            "code": -32044, "message": "Fixture rejected the interrupt while the turn remains active.",
                        }})
                        interrupt_release = Path(str(sys.argv[0]) + ".interrupt-release")
                        ack_deadline = time.monotonic() + 15
                        while not interrupt_release.exists() and time.monotonic() < ack_deadline:
                            drain_pending_stdin()
                            time.sleep(0.02)
                        interrupt_release.unlink(missing_ok=True)
                        write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                            "threadId": THREAD_ID,
                            "item": {"id": "item_stationai_message", "type": "agentMessage", "text": "The turn completed after Stop was rejected."},
                        }})
                        write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                            "threadId": THREAD_ID,
                            "turn": {"id": TURN_ID, "status": "completed"},
                        }})
                        break
                    interrupt_release = Path(str(sys.argv[0]) + ".interrupt-release")
                    ack_deadline = time.monotonic() + 15
                    while not interrupt_release.exists() and time.monotonic() < ack_deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    interrupt_release.unlink(missing_ok=True)
                    write({"jsonrpc": "2.0", "id": interrupt_message["id"], "result": {}})
                    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                        "threadId": THREAD_ID,
                        "turn": {"id": TURN_ID, "status": "interrupted", "error": {"message": "Codex interrupted this turn."}},
                    }})
                    break
                active.unlink(missing_ok=True)
                if not received_interrupt:
                    os._exit(3)
            elif mode.endswith("-abort"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "interrupted", "error": {"message": "Fixture interrupted the conflict-resolution turn."}},
                }})
            elif mode.endswith("-success"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-title-success-wait"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-title-failure"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif async_mode:
                first_turn = len(serial_history().get("messages", [])) == 1
                if first_turn:
                    items = [async_question_item(), {
                        "id": "item_stationai_async_followup",
                        "type": "agentMessage", "phase": "final_answer",
                        "text": "I can continue while you decide.",
                    }]
                else:
                    items = [{
                        "id": "item_stationai_async_answer",
                        "type": "agentMessage", "phase": "final_answer",
                        "text": f"Answers received: {turn_message}",
                    }]
                for item in items:
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID, "item": item,
                    }})
                if first_turn and not mode.endswith("-async-question-queued"):
                    ready = Path(str(sys.argv[0]) + ".question-ready")
                    ready.write_text("The async question is waiting during an active turn.\n", encoding="utf-8")
                    deadline = time.monotonic() + 120
                    steered_answer = None
                    while steered_answer is None and time.monotonic() < deadline:
                        readable, _, _ = select.select([sys.stdin], [], [], 0.02)
                        if not readable:
                            continue
                        incoming = json.loads(sys.stdin.readline())
                        if incoming.get("method") == "thread/items/list":
                            entries = []
                            for index, saved_turn in enumerate(serial_history().get("messages", []), start=1):
                                turn_id = saved_turn["turnID"]
                                entries.append({"turnId": turn_id, "item": {
                                    "id": f"item_stationai_async_user_{index}", "type": "userMessage",
                                    "content": [{"type": "text", "text": saved_turn["userMessage"]}],
                                }})
                                if index == 1:
                                    entries.extend([
                                        {"turnId": turn_id, "item": async_question_item()},
                                        {"turnId": turn_id, "item": {
                                            "id": "item_stationai_async_followup", "type": "agentMessage",
                                            "phase": "final_answer", "text": "I can continue while you decide.",
                                        }},
                                    ])
                            write({"jsonrpc": "2.0", "id": incoming["id"], "result": {"data": entries, "nextCursor": None}})
                        elif incoming.get("method") == "turn/steer":
                            params = incoming.get("params", {})
                            if params.get("threadId") != THREAD_ID or params.get("expectedTurnId") != TURN_ID:
                                write({"jsonrpc": "2.0", "id": incoming["id"], "error": {"code": -32000, "message": "No matching active turn."}})
                                continue
                            steered_answer = "\n".join(item.get("text", "") for item in params.get("input", []) if item.get("type") == "text")
                            write({"jsonrpc": "2.0", "id": incoming["id"], "result": {"turnId": TURN_ID}})
                        else:
                            answer_read_while_held(incoming)
                    if steered_answer is None:
                        os._exit(3)
                    ready.unlink(missing_ok=True)
                    saved_history = serial_history()
                    saved_history["messages"][0]["steeredAnswer"] = steered_answer
                    saved_history["steerRequests"] = saved_history.get("steerRequests", []) + [params]
                    history_path.write_text(json.dumps(saved_history), encoding="utf-8")
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID, "item": {
                            "id": "item_stationai_async_answer_steered", "type": "agentMessage", "phase": "final_answer",
                            "text": f"Answers received: {steered_answer}",
                        },
                    }})
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID, "item": later_async_question_item(),
                    }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif serial_mode and serial_first_turn and mode.endswith("-serial-success-wait"):
                ready = Path(str(sys.argv[0]) + ".resolve-ready")
                resume = Path(str(sys.argv[0]) + ".resolve-continue")
                ready.write_text("The first serialized fixture turn is active.\n", encoding="utf-8")
                # The UI case exercises several XPC/UI round trips while the
                # turn remains active. Keep the deterministic fixture held
                # long enough for that interaction sequence in Tart.
                deadline = time.monotonic() + 120
                steer_requests = []
                rejected_steer_requests = []
                while not resume.exists() and time.monotonic() < deadline:
                    readable, _, _ = select.select([sys.stdin], [], [], 0.02)
                    if readable:
                        try:
                            steer_request = json.loads(sys.stdin.readline())
                        except json.JSONDecodeError:
                            continue
                        if steer_request.get("method") == "thread/items/list":
                            observe_history = Path(str(sys.argv[0]) + ".observe-history-while-active")
                            if observe_history.exists():
                                Path(str(sys.argv[0]) + ".history-read-while-active").touch()
                            write({"jsonrpc": "2.0", "id": steer_request.get("id"), "result": {"data": [], "nextCursor": None}})
                        elif steer_request.get("method") == "turn/steer":
                            params = steer_request.get("params", {})
                            reject_marker = Path(str(sys.argv[0]) + ".reject-next-steer")
                            if reject_marker.exists():
                                rejection = reject_marker.read_text(encoding="utf-8").strip()
                                reject_marker.unlink()
                                rejected_steer_requests.append(params)
                                error_code = -32010 if rejection == "The expected turn ID is stale." else -32000
                                write({"jsonrpc": "2.0", "id": steer_request["id"], "error": {"code": error_code, "message": rejection}})
                            elif params.get("threadId") != THREAD_ID or params.get("expectedTurnId") != TURN_ID:
                                rejected_steer_requests.append(params)
                                write({"jsonrpc": "2.0", "id": steer_request["id"], "error": {"code": -32000, "message": f"expected active turn id {params.get('expectedTurnId')} but found {TURN_ID}"}})
                            else:
                                steer_requests.append(params)
                                write({"jsonrpc": "2.0", "id": steer_request["id"], "result": {"turnId": TURN_ID}})
                        elif not answer_read_while_held(steer_request):
                            write({"jsonrpc": "2.0", "id": steer_request.get("id"), "error": {"code": -32601, "message": "Unsupported fixture request."}})
                if not resume.exists():
                    os._exit(3)
                ready.unlink(missing_ok=True)
                resume.unlink(missing_ok=True)
                if steer_requests or rejected_steer_requests:
                    saved_history = serial_history()
                    saved_history["steerRequests"] = saved_history.get("steerRequests", []) + steer_requests
                    saved_history["rejectedSteerRequests"] = saved_history.get("rejectedSteerRequests", []) + rejected_steer_requests
                    history_path.write_text(json.dumps(saved_history), encoding="utf-8")
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif serial_mode and Path(str(sys.argv[0]) + ".hold-next-queued-turn").exists():
                hold_marker = Path(str(sys.argv[0]) + ".hold-next-queued-turn")
                hold_marker.unlink(missing_ok=True)
                ready = Path(str(sys.argv[0]) + ".queued-turn-ready")
                release = Path(str(sys.argv[0]) + ".queued-turn-release")
                ready.write_text("A targeted queued turn is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                steer_requests = []
                rejected_steer_requests = []
                while not release.exists() and time.monotonic() < deadline:
                    readable, _, _ = select.select([sys.stdin], [], [], 0.02)
                    if not readable:
                        continue
                    try:
                        queued_request = json.loads(sys.stdin.readline())
                    except json.JSONDecodeError:
                        continue
                    if queued_request.get("method") == "thread/items/list":
                        write({"jsonrpc": "2.0", "id": queued_request.get("id"), "result": {"data": [], "nextCursor": None}})
                    elif queued_request.get("method") == "turn/steer":
                        rejection = Path(str(sys.argv[0]) + ".reject-next-steer")
                        if rejection.exists():
                            message_text = rejection.read_text(encoding="utf-8").strip()
                            rejection.unlink(missing_ok=True)
                            rejected_steer_requests.append(queued_request.get("params", {}))
                            error_code = -32010 if message_text == "The expected turn ID is stale." else -32000
                            write({"jsonrpc": "2.0", "id": queued_request["id"], "error": {"code": error_code, "message": message_text}})
                        else:
                            params = queued_request.get("params", {})
                            steer_requests.append(params)
                            write({"jsonrpc": "2.0", "id": queued_request["id"], "result": {"turnId": TURN_ID}})
                    elif not answer_read_while_held(queued_request):
                        write({"jsonrpc": "2.0", "id": queued_request.get("id"), "error": {"code": -32601, "message": "Unsupported fixture request."}})
                ready.unlink(missing_ok=True)
                released = release.exists()
                release.unlink(missing_ok=True)
                if not released:
                    os._exit(3)
                saved_history = serial_history()
                saved_history["steerRequests"] = saved_history.get("steerRequests", []) + steer_requests
                saved_history["rejectedSteerRequests"] = saved_history.get("rejectedSteerRequests", []) + rejected_steer_requests
                history_path.write_text(json.dumps(saved_history), encoding="utf-8")
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif serial_mode:
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-success-wait") and not mode.endswith("-title-success-wait"):
                ready = Path(str(sys.argv[0]) + ".resolve-ready")
                resume = Path(str(sys.argv[0]) + ".resolve-continue")
                with Path(str(sys.argv[0]) + ".resolve-start-count").open("a", encoding="utf-8") as stream:
                    stream.write("start\n")
                ready.write_text("Codex conflict-resolution turn is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not resume.exists() and time.monotonic() < deadline:
                    drain_pending_stdin()
                    time.sleep(0.02)
                if not resume.exists():
                    os._exit(3)
                ready.unlink(missing_ok=True)
                resume.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-context-compaction"):
                compaction_item = {"id": "item_stationai_compaction", "type": "contextCompaction", "payload": {"opaque": "COMPACTION_OPAQUE_SENTINEL"}}
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID, "item": compaction_item,
                }})
                ready = Path(str(sys.argv[0]) + ".compaction-ready")
                release = Path(str(sys.argv[0]) + ".compaction-release")
                ready.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                ready.write_text("Context compaction is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    drain_pending_stdin()
                    time.sleep(0.02)
                ready.unlink(missing_ok=True)
                if not release.exists():
                    os._exit(3)
                release.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID, "item": compaction_item,
                }})
                item = {"id": "item_stationai_final", "type": "agentMessage", "phase": "final_answer", "text": "Context compaction completed."}
                write({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "item": item}})
                write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "itemId": item["id"], "delta": item["text"]}})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "item": item}})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"}}})
            elif mode.endswith("-subagent") or mode.endswith("-subagent-wait") or mode.endswith("-tool-activity"):
                if mode.endswith("-subagent-wait"):
                    active = Path(str(sys.argv[0]) + ".turn-active")
                    release = Path(str(sys.argv[0]) + ".turn-release")
                    active.write_text("The subagent fixture turn is active before assistant output.\n", encoding="utf-8")
                    deadline = time.monotonic() + 90
                    while not release.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    was_released = release.exists()
                    active.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                    if not was_released:
                        os._exit(3)
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "item": subagent_item("inProgress"),
                }})
                first_child_started = subagent_activity(
                    "started", CHILD_THREAD_ID, "/agents/Sandbox review",
                    model="gpt-6-sol", reasoning_effort="high",
                )
                second_child_id = "00000000-0000-0000-0000-000000000003"
                second_child_started = subagent_activity(
                    "started", second_child_id, "/agents/some_agent",
                )
                for child_item in [first_child_started, second_child_started]:
                    write({"jsonrpc": "2.0", "method": "item/started", "params": {
                        "threadId": THREAD_ID, "item": child_item,
                    }})
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID,
                    "item": subagent_activity(
                        "interacted", CHILD_THREAD_ID, "/agents/Sandbox review",
                        model="gpt-6-sol", reasoning_effort="high",
                    ),
                }})
                if not mode.endswith("-tool-activity"):
                    ready = Path(str(sys.argv[0]) + ".subagent-ready")
                    release = Path(str(sys.argv[0]) + ".subagent-release")
                    ready.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                    ready.write_text("Subagent activities are active.\n", encoding="utf-8")
                    deadline = time.monotonic() + 30
                    while not release.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    ready.unlink(missing_ok=True)
                    if not release.exists():
                        os._exit(3)
                    release.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    # A terminal event may omit metadata reported by the start.
                    "item": subagent_activity("completed", CHILD_THREAD_ID, None),
                }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "item": subagent_activity("interrupted", second_child_id, "/agents/some_agent"),
                }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "item": subagent_activity("futureKind", "00000000-0000-0000-0000-000000000004", "/agents/Future review"),
                }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "item": subagent_item("completed"),
                }})
                if mode.endswith("-tool-activity"):
                    mcp_item = {
                        "id": "item_fixture_mcp_call", "type": "mcpToolCall", "server": "fixture-server",
                        "tool": "lookup", "status": "inProgress", "arguments": {"token": "RAW_ARGUMENT_SECRET"},
                    }
                    dynamic_item = {
                        "id": "item_fixture_dynamic_call", "type": "dynamicToolCall", "tool": "summarize",
                        "status": "inProgress", "arguments": {"prompt": "RAW_ARGUMENT_SECRET"},
                    }
                    legacy_dynamic_item = {
                        "id": "item_fixture_dynamic_legacy", "type": "dynamicToolCall", "tool": "legacySummary",
                        "status": "inProgress", "arguments": {"input": "RAW_ARGUMENT_SECRET"},
                    }
                    active_command_item = {
                        "id": "item_fixture_active_long_command", "type": "commandExecution",
                        "command": "long-command-name " + "argument-" * 40,
                        "cwd": "/tmp/stationai-fixture", "status": "inProgress",
                    }
                    for tool_item in [mcp_item, dynamic_item, legacy_dynamic_item, active_command_item]:
                        write({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": THREAD_ID, "item": tool_item}})
                    ready = Path(str(sys.argv[0]) + ".tool-ready")
                    release = Path(str(sys.argv[0]) + ".tool-release")
                    ready.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                    ready.write_text("Tool lifecycle starts are visible.\n", encoding="utf-8")
                    release_latest = Path(str(sys.argv[0]) + ".tool-release-latest")
                    release_latest.unlink(missing_ok=True)
                    deadline = time.monotonic() + 30
                    while not release_latest.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    if not release_latest.exists():
                        os._exit(3)
                    release_latest.unlink(missing_ok=True)
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": THREAD_ID, "item": {
                        **active_command_item, "status": "completed", "durationMs": 37,
                    }}})
                    while not release.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    ready.unlink(missing_ok=True)
                    if not release.exists():
                        os._exit(3)
                    release.unlink(missing_ok=True)
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": THREAD_ID, "item": {
                        **legacy_dynamic_item, "status": "completed", "success": True,
                        "contentItems": [{"type": "inputText", "text": "RAW_RESULT_SECRET"}], "durationMs": 41,
                    }}})
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": THREAD_ID, "item": {
                        **mcp_item, "status": "completed", "result": {"content": [{"type": "text", "text": "RAW_RESULT_SECRET"}]},
                    }}})
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": THREAD_ID, "item": {
                        **dynamic_item, "status": "failed", "success": False, "durationMs": 37,
                    }}})
                for action_item in diagnostic_action_items(os.environ.get("STATIONAI_FIXTURE_WORKSPACE", os.getcwd())):
                    write({"jsonrpc": "2.0", "method": "item/started", "params": {
                        "threadId": THREAD_ID, "item": {**action_item, "status": "inProgress"},
                    }})
                    if action_item["type"] == "commandExecution":
                        for delta in ("CODEX_STREAMED_", "OUTPUT_NOT_LOGGED"):
                            write({"jsonrpc": "2.0", "method": "item/commandExecution/outputDelta", "params": {
                                "threadId": THREAD_ID, "turnId": TURN_ID,
                                "itemId": action_item["id"], "delta": delta,
                            }})
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "item": action_item,
                    }})
                progress_text = "I inspected the project structure and am preparing the summary."
                for phase, item_id, text in [("commentary", "item_stationai_commentary", progress_text)]:
                    item = {"id": item_id, "type": "agentMessage", "text": "", "phase": phase}
                    write({"jsonrpc": "2.0", "method": "item/started", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID, "item": item,
                    }})
                    midpoint = len(text) // 2
                    for delta in (text[:midpoint], text[midpoint:]):
                        write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
                            "threadId": THREAD_ID, "turnId": TURN_ID, "itemId": item_id, "delta": delta,
                        }})
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID,
                        "turnId": TURN_ID,
                        "item": {**item, "text": text},
                    }})
                if mode.endswith("-subagent-wait"):
                    active = Path(str(sys.argv[0]) + ".commentary-active")
                    release = Path(str(sys.argv[0]) + ".commentary-release")
                    active.write_text("The subagent fixture turn has live commentary.\n", encoding="utf-8")
                    deadline = time.monotonic() + 90
                    while not release.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    was_released = release.exists()
                    active.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                    if not was_released:
                        os._exit(3)
                phase, item_id, text = ("final_answer", "item_stationai_final", "The subagent inspected the project structure.")
                item = {"id": item_id, "type": "agentMessage", "text": "", "phase": phase}
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID, "item": item,
                }})
                midpoint = len(text) // 2
                for delta in (text[:midpoint], text[midpoint:]):
                    write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID, "itemId": item_id, "delta": delta,
                    }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "turnId": TURN_ID,
                    "item": {**item, "text": text},
                }})
                final_answer_pause = Path(str(sys.argv[0]) + ".final-answer-pause")
                if final_answer_pause.exists():
                    final_answer_ready = Path(str(sys.argv[0]) + ".final-answer-ready")
                    final_answer_release = Path(str(sys.argv[0]) + ".final-answer-release")
                    final_answer_ready.write_text("The final answer is visible before turn completion.\n", encoding="utf-8")
                    deadline = time.monotonic() + 90
                    while not final_answer_release.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    was_released = final_answer_release.exists()
                    final_answer_ready.unlink(missing_ok=True)
                    final_answer_release.unlink(missing_ok=True)
                    if not was_released:
                        os._exit(3)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-markdown"):
                plan_item_id = "item_stationai_plan"
                is_plan_turn = message.get("params", {}).get("collaborationMode", {}).get("mode") == "plan"
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {"id": plan_item_id, "type": "plan", "text": ""},
                }})
                for index, delta in enumerate((MARKDOWN_PLAN[:64], MARKDOWN_PLAN[64:])):
                    write({"jsonrpc": "2.0", "method": "item/plan/delta", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID,
                        "itemId": plan_item_id, "delta": delta,
                    }})
                    if index == 0 and is_plan_turn and Path(str(sys.argv[0]) + ".plan-delta-hold").exists():
                        ready = Path(str(sys.argv[0]) + ".plan-delta-ready")
                        release = Path(str(sys.argv[0]) + ".plan-delta-release")
                        ready.write_text("The first plan delta is visible before completion.\n", encoding="utf-8")
                        deadline = time.monotonic() + 30
                        while not release.exists() and time.monotonic() < deadline:
                            drain_pending_stdin()
                            time.sleep(0.02)
                        if not release.exists():
                            os._exit(3)
                        ready.unlink()
                        release.unlink()
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {"id": plan_item_id, "type": "plan", "text": MARKDOWN_PLAN},
                }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-hold"):
                hold_used = Path(str(sys.argv[0]) + ".hold-used")
                if hold_used.exists():
                    question_request(901)
                else:
                    hold_used.write_text("The first fixture turn is held for restart recovery.\n", encoding="utf-8")
                    release = Path(str(sys.argv[0]) + ".turn-release")
                    deadline = time.monotonic() + 90
                    while not release.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    if release.exists():
                        release.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif is_restart_question_mode(mode):
                asked = Path(str(sys.argv[0]) + ".asked")
                secret_stage = Path(str(sys.argv[0]) + ".secret-stage")
                if not asked.exists():
                    question_request(901)
                    asked.write_text("Provider process ended with a pending question.\n", encoding="utf-8")
                    os._exit(0)
                if mode.endswith("-restart-question-no-secret") and turn_message == "Ask a second restart-safe structured question.":
                    secret_stage.write_text("A later secret question is pending.\n", encoding="utf-8")
                    question_request(902)
                    os._exit(0)
                if is_outcome_reminder:
                    question_request(901)
                    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                        "threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"},
                    }})
                    return
                if turn_message and not turn_message.startswith("Continue this conversation by applying"):
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID,
                        "item": {"id": "item_followup_answer", "type": "agentMessage", "phase": "final_answer", "text": "Follow-up after private recovery."},
                    }})
                    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                        "threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"},
                    }})
                    return
                if "-nonblocking" in mode:
                    expected_recovery_answers = ("Custom approach", "fixture-secret")
                else:
                    no_secret_recovery = mode.endswith("-restart-question-no-secret") and not secret_stage.exists()
                    expected_recovery_answers = ("Blue",) if no_secret_recovery else ("Green", "fixture-secret")
                if not turn_message or any(answer not in turn_message for answer in expected_recovery_answers):
                    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                        "threadId": THREAD_ID,
                        "turn": {"id": TURN_ID, "status": "failed", "error": {"message": "Recovery turn omitted a re-entered answer."}},
                    }})
                    return
                private_activity = {
                    "id": "item_private_recovery_command",
                    "type": "commandExecution",
                    "command": "printf fixture-secret",
                    "cwd": "/tmp",
                    "aggregatedOutput": "fixture-secret",
                    "exitCode": 0,
                    "status": "completed",
                }
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID, "item": private_activity,
                }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID, "item": private_activity,
                }})
                write({"jsonrpc": "2.0", "method": "turn/diff/updated", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "diff": "diff --git a/private.txt b/private.txt\n+fixture-secret\n",
                }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {
                        "id": "item_private_recovery_live_async", "type": "agentMessage",
                        "phase": "final_answer", "delivery": "async", "text": "Private follow-up question",
                        "questions": [{"title": "fixture-secret?", "options": ["fixture-secret"]}],
                    },
                }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {"id": f"item_recovered_answer_{TURN_ID}", "type": "agentMessage", "phase": "final_answer", "text": answer_text(turn_message)},
                }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"},
                }})
                return
            elif mode.endswith("-question"):
                active = Path(str(sys.argv[0]) + ".turn-active")
                release = Path(str(sys.argv[0]) + ".turn-release")
                active.write_text("The progress report fixture turn is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    drain_pending_stdin()
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                if not was_released:
                    os._exit(3)
                question_request(901)
            elif "-hold-release" in mode:
                active = Path(str(sys.argv[0]) + ".turn-active")
                release = Path(str(sys.argv[0]) + ".turn-release")
                active.write_text("The progress report fixture turn is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 90
                while not release.exists() and time.monotonic() < deadline:
                    drain_pending_stdin()
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                time.sleep(0.1)
                if not was_released:
                    os._exit(3)
                turn_status = "interrupted" if "-interrupted" in mode else ("failed" if "-failed" in mode else "completed")
                echoed = echoed_outcome_answer(turn_message)
                if echoed and turn_status == "completed":
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID,
                        "item": {"id": "item_stationai_echoed_outcome", "type": "agentMessage", "phase": "final_answer", "text": echoed},
                    }})
                turn_error = {"error": {"message": "Codex interrupted this turn." if turn_status == "interrupted" else "Codex failed this turn."}} if turn_status != "completed" else {}
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "00000000-0000-0000-0000-000000000001",
                    "turn": {"id": TURN_ID, "status": turn_status, **turn_error},
                }})
            else:
                question_request(901)
        elif message.get("id") in {901, 902} or message.get("id") in question_contexts:
            if "-question-isolation-" in mode:
                THREAD_ID, TURN_ID = question_contexts.pop(message["id"])
            if "error" in message:
                answers = None
                rejection_message = message.get("error", {}).get("message", "")
                if "private StationAI status nudge" in rejection_message:
                    with Path(str(sys.argv[0]) + ".private-reminder-question-rejection").open("a", encoding="utf-8") as stream:
                        stream.write(rejection_message + "\n")
            else:
                answers = message.get("result", {}).get("answers")
            if "-slow" in mode and not mode.endswith("-interrupted"):
                time.sleep(2)
            expected_answers = {
                "color": {"answers": ["Blue"]},
                "token": {"answers": ["fixture-secret"]},
            }
            if "-nonblocking" in mode:
                expected_answers = {"color": {"answers": ["Custom approach"]}, "token": {"answers": ["fixture-secret"]}}
            elif is_restart_question_mode(mode):
                no_secret_fixture = mode.endswith("-restart-question-no-secret")
                secret_stage = Path(str(sys.argv[0]) + ".secret-stage").exists()
                expected_answers = (
                    {"color": {"answers": ["Blue"]}}
                    if no_secret_fixture and not secret_stage
                    else ({"color": {"answers": ["Green"]}, "token": {"answers": ["fixture-secret"]}}
                          if no_secret_fixture else {"token": {"answers": ["fixture-secret"]}})
                )
            elif mode.endswith("-nonblocking-slow"):
                expected_answers["color"] = {"answers": ["Custom approach"]}
            if mode.endswith("-user-question"):
                expected_answers = {"question_action": {"answers": ["Continue"]}}
            failed = mode.endswith("-empty") or mode.endswith("-fail") or answers != expected_answers
            if not failed and "-question-isolation-" in mode and THREAD_ID == first_question_thread and question_rounds[THREAD_ID] == 1:
                question_request(901, followup=True)
                return
            if "-question-isolation-" in mode:
                isolation_turns[THREAD_ID] = (TURN_ID, answers)
            if not failed and Path(str(sys.argv[0]) + ".outcome-hold").exists():
                active = Path(str(sys.argv[0]) + ".outcome-active")
                release = Path(str(sys.argv[0]) + ".outcome-release")
                active.write_text("The answered fixture turn is waiting for its explicit outcome.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    drain_pending_stdin()
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                if not was_released:
                    os._exit(3)
            if not failed and is_restart_question_mode(mode):
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {"id": f"item_recovered_answer_{TURN_ID}", "type": "agentMessage", "phase": "final_answer", "text": answer_text(turn_message)},
                }})
            else:
                echoed = echoed_outcome_answer(turn_message)
                if not failed and echoed:
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID,
                        "item": {
                            "id": "item_stationai_echoed_outcome",
                            "type": "agentMessage",
                            "phase": "final_answer",
                            "text": echoed,
                        },
                    }})
            write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": THREAD_ID,
                "turn": {"id": TURN_ID, "status": "interrupted" if mode.endswith("-interrupted") else ("failed" if failed else "completed"),
                         **({"error": {"message": "Codex interrupted this turn."}} if mode.endswith("-interrupted") else ({"error": {"message": "Question response was missing or incorrect."}} if failed else {}))},
            }})
        elif message.get("method") == "turn/steer":
            params = message.get("params", {})
            if params.get("threadId") != THREAD_ID or params.get("expectedTurnId") != TURN_ID:
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32010, "message": "The expected turn ID is stale."}})
            else:
                saved_history = serial_history()
                saved_history.setdefault("steerRequests", []).append(params)
                history_path.write_text(json.dumps(saved_history), encoding="utf-8")
                write({"jsonrpc": "2.0", "id": message["id"], "result": {"turnId": TURN_ID}})
        elif message.get("method") == "turn/interrupt":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
        elif message.get("method") == "thread/read":
            if message.get("params", {}).get("threadId") != CHILD_THREAD_ID:
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32005, "message": "Unknown fixture child thread."}})
                return
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": CHILD_THREAD_ID, "turns": []}}})
        elif message.get("method") == "thread/turns/list":
            if message.get("params", {}).get("threadId") != CHILD_THREAD_ID:
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32005, "message": "Unknown fixture child thread."}})
                return
            write({"jsonrpc": "2.0", "id": message["id"], "result": {
                "data": [{"id": CHILD_TURN_ID, "status": "completed"}],
                "nextCursor": None,
            }})
        elif message.get("method") == "thread/items/list":
            if message.get("params", {}).get("threadId") == CHILD_THREAD_ID:
                write({"jsonrpc": "2.0", "id": message["id"], "result": {
                    "data": [{"item": item, "turnId": CHILD_TURN_ID} for item in CHILD_MESSAGES],
                    "nextCursor": None,
                }})
                return
            if Path(str(sys.argv[0]) + ".history-error").is_file():
                write({"jsonrpc": "2.0", "id": message["id"], "error": {
                    "code": -32009,
                    "message": "Fixture history failed after receiving fixture-secret.",
                }})
                return
            saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
            if serial_mode and message.get("params", {}).get("threadId") != saved_history.get("threadID"):
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32004, "message": "History can only be read from the persisted fixture thread."}})
                return
            if async_mode:
                entries = []
                for index, saved_turn in enumerate(saved_history.get("messages", []), start=1):
                    turn_id = saved_turn["turnID"]
                    entries.append({"turnId": turn_id, "item": {
                        "id": f"item_stationai_async_user_{index}",
                        "type": "userMessage",
                        "content": [{"type": "text", "text": saved_turn["userMessage"]}],
                    }})
                    if index == 1:
                        entries.extend([
                            {"turnId": turn_id, "item": async_question_item()},
                            {"turnId": turn_id, "item": {
                                "id": "item_stationai_async_followup",
                                "type": "agentMessage", "phase": "final_answer",
                                "text": "I can continue while you decide.",
                            }},
                        ])
                        if saved_turn.get("steeredAnswer"):
                            entries.extend([
                                {"turnId": turn_id, "item": {
                                    "id": "item_stationai_async_steered_user", "type": "userMessage",
                                    "content": [{"type": "text", "text": saved_turn["steeredAnswer"]}],
                                }},
                                {"turnId": turn_id, "item": {
                                    "id": "item_stationai_async_answer_steered", "type": "agentMessage", "phase": "final_answer",
                                    "text": f"Answers received: {saved_turn['steeredAnswer']}",
                                }},
                                {"turnId": turn_id, "item": later_async_question_item()},
                            ])
                    else:
                        entries.append({"turnId": turn_id, "item": {
                            "id": f"item_stationai_async_answer_{index}",
                            "type": "agentMessage", "phase": "final_answer",
                            "text": f"Answers received: {saved_turn['userMessage']}",
                        }})
                write({"jsonrpc": "2.0", "id": message["id"], "result": {
                    "data": entries, "nextCursor": None,
                }})
                return
            if serial_mode and saved_history.get("messages"):
                contents = []
                for index, saved_turn in enumerate(saved_history["messages"], start=1):
                    user_message = saved_turn.get("userMessage")
                    user_images = saved_turn.get("images", [])
                    user_content = ([{"type": "text", "text": user_message}] if user_message else []) + [
                        {"type": "image", "url": image_url} for image_url in user_images
                    ]
                    if user_content:
                        contents.extend([
                            {"id": f"item_user_fixture_{index}", "type": "userMessage", "content": user_content},
                            {"id": f"item_assistant_fixture_{index}", "type": "agentMessage", "phase": "final_answer", "text": answer_text(user_message)},
                        ])
            elif saved_history.get("turns"):
                contents = []
                for index, saved_turn in enumerate(saved_history["turns"], start=1):
                    user_message = saved_turn.get("userMessage")
                    user_images = saved_turn.get("images", [])
                    user_content = ([{"type": "text", "text": user_message}] if user_message else []) + [
                        {"type": "image", "url": image_url} for image_url in user_images
                    ]
                    if user_content:
                        echoed = echoed_outcome_answer(user_message)
                        assistant = {"id": f"item_assistant_fixture_{index}", "type": "agentMessage", "phase": "final_answer", "text": "Answers received: Blue / fixture-secret."}
                        if echoed:
                            assistant.update(phase="final_answer", text=echoed)
                        contents.extend([
                            {"id": f"item_user_fixture_{index}", "type": "userMessage", "content": user_content},
                            assistant if echoed else {"id": f"item_assistant_fixture_{index}", "type": "agentMessage", "phase": "final_answer", "text": answer_text(user_message)},
                        ])
                        if mode.endswith("-hold-release") and "stationai internal outcome nudge:" not in (user_message or "").lower():
                            contents.append({
                                "id": f"item_hold_release_file_change_{index}",
                                "type": "fileChange",
                                "changes": [{"path": "progress-fixture.txt", "kind": "update", "diff": "+ordinary-turn-diff-after-reminders"}],
                                "status": "completed",
                            })
                        if "fixture-secret" in own_user_text(user_message):
                            contents.append({
                                "id": f"item_private_recovery_file_change_{index}",
                                "type": "fileChange",
                                "changes": [{"path": "private.txt", "kind": "update", "diff": "+fixture-secret"}],
                                "status": "completed",
                            })
                            contents.append({
                                "id": f"item_private_recovery_agent_{index}",
                                "type": "collabAgentToolCall",
                                "tool": "spawnAgent",
                                "prompt": "Keep this private: fixture-secret",
                                "status": "completed",
                            })
                            contents.append({
                                "id": f"item_private_recovery_subagent_{index}",
                                "type": "subAgentActivity",
                                "agentThreadId": f"fixture-private-subagent-{index}",
                                "kind": "completed",
                                "agentPath": "/agents/fixture-secret",
                            })
                            contents.append({
                                "id": f"item_private_recovery_async_{index}",
                                "type": "agentMessage",
                                "phase": "final_answer",
                                "delivery": "async",
                                "text": "Private follow-up question",
                                "questions": [{"title": "fixture-secret?", "options": ["fixture-secret"]}],
                            })
                        elif user_message == "Follow up after private recovery.":
                            contents.append({
                                "id": f"item_followup_file_change_{index}",
                                "type": "fileChange",
                                "changes": [{"path": "follow-up.txt", "kind": "update", "diff": "+follow-up-visible-diff"}],
                                "status": "completed",
                            })
            else:
                user_message = saved_history.get("userMessage") or (turn_message if answers else None)
                user_images = saved_history.get("images", [])
                user_content = ([{"type": "text", "text": user_message}] if user_message else []) + [
                    {"type": "image", "url": image_url} for image_url in user_images
                ]
                contents = ([
                    {"id": "item_user_fixture", "type": "userMessage", "content": user_content},
                    {"id": "item_assistant_fixture", "type": "agentMessage", "phase": "final_answer", "text": answer_text(user_message)},
                ] if user_content and not mode.endswith("-empty") else [])
            if mode.endswith("-subagent") or mode.endswith("-subagent-wait"):
                contents = [
                    {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Delegate this task."}]},
                    {"id": "item_stationai_commentary", "type": "agentMessage", "phase": "commentary", "text": "I inspected the project structure and am preparing the summary."},
                    {"id": "item_stationai_final", "type": "agentMessage", "phase": "final_answer", "text": "The subagent inspected the project structure."},
                    subagent_item("completed"),
                    subagent_activity("completed", CHILD_THREAD_ID, "/agents/Sandbox review", model="gpt-6-sol", reasoning_effort="high"),
                    subagent_activity("interrupted", "00000000-0000-0000-0000-000000000003", "/agents/some_agent"),
                    subagent_activity("futureKind", "00000000-0000-0000-0000-000000000004", "/agents/Future review"),
                    *diagnostic_action_items(os.environ.get("STATIONAI_FIXTURE_WORKSPACE", os.getcwd())),
                ]
            if mode.endswith("-context-compaction"):
                contents = [
                    {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Compact the context."}]},
                    {"id": "item_stationai_compaction", "type": "contextCompaction", "payload": {"opaque": "COMPACTION_OPAQUE_SENTINEL"}},
                    {"id": "item_stationai_final", "type": "agentMessage", "phase": "final_answer", "text": "Context compaction completed."},
                ]
            if "-long-history-" in mode:
                contents = []
                for index in range(1, 61):
                    contents.extend([
                        {"id": f"item_long_history_user_{index}", "type": "userMessage", "content": [{"type": "text", "text": f"Long history user {index:02d}."}]},
                        {"id": f"item_long_history_assistant_{index}", "type": "agentMessage", "phase": "final_answer", "text": f"Long history assistant {index:02d}."},
                    ])
            if mode.endswith("-tool-activity"):
                contents.extend([
                    {"id": "item_fixture_mcp_call", "type": "mcpToolCall", "server": "fixture-server", "tool": "lookup", "status": "completed", "arguments": {"token": "RAW_ARGUMENT_SECRET"}, "result": {"content": [{"type": "text", "text": "RAW_RESULT_SECRET"}]}},
                    {"id": "item_fixture_dynamic_call", "type": "dynamicToolCall", "tool": "summarize", "status": "failed", "arguments": {"prompt": "RAW_ARGUMENT_SECRET"}, "success": False, "durationMs": 37},
                    {"id": "item_fixture_dynamic_legacy", "type": "dynamicToolCall", "tool": "legacySummary", "status": "completed", "arguments": {"input": "RAW_ARGUMENT_SECRET"}, "success": True, "contentItems": [{"type": "inputText", "text": "RAW_RESULT_SECRET"}]},
                    {"id": "item_user_fixture_later", "type": "userMessage", "content": [{"type": "text", "text": "A later turn starts."}]},
                    {"id": "item_assistant_fixture_later", "type": "agentMessage", "text": "Later turn response."},
                ])
            if mode.endswith("-markdown"):
                saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
                contents = [
                    {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": saved_history.get("userMessage", "Plan the task.")} ]},
                    {"id": "item_stationai_plan", "type": "plan", "text": MARKDOWN_PLAN},
                ]
            entries = []
            saved_turns = saved_history.get("messages") or saved_history.get("turns") or []
            ordinary_turn_indexes = [
                index for index, saved_turn in enumerate(saved_turns)
                if "stationai internal outcome nudge:" not in (saved_turn.get("userMessage") or "").lower()
            ]
            for turn_index, saved_turn in enumerate(saved_turns, start=1):
                if (
                    "hold-release" in os.path.basename(sys.argv[0])
                    and "stationai internal outcome nudge:" in (saved_turn.get("userMessage") or "").lower()
                ):
                    contents.append({
                        "id": f"item_private_reminder_activity_{turn_index}",
                        "type": "mcpToolCall",
                        "server": "private-reminder-fixture",
                        "tool": "reminder-only-tool",
                        "status": "completed",
                        "durationMs": 11,
                        "_fixture_turn_index": turn_index - 1,
                    })
            unassociated_restart_question = os.path.basename(sys.argv[0]).endswith("-unassociated-restart-question")
            for index, item in enumerate(contents):
                item_id = item.get("id", "")
                turn_id = TURN_ID
                if saved_turns:
                    try:
                        if "_fixture_turn_index" in item:
                            turn_index = item.pop("_fixture_turn_index")
                        elif item_id.startswith("item_long_history_"):
                            turn_index = int(item_id.rsplit("_", 1)[1]) - 1
                        elif item_id.rsplit("_", 1)[-1].isdigit():
                            turn_index = int(item_id.rsplit("_", 1)[1]) - 1
                        elif mode.endswith("-tool-activity") and ordinary_turn_indexes:
                            turn_index = ordinary_turn_indexes[0]
                        elif ordinary_turn_indexes:
                            turn_index = ordinary_turn_indexes[-1]
                        else:
                            turn_index = min(index // 2, len(saved_turns) - 1)
                    except (ValueError, IndexError):
                        turn_index = -1
                    if 0 <= turn_index < len(saved_turns):
                        turn_id = saved_turns[turn_index].get("turnID", TURN_ID)
                        if turn_index in ordinary_turn_indexes and ordinary_turn_indexes.index(turn_index) == 1:
                            item["createdAt"] = "2026-10-26T12:34:00Z"
                if unassociated_restart_question and item.get("type") == "userMessage":
                    entries.append({"item": item})
                else:
                    entries.append({"item": item, "turnId": turn_id})
            write({"jsonrpc": "2.0", "id": message["id"], "result": {
                "data": entries,
                "nextCursor": None,
            }})

    # Requests a real, evented app-server keeps answering while another turn
    # is in progress. Anything else that arrives during a held turn is
    # deferred and handled after it, in arrival order, as before.
    answer_while_held = {"thread/items/list", "thread/turns/list", "thread/read",
                         "thread/resume", "model/list", "thread/goal/get"}
    deferred = []

    def snapshot_state():
        return {"THREAD_ID": THREAD_ID, "TURN_ID": TURN_ID, "_": _, "ack_deadline": ack_deadline, "action_item": action_item, "active": active, "active_command_item": active_command_item, "answers": answers, "asked": asked, "assistant": assistant, "async_provider_error": async_provider_error, "child_item": child_item, "compaction_item": compaction_item, "completed": completed, "contents": contents, "deadline": deadline, "delta": delta, "descriptor": descriptor, "dynamic_item": dynamic_item, "echoed": echoed, "entries": entries, "error_code": error_code, "expected_answers": expected_answers, "expected_recovery_answers": expected_recovery_answers, "fail_marker": fail_marker, "failed": failed, "final_answer_pause": final_answer_pause, "final_answer_ready": final_answer_ready, "final_answer_release": final_answer_release, "first_child_started": first_child_started, "first_turn": first_turn, "first_turn_marker": first_turn_marker, "goal": goal, "history": history, "hold_marker": hold_marker, "hold_used": hold_used, "image_inputs": image_inputs, "image_url": image_url, "incoming": incoming, "index": index, "instructions": instructions, "interrupt_message": interrupt_message, "interrupt_release": interrupt_release, "is_outcome_reminder": is_outcome_reminder, "is_plan_turn": is_plan_turn, "is_title_request": is_title_request, "item": item, "item_id": item_id, "items": items, "key": key, "legacy_dynamic_item": legacy_dynamic_item, "level": level, "mcp_item": mcp_item, "message_text": message_text, "messages": messages, "midpoint": midpoint, "no_secret_fixture": no_secret_fixture, "no_secret_recovery": no_secret_recovery, "observe_history": observe_history, "ordinary_turn_indexes": ordinary_turn_indexes, "outcome_command": outcome_command, "outcome_line": outcome_line, "params": params, "phase": phase, "plan_item_id": plan_item_id, "preserve_no_outcome": preserve_no_outcome, "private_activity": private_activity, "progress_text": progress_text, "provider_error": provider_error, "queued_request": queued_request, "readable": readable, "ready": ready, "received_interrupt": received_interrupt, "reject": reject, "reject_deadline": reject_deadline, "reject_marker": reject_marker, "rejected_steer_requests": rejected_steer_requests, "rejection": rejection, "rejection_message": rejection_message, "release": release, "release_latest": release_latest, "released": released, "requested": requested, "requested_thread_id": requested_thread_id, "resume": resume, "resume_error": resume_error, "saved_history": saved_history, "saved_turn": saved_turn, "saved_turns": saved_turns, "saw_question": saw_question, "saw_turn": saw_turn, "second_child_id": second_child_id, "second_child_started": second_child_started, "secret_stage": secret_stage, "serial_first_turn": serial_first_turn, "steer_request": steer_request, "steer_requests": steer_requests, "steered_answer": steered_answer, "stream": stream, "text": text, "thread_start_instructions": thread_start_instructions, "tool_item": tool_item, "turn_error": turn_error, "turn_history": turn_history, "turn_id": turn_id, "turn_index": turn_index, "turn_input": turn_input, "turn_message": turn_message, "turn_status": turn_status, "turn_thread_id": turn_thread_id, "turns": turns, "unassociated_restart_question": unassociated_restart_question, "user_content": user_content, "user_images": user_images, "user_message": user_message, "value": value, "was_released": was_released}

    def restore_state(state):
        global THREAD_ID, TURN_ID
        nonlocal _, ack_deadline, action_item, active, active_command_item, answers, asked, assistant
        nonlocal async_provider_error, child_item, compaction_item, completed, contents, deadline, delta
        nonlocal descriptor, dynamic_item, echoed, entries, error_code, expected_answers
        nonlocal expected_recovery_answers, fail_marker, failed, final_answer_pause, final_answer_ready
        nonlocal final_answer_release, first_child_started, first_turn, first_turn_marker, goal, history
        nonlocal hold_marker, hold_used, image_inputs, image_url, incoming, index, instructions
        nonlocal interrupt_message, interrupt_release, is_outcome_reminder, is_plan_turn, is_title_request
        nonlocal item, item_id, items, key, legacy_dynamic_item, level, mcp_item, message_text, messages
        nonlocal midpoint, no_secret_fixture, no_secret_recovery, observe_history, ordinary_turn_indexes
        nonlocal outcome_command, outcome_line, params, phase, plan_item_id, preserve_no_outcome
        nonlocal private_activity, progress_text, provider_error, queued_request, readable, ready
        nonlocal received_interrupt, reject, reject_deadline, reject_marker, rejected_steer_requests
        nonlocal rejection, rejection_message, release, release_latest, released, requested
        nonlocal requested_thread_id, resume, resume_error, saved_history, saved_turn, saved_turns
        nonlocal saw_question, saw_turn, second_child_id, second_child_started, secret_stage
        nonlocal serial_first_turn, steer_request, steer_requests, steered_answer, stream, text
        nonlocal thread_start_instructions, tool_item, turn_error, turn_history, turn_id, turn_index
        nonlocal turn_input, turn_message, turn_status, turn_thread_id, turns, unassociated_restart_question
        nonlocal user_content, user_images, user_message, value, was_released
        THREAD_ID = state["THREAD_ID"]
        TURN_ID = state["TURN_ID"]
        _ = state["_"]
        ack_deadline = state["ack_deadline"]
        action_item = state["action_item"]
        active = state["active"]
        active_command_item = state["active_command_item"]
        answers = state["answers"]
        asked = state["asked"]
        assistant = state["assistant"]
        async_provider_error = state["async_provider_error"]
        child_item = state["child_item"]
        compaction_item = state["compaction_item"]
        completed = state["completed"]
        contents = state["contents"]
        deadline = state["deadline"]
        delta = state["delta"]
        descriptor = state["descriptor"]
        dynamic_item = state["dynamic_item"]
        echoed = state["echoed"]
        entries = state["entries"]
        error_code = state["error_code"]
        expected_answers = state["expected_answers"]
        expected_recovery_answers = state["expected_recovery_answers"]
        fail_marker = state["fail_marker"]
        failed = state["failed"]
        final_answer_pause = state["final_answer_pause"]
        final_answer_ready = state["final_answer_ready"]
        final_answer_release = state["final_answer_release"]
        first_child_started = state["first_child_started"]
        first_turn = state["first_turn"]
        first_turn_marker = state["first_turn_marker"]
        goal = state["goal"]
        history = state["history"]
        hold_marker = state["hold_marker"]
        hold_used = state["hold_used"]
        image_inputs = state["image_inputs"]
        image_url = state["image_url"]
        incoming = state["incoming"]
        index = state["index"]
        instructions = state["instructions"]
        interrupt_message = state["interrupt_message"]
        interrupt_release = state["interrupt_release"]
        is_outcome_reminder = state["is_outcome_reminder"]
        is_plan_turn = state["is_plan_turn"]
        is_title_request = state["is_title_request"]
        item = state["item"]
        item_id = state["item_id"]
        items = state["items"]
        key = state["key"]
        legacy_dynamic_item = state["legacy_dynamic_item"]
        level = state["level"]
        mcp_item = state["mcp_item"]
        message_text = state["message_text"]
        messages = state["messages"]
        midpoint = state["midpoint"]
        no_secret_fixture = state["no_secret_fixture"]
        no_secret_recovery = state["no_secret_recovery"]
        observe_history = state["observe_history"]
        ordinary_turn_indexes = state["ordinary_turn_indexes"]
        outcome_command = state["outcome_command"]
        outcome_line = state["outcome_line"]
        params = state["params"]
        phase = state["phase"]
        plan_item_id = state["plan_item_id"]
        preserve_no_outcome = state["preserve_no_outcome"]
        private_activity = state["private_activity"]
        progress_text = state["progress_text"]
        provider_error = state["provider_error"]
        queued_request = state["queued_request"]
        readable = state["readable"]
        ready = state["ready"]
        received_interrupt = state["received_interrupt"]
        reject = state["reject"]
        reject_deadline = state["reject_deadline"]
        reject_marker = state["reject_marker"]
        rejected_steer_requests = state["rejected_steer_requests"]
        rejection = state["rejection"]
        rejection_message = state["rejection_message"]
        release = state["release"]
        release_latest = state["release_latest"]
        released = state["released"]
        requested = state["requested"]
        requested_thread_id = state["requested_thread_id"]
        resume = state["resume"]
        resume_error = state["resume_error"]
        saved_history = state["saved_history"]
        saved_turn = state["saved_turn"]
        saved_turns = state["saved_turns"]
        saw_question = state["saw_question"]
        saw_turn = state["saw_turn"]
        second_child_id = state["second_child_id"]
        second_child_started = state["second_child_started"]
        secret_stage = state["secret_stage"]
        serial_first_turn = state["serial_first_turn"]
        steer_request = state["steer_request"]
        steer_requests = state["steer_requests"]
        steered_answer = state["steered_answer"]
        stream = state["stream"]
        text = state["text"]
        thread_start_instructions = state["thread_start_instructions"]
        tool_item = state["tool_item"]
        turn_error = state["turn_error"]
        turn_history = state["turn_history"]
        turn_id = state["turn_id"]
        turn_index = state["turn_index"]
        turn_input = state["turn_input"]
        turn_message = state["turn_message"]
        turn_status = state["turn_status"]
        turn_thread_id = state["turn_thread_id"]
        turns = state["turns"]
        unassociated_restart_question = state["unassociated_restart_question"]
        user_content = state["user_content"]
        user_images = state["user_images"]
        user_message = state["user_message"]
        value = state["value"]
        was_released = state["was_released"]

    def answer_read_while_held(message):
        # Answers a read-only/resume request during a held turn without letting
        # it disturb the held turn's in-memory state. False for anything else.
        if message.get("method") not in answer_while_held:
            return False
        state = snapshot_state()
        try:
            handle_message(message)
        finally:
            restore_state(state)
        return True

    def drain_pending_stdin():
        # Called from held-turn waits that poll a file marker.
        while True:
            ready, _, _ = select.select([sys.stdin], [], [], 0)
            if not ready:
                return
            line = sys.stdin.readline()
            if not line:
                return
            try:
                peeked = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not answer_read_while_held(peeked):
                deferred.append(peeked)

    for line in sys.stdin:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        handle_message(message)
        while deferred:
            handle_message(deferred.pop(0))
    if not saw_turn:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

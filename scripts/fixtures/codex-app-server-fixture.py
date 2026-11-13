#!/usr/bin/env python3

"""Deterministic app-server peer for Playhouse's protocol integration tests."""

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

# Record the bridge environment Playhouse handed this provider process, so tests
# can run in-turn `playhouse` calls with exactly what a real provider inherits.
Path(str(sys.argv[0]) + ".bridge-environment").write_text(
    json.dumps({
        name: os.environ.get(name)
        for name in ("PLAYHOUSE_BRIDGE_SERVICE_NAME", "PLAYHOUSE_DATA_DIRECTORY")
    }),
    encoding="utf-8",
)

if "-title-" in Path(sys.argv[0]).name:
    THREAD_ID = f"playhouse-fixture-{os.getpid()}"
    TURN_ID = f"turn-playhouse-fixture-{os.getpid()}"
else:
    THREAD_ID = "00000000-0000-0000-0000-000000000001"
    TURN_ID = "turn_playhouse_fixture"

# The turn id a freshly started provider process uses for ordinary turns, and the
# private reminder turns that replaced it. A long-lived process must not let a
# later ordinary turn inherit an earlier reminder's id.
DEFAULT_TURN_ID = TURN_ID
REMINDER_TURN_IDS = set()


MARKDOWN_PLAN = '## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening\n\nTwo numbered steps follow on the very next lines:\n1. First numbered step: capture the baseline state before changes.\n\n2. Second numbered step: apply the fix and confirm there are no regressions.\n\n```javascript\nconsole.log("Hello, world!");\n```\n\n| Step | Status |\n| --- | :---: |\n| Verify fixture | Done |\n| Render table | Pending |\n| Wrap long cell | This status note is deliberately long so that it has to wrap onto several lines inside its column instead of being cut off with an ellipsis, and it keeps going for a while longer so that even a wide window still needs at least three lines to show every word of it |\n\n## Still open\n\n2. Open question two: should the installed app differ from the dev build?\n3. Open question three: when should the app restart?\n4. Open question four: which version numbers do we use?\n5. Open question five: may we use the local test feed?\n\nModel sizes vary a lot in practice, and\n3. 5 billion parameters is a common size.'


def markdown_plan_deltas():
    """The plan in four deltas that end inside a paragraph, inside a list item that follows that
    paragraph, and inside the fenced code block, so the streamed reply grows across each kind."""
    list_item = MARKDOWN_PLAN.index("- Implementation detail 11: verify") + len("- Implementation detail 11: verify")
    code = MARKDOWN_PLAN.index('console.log("Hello') + len('console.log("Hello')
    return (MARKDOWN_PLAN[:64], MARKDOWN_PLAN[64:list_item], MARKDOWN_PLAN[list_item:code], MARKDOWN_PLAN[code:])


ECHOED_OUTCOME_PREFIX = "Echo the outcome command for "
ECHOED_OUTCOME_ANSWER = "Fixture answer with an echoed outcome."


def echoed_outcome_answer(user_message):
    """Reproduces a model writing its final outcome command as answer text."""
    if not user_message or not user_message.startswith(ECHOED_OUTCOME_PREFIX):
        return None
    task_id = user_message[len(ECHOED_OUTCOME_PREFIX):].strip().rstrip(".")
    return f"{ECHOED_OUTCOME_ANSWER}\U0001F6E0\uFE0F\nplayhouse-cli task outcome {task_id} completed"


def own_user_text(message):
    """The user's own words, without Playhouse's hidden context envelope.

    Standalone chat seeds a page's first turn with that page's transcript, so a sentinel
    repeated by an earlier assistant answer must not re-trigger a scenario branch here.
    """
    text = message or ""
    close = "</playhouse-handoff-context>"
    if text.startswith("<playhouse-handoff-context>") and close in text:
        return text.split(close, 1)[1].strip()
    return text


# The app-server reports a turn's cost on its terminal notification. Codex names
# its cached bucket `cached_input_tokens` and has no cache-write bucket, so the
# totals differ from the Claude fixture's on purpose.
TURN_USAGE = {
    "input_tokens": 900,
    "output_tokens": 150,
    "cached_input_tokens": 250,
}
TURN_USAGE_TOTAL = sum(TURN_USAGE.values())


def breakdown(input_tokens, cached, output_tokens):
    return {"inputTokens": input_tokens, "cachedInputTokens": cached, "cacheWriteInputTokens": 0,
            "outputTokens": output_tokens, "reasoningOutputTokens": 0,
            "totalTokens": input_tokens + output_tokens}


def token_usage_notification(thread_id, turn_id, last, total):
    return {"method": "thread/tokenUsage/updated", "params": {
        "threadId": thread_id, "turnId": turn_id,
        "tokenUsage": {"last": last, "total": total, "modelContextWindow": 258400}}}


def call_usage_notifications(thread_id, turn_id):
    """What a real app-server streams per model call, ahead of the turn's end.

    The main thread makes two calls (sending 700 then 900 tokens, so the final
    transcript is 900) and repeats the second notification; a subagent thread
    announces itself with its parent and makes one call sending 300. Codex's
    input count includes its cached tokens, so "sent" is the input count itself.
    """
    subagent = f"{thread_id}-subagent"
    first, second = breakdown(700, 500, 30), breakdown(900, 600, 40)
    cumulative = breakdown(1600, 1100, 70)
    sub = breakdown(300, 100, 10)
    return [
        token_usage_notification(thread_id, turn_id, first, first),
        token_usage_notification(thread_id, turn_id, second, cumulative),
        token_usage_notification(thread_id, turn_id, second, cumulative),
        {"method": "thread/started", "params": {"thread": {"id": subagent, "parentThreadId": thread_id}}},
        token_usage_notification(subagent, f"{turn_id}-subagent", sub, sub),
    ]


# The token-waste rollout: what Codex writes to `$CODEX_HOME/sessions` for a
# thread, with one `token_usage_record` per model request whose input adds up
# exactly. An MCP tool returns a 1,000-line log, README.md is read twice, one
# request misses the prompt cache, and a compaction drops the log from the
# final context. A subagent thread gets its own small rollout.
WASTE_LOG = "".join(
    f"2026-11-03T10:{index // 60 % 60:02d}:{index % 60:02d}Z INFO fixture log line {index:04d} "
    f"{'NEEDLE-42 ' if index == 900 else ''}request ok path=/api/orc/builds/{index:04d}\n"
    for index in range(1, 1001)
)
WASTE_README = "Fixture README.\n" + "This project is a deterministic fixture for token accounting.\n" * 10


def write_waste_rollouts(thread_id):
    home = os.environ.get("CODEX_HOME")
    if not home or not thread_id:
        return
    directory = Path(home) / "sessions" / "2026" / "11" / "03"
    directory.mkdir(parents=True, exist_ok=True)

    def item(payload):
        return {"type": "response_item", "payload": payload}

    def message(role, text):
        kind = "output_text" if role == "assistant" else "input_text"
        return item({"type": "message", "role": role, "content": [{"type": kind, "text": text}]})

    def record(input_tokens, cached):
        return {"type": "token_usage_record", "payload": {"usage": {
            "input_tokens": input_tokens, "cached_input_tokens": cached, "output_tokens": 20}}}

    main = [
        {"type": "session_meta", "payload": {"id": thread_id, "base_instructions": {"text": "You are the Codex fixture. " * 80}}},
        message("developer", "<permissions instructions>\nThe fixture may run any command.\n</permissions instructions>"),
        message("user", "# AGENTS.md instructions for the fixture\nKeep answers short."),
        message("user", "Show token waste."),
        item({"type": "reasoning", "summary": [], "encrypted_content": "gAAAA" + "x" * 300}),
        item({"type": "function_call", "namespace": "mcp__fixturelogs", "name": "query_logs",
              "arguments": json.dumps({"stream": "orc", "limit": 5000}), "call_id": "call_waste_logs"}),
        record(4000, 0),
        item({"type": "function_call_output", "call_id": "call_waste_logs", "output": WASTE_LOG}),
        item({"type": "custom_tool_call", "name": "exec", "input": "cat README.md", "call_id": "call_waste_read1"}),
        record(19000, 3900),
        item({"type": "custom_tool_call_output", "call_id": "call_waste_read1", "output": WASTE_README}),
        item({"type": "custom_tool_call", "name": "exec", "input": "cat README.md", "call_id": "call_waste_read2"}),
        record(19300, 18900),
        item({"type": "custom_tool_call_output", "call_id": "call_waste_read2", "output": WASTE_README}),
        message("assistant", "Logs and README checked."),
        record(19600, 100),
        {"type": "compacted", "payload": {"message": "", "replacement_history": [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Show token waste."}]},
            {"type": "compaction", "encrypted_content": "gAAAA" + "y" * 400},
        ]}},
        message("user", "Continue."),
        record(4400, 3900),
        message("assistant", "Token waste shown."),
    ]
    subagent = [
        {"type": "session_meta", "payload": {"id": f"{thread_id}-subagent", "base_instructions": {"text": "You are a fixture subagent. " * 10}}},
        message("user", "Find the README."),
        record(300, 0),
        message("assistant", "Found it."),
    ]
    for name, lines in ((thread_id, main), (f"{thread_id}-subagent", subagent)):
        with open(directory / f"rollout-2026-11-03T10-00-00-{name}.jsonl", "w", encoding="utf-8") as handle:
            for line in lines:
                handle.write(json.dumps({"timestamp": "2026-11-03T10:00:00.000Z", **line}) + "\n")


# Side chat threads this server forked, each with the thread it was forked from.
SIDE_CHAT_THREADS = {}


def side_chat_selection(text):
    match = re.search(r"<selected-text>\n(.*?)\n</selected-text>", text or "", re.S)
    return match.group(1) if match else None


# Codex's read-only sandbox with network access: no file writes, sockets allowed.
READ_ONLY_SANDBOX_PROFILE = '(version 1)(allow default)(deny file-write*)(allow file-write* (literal "/dev/null"))'


def run_side_chat_cli(instructions, marker, extra):
    """Runs the Playhouse CLI the side chat instructions list (found by `marker`) with `extra`
    arguments inside a read-only macOS sandbox, as Codex runs a side chat's commands, and
    returns its parsed JSON output."""
    line = next((line.strip() for line in (instructions or "").splitlines()
                 if line.strip().startswith("'") and marker in line), None)
    if line is None:
        return {"ok": False, "error": "The side chat instructions list no such command."}
    executable = shlex.split(line)[0]
    completed = subprocess.run(["/usr/bin/sandbox-exec", "-p", READ_ONLY_SANDBOX_PROFILE, executable] + extra,
                               capture_output=True, text=True, timeout=60)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "error": completed.stderr.strip() or completed.stdout.strip()}


def handle_side_chat(message, history_path):
    """Serves a Playhouse side chat: `thread/fork` copies a thread under a new ID, and a turn on
    a forked thread answers about the selected text. Every fork and side chat turn is recorded
    in the history file. Returns whether the message was a side chat's."""
    method = message.get("method")
    params = message.get("params", {})
    def record(key, entry):
        history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
        history.setdefault(key, []).append(entry)
        history_path.write_text(json.dumps(history), encoding="utf-8")
    if method == "thread/fork":
        thread_id = f"fork-{uuid.uuid4()}"
        SIDE_CHAT_THREADS[thread_id] = {"source": params.get("threadId"), "instructions": params.get("developerInstructions"), "turns": 0}
        record("threadForks", {
            "threadId": thread_id, "sourceThreadId": params.get("threadId"), "sandbox": params.get("sandbox"),
            "approvalPolicy": params.get("approvalPolicy"), "excludeTurns": params.get("excludeTurns"),
            "cwd": params.get("cwd"), "developerInstructions": params.get("developerInstructions"),
        })
        write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": thread_id}, "model": params.get("model", "gpt-6-luna")}})
        return True
    if method == "thread/resume" and params.get("threadId") in SIDE_CHAT_THREADS:
        record("sideChatResumes", {"threadId": params.get("threadId"), "sandbox": params.get("sandbox")})
        write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": params.get("threadId")}, "model": params.get("model", "gpt-6-luna")}})
        return True
    if method in ("thread/read", "thread/turns/list", "thread/items/list") and params.get("threadId") in SIDE_CHAT_THREADS:
        write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": params.get("threadId"), "turns": []}, "data": [], "nextCursor": None}})
        return True
    if method != "turn/start" or params.get("threadId") not in SIDE_CHAT_THREADS:
        return False
    thread_id = params["threadId"]
    side_chat = SIDE_CHAT_THREADS[thread_id]
    side_chat["turns"] += 1
    text = next((item.get("text") for item in params.get("input", []) if item.get("type") == "text"), "") or ""
    turn_id = f"turn-side-chat-{uuid.uuid4()}"
    selection = side_chat_selection(text)
    question = text.split("</selected-text>", 1)[-1].strip()
    if "create a task" in question.lower():
        created = run_side_chat_cli(side_chat["instructions"], "task create", [
            "task", "create", "--title", "Side chat follow-up", "--prompt", f"Follow up on the side chat about: {question}"])
        task_id = (created.get("result") or {}).get("id") if created.get("ok") else None
        reply = f"Created task {task_id}." if task_id else f"Could not create the task: {created.get('error')}"
        if task_id:
            # Beyond the board commands, the daemon refuses what the sandbox would stop.
            deleted = run_side_chat_cli(side_chat["instructions"], "task create", ["task", "delete", task_id])
            record("sideChatForbiddenRequests", {"command": "task delete", "ok": deleted.get("ok"),
                                                  "error": (deleted.get("error") or {}).get("code") if isinstance(deleted.get("error"), dict) else deleted.get("error")})
    elif selection is not None:
        reply = f"Side chat about \"{selection}\", forked from {side_chat['source']}: {question}"
    else:
        reply = f"Side chat follow-up {side_chat['turns']} on {thread_id}: {question}"
    settings = (params.get("collaborationMode") or {}).get("settings") or {}
    record("sideChatTurns", {"threadId": thread_id, "text": text, "sandboxPolicy": params.get("sandboxPolicy"),
                             "approvalPolicy": params.get("approvalPolicy"), "reply": reply,
                             "model": params.get("model"), "effort": settings.get("reasoningEffort")})
    write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
    item = {"id": f"item-{turn_id}", "type": "agentMessage", "phase": "final_answer", "text": reply}
    write({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {**item, "text": ""}}})
    write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
        "threadId": thread_id, "turnId": turn_id, "itemId": item["id"], "delta": reply}})
    write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": item}})
    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}})
    return True


def write(value):
    if (isinstance(value, dict) and value.get("method") == "turn/completed"
            and "usage" not in value.get("params", {})):
        params = value["params"]
        for notification in call_usage_notifications(params.get("threadId"), (params.get("turn") or {}).get("id")):
            sys.stdout.write(json.dumps(notification, separators=(",", ":")) + "\n")
        sys.stdout.flush()
        value = {**value, "params": {**value["params"], "usage": dict(TURN_USAGE)}}
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def is_page_classifier_prompt(text):
    """A page classifier runs as a helper on its own thread in Codex, so its turns never
    belong to the chat thread's items."""
    return (text or "").startswith("Classify the latest user message for Playhouse's continuous chat page index.")


def answer_text(user_message):
    mode = os.path.basename(sys.argv[0])
    if isinstance(user_message, str) and user_message.startswith(
        "Classify the latest user message for Playhouse's continuous chat page index."
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
            if (turn.get("userMessage") or "").startswith("Classify the latest user message for Playhouse's continuous chat page index.")
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
    if "playhouse internal outcome nudge:" in (user_message or "").lower():
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
                    (f":playhouse-annotation{{index=\"{index}\"}} For ‘{item['text']}’: "
                     f"{item.get('comment', item.get('annotation', ''))}"
                     if tag == "response-comments" else
                     f"For ‘{item['text']}’: {item.get('comment', item.get('annotation', ''))} "
                     f":codex-annotation{{index=\"{index}\"}}")
                    for index, item in enumerate(annotations)
                )
        except (KeyError, TypeError, ValueError):
            pass
    return "Answers received: Blue / fixture-secret."


NUDGED_WORK_COMMENTARY = "Codex is finishing the remaining check after the nudge."
NUDGED_WORK_ANSWER = "Codex finished the remaining check after the nudge. Everything is done."


def nudged_work_items(turn_index):
    """What a status nudge turn does when work remains: it keeps working."""
    return [
        {"id": f"item_nudged_commentary_{turn_index}", "type": "agentMessage", "phase": "commentary",
         "text": NUDGED_WORK_COMMENTARY},
        {"id": f"item_nudged_check_{turn_index}", "type": "commandExecution", "command": "echo NUDGED CHECK PASSED",
         "cwd": "/tmp/playhouse-fixture", "status": "completed", "exitCode": 0, "durationMs": 7,
         "aggregatedOutput": "NUDGED CHECK PASSED\n"},
        {"id": f"item_nudged_final_{turn_index}", "type": "agentMessage", "phase": "final_answer",
         "text": NUDGED_WORK_ANSWER},
    ]


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
            "itemId": "item_playhouse_question",
            "questions": questions,
            "isBlocking": "-nonblocking" not in mode and "-plan" not in mode,
        },
    })


def subagent_item(status):
    return {
        "id": "item_playhouse_subagent",
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
CHILD_TURN_ID = "turn_playhouse_child_fixture"
CHILD_MESSAGES = [
    {"id": "item_child_user", "type": "userMessage", "content": [{"type": "text", "text": "Inspect Playhouse entitlements."}]},
    {"id": "item_child_assistant", "type": "agentMessage", "text": "Sandbox review read PlayhouseEntitlements.entitlements and found the required profile."},
]


def async_question_item():
    return {
        "id": "item_playhouse_async_question",
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
        "id": "item_playhouse_async_later_question",
        "type": "agentMessage", "phase": "final_answer", "delivery": "async",
        "text": "One more check", "questions": [{"title": "One more check", "options": None}],
    }


def diagnostic_action_items(cwd):
    return [
        {
            "id": "item_playhouse_command",
            "type": "commandExecution",
            "command": "git status --short",
            "cwd": cwd,
            "aggregatedOutput": "CODEX_OUTPUT_NOT_LOGGED",
            "exitCode": 0,
            "status": "completed",
        },
        {
            "id": "item_playhouse_file_change",
            "type": "fileChange",
            "changes": [{"path": "README.md", "kind": "update", "diff": "CODEX_DIFF_NOT_LOGGED"}],
            "status": "completed",
        },
    ]


def follow_turn_items(finished):
    """The `-follow-active-turn` turn's items, as its stream and history report them."""
    items = [
        {"id": "item_follow_commentary", "type": "agentMessage", "phase": "commentary",
         "text": "Codex is partway through the followed turn."},
        {"id": "item_follow_active_command", "type": "commandExecution", "command": "fixture-follow-step",
         "cwd": "/tmp/playhouse-fixture", "status": "completed" if finished else "inProgress",
         **({"exitCode": 0, "durationMs": 25} if finished else {})},
    ]
    if finished:
        items.append({"id": "item_follow_final", "type": "agentMessage", "phase": "final_answer",
                      "text": "Codex finished the followed turn."})
    return items


CPU_ATTRIBUTION_TURN = re.compile(r"\b(burn|idle) cpu for (\d+(?:\.\d+)?) seconds\b", re.IGNORECASE)


def run_cpu_attribution_server():
    """A small evented app-server for per-task CPU attribution tests.

    Unlike the default fixture, which runs one held turn at a time, this one
    keeps several threads' turns running at once on one process, the way a
    single shared `codex app-server` does. Every thread gets its own ID. A
    turn whose message says "burn cpu for N seconds" or "idle cpu for N
    seconds" runs one real child process in the turn's own `cwd` (a busy
    loop or a sleep); the turn reports its outcome and completes when that
    child exits. Other turns (titles, outcome nudges) complete immediately.
    """
    threads = {}
    running = {}
    buffer = b""

    def finish(thread_id, turn_id, text, status="completed"):
        threads[thread_id]["items"].append({"turnId": turn_id, "item": {
            "id": f"item_{turn_id}_answer", "type": "agentMessage", "phase": "final_answer", "text": text,
        }})
        write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": thread_id, "turnId": turn_id, "item": threads[thread_id]["items"][-1]["item"],
        }})
        write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": thread_id, "turn": {"id": turn_id, "status": status},
        }})

    def report_outcome(thread_id):
        instructions = threads[thread_id].get("instructions") or ""
        line = next((line.strip() for line in instructions.splitlines() if " task outcome " in line), None)
        if line:
            subprocess.run(shlex.split(line.replace("<completed|in-progress|waiting-response>", "completed")),
                           capture_output=True, text=True, timeout=60)

    def handle(message):
        method = message.get("method")
        params = message.get("params", {})
        if "id" not in message:
            return
        reply = lambda result: write({"jsonrpc": "2.0", "id": message["id"], "result": result})
        if method in ACCOUNT_METHODS:
            handle_account_request(message)
        elif method == "initialize":
            reply({"serverInfo": {"name": "playhouse-cpu-fixture", "version": "1"}})
        elif method == "model/list":
            reply({"data": [{"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True,
                             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]}]})
        elif method in ("thread/start", "thread/resume"):
            thread_id = params.get("threadId") or str(uuid.uuid4())
            thread = threads.setdefault(thread_id, {"items": []})
            thread["instructions"] = params.get("developerInstructions") or thread.get("instructions")
            reply({"thread": {"id": thread_id}, "model": params.get("model", "gpt-6-luna")})
        elif method == "thread/read":
            reply({"thread": {"id": params.get("threadId"), "turns": []}})
        elif method == "thread/turns/list":
            reply({"data": [], "nextCursor": None})
        elif method == "thread/items/list":
            reply({"data": threads.get(params.get("threadId"), {}).get("items", []), "nextCursor": None})
        elif method == "turn/start":
            thread_id = params.get("threadId")
            thread = threads.setdefault(thread_id, {"items": []})
            thread["instructions"] = (params.get("collaborationMode", {}).get("settings", {}).get("developerInstructions")
                                      or thread.get("instructions"))
            turn_id = f"turn-{uuid.uuid4()}"
            text = next((item.get("text") for item in params.get("input", []) if item.get("type") == "text"), "") or ""
            thread["items"].append({"turnId": turn_id, "item": {
                "id": f"item_{turn_id}_user", "type": "userMessage", "content": [{"type": "text", "text": text}],
            }})
            reply({"turn": {"id": turn_id, "status": "inProgress"}})
            match = CPU_ATTRIBUTION_TURN.search(text)
            if not match:
                finish(thread_id, turn_id, "Generated fixture title" if text.startswith("Write a concise task title") else "Done.")
                return
            seconds = float(match.group(2))
            # The child records its own real PID, parent PID and working
            # directory beside the fixture, so tests (including the sandboxed
            # UI runner, which can't list other processes) can verify where
            # and under which app-server it runs.
            record = ("import json, os, sys, time\n"
                      "path = sys.argv[3] + '.cpu-child-' + sys.argv[2] + '.json'\n"
                      "open(path + '.tmp', 'w').write(json.dumps("
                      "{'pid': os.getpid(), 'parentPID': os.getppid(), 'workingDirectory': os.getcwd()}))\n"
                      "os.replace(path + '.tmp', path)\n")
            code = record + (f"end = time.time() + {seconds}\nwhile time.time() < end:\n    pass\n"
                             if match.group(1).lower() == "burn" else f"time.sleep({seconds})\n")
            # The trailing arguments label the child and name its record file.
            child = subprocess.Popen(
                [sys.executable, "-c", code, "playhouse-cpu-attribution", match.group(1).lower(), sys.argv[0]],
                cwd=params.get("cwd") or os.getcwd(),
            )
            running[thread_id] = (turn_id, child, match.group(1).lower())
        elif method == "turn/interrupt":
            reply({})
            thread_id = params.get("threadId")
            if thread_id in running:
                turn_id, child, _ = running.pop(thread_id)
                child.kill()
                child.wait()
                finish(thread_id, turn_id, "Interrupted.", status="interrupted")
        else:
            reply({})

    while True:
        ready, _, _ = select.select([sys.stdin.fileno()], [], [], 0.05)
        if ready:
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                handle(message)
        for thread_id, (turn_id, child, kind) in list(running.items()):
            if child.poll() is not None:
                del running[thread_id]
                # A record exists only while its child runs, so cleanup never signals a reused PID.
                Path(f"{sys.argv[0]}.cpu-child-{'burn' if kind == 'burn' else 'idle'}.json").unlink(missing_ok=True)
                report_outcome(thread_id)
                finish(thread_id, turn_id, f"Finished the {kind} command.")
    for _, child, _ in running.values():
        child.kill()
    return 0


def run_reattach_server():
    """A small app-server for the daemon-restart cases (`-reattach` in the executable name).

    A turn writes "Before restart." and then holds, so the test can kill Playhouse's daemon
    while it runs. Marker files beside the executable drive it from there:
    `.reattach-raise` raises an approval and a question (left pending until a client answers),
    `.reattach-release` finishes the turn with "After restart." and its outcome,
    `.reattach-release-quiet` finishes it with "After restart." and no outcome report, and
    `.reattach-die` makes the server exit with the turn unfinished. For a standalone chat,
    `.reattach-close-turn` runs the turn's real `chat page close-turn` without ending the turn
    (a new page titled by the marker's text, or `--continues true` when it is empty), logging
    the command's result to `.reattach-close-turn-output`. `.reattach-ready` holds the running
    turn's thread, turn and prompt text. Every reply a client sends to a server request is
    logged to `.reattach-replies`, steers to `.reattach-steers`."""
    base = str(sys.argv[0])
    threads_path = Path(f"{base}.reattach-threads")
    active = {}
    buffer = b""

    def save_threads():
        # Like Codex's rollout files: a later server process reads what an earlier one wrote.
        threads_path.write_text(json.dumps(threads), encoding="utf-8")

    threads = {}
    if threads_path.is_file():
        threads = json.loads(threads_path.read_text(encoding="utf-8"))
        for thread in threads.values():
            for turn in thread["turns"]:
                if turn["status"] == "inProgress":
                    turn["status"] = "interrupted"

    def emit_message(thread_id, turn_id, item_id, text):
        item = {"id": item_id, "type": "agentMessage", "phase": "commentary", "text": text}
        write({"jsonrpc": "2.0", "method": "item/started", "params": {
            "threadId": thread_id, "turnId": turn_id, "item": {**item, "text": ""}}})
        write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
            "threadId": thread_id, "turnId": turn_id, "itemId": item_id, "delta": text}})
        write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": thread_id, "turnId": turn_id, "item": item}})
        threads[thread_id]["items"].append({"turnId": turn_id, "item": item})
        save_threads()

    def set_status(thread_id, turn_id, status):
        for turn in threads[thread_id]["turns"]:
            if turn["id"] == turn_id:
                turn["status"] = status
        save_threads()

    def report_outcome(thread_id):
        """Starts the turn's outcome report. Like a real tool call it runs while the server keeps
        answering: with no daemon up, the report starts one, which resumes this thread first."""
        instructions = threads[thread_id].get("instructions") or ""
        line = next((line.strip() for line in instructions.splitlines() if " task outcome " in line), None)
        if not line:
            return None
        return subprocess.Popen(shlex.split(line.replace("<completed|in-progress|waiting-response>", "waiting-response")),
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def complete(thread_id, status="completed"):
        turn_id = active.pop(thread_id)["turn"]
        set_status(thread_id, turn_id, status)
        write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": thread_id, "turn": {"id": turn_id, "status": status}}})

    def log(name, value):
        with open(f"{base}.{name}", "a", encoding="utf-8") as handle:
            handle.write(json.dumps(value) + "\n")

    def handle(message):
        method = message.get("method")
        params = message.get("params", {})
        if "id" in message and method is None:
            # A client's reply to a server request.
            log("reattach-replies", {"id": message["id"], "result": message.get("result"), "error": message.get("error")})
            for thread_id, turn in active.items():
                if message["id"] == turn.get("question") and message.get("result"):
                    answers = message["result"].get("answers", {})
                    answer = ", ".join(answers.get("color", {}).get("answers", []))
                    emit_message(thread_id, turn["turn"], f"item_{turn['turn']}_answer", f"Answer received: {answer}.")
            return
        if "id" not in message:
            return
        reply = lambda result: write({"jsonrpc": "2.0", "id": message["id"], "result": result})
        if method in ACCOUNT_METHODS:
            handle_account_request(message)
        elif method == "initialize":
            reply({"serverInfo": {"name": "playhouse-reattach-fixture", "version": "1"}})
        elif method == "model/list":
            reply({"data": [{"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True,
                             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]}]})
        elif method in ("thread/start", "thread/resume"):
            thread_id = params.get("threadId") or str(uuid.uuid4())
            thread = threads.setdefault(thread_id, {"items": [], "turns": []})
            thread["instructions"] = params.get("developerInstructions") or thread.get("instructions")
            if method == "thread/resume":
                log("reattach-resumes", {"threadId": thread_id, "excludeTurns": params.get("excludeTurns")})
            reply({"thread": {"id": thread_id, "turns": []}, "model": params.get("model", "gpt-6-luna")})
        elif method == "thread/turns/list":
            turns = threads.get(params.get("threadId"), {}).get("turns", [])
            reply({"data": list(reversed(turns))[:params.get("limit") or 50], "nextCursor": None})
        elif method == "thread/items/list":
            reply({"data": threads.get(params.get("threadId"), {}).get("items", []), "nextCursor": None})
        elif method == "turn/start":
            thread_id = params.get("threadId")
            thread = threads.setdefault(thread_id, {"items": [], "turns": []})
            turn_id = f"turn-{uuid.uuid4()}"
            text = next((item.get("text") for item in params.get("input", []) if item.get("type") == "text"), "") or ""
            thread["items"].append({"turnId": turn_id, "item": {
                "id": f"item_{turn_id}_user", "type": "userMessage", "content": [{"type": "text", "text": text}]}})
            thread["turns"].append({"id": turn_id, "status": "inProgress"})
            save_threads()
            reply({"turn": {"id": turn_id, "status": "inProgress"}})
            write({"jsonrpc": "2.0", "method": "turn/started", "params": {
                "threadId": thread_id, "turn": {"id": turn_id, "status": "inProgress"}}})
            if text.startswith("Write a concise task title") or "outcome nudge" in text.lower():
                emit_message(thread_id, turn_id, f"item_{turn_id}_answer", "Reattach fixture task")
                active[thread_id] = {"turn": turn_id, "reporting": None if text.startswith("Write") else report_outcome(thread_id)}
                if active[thread_id]["reporting"] is None:
                    complete(thread_id)
                return
            emit_message(thread_id, turn_id, f"item_{turn_id}_before", "Before restart.")
            active[thread_id] = {"turn": turn_id}
            Path(f"{base}.reattach-ready").write_text(json.dumps({"threadId": thread_id, "turnId": turn_id, "text": text}), encoding="utf-8")
        elif method == "turn/steer":
            thread_id = params.get("threadId")
            turn = active.get(thread_id)
            if not turn or params.get("expectedTurnId") != turn["turn"]:
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32010, "message": "The expected turn ID is stale."}})
                return
            text = "".join(item.get("text", "") for item in params.get("input", []) if item.get("type") == "text")
            log("reattach-steers", {"threadId": thread_id, "text": text})
            threads[thread_id]["items"].append({"turnId": turn["turn"], "item": {
                "id": f"item_steer_{uuid.uuid4()}", "type": "userMessage", "content": [{"type": "text", "text": text}]}})
            save_threads()
            reply({"turnId": turn["turn"]})
            # A question on a thread no conversation owns, raised while a client is connected: the
            # client must leave it for its owner rather than reject it.
            write({"jsonrpc": "2.0", "id": "question-foreign", "method": "item/tool/requestUserInput", "params": {
                "threadId": "thread-owned-by-no-conversation", "turnId": "turn-foreign", "itemId": "call-foreign", "isBlocking": True,
                "questions": [{"id": "color", "header": "Color", "question": "Which color?", "isOther": False,
                               "isSecret": False, "options": [{"label": "red"}]}]}})
        elif method == "turn/interrupt":
            reply({})
            thread_id = params.get("threadId")
            if thread_id in active:
                Path(f"{base}.reattach-interrupted").write_text("interrupted\n", encoding="utf-8")
                complete(thread_id, status="interrupted")
        else:
            reply({})

    while True:
        ready, _, _ = select.select([sys.stdin.fileno()], [], [], 0.05)
        if ready:
            chunk = os.read(sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    handle(json.loads(line))
                except json.JSONDecodeError:
                    continue
        for thread_id, turn in list(active.items()):
            raise_marker = Path(f"{base}.reattach-raise")
            if raise_marker.exists() and "question" not in turn:
                raise_marker.unlink()
                turn["approval"] = f"approval-{turn['turn']}"
                turn["question"] = f"question-{turn['turn']}"
                write({"jsonrpc": "2.0", "id": turn["approval"], "method": "item/commandExecution/requestApproval", "params": {
                    "threadId": thread_id, "turnId": turn["turn"], "itemId": f"exec-{turn['turn']}",
                    "command": "touch reattach-marker.txt", "cwd": os.getcwd()}})
                write({"jsonrpc": "2.0", "id": turn["question"], "method": "item/tool/requestUserInput", "params": {
                    "threadId": thread_id, "turnId": turn["turn"], "itemId": f"call-{turn['turn']}", "isBlocking": True,
                    "questions": [{"id": "color", "header": "Color", "question": "Which color?", "isOther": False,
                                   "isSecret": False, "options": [{"label": "red"}, {"label": "blue"}]}]}})
                Path(f"{base}.reattach-raised").write_text("raised\n", encoding="utf-8")
            close_turn_marker = Path(f"{base}.reattach-close-turn")
            if close_turn_marker.exists():
                title = close_turn_marker.read_text(encoding="utf-8").strip()
                close_turn_marker.unlink()
                instructions = threads[thread_id].get("instructions") or ""
                command = next((line.strip() for line in instructions.splitlines()
                                if " chat page close-turn " in line and "--continues true" in line), None)
                if command and title:
                    command = command.replace("--continues true", f"--continues false --new-title {shlex.quote(title)}")
                # Like a tool call, it runs while the server keeps answering: with no daemon up,
                # the command starts one, which resumes this thread first.
                turn["closing"] = (command, subprocess.Popen(shlex.split(command), stdout=subprocess.PIPE,
                                                             stderr=subprocess.DEVNULL, text=True) if command else None)
            if turn.get("closing") and (turn["closing"][1] is None or turn["closing"][1].poll() is not None):
                command, process = turn.pop("closing")
                log("reattach-close-turn-output", {
                    "command": command,
                    "returncode": process.returncode if process else None,
                    "output": process.stdout.read() if process else "",
                })
            if Path(f"{base}.reattach-die").exists():
                # Consumed, so a later server of the same fixture runs normally.
                Path(f"{base}.reattach-die").unlink(missing_ok=True)
                os._exit(3)
            quiet = Path(f"{base}.reattach-release-quiet")
            if quiet.exists() and "reporting" not in turn:
                quiet.unlink()
                emit_message(thread_id, turn["turn"], f"item_{turn['turn']}_after", "After restart.")
                turn["reporting"] = None
                complete(thread_id)
                continue
            release = Path(f"{base}.reattach-release")
            if release.exists() and "reporting" not in turn:
                release.unlink()
                emit_message(thread_id, turn["turn"], f"item_{turn['turn']}_after", "After restart.")
                turn["reporting"] = report_outcome(thread_id)
                if turn["reporting"] is None:
                    complete(thread_id)
            elif turn.get("reporting") is not None and turn["reporting"].poll() is not None:
                complete(thread_id)
    return 0


ACCOUNT_METHODS = ("account/read", "account/rateLimits/read", "account/login/start", "account/logout")


def account_rate_limits(used_primary, used_secondary):
    now = int(time.time())
    return {"limitId": "codex", "limitName": None, "planType": "plus", "rateLimitReachedType": None,
            "primary": {"usedPercent": used_primary, "windowDurationMins": 300, "resetsAt": now + 8040},
            "secondary": {"usedPercent": used_secondary, "windowDurationMins": 10080, "resetsAt": now + 4 * 86400},
            "credits": {"hasCredits": True, "unlimited": False, "balance": "12.50"}}


def handle_account_request(message):
    """The app-server account methods Playhouse's Agents info block uses. The
    account lives in `<executable>.account` so a test can sign it out or in."""
    state_path = Path(str(sys.argv[0]) + ".account")
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {
        "loggedIn": True, "email": "codex-fixture@example.com", "used": [30, 62]}
    method = message["method"]
    reply = lambda result: write({"jsonrpc": "2.0", "id": message["id"], "result": result})
    # A one-shot marker leaves the next account read unanswered, as a hung app-server would.
    hang = Path(os.environ.get("PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY", str(Path(sys.argv[0]).parent))) \
        / f"{Path(sys.argv[0]).name}.account-read-hang"
    if method == "account/read" and hang.is_file():
        hang.unlink(missing_ok=True)
        return
    if method == "account/read":
        account = {"type": "chatgpt", "email": state["email"], "planType": "plus"} if state["loggedIn"] else None
        reply({"account": account, "requiresOpenaiAuth": True})
    elif method == "account/rateLimits/read":
        if not state["loggedIn"]:
            write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32600, "message": "Not signed in."}})
            return
        snapshot = account_rate_limits(*state["used"])
        reply({"rateLimits": snapshot, "rateLimitsByLimitId": {"codex": snapshot}})
    elif method == "account/logout":
        state_path.write_text(json.dumps({"loggedIn": False, "email": None, "used": [0, 0]}), encoding="utf-8")
        reply({})
    elif method == "account/login/start":
        state = {"loggedIn": True, "email": "codex-second@example.com", "used": [7, 20]}
        state_path.write_text(json.dumps(state), encoding="utf-8")
        reply({"type": "chatgpt", "authUrl": "https://example.invalid/codex-login", "loginId": "fixture-login"})
        write({"jsonrpc": "2.0", "method": "account/login/completed",
               "params": {"success": True, "loginId": "fixture-login", "error": None}})
        write({"jsonrpc": "2.0", "method": "account/rateLimits/updated",
               "params": {"rateLimits": account_rate_limits(*state["used"])}})


# Real Codex runs a thread's commands in the cwd its thread and turn requests name. One shared
# socket app-server serves every task, so its own process cwd is whatever its first caller had.
THREAD_CWDS = {}
LAST_REQUESTED_CWD = None


def remember_thread_cwd(message):
    global LAST_REQUESTED_CWD
    params = message.get("params") or {}
    if message.get("method") in ("thread/start", "thread/resume", "turn/start") and params.get("cwd"):
        LAST_REQUESTED_CWD = params["cwd"]
        if params.get("threadId"):
            THREAD_CWDS[params["threadId"]] = params["cwd"]


def workspace_cwd():
    return (os.environ.get("PLAYHOUSE_FIXTURE_WORKSPACE") or THREAD_CWDS.get(THREAD_ID)
            or LAST_REQUESTED_CWD or os.getcwd())


class StdinLines:
    """Line reader over the stdio fd that keeps its own buffer, so a held turn can
    tell whether a request is waiting. Python's buffered `sys.stdin.readline()`
    pulls every message a write delivered into a buffer `select()` cannot see,
    which left a request that arrived together with another one unanswered until
    the hold ended."""

    def __init__(self, fd):
        self.fd = fd
        self.buffer = b""
        self.eof = False

    def fileno(self):
        return self.fd

    def has_line(self):
        return b"\n" in self.buffer or (self.eof and bool(self.buffer))

    def readline(self):
        while b"\n" not in self.buffer and not self.eof:
            chunk = os.read(self.fd, 65536)
            if chunk:
                self.buffer += chunk
            else:
                self.eof = True
        line, newline, self.buffer = self.buffer.partition(b"\n")
        return (line + newline).decode("utf-8")

    def __iter__(self):
        while True:
            line = self.readline()
            if not line:
                return
            yield line


def stdin_select(timeout):
    """`select.select([sys.stdin], [], [], timeout)` that also counts a line already buffered."""
    if isinstance(sys.stdin, StdinLines) and sys.stdin.has_line():
        return [sys.stdin], [], []
    return select.select([sys.stdin], [], [], timeout)


def main():
    global THREAD_ID, TURN_ID
    if "-cpu-attribution" in os.path.basename(sys.argv[0]):
        return run_cpu_attribution_server()
    if "-reattach" in os.path.basename(sys.argv[0]):
        return run_reattach_server()
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
    # `-single-server` modes: the turn Codex runs for each thread's active Goal.
    goal_turns = {}
    saw_question = False
    saw_turn = False
    turn_message = None
    history_path = Path(str(sys.argv[0]) + ".history")
    fixture_state_directory = Path(os.environ.get("PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY", str(Path(sys.argv[0]).parent)))
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
        remember_thread_cwd(message)
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
        if message.get("method") in ACCOUNT_METHODS and "id" in message:
            handle_account_request(message)
            return
        if message.get("method") == "initialized":
            return
        if "method" in message and "id" not in message:
            return
        if handle_side_chat(message, history_path):
            return
        if message.get("method") == "initialize":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"serverInfo": {"name": "playhouse-fixture", "version": "1"}}})
        elif message.get("method") == "model/list":
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
            models_override = Path(str(sys.argv[0]) + ".models-override")
            if models_override.exists():
                models = json.loads(models_override.read_text(encoding="utf-8"))
            if Path(str(sys.argv[0]) + ".models-delay").exists():
                time.sleep(1)
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"data": models}})
        elif message.get("method") == "mcpServerStatus/list":
            # The servers a test seeds in `<executable>.mcp-status`, as Codex lists
            # the ones its own configuration defines.
            # `<executable>.mcp-status-fail` makes the request fail, as when Codex can't be asked.
            if Path(str(sys.argv[0]) + ".mcp-status-fail").exists():
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": "Fixture MCP status is unavailable."}})
                return
            seeded = Path(str(sys.argv[0]) + ".mcp-status")
            servers = json.loads(seeded.read_text(encoding="utf-8")) if seeded.exists() else []
            # A sign-in finishes when a test writes the server's name to
            # `<executable>.mcp-callback`, as the browser's redirect would.
            callback = Path(str(sys.argv[0]) + ".mcp-callback")
            signed_in = set(callback.read_text(encoding="utf-8").split("\n")) if callback.exists() else set()
            servers = [{**server, "authStatus": "oAuth"} if server.get("name") in signed_in and server.get("authStatus") == "notLoggedIn" else server
                       for server in servers]
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"data": servers, "nextCursor": None}})
        elif message.get("method") == "mcpServer/oauth/login":
            # Codex's sign-in start: the link to open. Each start is logged.
            name = message.get("params", {}).get("name")
            with open(str(sys.argv[0]) + ".mcp-login", "a", encoding="utf-8") as starts:
                starts.write(json.dumps({"name": name}) + "\n")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {
                "authorizationUrl": f"https://auth.example.test/codex/authorize?server={name}", "loginId": f"fixture-login-{name}"}})
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
            if "-single-server" in mode:
                # Like Codex, the server tells every client on it that the Goal changed, starts
                # a work turn for an active Goal, and ends it when the Goal is paused.
                write({"jsonrpc": "2.0", "method": "thread/goal/updated",
                       "params": {"threadId": goal["threadId"], "goal": goal}})
                goal_thread = goal["threadId"]
                if goal["status"] == "active" and goal_thread not in goal_turns:
                    goal_turns[goal_thread] = f"turn-goal-{uuid.uuid4()}"
                    write({"jsonrpc": "2.0", "method": "turn/started", "params": {
                        "threadId": goal_thread, "turn": {"id": goal_turns[goal_thread], "status": "inProgress"}}})
                elif goal["status"] != "active" and goal_thread in goal_turns:
                    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                        "threadId": goal_thread, "turn": {"id": goal_turns.pop(goal_thread), "status": "completed"}}})
        elif "-goal" in mode and message.get("method") == "thread/goal/clear":
            goal_path.unlink(missing_ok=True)
            write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
            if "-single-server" in mode:
                goal_thread = message.get("params", {}).get("threadId")
                write({"jsonrpc": "2.0", "method": "thread/goal/cleared", "params": {"threadId": goal_thread}})
                if goal_thread in goal_turns:
                    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                        "threadId": goal_thread, "turn": {"id": goal_turns.pop(goal_thread), "status": "completed"}}})
        elif message.get("method") == "skills/extraRoots/set":
            # Records the bridged skill folders Playhouse hands the shared app-server.
            history = serial_history()
            history["skillExtraRoots"] = message.get("params", {}).get("extraRoots", [])
            history["skillExtraRootsCalls"] = history.get("skillExtraRootsCalls", 0) + 1
            history_path.write_text(json.dumps(history), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
        elif message.get("method") == "thread/start":
            # `-single-server` modes run several tasks' threads on one server.
            if "-question-isolation-" in mode or "-single-server" in mode:
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
                    "threadStartConfig": message.get("params", {}).get("config"),
                    "threadStartCwd": message.get("params", {}).get("cwd"),
                    "threadStartRuntimeWorkspaceRoots": message.get("params", {}).get("runtimeWorkspaceRoots", []),
                    "threadStartCount": history.get("threadStartCount", 0) + 1,
                })
                history_path.write_text(json.dumps(history), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": message.get("params", {}).get("model", "gpt-6-luna")}})
        elif message.get("method") == "thread/resume":
            if "-question-isolation-" in mode or "-single-server" in mode:
                THREAD_ID = message["params"]["threadId"]
            if "-single-server" in mode:
                with open(fixture_state_directory / f"{Path(sys.argv[0]).name}.resumes", "a", encoding="utf-8") as handle:
                    handle.write(json.dumps({"threadId": THREAD_ID, "model": message["params"].get("model")}) + "\n")
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
                    "threadResumeConfig": message.get("params", {}).get("config"),
                })
                history.setdefault("threadResumeDeveloperInstructions", []).append(
                    message.get("params", {}).get("developerInstructions")
                )
                history_path.write_text(json.dumps(history), encoding="utf-8")
            resumed_model = message.get("params", {}).get("model", "gpt-6-luna")
            # Codex ignores the requested model when it still has the thread open (a
            # turn on it just ended) and reports the thread's own; a one-shot marker
            # names the model that loaded thread keeps.
            kept_model = Path(str(sys.argv[0]) + ".resume-keeps-model")
            if kept_model.is_file():
                history = serial_history()
                history.setdefault("threadResumeKeptModels", []).append(
                    {"requested": resumed_model, "reported": kept_model.read_text(encoding="utf-8").strip()}
                )
                history_path.write_text(json.dumps(history), encoding="utf-8")
                resumed_model = history["threadResumeKeptModels"][-1]["reported"]
                kept_model.unlink(missing_ok=True)
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": resumed_model}})
        elif message.get("method") == "turn/start":
            if "-single-server" in mode:
                THREAD_ID = message["params"]["threadId"]
                TURN_ID = f"turn-{uuid.uuid4()}"
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
            is_outcome_reminder = "playhouse internal outcome nudge:" in (turn_message or "").lower()
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
                        "id": "item_playhouse_title",
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
            is_pull_request_summary_request = (turn_message or "").startswith("Write a very concise GitHub pull request description.")
            if is_pull_request_summary_request:
                # A one-shot helper turn (Auto PR's pull-request description), not an
                # interactive conversation: answer directly instead of asking a question.
                write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "item": {
                        "id": "item_playhouse_pr_summary",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "text": "Fixture pull request summary.",
                    },
                }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
                return
            if "-token-waste" in mode:
                write_waste_rollouts(turn_thread_id)
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
                "skillInputs": [item for item in turn_input if item.get("type") == "skill"],
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
            if is_outcome_reminder and "nudged-work" in mode:
                # The nudge says to keep working when work remains, so this turn
                # streams commentary and a shell check, answers, and only then
                # reports completed, all inside the private status nudge.
                saved = serial_history()
                instructions = (
                    turn_history.get("developerInstructions")
                    or saved.get("threadStartDeveloperInstructions")
                    or ((saved.get("threadResumeDeveloperInstructions") or [None])[-1])
                    or ""
                )
                write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
                if Path(str(sys.argv[0]) + ".nudged-steer-pause").exists():
                    # The test steers this running nudge turn, as a user can.
                    Path(str(sys.argv[0]) + ".nudged-steer-ready").write_text("The nudged turn is waiting for a steer.\n", encoding="utf-8")
                    steered_text = None
                    steer_deadline = time.monotonic() + 60
                    while steered_text is None and time.monotonic() < steer_deadline:
                        readable, _, _ = stdin_select(0.02)
                        if not readable:
                            continue
                        try:
                            incoming = json.loads(sys.stdin.readline())
                        except json.JSONDecodeError:
                            continue
                        if incoming.get("method") != "turn/steer":
                            answer_read_while_held(incoming)
                            continue
                        steer_params = incoming.get("params", {})
                        if steer_params.get("threadId") != THREAD_ID or steer_params.get("expectedTurnId") != TURN_ID:
                            write({"jsonrpc": "2.0", "id": incoming["id"], "error": {"code": -32000, "message": "No matching active turn."}})
                            continue
                        steered_text = "\n".join(item.get("text", "") for item in steer_params.get("input", []) if item.get("type") == "text")
                        write({"jsonrpc": "2.0", "id": incoming["id"], "result": {"turnId": TURN_ID}})
                        steered_history = serial_history()
                        steered_history["steerRequests"] = steered_history.get("steerRequests", []) + [steer_params]
                        history_path.write_text(json.dumps(steered_history), encoding="utf-8")
                    if steered_text is None:
                        os._exit(3)
                    # One steer per pause: a later nudge in the same conversation keeps working
                    # instead of waiting out the steer deadline.
                    Path(str(sys.argv[0]) + ".nudged-steer-pause").unlink(missing_ok=True)
                    Path(str(sys.argv[0]) + ".nudged-steer-ready").unlink(missing_ok=True)
                for item in nudged_work_items(len(saved.get("turns", [])) - 1):
                    if item["type"] == "commandExecution":
                        write({"jsonrpc": "2.0", "method": "item/started", "params": {
                            "threadId": THREAD_ID, "turnId": TURN_ID, "item": {**item, "status": "inProgress"},
                        }})
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID, "item": item,
                    }})
                outcome_line = next((line.strip() for line in instructions.splitlines() if " task outcome " in line), None)
                if outcome_line:
                    completed = subprocess.run(
                        shlex.split(outcome_line.replace("<completed|in-progress|waiting-response>", "completed")),
                        capture_output=True, text=True, timeout=60,
                    )
                    if completed.returncode != 0:
                        raise RuntimeError(f"Fixture task outcome command failed: {completed.stderr.strip()}")
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"}}})
                return
            if is_outcome_reminder and not preserve_no_outcome:
                # A fixture that only ever resumed an existing thread has no
                # thread-start instructions of its own; its outcome command
                # lives in the resume instructions Playhouse sent instead.
                saved = serial_history()
                instructions = (
                    turn_history.get("developerInstructions")
                    or saved.get("threadStartDeveloperInstructions")
                    or ((saved.get("threadResumeDeveloperInstructions") or [None])[-1])
                    or ""
                )
                # Command lines start with the quoted CLI path; prose (such as a chat's note
                # that task outcomes don't apply to it) may mention the same words.
                outcome_line = next((line.strip() for line in instructions.splitlines()
                                     if line.strip().startswith("'") and " task outcome " in line), None)
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
                "Classify the latest user message for Playhouse's continuous chat page index."
            ):
                # One-shot Codex helper clients consume the streamed completion
                # directly; provide the same fixture answer the transcript path
                # returns for ordinary conversation turns.
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "turnId": TURN_ID,
                    "item": {
                        "id": "item_playhouse_chat_classifier",
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
                # Report one activity before holding, so a user-initiated Stop with
                # no final answer still keeps the window's activity section mounted
                # and the fold it performs on settle is distinguishable from the
                # section simply never having rendered.
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {
                        "id": "item_fixture_stop_command",
                        "type": "commandExecution",
                        "command": "git status --short",
                        "cwd": workspace_cwd(),
                    },
                }})
                active = Path(str(sys.argv[0]) + ".interrupt-ready")
                active.write_text("The fixture turn is active and waiting for an interrupt.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                received_interrupt = False
                while time.monotonic() < deadline:
                    ready, _, _ = stdin_select(0.02)
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
                            "item": {"id": "item_playhouse_message", "type": "agentMessage", "text": "The turn completed after Stop was rejected."},
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
            elif mode.endswith("-success") or mode.endswith("-timeline-tool-calls"):
                # A timeline turn's items come from its thread history, not its stream.
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
                        "id": "item_playhouse_async_followup",
                        "type": "agentMessage", "phase": "final_answer",
                        "text": "I can continue while you decide.",
                    }]
                else:
                    items = [{
                        "id": "item_playhouse_async_answer",
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
                        readable, _, _ = stdin_select(0.02)
                        if not readable:
                            continue
                        incoming = json.loads(sys.stdin.readline())
                        if incoming.get("method") == "thread/items/list":
                            entries = []
                            for index, saved_turn in enumerate(serial_history().get("messages", []), start=1):
                                turn_id = saved_turn["turnID"]
                                entries.append({"turnId": turn_id, "item": {
                                    "id": f"item_playhouse_async_user_{index}", "type": "userMessage",
                                    "content": [{"type": "text", "text": saved_turn["userMessage"]}],
                                }})
                                if index == 1:
                                    entries.extend([
                                        {"turnId": turn_id, "item": async_question_item()},
                                        {"turnId": turn_id, "item": {
                                            "id": "item_playhouse_async_followup", "type": "agentMessage",
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
                            "id": "item_playhouse_async_answer_steered", "type": "agentMessage", "phase": "final_answer",
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
                    readable, _, _ = stdin_select(0.02)
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
                    readable, _, _ = stdin_select(0.02)
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
            elif mode.endswith("-follow-active-turn"):
                # Holds before any output, so a test can reopen the conversation first,
                # then again while commentary and a running command are visible.
                Path(str(sys.argv[0]) + ".follow-turn-done").unlink(missing_ok=True)
                for stage, description in [("started", "Codex turn started without output."),
                                           ("ready", "Codex turn shows progress and a running command.")]:
                    if stage == "ready":
                        for item in follow_turn_items(finished=False):
                            write({"jsonrpc": "2.0", "method": "item/started", "params": {
                                "threadId": THREAD_ID, "turnId": TURN_ID,
                                "item": {**item, "text": ""} if item["type"] == "agentMessage" else item,
                            }})
                            if item["type"] == "agentMessage":
                                write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
                                    "threadId": THREAD_ID, "turnId": TURN_ID, "itemId": item["id"], "delta": item["text"],
                                }})
                                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                                    "threadId": THREAD_ID, "turnId": TURN_ID, "item": item,
                                }})
                    ready = Path(str(sys.argv[0]) + f".follow-turn-{stage}")
                    release = Path(str(sys.argv[0]) + (".follow-turn-continue" if stage == "started" else ".follow-turn-release"))
                    ready.write_text(f"{description}\n", encoding="utf-8")
                    deadline = time.monotonic() + 60
                    while not release.exists() and time.monotonic() < deadline:
                        drain_pending_stdin()
                        time.sleep(0.02)
                    if not release.exists():
                        os._exit(3)
                    if stage == "ready":
                        Path(str(sys.argv[0]) + ".follow-turn-done").touch()
                    ready.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                for item in follow_turn_items(finished=True)[1:]:
                    if item["type"] == "agentMessage":
                        write({"jsonrpc": "2.0", "method": "item/started", "params": {
                            "threadId": THREAD_ID, "turnId": TURN_ID, "item": {**item, "text": ""},
                        }})
                        write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
                            "threadId": THREAD_ID, "turnId": TURN_ID, "itemId": item["id"], "delta": item["text"],
                        }})
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID, "item": item,
                    }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed"}}})
            elif mode.endswith("-context-compaction"):
                compaction_item = {"id": "item_playhouse_compaction", "type": "contextCompaction", "payload": {"opaque": "COMPACTION_OPAQUE_SENTINEL"}}
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
                item = {"id": "item_playhouse_final", "type": "agentMessage", "phase": "final_answer", "text": "Context compaction completed."}
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
                        "cwd": "/tmp/playhouse-fixture", "status": "inProgress",
                    }
                    for tool_item in [mcp_item, dynamic_item, legacy_dynamic_item, active_command_item]:
                        write({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": THREAD_ID, "item": tool_item}})
                    ready = Path(str(sys.argv[0]) + ".tool-ready")
                    release = Path(str(sys.argv[0]) + ".tool-release")
                    ready.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                    Path(str(sys.argv[0]) + ".tool-active-command-completed").unlink(missing_ok=True)
                    Path(str(sys.argv[0]) + ".tool-others-completed").unlink(missing_ok=True)
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
                    # A concurrent `thread/items/list` read (a second CLI call, or a
                    # reopened window resubscribing to this same thread) rebuilds its
                    # snapshot from scratch rather than sharing this process's live
                    # state; mark what has actually completed so that snapshot can
                    # tell genuinely in-progress items from settled ones.
                    Path(str(sys.argv[0]) + ".tool-active-command-completed").write_text("done\n", encoding="utf-8")
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
                    Path(str(sys.argv[0]) + ".tool-others-completed").write_text("done\n", encoding="utf-8")
                for action_item in diagnostic_action_items(workspace_cwd()):
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
                for phase, item_id, text in [("commentary", "item_playhouse_commentary", progress_text)]:
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
                phase, item_id, text = ("final_answer", "item_playhouse_final", "The subagent inspected the project structure.")
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
                plan_item_id = "item_playhouse_plan"
                is_plan_turn = message.get("params", {}).get("collaborationMode", {}).get("mode") == "plan"
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {"id": plan_item_id, "type": "plan", "text": ""},
                }})
                for stage, delta in enumerate(markdown_plan_deltas(), start=1):
                    write({"jsonrpc": "2.0", "method": "item/plan/delta", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID,
                        "itemId": plan_item_id, "delta": delta,
                    }})
                    # Every delta but the last can be held, so a test sees the plan at each stage.
                    if stage < 4 and is_plan_turn and Path(str(sys.argv[0]) + ".plan-delta-hold").exists():
                        ready = Path(str(sys.argv[0]) + f".plan-delta-ready-{stage}")
                        release = Path(str(sys.argv[0]) + f".plan-delta-release-{stage}")
                        ready.write_text(f"Plan delta {stage} is visible before completion.\n", encoding="utf-8")
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
                        "item": {"id": "item_playhouse_echoed_outcome", "type": "agentMessage", "phase": "final_answer", "text": echoed},
                    }})
                turn_error = {"error": {"message": "Codex interrupted this turn." if turn_status == "interrupted" else "Codex failed this turn."}} if turn_status != "completed" else {}
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "00000000-0000-0000-0000-000000000001",
                    "turn": {"id": TURN_ID, "status": turn_status, **turn_error},
                }})
            else:
                if mode.endswith("-interrupted"):
                    # An interrupted turn keeps the activity it already reported, so
                    # the window still renders its activity section after the turn
                    # settles and can be checked for folding rather than vanishing.
                    write({"jsonrpc": "2.0", "method": "item/started", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID,
                        "item": {
                            "id": "item_fixture_interrupted_command",
                            "type": "commandExecution",
                            "command": "git status --short",
                            "cwd": workspace_cwd(),
                        },
                    }})
                question_request(901)
        elif message.get("id") in {901, 902} or message.get("id") in question_contexts:
            if "-question-isolation-" in mode:
                THREAD_ID, TURN_ID = question_contexts.pop(message["id"])
            if "error" in message:
                answers = None
                rejection_message = message.get("error", {}).get("message", "")
                if "private Playhouse status nudge" in rejection_message:
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
                            "id": "item_playhouse_echoed_outcome",
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
            if message.get("params", {}).get("threadId") == THREAD_ID and TURN_ID:
                # A client that reconnects mid-turn learns the turn is still running.
                held = Path(str(sys.argv[0]) + ".interrupt-ready").exists()
                write({"jsonrpc": "2.0", "id": message["id"], "result": {
                    "data": [{"id": TURN_ID, "status": "inProgress" if held else "completed"}],
                    "nextCursor": None,
                }})
                return
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
                chat_turns = [
                    saved_turn for saved_turn in saved_history.get("messages", [])
                    if not is_page_classifier_prompt(saved_turn.get("userMessage"))
                ]
                for index, saved_turn in enumerate(chat_turns, start=1):
                    turn_id = saved_turn["turnID"]
                    entries.append({"turnId": turn_id, "item": {
                        "id": f"item_playhouse_async_user_{index}",
                        "type": "userMessage",
                        "content": [{"type": "text", "text": saved_turn["userMessage"]}],
                    }})
                    if index == 1:
                        entries.extend([
                            {"turnId": turn_id, "item": async_question_item()},
                            {"turnId": turn_id, "item": {
                                "id": "item_playhouse_async_followup",
                                "type": "agentMessage", "phase": "final_answer",
                                "text": "I can continue while you decide.",
                            }},
                        ])
                        if saved_turn.get("steeredAnswer"):
                            entries.extend([
                                {"turnId": turn_id, "item": {
                                    "id": "item_playhouse_async_steered_user", "type": "userMessage",
                                    "content": [{"type": "text", "text": saved_turn["steeredAnswer"]}],
                                }},
                                {"turnId": turn_id, "item": {
                                    "id": "item_playhouse_async_answer_steered", "type": "agentMessage", "phase": "final_answer",
                                    "text": f"Answers received: {saved_turn['steeredAnswer']}",
                                }},
                                {"turnId": turn_id, "item": later_async_question_item()},
                            ])
                    else:
                        entries.append({"turnId": turn_id, "item": {
                            "id": f"item_playhouse_async_answer_{index}",
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
                    if is_page_classifier_prompt(user_message):
                        continue
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
                    if is_page_classifier_prompt(user_message):
                        continue
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
                        if mode.endswith("-hold-release") and "playhouse internal outcome nudge:" not in (user_message or "").lower():
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
                    {"id": "item_playhouse_commentary", "type": "agentMessage", "phase": "commentary", "text": "I inspected the project structure and am preparing the summary."},
                    {"id": "item_playhouse_final", "type": "agentMessage", "phase": "final_answer", "text": "The subagent inspected the project structure."},
                    subagent_item("completed"),
                    subagent_activity("completed", CHILD_THREAD_ID, "/agents/Sandbox review", model="gpt-6-sol", reasoning_effort="high"),
                    subagent_activity("interrupted", "00000000-0000-0000-0000-000000000003", "/agents/some_agent"),
                    subagent_activity("futureKind", "00000000-0000-0000-0000-000000000004", "/agents/Future review"),
                    *diagnostic_action_items(workspace_cwd()),
                ]
            if mode.endswith("-context-compaction"):
                contents = [
                    {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Compact the context."}]},
                    {"id": "item_playhouse_compaction", "type": "contextCompaction", "payload": {"opaque": "COMPACTION_OPAQUE_SENTINEL"}},
                    {"id": "item_playhouse_final", "type": "agentMessage", "phase": "final_answer", "text": "Context compaction completed."},
                ]
            if mode.endswith("-follow-active-turn"):
                # A running turn's history holds the items it has reported so far.
                contents = [{"id": "item_user_fixture", "type": "userMessage",
                             "content": [{"type": "text", "text": saved_history.get("userMessage") or ""}]}]
                if Path(str(sys.argv[0]) + ".follow-turn-done").exists():
                    contents.extend(follow_turn_items(finished=True))
                elif Path(str(sys.argv[0]) + ".follow-turn-ready").exists():
                    contents.extend(follow_turn_items(finished=False))
            if "-long-history-" in mode:
                contents = []
                if "-with-prompt-" in mode:
                    # The sent prompt is the first stored user message, outside the newest history page.
                    contents.append({"id": "item_sent_prompt", "type": "userMessage", "content": [{"type": "text", "text": "Create a long history."}]})
                for index in range(1, 61):
                    contents.append({"id": f"item_long_history_user_{index}", "type": "userMessage", "content": [{"type": "text", "text": f"Long history user {index:02d}."}]})
                    if index == 21 and "-lazy-" in mode:
                        # A mid-history call whose output runs past the clipped lines, so the UI can
                        # expand it and check it stays expanded after its row is rendered lazily again.
                        contents.append({"id": "item_long_history_command_21", "type": "commandExecution", "command": "ls fixture-history",
                                         "cwd": "/tmp/playhouse-fixture", "status": "completed", "exitCode": 0, "durationMs": 5,
                                         "aggregatedOutput": "".join(f"history-file-{line}.txt\n" for line in range(1, 7))})
                    contents.append({"id": f"item_long_history_assistant_{index}", "type": "agentMessage", "phase": "final_answer", "text": f"Long history assistant {index:02d}."})
            if mode.endswith("-tool-activity"):
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
                contents = [{"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Show tool activity."}]}]
                # Read the completion markers the held turn writes so this snapshot
                # reports the calls still in progress accurately, instead of
                # always answering with their eventual terminal state.
                others_completed = Path(str(sys.argv[0]) + ".tool-others-completed").is_file()
                latest_completed = Path(str(sys.argv[0]) + ".tool-active-command-completed").is_file()
                if others_completed:
                    contents.extend([
                        {"id": "item_fixture_mcp_call", "type": "mcpToolCall", "server": "fixture-server", "tool": "lookup", "status": "completed", "arguments": {"token": "RAW_ARGUMENT_SECRET"}, "result": {"content": [{"type": "text", "text": "RAW_RESULT_SECRET"}]}},
                        {"id": "item_fixture_dynamic_call", "type": "dynamicToolCall", "tool": "summarize", "status": "failed", "arguments": {"prompt": "RAW_ARGUMENT_SECRET"}, "success": False, "durationMs": 37},
                        {"id": "item_fixture_dynamic_legacy", "type": "dynamicToolCall", "tool": "legacySummary", "status": "completed", "arguments": {"input": "RAW_ARGUMENT_SECRET"}, "success": True, "contentItems": [{"type": "inputText", "text": "RAW_RESULT_SECRET"}]},
                    ])
                else:
                    contents.extend([
                        {"id": "item_fixture_mcp_call", "type": "mcpToolCall", "server": "fixture-server", "tool": "lookup", "status": "inProgress", "arguments": {"token": "RAW_ARGUMENT_SECRET"}},
                        {"id": "item_fixture_dynamic_call", "type": "dynamicToolCall", "tool": "summarize", "status": "inProgress", "arguments": {"prompt": "RAW_ARGUMENT_SECRET"}},
                        {"id": "item_fixture_dynamic_legacy", "type": "dynamicToolCall", "tool": "legacySummary", "status": "inProgress", "arguments": {"input": "RAW_ARGUMENT_SECRET"}},
                    ])
                contents.append({
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
                    contents.extend([
                        {"id": "item_user_fixture_later", "type": "userMessage", "content": [{"type": "text", "text": "A later turn starts."}]},
                        {"id": "item_assistant_fixture_later", "type": "agentMessage", "text": "Later turn response."},
                    ])
            if mode.endswith("-markdown"):
                saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
                contents = [
                    {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": saved_history.get("userMessage", "Plan the task.")} ]},
                    {"id": "item_playhouse_plan", "type": "plan", "text": MARKDOWN_PLAN},
                ]
            entries = []
            saved_turns = saved_history.get("messages") or saved_history.get("turns") or []
            ordinary_turn_indexes = [
                index for index, saved_turn in enumerate(saved_turns)
                if "playhouse internal outcome nudge:" not in (saved_turn.get("userMessage") or "").lower()
            ]
            if mode.endswith("-timeline-tool-calls"):
                # Each ordinary turn as its thread items: the tool-call turn reports
                # commentary, shell commands with their output (one failing), and an
                # MCP call whose arguments and result stay private, between its messages.
                contents = []
                for turn_index in ordinary_turn_indexes:
                    user_message = saved_turns[turn_index].get("userMessage") or ""
                    suffix = f"t{turn_index}"
                    turn_items = [{"id": f"item_timeline_user_{suffix}", "type": "userMessage",
                                   "content": [{"type": "text", "text": user_message}]}]
                    if "show-tool-calls-inline" in user_message.lower():
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
                    contents += [{**item, "_fixture_turn_index": turn_index} for item in turn_items]
            for turn_index, saved_turn in enumerate(saved_turns, start=1):
                if is_page_classifier_prompt(saved_turn.get("userMessage")):
                    continue
                if (
                    "hold-release" in os.path.basename(sys.argv[0])
                    and "playhouse internal outcome nudge:" in (saved_turn.get("userMessage") or "").lower()
                ):
                    # A status-only nudge: its one call is Playhouse's own outcome
                    # report, which is bookkeeping, so the whole turn stays private.
                    contents.append({
                        "id": f"item_private_reminder_activity_{turn_index}",
                        "type": "commandExecution",
                        "command": f"'/fixture/playhouse-cli' task outcome {turn_index} waiting-response",
                        "cwd": "/tmp/playhouse-fixture",
                        "status": "completed",
                        "exitCode": 0,
                        "durationMs": 11,
                        "_fixture_turn_index": turn_index - 1,
                    })
            if "nudged-work" in mode:
                # Each saved turn as its own thread items. A status nudge that went
                # on to work holds commentary, a shell check, and its answer.
                contents = []
                for turn_index, saved_turn in enumerate(saved_turns):
                    user_message = saved_turn.get("userMessage") or ""
                    turn_items = [{"id": f"item_nudged_user_{turn_index}", "type": "userMessage",
                                   "content": [{"type": "text", "text": user_message}]}]
                    if "playhouse internal outcome nudge:" in user_message.lower():
                        # A message the user steered into this nudge turn follows its prompt.
                        for steer in saved_history.get("steerRequests", []):
                            if steer.get("expectedTurnId") == saved_turn.get("turnID"):
                                turn_items.append({"id": f"item_nudged_steer_{turn_index}", "type": "userMessage",
                                                   "content": [item for item in steer.get("input", []) if item.get("type") == "text"]})
                        turn_items += nudged_work_items(turn_index)
                    else:
                        turn_items.append({"id": f"item_nudged_answer_{turn_index}", "type": "agentMessage",
                                           "phase": "final_answer", "text": answer_text(user_message)})
                    contents += [{**item, "_fixture_turn_index": turn_index} for item in turn_items]
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
                if "-long-history-lazy-" in mode and item_id.startswith("item_long_history_"):
                    # Each history turn is its own turn, as in a real multi-turn thread, so the app
                    # treats every turn but the last as settled and shows its calls inline.
                    turn_id = f"turn_long_history_{item_id.rsplit('_', 1)[1]}"
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
    answer_while_held = {"initialize", "initialized", "thread/items/list", "thread/turns/list", "thread/read",
                         "thread/resume", "model/list", "thread/goal/get", *ACCOUNT_METHODS}
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
            ready, _, _ = stdin_select(0)
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


def listen_path():
    """The socket path of `--listen unix://PATH`, or None for stdio."""
    arguments = sys.argv[1:]
    for index, argument in enumerate(arguments):
        value = arguments[index + 1] if argument == "--listen" and index + 1 < len(arguments) else None
        if argument.startswith("--listen="):
            value = argument.split("=", 1)[1]
        if value and value.startswith("unix://"):
            return value[len("unix://"):]
    return None


def serve_unix_socket(path):
    """`--listen unix://PATH`: the real app-server's shared-server mode, as Playhouse's daemon
    uses it. This front end speaks WebSocket (RFC 6455) on a Unix socket and runs the stdio
    fixture as its child, so every fixture mode works unchanged over the socket. Like Codex it
    accepts several connections and keeps running while none is open: a turn carries on, its
    notifications are dropped, and the server requests it raised (approvals, questions) wait
    for the next client and are sent again once that client resumes the thread."""
    import base64
    import hashlib
    import signal
    import socket
    import struct

    arguments = sys.argv[1:]
    child_arguments, skip = [], False
    for index, argument in enumerate(arguments):
        if skip:
            skip = False
            continue
        if argument == "--listen":
            skip = True
            continue
        if argument.startswith("--listen="):
            continue
        child_arguments.append(argument)
    child = subprocess.Popen([sys.executable, sys.argv[0], *child_arguments, "--listen", "stdio://"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    signal.signal(signal.SIGTERM, lambda *_: (child.kill(), os._exit(0)))
    log_path = Path(str(sys.argv[0]) + ".socket-log")

    def log(entry):
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"time": time.time(), **entry}) + "\n")

    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(8)
    log({"event": "listening", "pid": os.getpid()})

    class Connection:
        counter = 0

        def __init__(self, sock):
            Connection.counter += 1
            self.id = Connection.counter
            self.sock = sock
            self.buffer = b""
            self.message = b""
            self.open = False

    connections = []
    child_buffer = b""
    next_id = [1_000_000]
    client_requests = {}  # child request id -> (connection, client id, method, params)
    # Codex gives every server request its own id. The stdio fixture reuses a few (901, 902), so
    # the front end renumbers them: a late reply to an earlier question can't answer a newer one.
    server_request_child_ids = {}  # relay id -> the child's own request id
    next_server_request_id = [500000]
    pending_server_requests = {}  # server request id -> message, until a client answers it

    def send_frame(connection, payload, opcode=1):
        header = bytes([0x80 | opcode])
        if len(payload) < 126:
            header += bytes([len(payload)])
        elif len(payload) < 65536:
            header += bytes([126]) + struct.pack(">H", len(payload))
        else:
            header += bytes([127]) + struct.pack(">Q", len(payload))
        try:
            connection.sock.sendall(header + payload)
        except OSError:
            close(connection)

    def send_json(connection, value):
        send_frame(connection, json.dumps(value, separators=(",", ":")).encode())

    def close(connection):
        if connection in connections:
            connections.remove(connection)
            log({"event": "disconnected", "connection": connection.id})
        try:
            connection.sock.close()
        except OSError:
            pass

    def from_client(connection, message):
        if "method" in message and "id" in message:
            child_id = next_id[0]
            next_id[0] += 1
            client_requests[child_id] = (connection, message["id"], message["method"], message.get("params") or {})
            message = {**message, "id": child_id}
        elif "id" in message and ("result" in message or "error" in message):
            # The first answer to a server request wins; a late duplicate from another client is dropped.
            log({"event": "client_reply", "connection": connection.id, "id": message["id"],
                 "forwarded": message["id"] in pending_server_requests})
            if pending_server_requests.pop(message["id"], None) is None:
                return
            message = {**message, "id": server_request_child_ids.pop(message["id"])}
        child.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        child.stdin.flush()

    def from_child(message):
        if "method" not in message and "id" in message and message["id"] in client_requests:
            connection, client_id, method, params = client_requests.pop(message["id"])
            if connection in connections:
                send_json(connection, {**message, "id": client_id})
            if method == "thread/resume" and connection in connections:
                # Codex sends a resumed thread's pending requests to the new subscriber.
                thread_id = params.get("threadId")
                for request in pending_server_requests.values():
                    if (request.get("params") or {}).get("threadId") in (thread_id, None):
                        log({"event": "resent_request", "connection": connection.id, "id": request["id"]})
                        send_json(connection, request)
            return
        if "method" in message and "id" in message:
            relay_id = next_server_request_id[0]
            next_server_request_id[0] += 1
            server_request_child_ids[relay_id] = message["id"]
            message = {**message, "id": relay_id}
            pending_server_requests[relay_id] = message
        for connection in list(connections):
            send_json(connection, message)

    def handshake(connection):
        if b"\r\n\r\n" not in connection.buffer:
            return
        head, connection.buffer = connection.buffer.split(b"\r\n\r\n", 1)
        key = ""
        for line in head.decode(errors="replace").split("\r\n"):
            if line.lower().startswith("sec-websocket-key:"):
                key = line.split(":", 1)[1].strip()
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        connection.sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                 f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        connection.open = True
        log({"event": "connected", "connection": connection.id})

    def frames(connection):
        while len(connection.buffer) >= 2:
            first, second = connection.buffer[0], connection.buffer[1]
            length, offset = second & 0x7F, 2
            if length == 126:
                if len(connection.buffer) < 4:
                    return
                length, offset = struct.unpack(">H", connection.buffer[2:4])[0], 4
            elif length == 127:
                if len(connection.buffer) < 10:
                    return
                length, offset = struct.unpack(">Q", connection.buffer[2:10])[0], 10
            masked = second & 0x80
            total = offset + (4 if masked else 0) + length
            if len(connection.buffer) < total:
                return
            mask = connection.buffer[offset:offset + 4] if masked else b"\0\0\0\0"
            start = offset + (4 if masked else 0)
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(connection.buffer[start:total]))
            connection.buffer = connection.buffer[total:]
            opcode = first & 0x0F
            if opcode == 8:
                close(connection)
                return
            if opcode == 9:
                send_frame(connection, payload, opcode=10)
                continue
            if opcode in (0, 1, 2):
                connection.message += payload
                if first & 0x80:
                    try:
                        message = json.loads(connection.message)
                    except json.JSONDecodeError:
                        message = None
                    connection.message = b""
                    if message is not None:
                        from_client(connection, message)

    while True:
        readable, _, _ = select.select([server, child.stdout] + [c.sock for c in connections], [], [], 0.25)
        if child.poll() is not None and not readable:
            break
        for source in readable:
            if source is server:
                sock, _ = server.accept()
                connections.append(Connection(sock))
            elif source is child.stdout:
                chunk = os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    child.wait()
                    return child.returncode or 0
                child_buffer += chunk
                while b"\n" in child_buffer:
                    line, child_buffer = child_buffer.split(b"\n", 1)
                    try:
                        from_child(json.loads(line))
                    except json.JSONDecodeError:
                        pass
            else:
                connection = next(c for c in connections if c.sock is source)
                try:
                    chunk = source.recv(65536)
                except OSError:
                    chunk = b""
                if not chunk:
                    close(connection)
                    continue
                connection.buffer += chunk
                if not connection.open:
                    handshake(connection)
                if connection.open:
                    frames(connection)
    return child.returncode or 0


def record_app_server_launch(socket_path):
    """`-single-server` modes: every launch appends its process, transport, arguments and Codex
    home, so a test can count the app-servers running on one Codex home. A socket server's
    stdio child records itself too, with the server as its parent."""
    state_directory = Path(os.environ.get("PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY", str(Path(sys.argv[0]).parent)))
    with open(state_directory / f"{Path(sys.argv[0]).name}.app-servers", "a", encoding="utf-8") as handle:
        handle.write(json.dumps({
            "pid": os.getpid(), "parentPID": os.getppid(), "listen": f"unix://{socket_path}" if socket_path else "stdio://",
            "arguments": sys.argv[1:], "codexHome": os.environ.get("CODEX_HOME"),
        }) + "\n")


if __name__ == "__main__":
    socket_path = listen_path()
    if "-single-server" in Path(sys.argv[0]).name:
        record_app_server_launch(socket_path)
    if socket_path:
        raise SystemExit(serve_unix_socket(socket_path))
    sys.stdin = StdinLines(sys.stdin.fileno())
    raise SystemExit(main())

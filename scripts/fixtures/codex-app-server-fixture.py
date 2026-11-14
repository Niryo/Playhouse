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
from types import SimpleNamespace
import codex_fixture_dispatch as _fixture_dispatch
import functools

import codex_fixture_handlers as _fixture_handlers


def _bind_fixture_handler(handler):
    return functools.partial(handler, sys.modules[__name__])


run_cpu_attribution_server = _bind_fixture_handler(_fixture_handlers.run_cpu_attribution_server)
run_reattach_server = _bind_fixture_handler(_fixture_handlers.run_reattach_server)
serve_unix_socket = _bind_fixture_handler(_fixture_handlers.serve_unix_socket)

import codex_fixture_helpers as _fixture_helpers

for _name in (
    "markdown_plan_deltas", "echoed_outcome_answer", "own_user_text", "breakdown",
    "token_usage_notification", "call_usage_notifications", "write_waste_rollouts",
    "side_chat_selection", "run_side_chat_cli", "handle_side_chat", "write",
    "is_page_classifier_prompt", "answer_text", "nudged_work_items",
    "is_restart_question_mode", "question_request", "subagent_item", "subagent_activity",
    "async_question_item", "later_async_question_item", "diagnostic_action_items",
    "follow_turn_items", "account_rate_limits", "handle_account_request",
    "remember_thread_cwd", "workspace_cwd", "stdin_select",
):
    globals()[_name] = _bind_fixture_handler(getattr(_fixture_helpers, _name))

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


ECHOED_OUTCOME_PREFIX = "Echo the outcome command for "
ECHOED_OUTCOME_ANSWER = "Fixture answer with an echoed outcome."


# The app-server reports a turn's cost on its terminal notification. Codex names
# its cached bucket `cached_input_tokens` and has no cache-write bucket, so the
# totals differ from the Claude fixture's on purpose.
TURN_USAGE = {
    "input_tokens": 900,
    "output_tokens": 150,
    "cached_input_tokens": 250,
}
TURN_USAGE_TOTAL = sum(TURN_USAGE.values())


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


# Side chat threads this server forked, each with the thread it was forked from.
SIDE_CHAT_THREADS = {}


# Codex's read-only sandbox with network access: no file writes, sockets allowed.
READ_ONLY_SANDBOX_PROFILE = '(version 1)(allow default)(deny file-write*)(allow file-write* (literal "/dev/null"))'


NUDGED_WORK_COMMENTARY = "Codex is finishing the remaining check after the nudge."
NUDGED_WORK_ANSWER = "Codex finished the remaining check after the nudge. Everything is done."


question_contexts = {}
question_rounds = {}
question_sequence = 900
first_question_thread = None


CHILD_THREAD_ID = "00000000-0000-0000-0000-000000000002"
CHILD_TURN_ID = "turn_playhouse_child_fixture"
CHILD_MESSAGES = [
    {"id": "item_child_user", "type": "userMessage", "content": [{"type": "text", "text": "Inspect Playhouse entitlements."}]},
    {"id": "item_child_assistant", "type": "agentMessage", "text": "Sandbox review read PlayhouseEntitlements.entitlements and found the required profile."},
]


CPU_ATTRIBUTION_TURN = re.compile(r"\b(burn|idle) cpu for (\d+(?:\.\d+)?) seconds\b", re.IGNORECASE)


ACCOUNT_METHODS = ("account/read", "account/rateLimits/read", "account/login/start", "account/logout")


# Real Codex runs a thread's commands in the cwd its thread and turn requests name. One shared
# socket app-server serves every task, so its own process cwd is whatever its first caller had.
THREAD_CWDS = {}
LAST_REQUESTED_CWD = None


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


def main():
    _session_state = SimpleNamespace()
    global THREAD_ID, TURN_ID
    if "-cpu-attribution" in os.path.basename(sys.argv[0]):
        return run_cpu_attribution_server()
    if "-reattach" in os.path.basename(sys.argv[0]):
        return run_reattach_server()
    _session_state._ = None
    _session_state.ack_deadline = None
    _session_state.action_item = None
    _session_state.active = None
    _session_state.active_command_item = None
    _session_state.asked = None
    _session_state.assistant = None
    _session_state.async_provider_error = None
    _session_state.child_item = None
    _session_state.compaction_item = None
    _session_state.completed = None
    _session_state.contents = None
    _session_state.deadline = None
    _session_state.delta = None
    _session_state.descriptor = None
    _session_state.dynamic_item = None
    _session_state.echoed = None
    _session_state.entries = None
    _session_state.error_code = None
    _session_state.expected_answers = None
    _session_state.expected_recovery_answers = None
    _session_state.fail_marker = None
    _session_state.failed = None
    _session_state.final_answer_pause = None
    _session_state.final_answer_ready = None
    _session_state.final_answer_release = None
    _session_state.first_child_started = None
    _session_state.first_turn = None
    _session_state.first_turn_marker = None
    _session_state.goal = None
    _session_state.history = None
    _session_state.hold_marker = None
    _session_state.hold_used = None
    _session_state.image_inputs = None
    _session_state.image_url = None
    _session_state.incoming = None
    _session_state.index = None
    _session_state.instructions = None
    _session_state.interrupt_message = None
    _session_state.interrupt_release = None
    _session_state.is_outcome_reminder = None
    _session_state.is_plan_turn = None
    _session_state.is_title_request = None
    _session_state.item = None
    _session_state.item_id = None
    _session_state.items = None
    _session_state.key = None
    _session_state.legacy_dynamic_item = None
    _session_state.level = None
    _session_state.mcp_item = None
    _session_state.message_text = None
    _session_state.messages = None
    _session_state.midpoint = None
    _session_state.no_secret_fixture = None
    _session_state.no_secret_recovery = None
    _session_state.observe_history = None
    _session_state.ordinary_turn_indexes = None
    _session_state.outcome_command = None
    _session_state.outcome_line = None
    _session_state.params = None
    _session_state.phase = None
    _session_state.plan_item_id = None
    _session_state.preserve_no_outcome = None
    _session_state.private_activity = None
    _session_state.progress_text = None
    _session_state.provider_error = None
    _session_state.queued_request = None
    _session_state.readable = None
    _session_state.ready = None
    _session_state.received_interrupt = None
    _session_state.reject = None
    _session_state.reject_deadline = None
    _session_state.reject_marker = None
    _session_state.rejected_steer_requests = None
    _session_state.rejection = None
    _session_state.rejection_message = None
    _session_state.release = None
    _session_state.release_latest = None
    _session_state.released = None
    _session_state.requested = None
    _session_state.requested_thread_id = None
    _session_state.resume = None
    _session_state.resume_error = None
    _session_state.saved_turn = None
    _session_state.saved_turns = None
    _session_state.second_child_id = None
    _session_state.second_child_started = None
    _session_state.secret_stage = None
    _session_state.serial_first_turn = None
    _session_state.steer_request = None
    _session_state.steer_requests = None
    _session_state.steered_answer = None
    _session_state.stream = None
    _session_state.text = None
    _session_state.thread_start_instructions = None
    _session_state.tool_item = None
    _session_state.turn_error = None
    _session_state.turn_history = None
    _session_state.turn_id = None
    _session_state.turn_index = None
    _session_state.turn_input = None
    _session_state.turn_status = None
    _session_state.turn_thread_id = None
    _session_state.turns = None
    _session_state.unassociated_restart_question = None
    _session_state.user_content = None
    _session_state.user_images = None
    _session_state.user_message = None
    _session_state.value = None
    _session_state.was_released = None
    _session_state.mode = os.path.basename(sys.argv[0])
    _session_state.answers = None
    _session_state.isolation_turns = {}
    # `-single-server` modes: the turn Codex runs for each thread's active Goal.
    _session_state.goal_turns = {}
    _session_state.saw_question = False
    _session_state.saw_turn = False
    _session_state.turn_message = None
    _session_state.history_path = Path(str(sys.argv[0]) + ".history")
    _session_state.fixture_state_directory = Path(os.environ.get("PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY", str(Path(sys.argv[0]).parent)))
    if "-goal" in _session_state.mode:
        (_session_state.fixture_state_directory / f"{Path(sys.argv[0]).name}.launch-args").write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
    _session_state.goal_path = _session_state.fixture_state_directory / f"{Path(sys.argv[0]).name}.goal"
    _session_state.async_mode = _session_state.mode.endswith("-async-question") or _session_state.mode.endswith("-async-question-queued")
    _session_state.serial_mode = _session_state.mode.endswith("-serial-success-wait") or _session_state.mode.endswith("-serial-success") or _session_state.async_mode
    if _session_state.serial_mode:
        _session_state.saved_history = json.loads(_session_state.history_path.read_text(encoding="utf-8")) if _session_state.history_path.is_file() else {}
        THREAD_ID = _session_state.saved_history.get("threadID")
        TURN_ID = f"turn-{uuid.uuid4()}"

    def serial_history():
        if _session_state.history_path.is_file():
            return json.loads(_session_state.history_path.read_text(encoding="utf-8"))
        return {"threadID": None, "events": [], "messages": []}
    _session_state.serial_history = serial_history

    _session_state.handle_message = lambda message: _fixture_dispatch.handle_message(
        sys.modules[__name__], _session_state, message
    )

    # Requests a real, evented app-server keeps answering while another turn
    # is in progress. Anything else that arrives during a held turn is
    # deferred and handled after it, in arrival order, as before.
    _session_state.answer_while_held = {"initialize", "initialized", "thread/items/list", "thread/turns/list", "thread/read",
                         "thread/resume", "model/list", "thread/goal/get", *ACCOUNT_METHODS}
    _session_state.deferred = []

    def snapshot_state():
        return {"THREAD_ID": THREAD_ID, "TURN_ID": TURN_ID, "_": _session_state._, "ack_deadline": _session_state.ack_deadline, "action_item": _session_state.action_item, "active": _session_state.active, "active_command_item": _session_state.active_command_item, "answers": _session_state.answers, "asked": _session_state.asked, "assistant": _session_state.assistant, "async_provider_error": _session_state.async_provider_error, "child_item": _session_state.child_item, "compaction_item": _session_state.compaction_item, "completed": _session_state.completed, "contents": _session_state.contents, "deadline": _session_state.deadline, "delta": _session_state.delta, "descriptor": _session_state.descriptor, "dynamic_item": _session_state.dynamic_item, "echoed": _session_state.echoed, "entries": _session_state.entries, "error_code": _session_state.error_code, "expected_answers": _session_state.expected_answers, "expected_recovery_answers": _session_state.expected_recovery_answers, "fail_marker": _session_state.fail_marker, "failed": _session_state.failed, "final_answer_pause": _session_state.final_answer_pause, "final_answer_ready": _session_state.final_answer_ready, "final_answer_release": _session_state.final_answer_release, "first_child_started": _session_state.first_child_started, "first_turn": _session_state.first_turn, "first_turn_marker": _session_state.first_turn_marker, "goal": _session_state.goal, "history": _session_state.history, "hold_marker": _session_state.hold_marker, "hold_used": _session_state.hold_used, "image_inputs": _session_state.image_inputs, "image_url": _session_state.image_url, "incoming": _session_state.incoming, "index": _session_state.index, "instructions": _session_state.instructions, "interrupt_message": _session_state.interrupt_message, "interrupt_release": _session_state.interrupt_release, "is_outcome_reminder": _session_state.is_outcome_reminder, "is_plan_turn": _session_state.is_plan_turn, "is_title_request": _session_state.is_title_request, "item": _session_state.item, "item_id": _session_state.item_id, "items": _session_state.items, "key": _session_state.key, "legacy_dynamic_item": _session_state.legacy_dynamic_item, "level": _session_state.level, "mcp_item": _session_state.mcp_item, "message_text": _session_state.message_text, "messages": _session_state.messages, "midpoint": _session_state.midpoint, "no_secret_fixture": _session_state.no_secret_fixture, "no_secret_recovery": _session_state.no_secret_recovery, "observe_history": _session_state.observe_history, "ordinary_turn_indexes": _session_state.ordinary_turn_indexes, "outcome_command": _session_state.outcome_command, "outcome_line": _session_state.outcome_line, "params": _session_state.params, "phase": _session_state.phase, "plan_item_id": _session_state.plan_item_id, "preserve_no_outcome": _session_state.preserve_no_outcome, "private_activity": _session_state.private_activity, "progress_text": _session_state.progress_text, "provider_error": _session_state.provider_error, "queued_request": _session_state.queued_request, "readable": _session_state.readable, "ready": _session_state.ready, "received_interrupt": _session_state.received_interrupt, "reject": _session_state.reject, "reject_deadline": _session_state.reject_deadline, "reject_marker": _session_state.reject_marker, "rejected_steer_requests": _session_state.rejected_steer_requests, "rejection": _session_state.rejection, "rejection_message": _session_state.rejection_message, "release": _session_state.release, "release_latest": _session_state.release_latest, "released": _session_state.released, "requested": _session_state.requested, "requested_thread_id": _session_state.requested_thread_id, "resume": _session_state.resume, "resume_error": _session_state.resume_error, "saved_history": _session_state.saved_history, "saved_turn": _session_state.saved_turn, "saved_turns": _session_state.saved_turns, "saw_question": _session_state.saw_question, "saw_turn": _session_state.saw_turn, "second_child_id": _session_state.second_child_id, "second_child_started": _session_state.second_child_started, "secret_stage": _session_state.secret_stage, "serial_first_turn": _session_state.serial_first_turn, "steer_request": _session_state.steer_request, "steer_requests": _session_state.steer_requests, "steered_answer": _session_state.steered_answer, "stream": _session_state.stream, "text": _session_state.text, "thread_start_instructions": _session_state.thread_start_instructions, "tool_item": _session_state.tool_item, "turn_error": _session_state.turn_error, "turn_history": _session_state.turn_history, "turn_id": _session_state.turn_id, "turn_index": _session_state.turn_index, "turn_input": _session_state.turn_input, "turn_message": _session_state.turn_message, "turn_status": _session_state.turn_status, "turn_thread_id": _session_state.turn_thread_id, "turns": _session_state.turns, "unassociated_restart_question": _session_state.unassociated_restart_question, "user_content": _session_state.user_content, "user_images": _session_state.user_images, "user_message": _session_state.user_message, "value": _session_state.value, "was_released": _session_state.was_released}
    _session_state.snapshot_state = snapshot_state

    def restore_state(state):
        global THREAD_ID, TURN_ID


        THREAD_ID = state["THREAD_ID"]
        TURN_ID = state["TURN_ID"]
        _session_state._ = state["_"]
        _session_state.ack_deadline = state["ack_deadline"]
        _session_state.action_item = state["action_item"]
        _session_state.active = state["active"]
        _session_state.active_command_item = state["active_command_item"]
        _session_state.answers = state["answers"]
        _session_state.asked = state["asked"]
        _session_state.assistant = state["assistant"]
        _session_state.async_provider_error = state["async_provider_error"]
        _session_state.child_item = state["child_item"]
        _session_state.compaction_item = state["compaction_item"]
        _session_state.completed = state["completed"]
        _session_state.contents = state["contents"]
        _session_state.deadline = state["deadline"]
        _session_state.delta = state["delta"]
        _session_state.descriptor = state["descriptor"]
        _session_state.dynamic_item = state["dynamic_item"]
        _session_state.echoed = state["echoed"]
        _session_state.entries = state["entries"]
        _session_state.error_code = state["error_code"]
        _session_state.expected_answers = state["expected_answers"]
        _session_state.expected_recovery_answers = state["expected_recovery_answers"]
        _session_state.fail_marker = state["fail_marker"]
        _session_state.failed = state["failed"]
        _session_state.final_answer_pause = state["final_answer_pause"]
        _session_state.final_answer_ready = state["final_answer_ready"]
        _session_state.final_answer_release = state["final_answer_release"]
        _session_state.first_child_started = state["first_child_started"]
        _session_state.first_turn = state["first_turn"]
        _session_state.first_turn_marker = state["first_turn_marker"]
        _session_state.goal = state["goal"]
        _session_state.history = state["history"]
        _session_state.hold_marker = state["hold_marker"]
        _session_state.hold_used = state["hold_used"]
        _session_state.image_inputs = state["image_inputs"]
        _session_state.image_url = state["image_url"]
        _session_state.incoming = state["incoming"]
        _session_state.index = state["index"]
        _session_state.instructions = state["instructions"]
        _session_state.interrupt_message = state["interrupt_message"]
        _session_state.interrupt_release = state["interrupt_release"]
        _session_state.is_outcome_reminder = state["is_outcome_reminder"]
        _session_state.is_plan_turn = state["is_plan_turn"]
        _session_state.is_title_request = state["is_title_request"]
        _session_state.item = state["item"]
        _session_state.item_id = state["item_id"]
        _session_state.items = state["items"]
        _session_state.key = state["key"]
        _session_state.legacy_dynamic_item = state["legacy_dynamic_item"]
        _session_state.level = state["level"]
        _session_state.mcp_item = state["mcp_item"]
        _session_state.message_text = state["message_text"]
        _session_state.messages = state["messages"]
        _session_state.midpoint = state["midpoint"]
        _session_state.no_secret_fixture = state["no_secret_fixture"]
        _session_state.no_secret_recovery = state["no_secret_recovery"]
        _session_state.observe_history = state["observe_history"]
        _session_state.ordinary_turn_indexes = state["ordinary_turn_indexes"]
        _session_state.outcome_command = state["outcome_command"]
        _session_state.outcome_line = state["outcome_line"]
        _session_state.params = state["params"]
        _session_state.phase = state["phase"]
        _session_state.plan_item_id = state["plan_item_id"]
        _session_state.preserve_no_outcome = state["preserve_no_outcome"]
        _session_state.private_activity = state["private_activity"]
        _session_state.progress_text = state["progress_text"]
        _session_state.provider_error = state["provider_error"]
        _session_state.queued_request = state["queued_request"]
        _session_state.readable = state["readable"]
        _session_state.ready = state["ready"]
        _session_state.received_interrupt = state["received_interrupt"]
        _session_state.reject = state["reject"]
        _session_state.reject_deadline = state["reject_deadline"]
        _session_state.reject_marker = state["reject_marker"]
        _session_state.rejected_steer_requests = state["rejected_steer_requests"]
        _session_state.rejection = state["rejection"]
        _session_state.rejection_message = state["rejection_message"]
        _session_state.release = state["release"]
        _session_state.release_latest = state["release_latest"]
        _session_state.released = state["released"]
        _session_state.requested = state["requested"]
        _session_state.requested_thread_id = state["requested_thread_id"]
        _session_state.resume = state["resume"]
        _session_state.resume_error = state["resume_error"]
        _session_state.saved_history = state["saved_history"]
        _session_state.saved_turn = state["saved_turn"]
        _session_state.saved_turns = state["saved_turns"]
        _session_state.saw_question = state["saw_question"]
        _session_state.saw_turn = state["saw_turn"]
        _session_state.second_child_id = state["second_child_id"]
        _session_state.second_child_started = state["second_child_started"]
        _session_state.secret_stage = state["secret_stage"]
        _session_state.serial_first_turn = state["serial_first_turn"]
        _session_state.steer_request = state["steer_request"]
        _session_state.steer_requests = state["steer_requests"]
        _session_state.steered_answer = state["steered_answer"]
        _session_state.stream = state["stream"]
        _session_state.text = state["text"]
        _session_state.thread_start_instructions = state["thread_start_instructions"]
        _session_state.tool_item = state["tool_item"]
        _session_state.turn_error = state["turn_error"]
        _session_state.turn_history = state["turn_history"]
        _session_state.turn_id = state["turn_id"]
        _session_state.turn_index = state["turn_index"]
        _session_state.turn_input = state["turn_input"]
        _session_state.turn_message = state["turn_message"]
        _session_state.turn_status = state["turn_status"]
        _session_state.turn_thread_id = state["turn_thread_id"]
        _session_state.turns = state["turns"]
        _session_state.unassociated_restart_question = state["unassociated_restart_question"]
        _session_state.user_content = state["user_content"]
        _session_state.user_images = state["user_images"]
        _session_state.user_message = state["user_message"]
        _session_state.value = state["value"]
        _session_state.was_released = state["was_released"]
    _session_state.restore_state = restore_state

    def answer_read_while_held(message):
        # Answers a read-only/resume request during a held turn without letting
        # it disturb the held turn's in-memory state. False for anything else.
        if message.get("method") not in _session_state.answer_while_held:
            return False
        state = _session_state.snapshot_state()
        try:
            _session_state.handle_message(message)
        finally:
            _session_state.restore_state(state)
        return True
    _session_state.answer_read_while_held = answer_read_while_held

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
            if not _session_state.answer_read_while_held(peeked):
                _session_state.deferred.append(peeked)
    _session_state.drain_pending_stdin = drain_pending_stdin

    for line in sys.stdin:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        _session_state.handle_message(message)
        while _session_state.deferred:
            _session_state.handle_message(_session_state.deferred.pop(0))
    if not _session_state.saw_turn:
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

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

import hashlib
import json
import re
import os
import select
import selectors
import shlex
import subprocess
import sys
import time
from pathlib import Path
import functools

import claude_fixture_handlers as _fixture_handlers


def _bind_fixture_handler(handler):
    return functools.partial(handler, sys.modules[__name__])


respond = _bind_fixture_handler(_fixture_handlers.respond)
run_reattach_turn = _bind_fixture_handler(_fixture_handlers.run_reattach_turn)

class AgentInput:
    """Reads stdin the way Claude Code's runtime (Bun) does: it waits for kqueue to report the
    input readable, then reads. On macOS kqueue does not report a FIFO readable while a blocking
    write() of more than the FIFO holds is pending, so a Playhouse that wrote a large message
    (one with an image, say) in one blocking write would stall this fixture just as it stalls
    Claude Code, instead of the fixture reading it with a blocking read Claude Code never does."""

    def __init__(self, fd=0):
        self.fd = fd
        self.buffer = b""
        self.ended = False
        self.selector = None

    def readline(self, timeout=None):
        """The next line with its newline, "" once input has ended, or None when `timeout`
        seconds pass first."""
        if self.selector is None:
            self.selector = selectors.KqueueSelector()
            self.selector.register(self.fd, selectors.EVENT_READ)
        deadline = None if timeout is None else time.monotonic() + timeout
        while b"\n" not in self.buffer:
            if self.ended:
                line, self.buffer = self.buffer, b""
                return line.decode()
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                return None
            if not self.selector.select(remaining):
                continue
            chunk = os.read(self.fd, 65536)
            if chunk:
                self.buffer += chunk
            else:
                self.ended = True
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.decode() + "\n"

    def __iter__(self):
        while True:
            line = self.readline()
            if not line:
                return
            yield line


STDIN = AgentInput()


STORY = "BISCUIT-7 waited by the gate every evening. One night the boy finally came home."
STORY_CLOSING = "The story is above."
INSPECTION_INTENT = "I'll inspect the workspace first."
INSPECTION_ANSWER = "Inspection done: the workspace is ready."
UNANSWERED_FIRST = "Starting the checks."
UNANSWERED_LAST = "Checks are running; results will follow."
CHAT_INTENT = "Let me check the newer release first."
CHAT_ANSWER = "Confirmed: 2.1.309 registers the new model and 2.1.308 does not."
CHAT_CLOSING = "Tell me if you want the upgrade command."
# A chat turn that runs close-turn first and answers after it, as the instructions ask.
CHAT_CLOSE_FIRST_PROMPT = "Name the largest moon of Jupiter."
CHAT_CLOSE_FIRST_ANSWER = "Ganymede is the largest moon of Jupiter."
# A chat turn that answers, runs close-turn last, and then gets Claude Code's own notice.
CHAT_NOTICE_PROMPT = "Name the largest moon of Saturn."
CHAT_NOTICE_ANSWER = "Titan is the largest moon of Saturn."
CHAT_NOTICE_REPLY = "I already answered above."
NO_VISIBLE_OUTPUT_NOTICE = "[Your previous response had no visible output. Please continue and produce a user-visible response.]"
# A chat turn that forgets close-turn; Playhouse's one visible nudge then gets it run.
CHAT_SKIPPED_CLOSE_TURN_PROMPT = "Plan a weekend hiking trip."
CHAT_SKIPPED_CLOSE_TURN_ANSWER = "Pick a loop trail under 15 km and start early."
CHAT_NUDGE_PAGE_TITLE = "Hiking trip"
CHAT_NUDGE_REPLY = "Filed."
SIMPLE_ANSWER = "OK."
PENDING_QUESTION_SUCCESS_MARKER = "finish while a structured question remains pending"
# Claude writes questions in Markdown, as it does replies.
MARKDOWN_QUESTION = (
    "Which color should I use for **the primary button**?\n\nIt also tints `LinkText`.\n\n"
    "When the user clicks an \"Add here\" placeholder, which conversation should open: the task's active "
    "conversation, a new conversation started just for that placeholder, or the conversation the placeholder "
    "was originally added from?"
)
# Playhouse keys each answer by the question it answers.
QUESTION_TEXTS = ("Which color should I use?", MARKDOWN_QUESTION)
NUDGE_RACE_STALE_ANSWER = "The task review is approved. Only the UI review is still pending."
NUDGE_RACE_UI_REPORT = "UI review approved."
NUDGED_COMMENTARY = "Every review is approved. Running the final check."
NUDGED_SUITE_COMMENTARY = "Starting the final suite in the background."
NUDGED_SUITE_REPORT = "Final suite passed: all cases green."
NUDGED_IMAGE_CAPTION = "Nudged turn screenshot"
NUDGED_FINAL_ANSWER = "All checks passed and the screenshot is attached. The work is complete."
TINY_PNG_HEX = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"
# Lines each held stage of the streamed follow turn adds; the first stage alone
# outgrows the transcript viewport.
STREAM_FOLLOW_STAGES = (20, 8, 8, 8)
STREAM_FOLLOW_FINAL = "Streamed follow reply finished."


def stream_follow_line(line):
    return (f"Streamed follow line {line:02d}: the reply keeps growing below the question "
            "so the transcript has to scroll to keep its newest text in view.")


# Claude Code reports a turn's token cost on its `result` message. Every result
# this fixture writes carries the same deterministic block, so a test can assert
# exact per-turn and per-task totals.
TURN_USAGE = {
    "input_tokens": 1000,
    "output_tokens": 200,
    "cache_read_input_tokens": 300,
    "cache_creation_input_tokens": 100,
}
TURN_USAGE_TOTAL = sum(TURN_USAGE.values())


def maybe_burn_cpu():
    """Spends real, measurable CPU as a child process of this fixture while
    the turn stays active, so a bridge test can assert a non-zero CPU
    percentage for the task's process tree. No-op unless
    PLAYHOUSE_E2E_CLAUDE_FIXTURE_BURN_CPU is set. Additive only: leaves every
    other fixture behavior unchanged.
    """
    if os.environ.get("PLAYHOUSE_E2E_CLAUDE_FIXTURE_BURN_CPU") != "1":
        return
    seconds = float(os.environ.get("PLAYHOUSE_E2E_CLAUDE_FIXTURE_BURN_CPU_SECONDS", "10"))
    burner = subprocess.Popen([
        sys.executable, "-c",
        f"import time\nend = time.time() + {seconds}\nwhile time.time() < end:\n    pass\n",
    ])
    burner.wait()


def write(value):
    if isinstance(value, dict) and value.get("type") == "result" and "usage" not in value:
        value = {**value, "usage": dict(TURN_USAGE)}
    if isinstance(value, dict) and value.get("type") == "result" and os.environ.get("PLAYHOUSE_E2E_CLAUDE_FIXTURE_CACHE_MISS") == "1":
        value = {**value, "usage": {
            "input_tokens": 250000, "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 250000, "output_tokens": 5,
        }}
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


SIDE_CHAT_MARKER = "You are now in a Playhouse side chat"


def side_chat_respond(user_text, instructions, turn, prior_turns):
    """Answers a Playhouse side chat turn. The first turn of a fork quotes the selection and the
    source session's latest prompt. Asking it to create a task tries four tool calls: a Write, an
    ordinary shell command, the Playhouse CLI chained with `&` to another command, and the CLI's
    `task create` whose quoted description contains shell punctuation. As Claude Code does, each
    call first goes through the `PreToolUse` hooks the launch's --settings carry (recorded in
    `hookDecisions`), and the fixture then asks Playhouse's permission handler about each one
    (`permissionDecisions`). The CLI command really runs when both allow it."""
    selection = re.search(r"<selected-text>\n(.*?)\n</selected-text>", user_text, re.S)
    question = user_text.split("</selected-text>", 1)[-1].strip()
    session = turn["sessionID"]
    if "create a task" in question.lower():
        line = next((line.strip() for line in instructions.splitlines()
                     if line.strip().startswith("'") and "task create" in line), "")
        executable = shlex.split(line)[0] if line else "playhouse-cli"
        cli_command = shlex.join([executable, "task", "create", "--title", "Side chat follow-up",
                                  "--prompt", f"Follow up on the side chat about: {question} -> keep a; b <path>"])
        requests = {
            "side-chat-write": {"tool_name": "Write", "input": {"file_path": os.path.join(os.getcwd(), "side-chat-forbidden.txt"), "content": "no"}},
            "side-chat-shell": {"tool_name": "Bash", "input": {"command": "touch side-chat-forbidden.txt"}},
            "side-chat-chained": {"tool_name": "Bash", "input": {"command": shlex.join([executable, "task", "list"]) + " & touch side-chat-forbidden.txt"}},
            "side-chat-cli": {"tool_name": "Bash", "input": {"command": cli_command}},
        }
        settings = json.loads(argument("--settings") or "{}")
        hook_commands = [hook["command"] for entry in settings.get("hooks", {}).get("PreToolUse", [])
                         for hook in entry.get("hooks", []) if hook.get("type") == "command"]
        hook_decisions = {}
        for request_id, request in requests.items():
            decision = "pass"
            for hook_command in hook_commands:
                completed = subprocess.run(hook_command, shell=True, capture_output=True, text=True, timeout=30,
                                           input=json.dumps({"hook_event_name": "PreToolUse", "tool_name": request["tool_name"],
                                                             "tool_input": request["input"]}))
                output = json.loads(completed.stdout) if completed.stdout.strip() else {}
                if (output.get("hookSpecificOutput") or {}).get("permissionDecision") == "deny":
                    decision = "deny"
            hook_decisions[request_id] = decision
        turn["hookDecisions"] = hook_decisions
        for request_id, request in requests.items():
            write({"type": "control_request", "request_id": request_id, "request": {"subtype": "can_use_tool", **request}})
        decisions = {}
        while len(decisions) < len(requests):
            line = STDIN.readline()
            if not line:
                break
            if not line.strip():
                continue
            message = json.loads(line)
            response = (message.get("response") or {}) if message.get("type") == "control_response" else {}
            if response.get("request_id") in requests:
                decisions[response["request_id"]] = (response.get("response") or {}).get("behavior")
        turn["permissionDecisions"] = decisions
        created = None
        if decisions.get("side-chat-cli") == "allow" and hook_decisions.get("side-chat-cli") == "pass":
            completed = subprocess.run(shlex.split(cli_command), capture_output=True, text=True, timeout=60)
            try:
                created = (json.loads(completed.stdout).get("result") or {}).get("id")
            except json.JSONDecodeError:
                created = None
        reply = f"Created task {created}." if created else "Could not create the task."
    elif selection:
        source = turn.get("forkedFrom")
        source_prompt = next((prior.get("userText", "") for prior in reversed(prior_turns)
                              if prior.get("sessionID") == source and prior.get("userText")
                              and "playhouse internal outcome nudge:" not in prior["userText"].lower()), "")
        first_line = source_prompt.strip().splitlines()[0] if source_prompt.strip() else ""
        reply = f"Side chat about \"{selection.group(1)}\", forked from {source} (which asked: {first_line[:80]}): {question}"
    else:
        earlier = sum(1 for prior in prior_turns if prior.get("sessionID") == session)
        reply = f"Side chat follow-up {earlier + 1} on {session}: {question}"
    turn["sideChatReply"] = reply
    text("msg_side_chat", reply)
    return []


def assistant(message_id, blocks, usage=None, parent=None):
    if usage is None and os.environ.get("PLAYHOUSE_E2E_CLAUDE_FIXTURE_CACHE_MISS") == "1":
        usage = {
            "input_tokens": 250000, "cache_read_input_tokens": 0,
            "cache_creation_input_tokens": 250000, "output_tokens": 5,
        }
    message = {"id": message_id, "role": "assistant", "content": blocks}
    if usage:
        message["usage"] = dict(usage)
    write({"type": "assistant", "parent_tool_use_id": parent, "message": message})


def text(message_id, value, usage=None):
    write({"type": "stream_event", "parent_tool_use_id": None,
           "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": value}}})
    assistant(message_id, [{"type": "text", "text": value}], usage)


# Per-model-call usage of the story turn, deterministic so a test can assert
# exact call counts and sent/output totals. "Sent" is input + cache read + cache
# creation: the two main-agent calls send 550 and 650 (so the final transcript
# is 650), the two subagent calls send 300 and 340.
def call_usage(input_tokens, cache_read, cache_creation, output_tokens):
    return {"input_tokens": input_tokens, "cache_read_input_tokens": cache_read,
            "cache_creation_input_tokens": cache_creation, "output_tokens": output_tokens}


STORY_MAIN_CALLS = [call_usage(100, 400, 50, 20), call_usage(120, 500, 30, 40)]
STORY_SUBAGENT_CALLS = [call_usage(200, 80, 20, 10), call_usage(240, 90, 10, 15)]


def write_session_calls(session_id, turn_number, main_calls):
    """Appends this turn's calls to Claude Code's own session files, as the real CLI does.

    A call is written once per content block (so twice here for the first main
    call), plus a zero-usage synthetic entry; a reader must count each message
    ID once and ignore the synthetic one.
    """
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    if not config or not session_id:
        return
    project = Path(config) / "projects" / "-fixture-project"
    (project / session_id / "subagents").mkdir(parents=True, exist_ok=True)

    def line(message_id, usage, sidechain=False):
        return json.dumps({"type": "assistant", "isSidechain": sidechain,
                           "message": {"id": message_id, "role": "assistant", "usage": usage}}) + "\n"

    with open(project / f"{session_id}.jsonl", "a", encoding="utf-8") as handle:
        for index, (message_id, usage) in enumerate(main_calls):
            handle.write(line(message_id, usage))
            if index == 0:
                handle.write(line(message_id, usage))
        handle.write(line(f"synthetic_{turn_number}", call_usage(0, 0, 0, 0)))
    with open(project / session_id / "subagents" / f"agent-fx{turn_number}.jsonl", "a", encoding="utf-8") as handle:
        for index, usage in enumerate(STORY_SUBAGENT_CALLS):
            handle.write(line(f"msg_fx_sub{turn_number}_{index}", usage, sidechain=True))


def write_session_context(session_id, tokens, minutes_ago=0):
    """Write a real-looking main-agent usage line to position the cache clock."""
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    if not config or not session_id:
        return
    project = Path(config) / "projects" / "-fixture-project"
    project.mkdir(parents=True, exist_ok=True)
    model = argument("--model") or "claude-opus-5-5"
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - minutes_ago * 60))
    entry = {"type": "assistant", "timestamp": timestamp,
             "message": {"id": f"fixture-context-{time.time_ns()}", "model": model,
                         "usage": {"input_tokens": tokens, "cache_read_input_tokens": 0,
                                   "cache_creation_input_tokens": 0, "output_tokens": 1}}}
    with open(project / f"{session_id}.jsonl", "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def write_compaction_boundary(session_id, trigger, pre_tokens, post_tokens=6000):
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    if config and session_id:
        project = Path(config) / "projects" / "-fixture-project"
        project.mkdir(parents=True, exist_ok=True)
        entry = {"type": "system", "subtype": "compact_boundary", "timestamp": timestamp,
                 "compactMetadata": {"trigger": trigger, "preTokens": pre_tokens, "postTokens": post_tokens}}
        with open(project / f"{session_id}.jsonl", "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry) + "\n")
    write({"type": "system", "status": "compacting"})
    write({"type": "system", "status": None, "compact_result": "success"})
    write({"type": "system", "subtype": "compact_boundary", "compact_metadata": {
        "trigger": trigger, "pre_tokens": pre_tokens, "post_tokens": post_tokens
    }})


# The token-waste session: a Claude Code request log (`api-request-shape`,
# `api-request-blob`, `api-request`) whose usage adds up exactly, so a test can
# assert what each item cost. An MCP tool returns a 1,000-line log, README.md is
# read twice, one request misses the prompt cache, and a compaction drops the
# log from the final transcript. Ordinary messages are written as transcript
# lines and referenced by hash, as the real CLI does; only the first prompt and
# the compaction summary get blob lines.
WASTE_LOG_LINES = 1000
WASTE_LOG = "".join(
    f"2026-11-03T10:{index // 60 % 60:02d}:{index % 60:02d}Z INFO fixture log line {index:04d} "
    f"{'NEEDLE-42 ' if index == 900 else ''}request ok path=/api/orc/builds/{index:04d}\n"
    for index in range(1, WASTE_LOG_LINES + 1)
)
WASTE_README = "Fixture README.\n" + "This project is a deterministic fixture for token accounting.\n" * 10
WASTE_FILLER_ROUNDS = 60
WASTE_CACHE_MISS_ROUND = 30
WASTE_SYSTEM_PROMPT = "You are the Claude Code fixture. " * 40


def message_hash(message):
    return hashlib.sha256(json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def write_waste_session(session_id):
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    if not config or not session_id:
        return
    project = Path(config) / "projects" / "-fixture-project"
    (project / session_id / "subagents").mkdir(parents=True, exist_ok=True)
    tool = lambda name, description: {"name": name, "description": description,
                                      "input_schema": {"type": "object", "properties": {"value": {"type": "string"}}}}
    write_request_log(project / f"{session_id}.jsonl", "waste", {
        "system": [{"type": "text", "text": WASTE_SYSTEM_PROMPT}],
        "tools": [tool("Bash", "Run a shell command."), tool("Read", "Read a file."),
                  tool("mcp__fixturelogs__query_logs", "Query the fixture's log stream."),
                  tool("mcp__fixturelogs__list_streams", "List the fixture's log streams.")],
    }, main_session_steps())
    write_request_log(project / session_id / "subagents" / "agent-fxw.jsonl", "waste_sub", {
        "system": [{"type": "text", "text": "You are a fixture subagent. " * 10}],
        "tools": [tool("Read", "Read a file.")],
    }, [
        ("blob", [{"role": "user", "content": "Find the README."}], 800),
        ("turn", [("toolu_sub_read", "Read", {"file_path": "README.md"}, WASTE_README)], 1000),
        ("end", "Found it."),
    ], sidechain=True)


# The instruction-resume session: Claude Code's request log for a session
# that resumed after AGENTS.md changed. The resumed prompt carries the new
# copy while the first prompt's copy stays in the history, so every request
# after the resume sends both; the date reminder is sent again word for word.
RESUME_AGENTS = "/fixture/repo/AGENTS.md"
RESUME_RULES = "# Fixture rules\n" + "- Keep answers short.\n" * 40
RESUME_FIRST_INSTRUCTIONS = (
    "<system-reminder>\nCodebase and user instructions are shown below. Be sure to adhere to these instructions.\n\n"
    f"Contents of {RESUME_AGENTS} (project instructions, checked into the codebase):\n\n{RESUME_RULES}</system-reminder>"
)
RESUME_REREAD_INSTRUCTIONS = (
    "<system-reminder>\nInstruction files were re-read when this session started; these differ from their earlier copies.\n\n"
    f"Contents of {RESUME_AGENTS} (project instructions, checked into the codebase):\n\n{RESUME_RULES}- Also run the checks.\n</system-reminder>"
)
RESUME_DATE = "<system-reminder>\nToday's date is 2026-11-03.\n</system-reminder>"


def write_resume_session(session_id):
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    if not config or not session_id:
        return
    project = Path(config) / "projects" / "-fixture-project"
    project.mkdir(parents=True, exist_ok=True)
    tool = lambda name, description: {"name": name, "description": description,
                                      "input_schema": {"type": "object", "properties": {"value": {"type": "string"}}}}
    prompt = lambda instructions, words: {"role": "user", "content": [
        {"type": "text", "text": instructions}, {"type": "text", "text": RESUME_DATE}, {"type": "text", "text": words}]}
    write_request_log(project / f"{session_id}.jsonl", "resume", {
        "system": [{"type": "text", "text": "You are the Claude Code fixture. " * 20}],
        "tools": [tool("Bash", "Run a shell command."), tool("Read", "Read a file.")],
    }, [
        ("blob", [prompt(RESUME_FIRST_INSTRUCTIONS, "Start the fixture work.")], 4000),
        ("turn", [("toolu_resume_read", "Read", {"file_path": "README.md"}, WASTE_README)], 4300),
        ("turn", [("toolu_resume_bash1", "Bash", {"command": "echo first"}, "first")], 4400),
        ("end", "First turn done."),
        ("resume", [prompt(RESUME_REREAD_INSTRUCTIONS, "Continue after the resume.")], 9000),
        ("turn", [("toolu_resume_bash2", "Bash", {"command": "echo resumed"}, "resumed")], 9100),
        ("end", "Resumed turn done."),
    ], params={"model": "claude-fixture", "max_tokens": 1000},
       cache_control=[{"path": ["system", 0], "value": {"type": "ephemeral"}}])


def main_session_steps():
    prompt = {"role": "user", "content": [
        {"type": "text", "text": "<system-reminder>\nFixture project instructions: keep answers short.\n</system-reminder>"},
        {"type": "text", "text": "Show token waste."},
    ]}
    steps = [
        ("blob", [prompt], 3000),
        ("turn", [("toolu_waste_logs", "mcp__fixturelogs__query_logs", {"stream": "orc", "limit": 5000}, WASTE_LOG)], 21000),
        ("turn", [("toolu_waste_read1", "Read", {"file_path": "README.md"}, WASTE_README)], 21200),
        ("turn", [("toolu_waste_read2", "Read", {"file_path": "README.md"}, WASTE_README)], 21400),
    ]
    context = 21400
    for index in range(WASTE_FILLER_ROUNDS):
        # The first round runs two tools in parallel: one assistant message over
        # two lines, and two user lines the API receives as one message.
        calls = [(f"toolu_waste_bash{index}_{part}", "Bash", {"command": f"echo step {index}.{part}"}, f"step {index}.{part}")
                 for part in range(2 if index == 0 else 1)]
        context += 30 * len(calls)
        steps.append(("turn", calls, context, index + 1 == WASTE_CACHE_MISS_ROUND))
    steps.append(("compact", {"role": "user", "content": [
        {"type": "text", "text": "Summary: the logs were checked and the README was read twice."}]}, 3100))
    steps.append(("turn", [("toolu_waste_outcome", "Bash", {"command": "report outcome"}, "ok")], 3160))
    steps.append(("end", "Token waste shown."))
    return steps


def write_request_log(path, prefix, shape, steps, sidechain=False, params=None, cache_control=None):
    """Writes each step's request, the transcript lines it added, and the
    assistant line carrying the usage of the request before it. A `resume`
    step sends the last answer and a new prompt on top of the history."""
    shape_hash = hashlib.sha256(json.dumps(shape, sort_keys=True).encode()).hexdigest()
    lines = [{"type": "api-request-shape", "shapeHash": shape_hash, "shape": shape}]
    chain = []
    previous = None
    previous_context = 0
    pending_output = None
    last_answer = None

    def request(tail, context, keep, miss=False):
        nonlocal previous, previous_context
        request_id = f"{prefix}_request_{len([l for l in lines if l['type'] == 'api-request']) + 1}"
        entry = {"type": "api-request", "id": request_id, "keep": keep, "tail": tail, "shapeHash": shape_hash,
                 "querySource": "sdk", "timestamp": "2026-11-03T10:00:00.000Z"}
        if previous:
            entry["base"] = previous
        if params:
            entry["params"] = params
        if cache_control:
            entry["cacheControl"] = cache_control
        lines.append(entry)
        if miss:
            usage = {"input_tokens": 50, "cache_read_input_tokens": 0, "cache_creation_input_tokens": context - 50, "output_tokens": 5}
        else:
            read = max(0, min(previous_context, context - 2))
            usage = {"input_tokens": 2, "cache_read_input_tokens": read, "cache_creation_input_tokens": context - read - 2, "output_tokens": 5}
        previous, previous_context = request_id, context
        return request_id, usage

    for step in steps:
        kind = step[0]
        if kind in ("blob", "compact"):
            messages = step[1] if kind == "blob" else [step[1]]
            hashes = []
            for message in messages:
                digest = message_hash(message)
                lines.append({"type": "api-request-blob", "hash": digest, "message": message})
                hashes.append(digest)
            keep = 0 if kind == "blob" else 1
            chain = (chain[:keep] if kind == "compact" else []) + hashes
            pending_output = request(hashes, step[2], keep)
        elif kind == "turn":
            calls, context = step[1], step[2]
            request_id, usage = pending_output
            message_id = f"msg_{request_id}"
            blocks = [{"type": "tool_use", "id": call[0], "name": call[1], "input": call[2]} for call in calls]
            for index, block in enumerate(blocks):
                lines.append({"type": "assistant", "isSidechain": sidechain, "requestRef": request_id, "apiBlockIndex": index,
                              "message": {"id": message_id, "role": "assistant", "content": [block], "usage": usage}})
            results = [{"type": "tool_result", "tool_use_id": call[0], "content": call[3]} for call in calls]
            for result in results:
                lines.append({"type": "user", "isSidechain": sidechain, "message": {"role": "user", "content": [result]}})
            tail = [message_hash({"role": "assistant", "content": blocks}), message_hash({"role": "user", "content": results})]
            pending_output = request(tail, context, len(chain), miss=len(step) > 3 and step[3])
            chain += tail
        elif kind == "end":
            request_id, usage = pending_output
            answer = [{"type": "text", "text": step[1]}]
            lines.append({"type": "assistant", "isSidechain": sidechain, "requestRef": request_id,
                          "message": {"id": f"msg_{request_id}", "role": "assistant", "content": answer, "usage": usage}})
            last_answer = message_hash({"role": "assistant", "content": answer})
        elif kind == "resume":
            hashes = [last_answer]
            for message in step[1]:
                digest = message_hash(message)
                lines.append({"type": "api-request-blob", "hash": digest, "message": message})
                hashes.append(digest)
            pending_output = request(hashes, step[2], len(chain))
            chain += hashes
    with open(path, "a", encoding="utf-8") as handle:
        for line in lines:
            handle.write(json.dumps(line) + "\n")


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
        line = STDIN.readline(0.02)
        if line is None:
            continue
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


def auth_command(arguments):
    """`claude auth status|login|logout`, as the Agents info block uses them.
    The account lives in `<executable>.auth-state` so a test can sign it out or in."""
    state_path = Path(str(sys.argv[0]) + ".auth-state")
    state = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {
        "loggedIn": True, "authMethod": "claude.ai", "email": "claude-fixture@example.com", "subscriptionType": "max"}
    if arguments[:1] == ["status"]:
        if Path(str(sys.argv[0]) + ".auth-status-error").exists():
            return 1
        print(json.dumps(state))
    elif arguments[:1] == ["logout"]:
        state_path.write_text(json.dumps({"loggedIn": False}), encoding="utf-8")
    elif arguments[:1] == ["login"]:
        state_path.write_text(json.dumps({
            "loggedIn": True, "authMethod": "claude.ai", "email": "claude-second@example.com", "subscriptionType": "pro"}), encoding="utf-8")
    return 0


def fixture_commands():
    """Mirrors Claude Code's initialize commands: its built-ins, plus the skills it
    finds in `.claude/skills` of the working folder and of each --add-dir folder,
    leaving out any `--settings` skillOverrides turn off. Like Claude Code
    v2.1.309+, an --add-dir skill whose name an earlier skill already uses is
    named `<folder name>:<skill name>`."""
    commands = [
        {"name": "simplify", "description": "Review the changed code for reuse.", "builtin": True},
        {"name": "compact", "description": "Free up context by summarizing the conversation so far", "builtin": True},
    ]
    arguments = sys.argv[1:]
    folders = [os.getcwd()] + [arguments[index + 1] for index, value in enumerate(arguments[:-1]) if value == "--add-dir"]
    overrides = json.loads(argument("--settings") or "{}").get("skillOverrides", {})
    seen = {command["name"] for command in commands}
    for index, folder in enumerate(folders):
        skills = Path(folder) / ".claude" / "skills"
        for entry in sorted(skills.iterdir()) if skills.is_dir() else []:
            if (entry / "SKILL.md").is_file() and overrides.get(entry.name) != "off":
                name = f"{Path(folder).name}:{entry.name}" if index > 0 and entry.name in seen else entry.name
                seen.add(entry.name)
                commands.append({"name": name, "description": f"{entry.name} ({folder})"})
    return commands


def main():
    global background_result_sent, current_command_uuid
    if sys.argv[1:2] == ["auth"]:
        return auth_command(sys.argv[2:])
    if "-reattach" in Path(sys.argv[0]).name and "-p" in sys.argv:
        return run_reattach_turn()
    history_path = Path(str(sys.argv[0]) + ".history")
    instructions = argument("--append-system-prompt") or ""
    turn = {
        "arguments": sys.argv[1:],
        "sessionID": argument("--session-id") or argument("--resume"),
        "resumed": "--resume" in sys.argv,
        "forkedFrom": argument("--resume") if "--fork-session" in sys.argv else None,
        "cwd": os.getcwd(),
        "bridgeServiceName": os.environ.get("PLAYHOUSE_BRIDGE_SERVICE_NAME"),
        "effort": os.environ.get("CLAUDE_CODE_EFFORT_LEVEL"),
        "autoCompactWindow": os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW"),
        # The non-built-in skills this launch would load, after bridging and overrides.
        "skills": [command["name"] for command in fixture_commands() if not command.get("builtin")],
    }
    for line in STDIN:
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("type") == "control_request":
            request = message.get("request", {})
            if request.get("subtype") == "initialize":
                # One line per Claude Code session started, including metadata-only ones.
                with open(str(sys.argv[0]) + ".sessions", "a", encoding="utf-8") as sessions:
                    sessions.write("initialize\n")
                missing_resume = Path(str(sys.argv[0]) + ".missing-resume")
                if "--resume" in sys.argv and missing_resume.exists():
                    missing_resume.unlink()
                    write({"type": "result", "subtype": "error", "is_error": True,
                           "result": "No conversation found with session ID"})
                    return 1
                # Claude Code announces the newest release of a family only through the
                # bare alias, which names the concrete model in `resolvedModel`; no entry
                # has that concrete name as its own value.
                models = [
                    {"value": "default", "resolvedModel": "claude-opus-5-5", "displayName": "Default"},
                    {"value": "opus", "resolvedModel": "claude-opus-5-5", "displayName": "Opus 5.5"},
                    {"value": "claude-opus-5-5-20251001", "resolvedModel": "claude-opus-5-5-20251001",
                     "displayName": "Opus 5.5 (2025-10-01)"},
                    {"value": "claude-opus-5", "resolvedModel": "claude-opus-5", "displayName": "Opus 5"},
                    {"value": "claude-opus-4-8", "resolvedModel": "claude-opus-4-8", "displayName": "Opus 4.8"},
                    {"value": "sonnet", "resolvedModel": "claude-sonnet-5-5", "displayName": "Sonnet 5.5"},
                    {"value": "claude-sonnet-4-6", "resolvedModel": "claude-sonnet-4-6", "displayName": "Sonnet 4.6"},
                    {"value": "haiku", "resolvedModel": "claude-haiku-4-6", "displayName": "Haiku 4.6"},
                    {"value": "claude-haiku-4-5-20251001", "resolvedModel": "claude-haiku-4-5-20251001",
                     "displayName": "Haiku 4.5"},
                ]
                if os.environ.get("PLAYHOUSE_CLAUDE_MODEL_LIST") == "aliases-only" or "aliases-only" in Path(sys.argv[0]).name:
                    # A release that reports bare aliases with no resolved model at all.
                    models = [{"value": model["value"], "displayName": model["displayName"].split(" ")[0]}
                              for model in models if "-" not in model["value"]]
                # Tests seed Playhouse's model cache through a real discovery of this list.
                models_override = Path(str(sys.argv[0]) + ".models-override")
                if models_override.exists():
                    models = json.loads(models_override.read_text(encoding="utf-8"))
                # Lets a test observe the cached list before discovery replaces it.
                if Path(str(sys.argv[0]) + ".models-delay").exists():
                    time.sleep(8)
                response = {"claude_code_version": "2.1.308 (Claude Code fixture)",
                            "models": models,
                            "commands": fixture_commands(), "agents": []}
            elif request.get("subtype") == "mcp_status":
                # The servers a test seeds in `<executable>.mcp-status` (such as a
                # claude.ai connector), then each server this run was passed with
                # --mcp-config, as Claude Code reports the servers it starts.
                # `<executable>.mcp-status-delay` holds the seconds the answer takes,
                # so a test can see the page while it is still checking.
                delay = Path(str(sys.argv[0]) + ".mcp-status-delay")
                if delay.exists():
                    time.sleep(float(delay.read_text(encoding="utf-8").strip() or "0"))
                seeded = Path(str(sys.argv[0]) + ".mcp-status")
                servers = json.loads(seeded.read_text(encoding="utf-8")) if seeded.exists() else []
                # A sign-in finishes when a test writes the server's name to
                # `<executable>.mcp-callback`, as the browser's redirect would.
                callback = Path(str(sys.argv[0]) + ".mcp-callback")
                signed_in = set(callback.read_text(encoding="utf-8").split("\n")) if callback.exists() else set()
                servers = [{**server, "status": "connected"} if server.get("name") in signed_in and server.get("status") == "needs-auth" else server
                           for server in servers]
                if "--mcp-config" in sys.argv:
                    passed = json.loads(sys.argv[sys.argv.index("--mcp-config") + 1]).get("mcpServers", {})
                    servers += [{"name": name, "status": "connected", "scope": "dynamic"} for name in sorted(passed)]
                response = {"mcpServers": servers}
            elif request.get("subtype") == "mcp_authenticate":
                # Claude Code's sign-in start: the link to open, with Claude Code
                # itself listening for the redirect. Each start is logged.
                name = request.get("serverName")
                with open(str(sys.argv[0]) + ".mcp-authenticate", "a", encoding="utf-8") as starts:
                    starts.write(json.dumps({"serverName": name}) + "\n")
                response = {"authUrl": f"https://auth.example.test/claude/authorize?server={name}",
                            "requiresUserAction": True, "callbackExpected": True,
                            "redirectScheme": "localhost", "callbackPort": 54321}
            elif request.get("subtype") == "get_usage":
                # The plan's usage as `/usage` reads it; without a seeded file the
                # account has none, as with an API-key login.
                with open(str(sys.argv[0]) + ".usage-reads", "a", encoding="utf-8") as reads:
                    reads.write(json.dumps({"skipBehaviors": request.get("skip_behaviors")}) + "\n")
                # A usage service that never answers: the request gets no reply at all.
                if Path(str(sys.argv[0]) + ".usage-hang").exists():
                    continue
                usage = Path(str(sys.argv[0]) + ".usage")
                response = json.loads(usage.read_text(encoding="utf-8")) if usage.exists() else {
                    "rate_limits_available": False, "rate_limits": None,
                }
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
            question_text = next(iter(answers)) if len(answers) == 1 else None
            if question_text not in QUESTION_TEXTS or not isinstance(answers[question_text], str) or not answers[question_text].strip():
                raise ValueError(f"Malformed Claude question answer: {answers!r}")
            answer = answers[question_text]
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
            rate_limit_event = Path(str(sys.argv[0]) + ".rate-limit-event")
            if rate_limit_event.exists():
                write(json.loads(rate_limit_event.read_text(encoding="utf-8")))
            content = message.get("message", {}).get("content", [])
            user_text = "".join(block.get("text", "") for block in content if block.get("type") == "text")
            turn["userText"] = user_text
            session_id = argument("--session-id") or argument("--resume")
            if user_text.strip() == "/compact":
                history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.exists() else {"turns": []}
                turn["compaction"] = {"trigger": "manual"}
                history.setdefault("turns", []).append(turn)
                history_path.write_text(json.dumps(history), encoding="utf-8")
                write({"type": "command_lifecycle", "command_uuid": current_command_uuid, "state": "started"})
                if Path(str(sys.argv[0]) + ".compact-hold").exists():
                    write({"type": "system", "subtype": "status", "status": "compacting"})
                    Path(str(sys.argv[0]) + ".compact-ready").touch()
                    deadline = time.monotonic() + 30
                    while time.monotonic() < deadline:
                        line = STDIN.readline(0.02)
                        if line is None:
                            continue
                        control = json.loads(line)
                        if control.get("type") == "control_request" and control.get("request", {}).get("subtype") == "interrupt":
                            write({"type": "control_response", "response": {
                                "subtype": "success", "request_id": control.get("request_id"), "response": {},
                            }})
                            write({"type": "system", "subtype": "status", "status": None, "compact_result": "failed"})
                            write({"type": "command_lifecycle", "command_uuid": current_command_uuid, "state": "completed"})
                            write({"type": "result", "subtype": "error", "is_error": True, "result": "Interrupted"})
                            return 0
                    raise TimeoutError("Compaction was not interrupted.")
                if Path(str(sys.argv[0]) + ".compact-fail").exists():
                    write({"type": "system", "subtype": "status", "status": "compacting"})
                    write({"type": "system", "subtype": "status", "status": None, "compact_result": "failed"})
                else:
                    write_compaction_boundary(session_id, "manual", 180000)
                write({"type": "command_lifecycle", "command_uuid": current_command_uuid, "state": "completed"})
                write({"type": "result", "subtype": "success", "is_error": False, "result": "", "usage": {
                    "input_tokens": 20, "output_tokens": 40, "cache_read_input_tokens": 180000,
                    "cache_creation_input_tokens": 0
                }})
                continue
            if match := re.search(r"fill context to (\d+) tokens(?: (\d+) minutes ago)?", user_text.lower()):
                filled = int(match.group(1))
                minutes_ago = int(match.group(2) or 0)
                write_session_context(session_id, filled, minutes_ago)
                turn["filledContextTokens"] = filled
                configured_window = int(os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "0") or 0)
                if configured_window and filled >= configured_window:
                    write_compaction_boundary(session_id, "auto", filled)
                    turn["autoCompacted"] = True
            # What arrived of each image, without keeping its payload in the history.
            turn["images"] = [
                {"mediaType": block.get("source", {}).get("media_type"),
                 "base64Length": len(block.get("source", {}).get("data", ""))}
                for block in content if block.get("type") == "image"
            ]
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
            maybe_burn_cpu()
            if SIDE_CHAT_MARKER in instructions:
                turn["reportCommands"] = side_chat_respond(user_text, instructions, turn, prior_turns)
            else:
                turn["reportCommands"] = respond(user_text, instructions, preserve_no_outcome=preserve_no_outcome,
                                                previous_prompt=previous_prompt)
            if (os.environ.get("PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME") == "1"
                    and "playhouse internal outcome nudge:" not in user_text.lower()
                    and "hold" not in user_text.lower()):
                outcome = report_command(instructions, " task outcome ", "waiting-response")
                if outcome:
                    turn["reportCommands"].append({
                        "command": outcome,
                        "output": run_tool("toolu_fixture_compaction_outcome", "Bash", {"command": outcome}, outcome),
                    })
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

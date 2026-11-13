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


def respond(user_text, instructions, preserve_no_outcome=False, previous_prompt=""):
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
    elif "playhouse internal outcome nudge:" in user_text.lower() and previous_prompt.rstrip().endswith(CHAT_SKIPPED_CLOSE_TURN_PROMPT.lower()):
        # Answers Playhouse's chat nudge the way it asks: close-turn for the previous reply,
        # then one short line, without repeating that reply.
        close_turn = report_command(instructions, " chat page close-turn ")
        if close_turn:
            command = close_turn.replace("--continues true", f"--continues false --new-title {shlex.quote(CHAT_NUDGE_PAGE_TITLE)}")
            commands.append({"command": command, "output": run_tool("toolu_nudged_close_turn", "Bash", {"command": command}, command)})
        text("msg_chat_nudge_reply", CHAT_NUDGE_REPLY)
    elif user_text.rstrip().endswith(CHAT_SKIPPED_CLOSE_TURN_PROMPT):
        text("msg_chat_skipped_close_turn", CHAT_SKIPPED_CLOSE_TURN_ANSWER)
    elif user_text.rstrip().endswith(CHAT_CLOSE_FIRST_PROMPT):
        close_turn = report_command(instructions, " chat page close-turn ")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": run_tool("toolu_close_first", "Bash", {"command": close_turn}, close_turn)})
        text("msg_chat_close_first_answer", CHAT_CLOSE_FIRST_ANSWER)
    elif user_text.rstrip().endswith(CHAT_NOTICE_PROMPT):
        # Mirrors the observed incident: the turn ends on close-turn, so Claude Code adds its
        # synthetic "no visible output" message to the same turn and Claude answers again.
        text("msg_chat_notice_answer", CHAT_NOTICE_ANSWER)
        close_turn = report_command(instructions, " chat page close-turn ")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": run_tool("toolu_close_last", "Bash", {"command": close_turn}, close_turn)})
        write({"type": "user", "parent_tool_use_id": None, "isSynthetic": True, "uuid": "fixture-no-visible-output-notice",
               "message": {"role": "user", "content": [{"type": "text", "text": NO_VISIBLE_OUTPUT_NOTICE}]}})
        text("msg_chat_notice_reply", CHAT_NOTICE_REPLY)
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
    elif "pending ui review" in user_text.lower():
        # Mirrors the observed incident: Claude answers while a background
        # review still runs, the review's notification lands right after that
        # answer, and the woken turn says nothing new (Claude Code's synthetic
        # "No response requested." never reaches stdout). No outcome is reported.
        tool_id = "toolu_pending_ui_review"
        task_id = "bgtask-pending-ui-review"
        assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Agent", "input": {
            "subagent_type": "ui-verifier", "description": "UI review", "prompt": "review the UI",
            "run_in_background": True,
        }}])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "ui-verifier", "description": "UI review"},
        ]})
        write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "UI review", "subagent_type": "ui-verifier",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        text("msg_pending_ui_review", NUDGE_RACE_STALE_ANSWER)
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        background_result_sent = True
        write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "", "summary": NUDGE_RACE_UI_REPORT})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        parent_request_started("msg_pending_ui_review_woken", woken=True)
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    elif "playhouse internal outcome nudge:" in user_text.lower() and "pending ui review" in previous_prompt:
        # The nudge says to keep working when work remains, and this turn does:
        # it runs a check, starts a background suite, and Claude Code wakes it
        # for the suite's notification, where it presents a screenshot, answers,
        # and only then reports completed.
        assistant("msg_nudged_intro", [{"type": "text", "text": NUDGED_COMMENTARY}])
        run_tool("toolu_nudged_check", "Bash", {"command": "echo NUDGED CHECK PASSED", "description": "Final check"},
                 "echo NUDGED CHECK PASSED")
        steered_uuid = None
        if Path(str(sys.argv[0]) + ".nudged-steer-pause").exists():
            # The test steers this running nudge turn, as a user can.
            Path(str(sys.argv[0]) + ".nudged-steer-ready").write_text("The nudged turn is waiting for a steer.\n", encoding="utf-8")
            steered, steered_uuid = read_steered_input("the nudged turn")
            text("msg_nudged_steer_answer", f"STEERED NUDGE: {steered}")
        assistant("msg_nudged_suite_intro", [{"type": "text", "text": NUDGED_SUITE_COMMENTARY}])
        suite_tool, suite_task = "toolu_nudged_suite", "bgtask-nudged-suite"
        assistant(f"msg_{suite_tool}", [{"type": "tool_use", "id": suite_tool, "name": "Agent", "input": {
            "subagent_type": "general-purpose", "description": "Final suite", "prompt": "run the suite",
            "run_in_background": True,
        }}])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": suite_tool, "content": "Async agent launched successfully.", "is_error": False},
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": suite_task, "run_id": "fixture-run-1", "task_type": "local_agent",
             "subagent_type": "general-purpose", "description": "Final suite"},
        ]})
        write({"type": "system", "subtype": "task_started", "task_id": suite_task, "run_id": "fixture-run-1",
               "tool_use_id": suite_tool, "description": "Final suite", "subagent_type": "general-purpose",
               "is_backgrounded": True, "spawn_depth": 1, "task_type": "local_agent"})
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        background_result_sent = True
        write({"type": "system", "subtype": "task_notification", "task_id": suite_task, "run_id": "fixture-run-1",
               "tool_use_id": suite_tool, "status": "completed", "output_file": "", "summary": NUDGED_SUITE_REPORT})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        parent_request_started("msg_nudged_woken", woken=True)
        present = report_command(instructions, " conversation present-image ")
        if present:
            image = Path(str(sys.argv[0]) + ".nudged-screenshot.png")
            image.write_bytes(bytes.fromhex(TINY_PNG_HEX))
            present = present.replace("<path>", shlex.quote(str(image))).replace(
                '[--caption "short caption"]', f"--caption {shlex.quote(NUDGED_IMAGE_CAPTION)}")
            commands.append({"command": present, "output": run_tool("toolu_nudged_image", "Bash", {"command": present}, present)})
        text("msg_nudged_final", NUDGED_FINAL_ANSWER)
        outcome = report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome, "output": run_tool("toolu_nudged_outcome", "Bash", {"command": outcome}, outcome)})
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        if steered_uuid:
            complete_command(steered_uuid)
            complete_command(current_command_uuid)
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
        recovery_pause = Path(str(sys.argv[0]) + ".recovery-pause")
        if recovery_pause.exists():
            # Hold the recovery turn open so tests can inspect it mid-turn.
            recovery_release = Path(str(sys.argv[0]) + ".recovery-release")
            Path(str(sys.argv[0]) + ".recovery-ready").write_text("The recovery turn is running.\n", encoding="utf-8")
            recovery_deadline = time.monotonic() + 30
            while not recovery_release.exists() and time.monotonic() < recovery_deadline:
                time.sleep(0.02)
            if not recovery_release.exists():
                raise TimeoutError("The test did not release the recovery turn.")
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
                "question": MARKDOWN_QUESTION,
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
        # Report one in-progress tool use before holding, so a user-initiated Stop
        # with no final answer still keeps the window's activity section mounted,
        # and the fold it performs on settle is distinguishable from the section
        # simply never having rendered.
        assistant("msg_stop_command", [{"type": "tool_use", "id": "toolu_stop_command", "name": "Bash", "input": {"command": "git status --short"}}])
        ready = Path(str(sys.argv[0]) + ".interrupt-ready")
        ready.write_text("The Claude fixture turn is active and waiting for an interrupt.\n", encoding="utf-8")
        deadline = time.monotonic() + 30
        received_interrupt = False
        while time.monotonic() < deadline:
            line = STDIN.readline(0.02)
            if line is None:
                continue
            control = json.loads(line)
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
    elif user_text.strip().lower() == "please fail-this-claude-turn.":
        # Match only the live message, not a historical mention: once this turn
        # fails and its text is part of the transcript, a later turn's handoff
        # context quotes it back verbatim, and a substring check would misfire.
        # The session already exists by now: Playhouse answered initialize and
        # sent this turn. Failing here leaves the session behind, so the next
        # turn must resume it instead of claiming its ID again.
        raise RuntimeError("Claude fixture failed this turn after creating its session.")
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
    elif "show-tool-calls-inline" in user_text.lower():
        # Commentary, then shell calls with their stated purpose and output, a
        # failing call, and an MCP call whose arguments and result stay private,
        # so the timeline can place each call after the text written before it.
        def tool_call(tool_id, name, tool_input, output, is_error=False):
            assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}])
            write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tool_id, "content": output, "is_error": is_error},
            ]}})
        text("msg_timeline_intro", "I'll check the repository status first.")
        tool_call("toolu_timeline_status", "Bash", {
            "command": "git status --short && echo fixture-status-done", "description": "Check repository status",
        }, "fixture-status-done")
        text("msg_timeline_middle", "The status is clean. Next I'll list the files and run the check.")
        tool_call("toolu_timeline_list", "Bash", {"command": "ls -1", "description": "List fixture files"},
                  "README.md\nfixture-one.txt\nfixture-two.txt\nfixture-three.txt\nfixture-four.txt")
        tool_call("toolu_timeline_fail", "Bash", {"command": "exit 3", "description": "Run the failing check"},
                  "Exit code 3", is_error=True)
        tool_call("toolu_timeline_mcp", "mcp__fixture__lookup", {"query": "timeline-private-argument"},
                  "timeline-private-result")
        text("msg_timeline_final", "Here is what ran:\n1. `git status --short` was clean.\n2. The check exited with code `3`.\n\n- Bullets read at text size\n- Inline `code` is tinted")
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
    elif "stream-follow-latest" in user_text.lower():
        # Streams a long reply in held stages, so a test can check the transcript
        # between them: following the bottom, then left alone once scrolled up.
        for stage, count in enumerate(STREAM_FOLLOW_STAGES, start=1):
            first = sum(STREAM_FOLLOW_STAGES[:stage - 1]) + 1
            for line in range(first, first + count):
                text(f"msg_stream_follow_{line}", stream_follow_line(line))
            ready = Path(str(sys.argv[0]) + f".stream-follow-ready-{stage}")
            release = Path(str(sys.argv[0]) + f".stream-follow-release-{stage}")
            ready.write_text(f"Streamed follow stage {stage} is visible.\n", encoding="utf-8")
            deadline = time.monotonic() + 60
            while not release.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            ready.unlink(missing_ok=True)
            if not release.exists():
                raise TimeoutError(f"The test did not release streamed follow stage {stage}.")
            release.unlink(missing_ok=True)
        text("msg_stream_follow_final", STREAM_FOLLOW_FINAL)
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
    elif "recall-earlier-pages" in user_text.lower():
        # A standalone chat looking back: it reads each earlier page named in the
        # message ("page-id:<id>") with the real `chat page read` command, then answers.
        close_turn = report_command(instructions, " chat page close-turn ")
        cli = close_turn.split(" chat page close-turn ")[0] if close_turn else None
        turn_key = hashlib.md5(user_text.encode()).hexdigest()[:8]
        text(f"msg_recall_intro_{turn_key}", "Let me look back at those pages.")
        for index, page_id in enumerate(re.findall(r"page-id:([A-Za-z0-9-]+)", user_text)):
            command = f"{cli} chat page read {page_id}"
            commands.append({"command": command,
                             "output": run_tool(f"toolu_recall_{index}", "Bash", {"command": command}, command)})
        hold = Path(str(sys.argv[0]) + ".recall-hold")
        if hold.exists():
            # Holds the turn open after the reads so a test can look at the live turn.
            ready = Path(str(sys.argv[0]) + ".recall-ready")
            release = Path(str(sys.argv[0]) + ".recall-release")
            ready.write_text("The recalling turn is active.\n", encoding="utf-8")
            deadline = time.monotonic() + 60
            while not release.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            ready.unlink(missing_ok=True)
            if not release.exists():
                raise TimeoutError("Timed out waiting for the recall hold release.")
            hold.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
        text(f"msg_recall_answer_{turn_key}", "I recalled both pages.")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": run_tool("toolu_close_turn", "Bash", {"command": close_turn}, close_turn)})
    elif "release notes" in user_text.lower():
        # A standalone chat has no outcome to report, so it ends every turn with
        # its page signal instead. That signal runs in the same place a task
        # outcome does: after the answer, before Claude's closing line.
        text("msg_chat_intent", CHAT_INTENT)
        run_tool("toolu_chat_read", "Read", {"file_path": os.path.join(os.getcwd(), "README.md")})
        text("msg_chat_answer", CHAT_ANSWER)
        close_turn = report_command(instructions, " chat page close-turn ")
        if close_turn:
            commands.append({"command": close_turn,
                             "output": run_tool("toolu_close_turn", "Bash", {"command": close_turn}, close_turn)})
        text("msg_chat_closing", CHAT_CLOSING)
    elif match := re.search(r"long history turn (\d+)", user_text.lower()):
        # Thirty visible assistant messages in one turn, so a few turns build a
        # transcript long enough to page through.
        number = match.group(1)
        for index in range(1, 31):
            text(f"msg_long_{number}_{index}", f"Long history turn {number}, message {index}.")
    elif "token waste" in user_text.lower() or "instruction resume" in user_text.lower():
        if "instruction resume" in user_text.lower():
            write_resume_session(argument("--session-id") or argument("--resume"))
        else:
            write_waste_session(argument("--session-id") or argument("--resume"))
        text("msg_waste_answer", "Token waste shown.")
        progress_clear = report_command(instructions, " task progress clear ")
        outcome = report_command(instructions, " task outcome ", "completed")
        for tool_id, command in [("toolu_progress_clear", progress_clear), ("toolu_outcome", outcome)]:
            if command:
                commands.append({"command": command, "output": run_tool(tool_id, "Bash", {"command": command}, command)})
        text("msg_waste_closing", "The token waste is above.")
    elif "story" in user_text.lower():
        # Kept on disk because each send may start a fresh fixture process, and
        # a repeated message ID would make the second turn's calls look like the first's.
        counter = Path(str(sys.argv[0]) + ".story-turns")
        story_turns = (int(counter.read_text()) if counter.is_file() else 0) + 1
        counter.write_text(str(story_turns))
        main_ids = [f"msg_story_{story_turns}", f"msg_story_closing_{story_turns}"]
        for index, usage in enumerate(STORY_SUBAGENT_CALLS):
            assistant(f"msg_fx_sub{story_turns}_{index}", [{"type": "text", "text": "subagent step"}], usage,
                      parent=f"toolu_fx_agent_{story_turns}")
        write_session_calls(argument("--session-id") or argument("--resume"), story_turns,
                            list(zip(main_ids, STORY_MAIN_CALLS)))
        text(main_ids[0], STORY, STORY_MAIN_CALLS[0])
        # Claude Code writes one line per content block of a call; the repeat shares the call's ID.
        assistant(main_ids[0], [{"type": "thinking", "thinking": ""}], STORY_MAIN_CALLS[0])
        progress_clear = report_command(instructions, " task progress clear ")
        outcome = report_command(instructions, " task outcome ", "completed")
        for tool_id, command in [("toolu_progress_clear", progress_clear), ("toolu_outcome", outcome)]:
            if command:
                commands.append({"command": command, "output": run_tool(tool_id, "Bash", {"command": command}, command)})
        text(main_ids[1], STORY_CLOSING, STORY_MAIN_CALLS[1])
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
        assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo WAKE", "description": "Consumed wake shell", "run_in_background": True,
        }}])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Consumed wake shell"},
        ]})
        write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Consumed wake shell", "task_type": "local_bash"})
        text("msg_consumed_wake_started", "WAKE SHELL STARTED")
        outcome = report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome,
                             "output": run_tool("toolu_consumed_wake_outcome", "Bash", {"command": outcome}, outcome)})
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        background_result_sent = True
        complete_command(current_command_uuid)
        wait_for_release("consumed-wake", "The parent result is out while the background shell runs.")
        write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Consumed wake shell" completed (exit code 0)'})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        # The woken provider turn starts and then goes quiet: no parent request,
        # no answer, no result of its own, ever.
        write({"type": "system", "subtype": "init"})
        Path(str(sys.argv[0]) + ".consumed-wake-woken").write_text(
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
        assistant(f"msg_{tool_id}", [{"type": "tool_use", "id": tool_id, "name": "Bash", "input": {
            "command": "sleep 1; echo SLOW", "description": "Slow woken shell", "run_in_background": True,
        }}])
        write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": tool_id, "is_error": False,
             "content": f"Command running in background with ID: {task_id}."},
        ]}})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": [
            {"task_id": task_id, "run_id": "fixture-run-1", "task_type": "local_bash", "description": "Slow woken shell"},
        ]})
        write({"type": "system", "subtype": "task_started", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "description": "Slow woken shell", "task_type": "local_bash"})
        text("msg_slow_woken_started", "SLOW SHELL STARTED")
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        background_result_sent = True
        complete_command(current_command_uuid)
        write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Slow woken shell" completed (exit code 0)'})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        write({"type": "system", "subtype": "init"})
        Path(str(sys.argv[0]) + ".slow-woken-announced").write_text(
            "The woken turn started and is about to go quiet for a while.\n", encoding="utf-8"
        )
        time.sleep(float(os.environ.get("PLAYHOUSE_E2E_CLAUDE_SLOW_WOKEN_SILENCE_SECONDS", "6")))
        # Only `parent_request_started` without a second `init`: this turn was
        # already announced above, it is just finally speaking.
        parent_request_started("msg_slow_woken_answer")
        text("msg_slow_woken_answer", "SLOW WOKEN HANDLED")
        outcome = report_command(instructions, " task outcome ", "completed")
        if outcome:
            commands.append({"command": outcome,
                             "output": run_tool("toolu_slow_woken_outcome", "Bash", {"command": outcome}, outcome)})
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
        parent_request_started("msg_parked_steered_answer")
        text("msg_parked_steered", f"STEERED: {steered}")
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        write({"type": "system", "subtype": "task_updated", "task_id": task_id, "run_id": "fixture-run-1",
               "patch": {"status": "completed", "end_time": 0}})
        write({"type": "system", "subtype": "task_notification", "task_id": task_id, "run_id": "fixture-run-1",
               "tool_use_id": tool_id, "status": "completed", "output_file": "",
               "summary": 'Background command "Parked shell" completed (exit code 0)'})
        write({"type": "system", "subtype": "background_tasks_changed", "tasks": []})
        parent_request_started("msg_parked_final", woken=True)
        text("msg_parked_final", "PARKED HANDLED")
        wait_for_release("steered-answer", "The steered answer is visible while the woken parent result is pending.")
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


def run_reattach_turn():
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
    Every input line is logged to `.reattach-stdin`."""
    base = str(sys.argv[0])
    instructions = argument("--append-system-prompt") or ""
    turn_uuid = None
    reporting = None
    pending = {}

    def log(name, value):
        with open(f"{base}.{name}", "a", encoding="utf-8") as handle:
            handle.write(json.dumps(value) + "\n")

    def finish():
        write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
        complete_command(turn_uuid)

    def handle(line):
        nonlocal turn_uuid, reporting
        log("reattach-stdin", line)
        if not line.strip():
            return
        message = json.loads(line)
        kind = message.get("type")
        if kind == "control_request":
            subtype = (message.get("request") or {}).get("subtype")
            response = {"claude_code_version": "2.1.308 (Claude Code fixture)", "models": [], "commands": [], "agents": []} \
                if subtype == "initialize" else {}
            if subtype == "interrupt":
                Path(f"{base}.reattach-interrupted").write_text(message.get("request_id", ""), encoding="utf-8")
            write({"type": "control_response", "response": {
                "subtype": "success", "request_id": message.get("request_id"), "response": response}})
            if subtype == "interrupt":
                write({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "Interrupted."})
                complete_command(turn_uuid)
        elif kind == "control_response":
            response = message.get("response") or {}
            request_id = response.get("request_id")
            log("reattach-replies", {"id": request_id, "response": response.get("response")})
            if pending.pop(request_id, None) == "question":
                answers = ((response.get("response") or {}).get("updatedInput") or {}).get("answers") or {}
                write({"type": "user", "parent_tool_use_id": None, "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_reattach_question", "content": json.dumps(answers), "is_error": False}]}})
                text("msg_reattach_answer", f"Answer received: {answers.get('Which color?', '')}.")
        elif kind == "user":
            content = message.get("message", {}).get("content", [])
            user_text = "".join(block.get("text", "") for block in content if block.get("type") == "text")
            if turn_uuid is None and user_text.startswith("Classify the latest user message for Playhouse's continuous chat page index."):
                turn_uuid = message.get("uuid")
                text("msg_reattach_classification", '{"continues":false,"title":"Restart fallback"}')
                finish()
            elif turn_uuid is None and "playhouse internal outcome nudge" in user_text.lower() \
                    and Path(f"{base}.reattach-hold-nudge").exists():
                Path(f"{base}.reattach-hold-nudge").unlink()
                turn_uuid = message.get("uuid")
                write({"type": "system", "subtype": "init", "session_id": argument("--session-id") or argument("--resume")})
                text("msg_reattach_nudge_before", "Nudge before restart.")
                Path(f"{base}.reattach-ready").write_text(user_text, encoding="utf-8")
            elif turn_uuid is None and "playhouse internal outcome nudge" in user_text.lower():
                # A status nudge is answered at once with the outcome.
                turn_uuid = message.get("uuid")
                text("msg_reattach_nudge", "Waiting for your review.")
                command = report_command(instructions, "task outcome", "waiting-response")
                reporting = subprocess.Popen(shlex.split(command), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) \
                    if command else None
                if reporting is None:
                    finish()
            elif turn_uuid is None:
                turn_uuid = message.get("uuid")
                write({"type": "system", "subtype": "init", "session_id": argument("--session-id") or argument("--resume")})
                text("msg_reattach_before", "Before restart.")
                Path(f"{base}.reattach-ready").write_text(user_text, encoding="utf-8")
            else:
                # A steered follow-up reaches the running turn and is answered in it.
                log("reattach-steers", user_text)
                text(f"msg_reattach_steer_{len(user_text)}", f"Steer received: {user_text}")
                complete_command(message.get("uuid"))

    while True:
        line = STDIN.readline(0.05)
        while line:
            handle(line[:-1] if line.endswith("\n") else line)
            line = STDIN.readline(0)
        if line == "":
            # A piped helper run ends with its input; a file-backed run never sees this.
            return 0
        if turn_uuid is None:
            continue
        if Path(f"{base}.reattach-ask").exists():
            Path(f"{base}.reattach-ask").unlink()
            pending["reattach-approval-1"] = "approval"
            write({"type": "control_request", "request_id": "reattach-approval-1", "request": {
                "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "touch reattach.txt"}}})
            pending["reattach-question-1"] = "question"
            write({"type": "control_request", "request_id": "reattach-question-1", "request": {
                "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": {"questions": [{
                    "question": "Which color?", "header": "Color",
                    "options": [{"label": "red"}, {"label": "blue"}], "multiSelect": False}]}}})
            Path(f"{base}.reattach-asked").write_text("asked\n", encoding="utf-8")
        close_turn_marker = Path(f"{base}.reattach-close-turn")
        if close_turn_marker.exists():
            title = close_turn_marker.read_text(encoding="utf-8").strip()
            close_turn_marker.unlink()
            command = report_command(instructions, " chat page close-turn ")
            if command and title:
                command = command.replace("--continues true", f"--continues false --new-title {shlex.quote(title)}")
            # Like a tool call, it runs inside the turn, which keeps going after it returns.
            completed = subprocess.run(shlex.split(command), capture_output=True, text=True) if command else None
            log("reattach-close-turn-output", {
                "command": command,
                "returncode": completed.returncode if completed else None,
                "output": completed.stdout if completed else "",
            })
        if Path(f"{base}.reattach-late-reply").exists():
            Path(f"{base}.reattach-late-reply").unlink()
            write({"type": "control_response", "response": {"subtype": "success", "request_id": "playhouse-1", "response": {}}})
        if Path(f"{base}.reattach-exit").exists():
            # Consumed, so a later turn of the same fixture runs normally.
            Path(f"{base}.reattach-exit").unlink(missing_ok=True)
            os._exit(3)
        if reporting is None and Path(f"{base}.reattach-release-quiet").exists():
            Path(f"{base}.reattach-release-quiet").unlink()
            text("msg_reattach_after", "After restart.")
            finish()
        if reporting is None and Path(f"{base}.reattach-release").exists():
            Path(f"{base}.reattach-release").unlink()
            text("msg_reattach_after", "After restart.")
            command = report_command(instructions, "task outcome", "waiting-response")
            # Like a tool call, the report runs while the turn keeps reading its input.
            reporting = subprocess.Popen(shlex.split(command), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) \
                if command else None
            if reporting is None:
                finish()
        if reporting is not None and reporting.poll() is not None:
            reporting = None
            finish()


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

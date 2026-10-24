#!/usr/bin/env python3
"""Deterministic stand-in for the `claude` CLI's stream-json protocol.

StationAI launches it exactly like Claude Code (`-p --input-format stream-json
--output-format stream-json ... --append-system-prompt <instructions>`). Each
process serves one turn, as Claude Code does under StationAI. The reply
reproduces Claude's observed habit of answering, running its StationAI report
commands, and then adding a closing line. The report commands are taken from the
instructions StationAI appended and really run, so outcomes reach the task.

Every turn is recorded in `<executable>.history` for test assertions.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

STORY = "BISCUIT-7 waited by the gate every evening. One night the boy finally came home."
STORY_CLOSING = "The story is above."
INSPECTION_INTENT = "I'll inspect the workspace first."
INSPECTION_ANSWER = "Inspection done: the workspace is ready."
UNANSWERED_FIRST = "Starting the checks."
UNANSWERED_LAST = "Checks are running; results will follow."
SIMPLE_ANSWER = "OK."


def write(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


def argument(name):
    arguments = sys.argv[1:]
    return arguments[arguments.index(name) + 1] if name in arguments else None


def report_command(instructions, marker, replacement=None):
    """Returns the CLI command line StationAI's instructions give for `marker`."""
    for line in instructions.splitlines():
        if marker in line:
            command = line.strip()
            return command.replace("<completed|waiting-response>", replacement) if replacement else command
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


def respond(user_text, instructions):
    commands = []
    if "story" in user_text.lower():
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
    else:
        text("msg_simple", SIMPLE_ANSWER)
    write({"type": "result", "subtype": "success", "is_error": False, "result": ""})
    return commands


def main():
    history_path = Path(str(sys.argv[0]) + ".history")
    instructions = argument("--append-system-prompt") or ""
    turn = {
        "arguments": sys.argv[1:],
        "sessionID": argument("--session-id") or argument("--resume"),
        "resumed": "--resume" in sys.argv,
        "cwd": os.getcwd(),
        "bridgeServiceName": os.environ.get("STATIONAI_BRIDGE_SERVICE_NAME"),
    }
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("type") == "control_request":
            request = message.get("request", {})
            if request.get("subtype") == "initialize":
                response = {"claude_code_version": "2.1.308 (Claude Code fixture)",
                            "models": [{"value": "default", "displayName": "Default"}],
                            "commands": [], "agents": []}
            elif request.get("subtype") == "mcp_status":
                response = {"mcpServers": []}
            else:
                response = {}
            write({"type": "control_response", "response": {
                "subtype": "success", "request_id": message.get("request_id"), "response": response,
            }})
        elif message.get("type") == "user":
            content = message.get("message", {}).get("content", [])
            user_text = "".join(block.get("text", "") for block in content if block.get("type") == "text")
            turn["userText"] = user_text
            turn["reportCommands"] = respond(user_text, instructions)
            history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.exists() else {"turns": []}
            history["turns"].append(turn)
            history_path.write_text(json.dumps(history), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())

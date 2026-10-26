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
    if "hold until stopped" in user_text.lower() or "hold-until-stopped" in user_text.lower():
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
    elif user_text.startswith("Write a concise task title"):
        if "title-failure" not in sys.argv[0]:
            text("msg_title", "Generated Claude title")
    elif "<response-comments>" in user_text:
        payload = user_text.split("<response-comments>", 1)[1].split("</response-comments>", 1)[0]
        comments = json.loads(payload)
        answer = "\n".join(
            f':stationai-annotation{{index="{index}"}} For ‘{item["text"]}’: {item["comment"]}'
            for index, item in enumerate(comments)
        )
        text("msg_comments", answer)
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
        "effort": os.environ.get("CLAUDE_CODE_EFFORT_LEVEL"),
    }
    for line in sys.stdin:
        if not line.strip():
            continue
        message = json.loads(line)
        if message.get("type") == "control_request":
            request = message.get("request", {})
            if request.get("subtype") == "initialize":
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
                if os.environ.get("STATIONAI_CLAUDE_MODEL_LIST") == "aliases-only" or "aliases-only" in Path(sys.argv[0]).name:
                    models = models[:2] + models[5:6] + models[8:9]
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

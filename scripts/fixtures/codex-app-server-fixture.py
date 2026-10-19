#!/usr/bin/env python3

"""Deterministic app-server peer for StationAI's structured-question tests."""

import json
import os
import sys
import time
from pathlib import Path

if "-title-" in Path(sys.argv[0]).name:
    THREAD_ID = f"stationai-fixture-{os.getpid()}"
    TURN_ID = f"turn-stationai-fixture-{os.getpid()}"
else:
    THREAD_ID = "00000000-0000-0000-0000-000000000001"
    TURN_ID = "turn_stationai_fixture"


def write(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def question_request(request_id):
    mode = os.path.basename(sys.argv[0])
    questions = [] if mode.endswith("-empty") else [
        {
            "id": "color",
            "header": "Color",
            "question": "Which color should I use?",
            "options": [
                {"label": "Blue", "description": "Use blue."},
                {"label": "Green", "description": "Use green."},
            ],
            "isOther": False,
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
    write({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "item/tool/requestUserInput",
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


def main():
    mode = os.path.basename(sys.argv[0])
    answers = None
    saw_question = False
    saw_turn = False
    turn_message = None
    history_path = Path(str(sys.argv[0]) + ".history")
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("method") == "initialized":
            continue
        if "method" in message and "id" not in message:
            continue
        if message.get("method") == "initialize":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"serverInfo": {"name": "stationai-fixture", "version": "1"}}})
        elif message.get("method") == "thread/start":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": "gpt-6-luna"}})
        elif message.get("method") == "thread/resume":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": "gpt-6-luna"}})
        elif message.get("method") == "turn/start":
            saw_turn = True
            saw_question = True
            turn_input = message.get("params", {}).get("input", [])
            turn_message = next((item.get("text") for item in turn_input if item.get("type") == "text"), None)
            is_title_request = (turn_message or "").startswith("Write a concise task title of at most 8 words")
            if is_title_request:
                write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
                if mode.endswith("-title-failure"):
                    write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                        "threadId": THREAD_ID,
                        "turn": {"id": TURN_ID, "status": "failed", "error": {"message": "Fixture rejected task-title generation."}},
                    }})
                    continue
                if mode.endswith("-success-wait"):
                    ready = Path(str(sys.argv[0]) + ".resolve-ready")
                    resume = Path(str(sys.argv[0]) + ".resolve-continue")
                    ready.write_text("Codex task-title turn is active.\n", encoding="utf-8")
                    deadline = time.monotonic() + 30
                    while not resume.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    if not resume.exists():
                        return 3
                    ready.unlink(missing_ok=True)
                    resume.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID,
                    "item": {"id": "item_stationai_title", "type": "agentMessage", "text": "Generated fixture title"},
                }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
                continue
            image_inputs = [item for item in turn_input if item.get("type") == "image"]
            history_path.write_text(json.dumps({
                "userMessage": turn_message,
                "images": [item.get("url") for item in image_inputs],
                "imageInputs": image_inputs,
                "developerInstructions": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("developerInstructions"),
            }), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
            if mode.endswith("-abort"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "interrupted", "error": {"message": "Fixture interrupted the conflict-resolution turn."}},
                }})
            elif mode.endswith("-success"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-title-failure"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-success-wait"):
                ready = Path(str(sys.argv[0]) + ".resolve-ready")
                resume = Path(str(sys.argv[0]) + ".resolve-continue")
                ready.write_text("Codex conflict-resolution turn is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not resume.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                if not resume.exists():
                    return 3
                ready.unlink(missing_ok=True)
                resume.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-subagent"):
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "item": subagent_item("inProgress"),
                }})
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "item": subagent_item("completed"),
                }})
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-markdown"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "00000000-0000-0000-0000-000000000001",
                    "turn": {"id": "turn_stationai_fixture", "status": "completed"},
                }})
            elif mode.endswith("-markdown"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "00000000-0000-0000-0000-000000000001",
                    "turn": {"id": "turn_stationai_fixture", "status": "completed"},
                }})
            elif mode.endswith("-hold"):
                time.sleep(30)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-question"):
                active = Path(str(sys.argv[0]) + ".turn-active")
                release = Path(str(sys.argv[0]) + ".turn-release")
                active.write_text("The progress report fixture turn is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                if not was_released:
                    return 3
                question_request(901)
            elif "-hold-release" in mode:
                active = Path(str(sys.argv[0]) + ".turn-active")
                release = Path(str(sys.argv[0]) + ".turn-release")
                active.write_text("The progress report fixture turn is active.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                if not was_released:
                    return 3
                turn_status = "interrupted" if "-interrupted" in mode else ("failed" if "-failed" in mode else "completed")
                turn_error = {"error": {"message": "Codex interrupted this turn." if turn_status == "interrupted" else "Codex failed this turn."}} if turn_status != "completed" else {}
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "00000000-0000-0000-0000-000000000001",
                    "turn": {"id": "turn_stationai_fixture", "status": turn_status, **turn_error},
                }})
            else:
                question_request(901)
        elif message.get("id") == 901:
            if "error" in message:
                answers = None
            else:
                answers = message.get("result", {}).get("answers")
            if "-slow" in mode and not mode.endswith("-interrupted"):
                time.sleep(2)
            failed = mode.endswith("-empty") or mode.endswith("-fail") or answers != {
                "color": {"answers": ["Blue"]},
                "token": {"answers": ["fixture-secret"]},
            }
            write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": THREAD_ID,
                "turn": {"id": TURN_ID, "status": "interrupted" if mode.endswith("-interrupted") else ("failed" if failed else "completed"),
                         **({"error": {"message": "Codex interrupted this turn."}} if mode.endswith("-interrupted") else ({"error": {"message": "Question response was missing or incorrect."}} if failed else {}))},
            }})
        elif message.get("method") == "thread/items/list":
            saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
            user_message = saved_history.get("userMessage") or (turn_message if answers else None)
            user_images = saved_history.get("images", [])
            user_content = ([{"type": "text", "text": user_message}] if user_message else []) + [
                {"type": "image", "image_url": image_url} for image_url in user_images
            ]
            contents = ([
                {"id": "item_user_fixture", "type": "userMessage", "content": user_content},
                {"id": "item_assistant_fixture", "type": "agentMessage", "text": "Answers received: Blue / fixture-secret."},
            ] if user_content and not mode.endswith("-empty") else [])
            if mode.endswith("-subagent"):
                contents = [
                    {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Delegate this task."}]},
                    {"id": "item_assistant_fixture", "type": "agentMessage", "text": "The subagent inspected the project structure."},
                    subagent_item("completed"),
                ]
            if mode.endswith("-markdown"):
                saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
                contents = [
                    {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": saved_history.get("userMessage", "Plan the task.")} ]},
                    {"id": "item_assistant_fixture", "type": "agentMessage", "text": "## Implementation plan\n\nStart with the **workspace model**.\n\n- Add structured conversation rendering\n- Verify history after reopening"},
                ]
            write({"jsonrpc": "2.0", "id": message["id"], "result": {
                "data": [{"item": item, "turnId": TURN_ID} for item in contents],
                "nextCursor": None,
            }})
    if not saw_turn:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

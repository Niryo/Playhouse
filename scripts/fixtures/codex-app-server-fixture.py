#!/usr/bin/env python3

"""Deterministic app-server peer for StationAI's structured-question tests."""

import json
import os
import sys
import time
from pathlib import Path


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
            "threadId": "thr_stationai_fixture",
            "turnId": "turn_stationai_fixture",
            "itemId": "item_stationai_question",
            "questions": questions,
            "isBlocking": "-nonblocking" not in mode,
        },
    })


def main():
    mode = os.path.basename(sys.argv[0])
    answers = None
    saw_question = False
    saw_turn = False
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
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": "thr_stationai_fixture"}, "model": "gpt-6-luna"}})
        elif message.get("method") == "thread/resume":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": "thr_stationai_fixture"}, "model": "gpt-6-luna"}})
        elif message.get("method") == "turn/start":
            saw_turn = True
            saw_question = True
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": "turn_stationai_fixture", "status": "inProgress"}}})
            if mode.endswith("-abort"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "thr_stationai_fixture",
                    "turn": {"id": "turn_stationai_fixture", "status": "interrupted", "error": {"message": "Fixture interrupted the conflict-resolution turn."}},
                }})
            elif mode.endswith("-success"):
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "thr_stationai_fixture",
                    "turn": {"id": "turn_stationai_fixture", "status": "completed"},
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
                    "threadId": "thr_stationai_fixture",
                    "turn": {"id": "turn_stationai_fixture", "status": "completed"},
                }})
            elif mode.endswith("-hold"):
                time.sleep(30)
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": "thr_stationai_fixture",
                    "turn": {"id": "turn_stationai_fixture", "status": "completed"},
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
                "threadId": "thr_stationai_fixture",
                "turn": {"id": "turn_stationai_fixture", "status": "interrupted" if mode.endswith("-interrupted") else ("failed" if failed else "completed"),
                         **({"error": {"message": "Codex interrupted this turn."}} if mode.endswith("-interrupted") else ({"error": {"message": "Question response was missing or incorrect."}} if failed else {}))},
            }})
        elif message.get("method") == "thread/items/list":
            contents = [
                {"id": "item_user_fixture", "type": "userMessage", "content": [{"type": "text", "text": "Please ask your questions."}]},
                {"id": "item_assistant_fixture", "type": "agentMessage", "text": "Answers received: Blue / fixture-secret."},
            ] if answers and not mode.endswith("-empty") else []
            write({"jsonrpc": "2.0", "id": message["id"], "result": {
                "data": [{"item": item, "turnId": "turn_stationai_fixture"} for item in contents],
                "nextCursor": None,
            }})
    if not saw_turn:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

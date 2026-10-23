#!/usr/bin/env python3

"""Deterministic app-server peer for StationAI's protocol integration tests."""

import json
import os
import select
import sys
import time
import uuid
from pathlib import Path

if "-title-" in Path(sys.argv[0]).name:
    THREAD_ID = f"stationai-fixture-{os.getpid()}"
    TURN_ID = f"turn-stationai-fixture-{os.getpid()}"
else:
    THREAD_ID = "00000000-0000-0000-0000-000000000001"
    TURN_ID = "turn_stationai_fixture"


MARKDOWN_PLAN = '## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening'

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
    mode = os.path.basename(sys.argv[0])
    answers = None
    saw_question = False
    saw_turn = False
    turn_message = None
    history_path = Path(str(sys.argv[0]) + ".history")
    if "-goal" in mode:
        Path(str(sys.argv[0]) + ".launch-args").write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
    goal_path = Path(str(sys.argv[0]) + ".goal")
    serial_mode = mode.endswith("-serial-success-wait") or mode.endswith("-serial-success")
    if serial_mode:
        saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
        THREAD_ID = saved_history.get("threadID")
        TURN_ID = f"turn-{uuid.uuid4()}"

    def serial_history():
        if history_path.is_file():
            return json.loads(history_path.read_text(encoding="utf-8"))
        return {"threadID": None, "events": [], "messages": []}

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
        elif message.get("method") == "model/list":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"data": [
                {"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True},
                {"id": "gpt-6-sol", "displayName": "GPT-6 Sol", "isDefault": False},
            ]}})
        elif "-goal" in mode and message.get("method") == "thread/goal/get":
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
            thread_start_instructions = message.get("params", {}).get("developerInstructions")
            if serial_mode:
                history = serial_history()
                if history.get("threadID") is not None:
                    write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32001, "message": "This fixture thread already exists; resume it instead of starting another."}})
                    continue
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
                    "threadStartCount": history.get("threadStartCount", 0) + 1,
                })
                history_path.write_text(json.dumps(history), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": "gpt-6-luna"}})
        elif message.get("method") == "thread/resume":
            if serial_mode:
                requested_thread_id = message.get("params", {}).get("threadId")
                history = serial_history()
                if not history.get("threadID") or requested_thread_id != history["threadID"]:
                    write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32002, "message": "The requested thread does not match the fixture's existing thread."}})
                    continue
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
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": THREAD_ID}, "model": "gpt-6-luna"}})
        elif message.get("method") == "turn/start":
            saw_turn = True
            saw_question = True
            turn_input = message.get("params", {}).get("input", [])
            turn_message = next((item.get("text") for item in turn_input if item.get("type") == "text"), None)
            is_title_request = (turn_message or "").startswith("Write a concise task title of at most 8 words")
            serial_first_turn = False
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
                continue
            fail_marker = Path(str(sys.argv[0]) + ".fail-next-turn-start")
            if serial_mode and fail_marker.exists():
                fail_marker.unlink(missing_ok=True)
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32099, "message": "Fixture rejected the targeted queued turn."}})
                continue
            if is_title_request:
                if mode.endswith("-title-failure"):
                    write({"jsonrpc": "2.0", "id": message["id"], "error": {
                        "code": -32042,
                        "message": f"Fixture rejected task-title generation. {turn_message}",
                    }})
                    continue
                write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
                if mode.endswith("-title-success-wait"):
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
            turn_history = {
                "userMessage": turn_message,
                "turnID": TURN_ID,
                "images": [item.get("url") for item in image_inputs],
                "imageInputs": image_inputs,
                "developerInstructions": message.get("params", {}).get("collaborationMode", {}).get("settings", {}).get("developerInstructions"),
            }
            if serial_mode:
                saved_history = serial_history()
                messages = saved_history["messages"]
                turn_history["threadID"] = THREAD_ID
                messages.append(turn_history)
                saved_history["messages"] = messages
                saved_history.update(turn_history)
                saved_history["events"].append({"method": "turn/start", "threadID": THREAD_ID, "turnID": TURN_ID, "userMessage": turn_message})
                history_path.write_text(json.dumps(saved_history), encoding="utf-8")
            else:
                saved_history = serial_history()
                saved_history.update(turn_history)
                turns = saved_history.get("turns", [])
                turns.append(turn_history)
                saved_history["turns"] = turns
                history_path.write_text(json.dumps(saved_history), encoding="utf-8")
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": TURN_ID, "status": "inProgress"}}})
            if Path(str(sys.argv[0]) + ".hold-release").exists():
                active = Path(str(sys.argv[0]) + ".turn-active")
                release = Path(str(sys.argv[0]) + ".turn-release")
                active.write_text("The fixture turn is active for a CLI outcome report.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                if not was_released:
                    return 3
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
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
                        else:
                            write({"jsonrpc": "2.0", "id": steer_request.get("id"), "error": {"code": -32601, "message": "Unsupported fixture request."}})
                if not resume.exists():
                    return 3
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
                    else:
                        write({"jsonrpc": "2.0", "id": queued_request.get("id"), "error": {"code": -32601, "message": "Unsupported fixture request."}})
                ready.unlink(missing_ok=True)
                released = release.exists()
                release.unlink(missing_ok=True)
                if not released:
                    return 3
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
                    time.sleep(0.02)
                if not resume.exists():
                    return 3
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
                    time.sleep(0.02)
                ready.unlink(missing_ok=True)
                if not release.exists():
                    return 3
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
                        time.sleep(0.02)
                    was_released = release.exists()
                    active.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                    if not was_released:
                        return 3
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
                        time.sleep(0.02)
                    ready.unlink(missing_ok=True)
                    if not release.exists():
                        return 3
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
                    for tool_item in [mcp_item, dynamic_item, legacy_dynamic_item]:
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
                        time.sleep(0.02)
                    if not release_latest.exists():
                        return 3
                    release_latest.unlink(missing_ok=True)
                    write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": THREAD_ID, "item": {
                        **legacy_dynamic_item, "status": "completed", "success": True, "contentItems": [{"type": "inputText", "text": "RAW_RESULT_SECRET"}],
                    }}})
                    while not release.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    ready.unlink(missing_ok=True)
                    if not release.exists():
                        return 3
                    release.unlink(missing_ok=True)
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
                        time.sleep(0.02)
                    was_released = release.exists()
                    active.unlink(missing_ok=True)
                    release.unlink(missing_ok=True)
                    if not was_released:
                        return 3
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
                        time.sleep(0.02)
                    was_released = final_answer_release.exists()
                    final_answer_ready.unlink(missing_ok=True)
                    final_answer_release.unlink(missing_ok=True)
                    if not was_released:
                        return 3
                write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                    "threadId": THREAD_ID,
                    "turn": {"id": TURN_ID, "status": "completed"},
                }})
            elif mode.endswith("-markdown"):
                plan_item_id = "item_stationai_plan"
                write({"jsonrpc": "2.0", "method": "item/started", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {"id": plan_item_id, "type": "plan", "text": ""},
                }})
                for index, delta in enumerate((MARKDOWN_PLAN[:64], MARKDOWN_PLAN[64:])):
                    write({"jsonrpc": "2.0", "method": "item/plan/delta", "params": {
                        "threadId": THREAD_ID, "turnId": TURN_ID,
                        "itemId": plan_item_id, "delta": delta,
                    }})
                    if index == 0 and Path(str(sys.argv[0]) + ".plan-delta-hold").exists():
                        ready = Path(str(sys.argv[0]) + ".plan-delta-ready")
                        release = Path(str(sys.argv[0]) + ".plan-delta-release")
                        ready.write_text("The first plan delta is visible before completion.\n", encoding="utf-8")
                        deadline = time.monotonic() + 30
                        while not release.exists() and time.monotonic() < deadline:
                            time.sleep(0.02)
                        if not release.exists():
                            return 3
                        ready.unlink()
                        release.unlink()
                write({"jsonrpc": "2.0", "method": "item/completed", "params": {
                    "threadId": THREAD_ID, "turnId": TURN_ID,
                    "item": {"id": plan_item_id, "type": "plan", "text": MARKDOWN_PLAN},
                }})
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
            if not failed and Path(str(sys.argv[0]) + ".outcome-hold").exists():
                active = Path(str(sys.argv[0]) + ".outcome-active")
                release = Path(str(sys.argv[0]) + ".outcome-release")
                active.write_text("The answered fixture turn is waiting for its explicit outcome.\n", encoding="utf-8")
                deadline = time.monotonic() + 30
                while not release.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                was_released = release.exists()
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)
                if not was_released:
                    return 3
            write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
                "threadId": THREAD_ID,
                "turn": {"id": TURN_ID, "status": "interrupted" if mode.endswith("-interrupted") else ("failed" if failed else "completed"),
                         **({"error": {"message": "Codex interrupted this turn."}} if mode.endswith("-interrupted") else ({"error": {"message": "Question response was missing or incorrect."}} if failed else {}))},
            }})
        elif message.get("method") == "turn/interrupt":
            write({"jsonrpc": "2.0", "id": message["id"], "result": {}})
        elif message.get("method") == "thread/read":
            if message.get("params", {}).get("threadId") != CHILD_THREAD_ID:
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32005, "message": "Unknown fixture child thread."}})
                continue
            write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": CHILD_THREAD_ID, "turns": []}}})
        elif message.get("method") == "thread/turns/list":
            if message.get("params", {}).get("threadId") != CHILD_THREAD_ID:
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32005, "message": "Unknown fixture child thread."}})
                continue
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
                continue
            saved_history = json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
            if serial_mode and message.get("params", {}).get("threadId") != saved_history.get("threadID"):
                write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32004, "message": "History can only be read from the persisted fixture thread."}})
                continue
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
                            {"id": f"item_assistant_fixture_{index}", "type": "agentMessage", "text": "Answers received: Blue / fixture-secret."},
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
                        contents.extend([
                            {"id": f"item_user_fixture_{index}", "type": "userMessage", "content": user_content},
                            {"id": f"item_assistant_fixture_{index}", "type": "agentMessage", "text": "Answers received: Blue / fixture-secret."},
                        ])
            else:
                user_message = saved_history.get("userMessage") or (turn_message if answers else None)
                user_images = saved_history.get("images", [])
                user_content = ([{"type": "text", "text": user_message}] if user_message else []) + [
                    {"type": "image", "url": image_url} for image_url in user_images
                ]
                contents = ([
                    {"id": "item_user_fixture", "type": "userMessage", "content": user_content},
                    {"id": "item_assistant_fixture", "type": "agentMessage", "text": "Answers received: Blue / fixture-secret."},
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
            write({"jsonrpc": "2.0", "id": message["id"], "result": {
                "data": [{"item": item, "turnId": TURN_ID} for item in contents],
                "nextCursor": None,
            }})
    if not saw_turn:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

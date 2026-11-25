"""Protocol and response helpers for the Codex app-server fixture."""

import collections

def markdown_plan_deltas(runtime):
    """The plan in four deltas that end inside a paragraph, inside a list item that follows that
    paragraph, and inside the fenced code block, so the streamed reply grows across each kind."""
    list_item = runtime.MARKDOWN_PLAN.index("- Implementation detail 11: verify") + len("- Implementation detail 11: verify")
    code = runtime.MARKDOWN_PLAN.index('console.log("Hello') + len('console.log("Hello')
    return (runtime.MARKDOWN_PLAN[:64], runtime.MARKDOWN_PLAN[64:list_item], runtime.MARKDOWN_PLAN[list_item:code], runtime.MARKDOWN_PLAN[code:])


def echoed_outcome_answer(runtime, user_message):
    """Reproduces a model writing its final outcome command as answer text."""
    if not user_message or not user_message.startswith(runtime.ECHOED_OUTCOME_PREFIX):
        return None
    task_id = user_message[len(runtime.ECHOED_OUTCOME_PREFIX):].strip().rstrip(".")
    return f"{runtime.ECHOED_OUTCOME_ANSWER}\U0001F6E0\uFE0F\nplayhouse-cli task outcome {task_id} completed"


def own_user_text(runtime, message):
    """The user's own words, without Playhouse's hidden context envelopes.

    Standalone chat seeds a page's first turn with that page's transcript, and a comment
    quotes the answer text it was made on, so a sentinel repeated by an earlier assistant
    answer must not re-trigger a scenario branch here.
    """
    text = message or ""
    close = "</playhouse-handoff-context>"
    if text.startswith("<playhouse-handoff-context>") and close in text:
        text = text.split(close, 1)[1].strip()
    start, close = "<playhouse-comment-context>", "</playhouse-comment-context>"
    if start in text and close in text.split(start, 1)[1]:
        before, rest = text.split(start, 1)
        text = (before + rest.split(close, 1)[1]).strip()
    return text


def breakdown(runtime, input_tokens, cached, output_tokens):
    return {"inputTokens": input_tokens, "cachedInputTokens": cached, "cacheWriteInputTokens": 0,
            "outputTokens": output_tokens, "reasoningOutputTokens": 0,
            "totalTokens": input_tokens + output_tokens}


def token_usage_notification(runtime, thread_id, turn_id, last, total):
    return {"method": "thread/tokenUsage/updated", "params": {
        "threadId": thread_id, "turnId": turn_id,
        "tokenUsage": {"last": last, "total": total, "modelContextWindow": 258400}}}


def call_usage_notifications(runtime, thread_id, turn_id):
    """What a real app-server streams per model call, ahead of the turn's end.

    The main thread makes two calls (sending 700 then 900 tokens, so the final
    transcript is 900) and repeats the second notification; a subagent thread
    announces itself with its parent and makes one call sending 300. Codex's
    input count includes its cached tokens, so "sent" is the input count itself.
    """
    subagent = f"{thread_id}-subagent"
    context_path = runtime.Path(str(runtime.sys.argv[0]) + ".context-tokens")
    context_tokens = int(
        context_path.read_text(encoding="utf-8").strip()
        if context_path.is_file()
        else (runtime.os.environ.get("PLAYHOUSE_E2E_CODEX_CONTEXT_TOKENS", "0") or 0)
    )
    first = runtime.breakdown(700, 500, 30)
    second = runtime.breakdown(context_tokens or 900, 0 if context_tokens else 600, 40)
    cumulative = runtime.breakdown(700 + (context_tokens or 900), 500 if context_tokens else 1100, 70)
    sub = runtime.breakdown(300, 100, 10)
    return [
        runtime.token_usage_notification(thread_id, turn_id, first, first),
        runtime.token_usage_notification(thread_id, turn_id, second, cumulative),
        runtime.token_usage_notification(thread_id, turn_id, second, cumulative),
        {"method": "thread/started", "params": {"thread": {"id": subagent, "parentThreadId": thread_id}}},
        runtime.token_usage_notification(subagent, f"{turn_id}-subagent", sub, sub),
    ]


def write_waste_rollouts(runtime, thread_id):
    home = runtime.os.environ.get("CODEX_HOME")
    if not home or not thread_id:
        return
    directory = runtime.Path(home) / "sessions" / "2026" / "11" / "03"
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
              "arguments": runtime.json.dumps({"stream": "orc", "limit": 5000}), "call_id": "call_waste_logs"}),
        record(4000, 0),
        item({"type": "function_call_output", "call_id": "call_waste_logs", "output": runtime.WASTE_LOG}),
        item({"type": "custom_tool_call", "name": "exec", "input": "cat README.md", "call_id": "call_waste_read1"}),
        record(19000, 3900),
        item({"type": "custom_tool_call_output", "call_id": "call_waste_read1", "output": runtime.WASTE_README}),
        item({"type": "custom_tool_call", "name": "exec", "input": "cat README.md", "call_id": "call_waste_read2"}),
        record(19300, 18900),
        item({"type": "custom_tool_call_output", "call_id": "call_waste_read2", "output": runtime.WASTE_README}),
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
    # Stamped with the turn's own time, as Codex stamps each line, so a turn's Token Stats can
    # tell which requests the turn made.
    now = runtime.time.time()
    timestamp = runtime.time.strftime("%Y-%m-%dT%H:%M:%S", runtime.time.gmtime(now)) + f".{int(now * 1000) % 1000:03d}Z"
    for name, lines in ((thread_id, main), (f"{thread_id}-subagent", subagent)):
        with open(directory / f"rollout-2026-11-03T10-00-00-{name}.jsonl", "w", encoding="utf-8") as handle:
            for line in lines:
                handle.write(runtime.json.dumps({"timestamp": timestamp, **line}) + "\n")


def side_chat_selection(runtime, text):
    match = runtime.re.search(r"<selected-text>\n(.*?)\n</selected-text>", text or "", runtime.re.S)
    return match.group(1) if match else None


def run_side_chat_cli(runtime, instructions, marker, extra):
    """Runs the Playhouse CLI the side chat instructions name (on the line holding `marker`) with `extra`
    arguments inside a read-only macOS sandbox, as Codex runs a side chat's commands, and
    returns its parsed JSON output."""
    line = next((line.strip() for line in (instructions or "").splitlines()
                 if line.strip().startswith("'") and marker in line), None)
    if line is None:
        return {"ok": False, "error": "The side chat instructions name no such command."}
    executable = runtime.shlex.split(line)[0]
    completed = runtime.subprocess.run(["/usr/bin/sandbox-exec", "-p", runtime.READ_ONLY_SANDBOX_PROFILE, executable] + extra,
                               capture_output=True, text=True, timeout=60)
    try:
        return runtime.json.loads(completed.stdout)
    except runtime.json.JSONDecodeError:
        return {"ok": False, "error": completed.stderr.strip() or completed.stdout.strip()}


def handle_side_chat(runtime, message, history_path):
    """Serves a Playhouse side chat: `thread/fork` copies a thread under a new ID, and a turn on
    a forked thread answers about the selected text. Every fork and side chat turn is recorded
    in the history file. Returns whether the message was a side chat's."""
    method = message.get("method")
    params = message.get("params", {})
    def record(key, entry):
        history = runtime.json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
        history.setdefault(key, []).append(entry)
        history_path.write_text(runtime.json.dumps(history), encoding="utf-8")
    if method == "thread/fork":
        thread_id = f"fork-{runtime.uuid.uuid4()}"
        runtime.SIDE_CHAT_THREADS[thread_id] = {"source": params.get("threadId"), "instructions": params.get("developerInstructions"), "turns": 0}
        record("threadForks", {
            "threadId": thread_id, "sourceThreadId": params.get("threadId"), "sandbox": params.get("sandbox"),
            "approvalPolicy": params.get("approvalPolicy"), "excludeTurns": params.get("excludeTurns"),
            "cwd": params.get("cwd"), "developerInstructions": params.get("developerInstructions"),
        })
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": thread_id}, "model": params.get("model", "gpt-6-luna")}})
        return True
    if method == "thread/resume" and params.get("threadId") in runtime.SIDE_CHAT_THREADS:
        record("sideChatResumes", {"threadId": params.get("threadId"), "sandbox": params.get("sandbox")})
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": params.get("threadId")}, "model": params.get("model", "gpt-6-luna")}})
        return True
    if method in ("thread/read", "thread/turns/list", "thread/items/list") and params.get("threadId") in runtime.SIDE_CHAT_THREADS:
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": params.get("threadId"), "turns": []}, "data": [], "nextCursor": None}})
        return True
    if method != "turn/start" or params.get("threadId") not in runtime.SIDE_CHAT_THREADS:
        return False
    thread_id = params["threadId"]
    side_chat = runtime.SIDE_CHAT_THREADS[thread_id]
    side_chat["turns"] += 1
    text = next((item.get("text") for item in params.get("input", []) if item.get("type") == "text"), "") or ""
    turn_id = f"turn-side-chat-{runtime.uuid.uuid4()}"
    selection = runtime.side_chat_selection(text)
    question = text.split("</selected-text>", 1)[-1].strip()
    if "create a task" in question.lower():
        created = runtime.run_side_chat_cli(side_chat["instructions"], " help --for side-chat", [
            "task", "create", "--title", "Side chat follow-up", "--prompt", f"Follow up on the side chat about: {question}"])
        task_id = (created.get("result") or {}).get("id") if created.get("ok") else None
        reply = f"Created task {task_id}." if task_id else f"Could not create the task: {created.get('error')}"
        if task_id:
            # Beyond the board commands, the daemon refuses what the sandbox would stop.
            deleted = runtime.run_side_chat_cli(side_chat["instructions"], " help --for side-chat", ["task", "delete", task_id])
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
    runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
    item = {"id": f"item-{turn_id}", "type": "agentMessage", "phase": "final_answer", "text": reply}
    runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {**item, "text": ""}}})
    runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
        "threadId": thread_id, "turnId": turn_id, "itemId": item["id"], "delta": reply}})
    runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": item}})
    runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}})
    return True


def _streamed_key(item):
    content = item.get("text") or item.get("command")
    return {key for key in (item.get("id"), (item.get("type"), str(content)) if content else None) if key}


def _unstreamed_turn_items(runtime, thread_id, turn_id):
    """The items this turn's thread history holds that the scenario never streamed.

    Real Codex streams every item of a turn before `turn/completed`, and Playhouse
    records a transcript only from those events, so a scenario that wrote an item
    only into its history file still streams it here."""
    import codex_fixture_history
    state = getattr(runtime, "SESSION_STATE", None)
    if state is None or getattr(runtime, "_synthesizing_turn_items", False):
        return []
    if turn_id in getattr(runtime, "SELF_CONTAINED_TURNS", set()):
        runtime.SELF_CONTAINED_TURNS.discard(turn_id)
        return []
    saved = dict(vars(state))
    captured = []
    original_write = runtime.write
    runtime._synthesizing_turn_items = True
    runtime.write = captured.append
    try:
        codex_fixture_history.list_items(runtime, state, {"id": "fixture-turn-items", "params": {"threadId": thread_id}})
    except Exception:
        captured = []
    finally:
        runtime.write = original_write
        runtime._synthesizing_turn_items = False
        vars(state).clear()
        vars(state).update(saved)
    entries = ((captured[0].get("result") or {}).get("data") or []) if captured else []
    streamed = runtime.STREAMED_TURN_ITEMS.setdefault(turn_id, set())
    # Scenarios reuse one turn ID across turns: the entries an earlier turn under the same
    # ID already completed with belong to that turn, not this one.
    # A history that shrank was reset (a case deletes the history file while this server
    # runs on), so the turns it recorded before are gone and nothing counts as completed.
    sizes = runtime.COMPLETED_TURN_HISTORY_SIZES
    earlier = runtime.COMPLETED_TURN_ENTRIES.get(turn_id, collections.Counter())
    if len(entries) < sizes.get(turn_id, 0):
        earlier = collections.Counter()
    sizes[turn_id] = len(entries)
    current = collections.Counter(
        runtime.json.dumps(entry, sort_keys=True) for entry in entries if entry.get("turnId") == turn_id
    )
    runtime.COMPLETED_TURN_ENTRIES[turn_id] = current
    unseen = current - earlier
    items = []
    for entry in entries:
        item = entry.get("item") or {}
        # A `thread/compact/start` compaction belongs to its own compaction turn; the
        # history only files it beside the next user turn.
        if entry.get("turnId") != turn_id or item.get("type") in (None, "userMessage", "contextCompaction"):
            continue
        encoded = runtime.json.dumps(entry, sort_keys=True)
        if unseen[encoded] <= 0:
            continue
        unseen[encoded] -= 1
        keys = _streamed_key(item)
        if keys & streamed:
            continue
        streamed |= keys
        items.append(item)
    # The turn ended; a later turn that reuses its ID streams its own items.
    runtime.STREAMED_TURN_ITEMS[turn_id] = set()
    return items


def write(runtime, value):
    if not hasattr(runtime, "STREAMED_TURN_ITEMS"):
        runtime.STREAMED_TURN_ITEMS = {}
        runtime.COMPLETED_TURN_ENTRIES = {}
        runtime.COMPLETED_TURN_HISTORY_SIZES = {}
    if isinstance(value, dict) and value.get("method") == "turn/started":
        runtime.STREAMED_TURN_ITEMS[((value.get("params") or {}).get("turn") or {}).get("id")] = set()
    if isinstance(value, dict) and value.get("method") in ("item/started", "item/completed"):
        params = value.get("params") or {}
        item = params.get("item") or {}
        if value["method"] == "item/completed" or item.get("type") != "agentMessage":
            runtime.STREAMED_TURN_ITEMS.setdefault(params.get("turnId"), set()).update(_streamed_key(item))
    if (isinstance(value, dict) and value.get("method") == "turn/completed"
            and "usage" not in value.get("params", {})):
        params = value["params"]
        turn_id = (params.get("turn") or {}).get("id")
        replayed = _unstreamed_turn_items(runtime, params.get("threadId"), turn_id)
        # An interrupted or failed turn ends with what it already streamed.
        if (params.get("turn") or {}).get("status", "completed") != "completed":
            replayed = []
        for item in replayed:
            runtime.sys.stdout.write(runtime.json.dumps({"jsonrpc": "2.0", "method": "item/completed", "params": {
                "threadId": params.get("threadId"), "turnId": turn_id, "item": item}}, separators=(",", ":")) + "\n")
        for notification in runtime.call_usage_notifications(params.get("threadId"), (params.get("turn") or {}).get("id")):
            runtime.sys.stdout.write(runtime.json.dumps(notification, separators=(",", ":")) + "\n")
        runtime.sys.stdout.flush()
        value = {**value, "params": {**value["params"], "usage": dict(runtime.TURN_USAGE)}}
    runtime.sys.stdout.write(runtime.json.dumps(value, separators=(",", ":")) + "\n")
    runtime.sys.stdout.flush()


def is_page_classifier_prompt(runtime, text):
    """A page classifier runs as a helper on its own thread in Codex, so its turns never
    belong to the chat thread's items."""
    return (text or "").startswith("Classify the latest user message for Playhouse's continuous chat page index.")


def answer_text(runtime, user_message):
    mode = runtime.os.path.basename(runtime.sys.argv[0])
    if isinstance(user_message, str) and user_message.startswith(
        "Classify the latest user message for Playhouse's continuous chat page index."
    ):
        hold = runtime.Path(str(runtime.sys.argv[0]) + ".hold-classifier")
        neptune_hold = runtime.Path(str(runtime.sys.argv[0]) + ".hold-neptune-classifier")
        should_hold = hold.exists() or (
            neptune_hold.exists()
            and "Latest user message:\nTell me about Neptune" in user_message
        )
        if should_hold:
            hold.unlink(missing_ok=True)
            neptune_hold.unlink(missing_ok=True)
            active = runtime.Path(str(runtime.sys.argv[0]) + ".classifier-active")
            release = runtime.Path(str(runtime.sys.argv[0]) + ".classifier-release")
            active.write_text("The fallback classifier is held in the background.\n", encoding="utf-8")
            deadline = runtime.time.monotonic() + 30
            while not release.exists() and runtime.time.monotonic() < deadline:
                runtime.time.sleep(0.02)
            released = release.exists()
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            if not released:
                return '{"continues":true,"title":null}'
        history_path = runtime.Path(str(runtime.sys.argv[0]) + ".history")
        history = runtime.json.loads(history_path.read_text(encoding="utf-8")) if history_path.is_file() else {}
        if runtime.Path(str(runtime.sys.argv[0]) + ".fail-classifier").exists():
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
    if "-background-" in mode:
        if "background work results" in (user_message or "").lower():
            return "I read the background test's result and reported where the task stands."
        if "playhouse internal outcome nudge:" not in (user_message or "").lower():
            return "I started the required UI test in the background and will wait for it."
    if "playhouse internal outcome nudge:" in (user_message or "").lower():
        return "Fixture internal reminder reply."
    if user_message == "Follow up after private recovery.":
        return "Follow-up after private recovery complete."
    if mode.endswith("-nonblocking-slow"):
        return "Answers received: Custom approach / fixture-secret."
    if mode.endswith("-nonblocking-restart-question") and (user_message or "").startswith("Continue this conversation by applying"):
        return "Answers received: Custom approach / fixture-secret."
    if runtime.is_restart_question_mode(mode) and mode.endswith("-no-secret") and (user_message or "").startswith("Continue this conversation by applying"):
        answer_values = runtime.re.findall(r"(?m)^\s*Answer:\s*(.*?)\s*$", user_message)
        secret_answer = any(value.strip() == "fixture-secret" for value in answer_values)
        return (
            "Recovered answer: Green; private token fixture-secret was applied."
            if secret_answer
            else "Recovered answer: Blue; no secret was required."
        )
    if runtime.is_restart_question_mode(mode) and not (user_message or "").startswith(
        "Continue this conversation by applying"
    ):
        return "I am waiting for the pending question to be answered."
    if runtime.is_restart_question_mode(mode):
        return "Recovered answer: Green; private token fixture-secret was applied."
    if runtime.Path(runtime.sys.argv[0]).name.endswith("-user-question"):
        return "Answer received: Continue."
    if user_message == "Copy message fixture input.":
        return runtime.COPY_MESSAGE_REPLY
    if isinstance(user_message, str) and user_message.startswith("Long response fixture input."):
        return "A long fixture response gives the conversation enough content to test comment hint truncation. " * 8
    if isinstance(user_message, str) and ("<response-comments>" in user_message or "<response-annotations>" in user_message):
        try:
            tag = "response-comments" if "<response-comments>" in user_message else "response-annotations"
            payload = user_message.split(f"<{tag}>", 1)[1].split(f"</{tag}>", 1)[0]
            annotations = runtime.json.loads(payload)
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


def nudged_work_items(runtime, turn_index):
    """What a status nudge turn does when work remains: it keeps working."""
    return [
        {"id": f"item_nudged_commentary_{turn_index}", "type": "agentMessage", "phase": "commentary",
         "text": runtime.NUDGED_WORK_COMMENTARY},
        {"id": f"item_nudged_check_{turn_index}", "type": "commandExecution", "command": "echo NUDGED CHECK PASSED",
         "cwd": "/tmp/playhouse-fixture", "status": "completed", "exitCode": 0, "durationMs": 7,
         "aggregatedOutput": "NUDGED CHECK PASSED\n"},
        {"id": f"item_nudged_final_{turn_index}", "type": "agentMessage", "phase": "final_answer",
         "text": runtime.NUDGED_WORK_ANSWER},
    ]


def is_restart_question_mode(runtime, mode):
    return mode.endswith("-restart-question") or mode.endswith("-restart-question-no-secret")


def question_request(runtime, request_id, followup=False):
    
    mode = runtime.os.path.basename(runtime.sys.argv[0])
    if mode.endswith("-restart-question-no-secret") and runtime.Path(str(runtime.sys.argv[0]) + ".secret-stage").exists():
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
    elif mode.endswith("-restart-question") and runtime.Path(str(runtime.sys.argv[0]) + ".asked").exists():
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
        runtime.question_sequence += 1
        request_id = runtime.question_sequence
        runtime.question_contexts[request_id] = (runtime.THREAD_ID, runtime.TURN_ID)
        runtime.question_rounds[runtime.THREAD_ID] = runtime.question_rounds.get(runtime.THREAD_ID, 0) + 1
        if runtime.first_question_thread is None:
            runtime.first_question_thread = runtime.THREAD_ID
        if followup:
            questions[0]["question"] = "Which color should I use next?"
    runtime.write({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tool/requestUserInput",
        "params": {
            "threadId": runtime.THREAD_ID,
            "turnId": runtime.TURN_ID,
            "itemId": "item_playhouse_question",
            "questions": questions,
            "isBlocking": "-nonblocking" not in mode and "-plan" not in mode,
        },
    })


def subagent_item(runtime, status):
    return {
        "id": "item_playhouse_subagent",
        "type": "collabAgentToolCall",
        "tool": "spawnAgent",
        "senderThreadId": runtime.THREAD_ID,
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


def subagent_activity(runtime, kind, child_thread_id, agent_path, *, model=None, reasoning_effort=None):
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


def async_question_item(runtime):
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


def later_async_question_item(runtime):
    return {
        "id": "item_playhouse_async_later_question",
        "type": "agentMessage", "phase": "final_answer", "delivery": "async",
        "text": "One more check", "questions": [{"title": "One more check", "options": None}],
    }


def diagnostic_action_items(runtime, cwd):
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


def follow_turn_items(runtime, finished):
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


def account_rate_limits(runtime, used_primary, used_secondary):
    now = int(runtime.time.time())
    return {"limitId": "codex", "limitName": None, "planType": "plus", "rateLimitReachedType": None,
            "primary": {"usedPercent": used_primary, "windowDurationMins": 300, "resetsAt": now + 8040},
            "secondary": {"usedPercent": used_secondary, "windowDurationMins": 10080, "resetsAt": now + 4 * 86400},
            "credits": {"hasCredits": True, "unlimited": False, "balance": "12.50"}}


def handle_account_request(runtime, message):
    """The app-server account methods Playhouse's Agents info block uses. The
    account lives in `<executable>.account` so a test can sign it out or in."""
    state_path = runtime.Path(str(runtime.sys.argv[0]) + ".account")
    state = runtime.json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {
        "loggedIn": True, "email": "codex-fixture@example.com", "used": [30, 62]}
    method = message["method"]
    reply = lambda result: runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": result})
    # A one-shot marker leaves the next account read unanswered, as a hung app-server would.
    hang = runtime.Path(runtime.os.environ.get("PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY", str(runtime.Path(runtime.sys.argv[0]).parent))) \
        / f"{runtime.Path(runtime.sys.argv[0]).name}.account-read-hang"
    if method == "account/read" and hang.is_file():
        hang.unlink(missing_ok=True)
        return
    account_error = runtime.Path(str(runtime.sys.argv[0]) + ".account-read-error")
    if method == "account/read" and account_error.exists():
        runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32603, "message": "failed to load workspace requirements"}})
        return
    if method == "account/read":
        account = {"type": "chatgpt", "email": state["email"], "planType": "plus"} if state["loggedIn"] else None
        reply({"account": account, "requiresOpenaiAuth": True})
    elif method == "account/rateLimits/read":
        if not state["loggedIn"]:
            runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32600, "message": "Not signed in."}})
            return
        snapshot = runtime.account_rate_limits(*state["used"])
        reply({"rateLimits": snapshot, "rateLimitsByLimitId": {"codex": snapshot}})
    elif method == "account/logout":
        state_path.write_text(runtime.json.dumps({"loggedIn": False, "email": None, "used": [0, 0]}), encoding="utf-8")
        reply({})
    elif method == "account/login/start":
        state = {"loggedIn": True, "email": "codex-second@example.com", "used": [7, 20]}
        state_path.write_text(runtime.json.dumps(state), encoding="utf-8")
        reply({"type": "chatgpt", "authUrl": "https://example.invalid/codex-login", "loginId": "fixture-login"})
        runtime.write({"jsonrpc": "2.0", "method": "account/login/completed",
               "params": {"success": True, "loginId": "fixture-login", "error": None}})
        runtime.write({"jsonrpc": "2.0", "method": "account/rateLimits/updated",
               "params": {"rateLimits": runtime.account_rate_limits(*state["used"])}})


def remember_thread_cwd(runtime, message):
    
    params = message.get("params") or {}
    if message.get("method") in ("thread/start", "thread/resume", "turn/start") and params.get("cwd"):
        runtime.LAST_REQUESTED_CWD = params["cwd"]
        if params.get("threadId"):
            runtime.THREAD_CWDS[params["threadId"]] = params["cwd"]


def workspace_cwd(runtime):
    return (runtime.os.environ.get("PLAYHOUSE_FIXTURE_WORKSPACE") or runtime.THREAD_CWDS.get(runtime.THREAD_ID)
            or runtime.LAST_REQUESTED_CWD or runtime.os.getcwd())


def stdin_select(runtime, timeout):
    """`select.select([sys.stdin], [], [], timeout)` that also counts a line already buffered."""
    if isinstance(runtime.sys.stdin, runtime.StdinLines) and runtime.sys.stdin.has_line():
        return [runtime.sys.stdin], [], []
    return runtime.select.select([runtime.sys.stdin], [], [], timeout)


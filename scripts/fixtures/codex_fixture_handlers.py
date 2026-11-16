"""Server handlers for the Codex app-server fixture executable."""

def run_cpu_attribution_server(runtime):
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
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "threadId": thread_id, "turnId": turn_id, "item": threads[thread_id]["items"][-1]["item"],
        }})
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": thread_id, "turn": {"id": turn_id, "status": status},
        }})

    def report_outcome(thread_id):
        instructions = threads[thread_id].get("instructions") or ""
        line = next((line.strip() for line in instructions.splitlines() if " task outcome " in line), None)
        if line:
            runtime.subprocess.run(runtime.shlex.split(line.replace("<completed|waiting-response|blocked>", "completed")),
                           capture_output=True, text=True, timeout=60)

    def handle(message):
        method = message.get("method")
        params = message.get("params", {})
        if "id" not in message:
            return
        reply = lambda result: runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": result})
        if method in runtime.ACCOUNT_METHODS:
            runtime.handle_account_request(message)
        elif method == "initialize":
            reply({"serverInfo": {"name": "playhouse-cpu-fixture", "version": "1"}})
        elif method == "model/list":
            reply({"data": [{"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True,
                             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]}]})
        elif method in ("thread/start", "thread/resume"):
            thread_id = params.get("threadId") or str(runtime.uuid.uuid4())
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
            turn_id = f"turn-{runtime.uuid.uuid4()}"
            text = next((item.get("text") for item in params.get("input", []) if item.get("type") == "text"), "") or ""
            thread["items"].append({"turnId": turn_id, "item": {
                "id": f"item_{turn_id}_user", "type": "userMessage", "content": [{"type": "text", "text": text}],
            }})
            reply({"turn": {"id": turn_id, "status": "inProgress"}})
            match = runtime.CPU_ATTRIBUTION_TURN.search(text)
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
            child = runtime.subprocess.Popen(
                [runtime.sys.executable, "-c", code, "playhouse-cpu-attribution", match.group(1).lower(), runtime.sys.argv[0]],
                cwd=params.get("cwd") or runtime.os.getcwd(),
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
        ready, _, _ = runtime.select.select([runtime.sys.stdin.fileno()], [], [], 0.05)
        if ready:
            chunk = runtime.os.read(runtime.sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    message = runtime.json.loads(line)
                except runtime.json.JSONDecodeError:
                    continue
                handle(message)
        for thread_id, (turn_id, child, kind) in list(running.items()):
            if child.poll() is not None:
                del running[thread_id]
                # A record exists only while its child runs, so cleanup never signals a reused PID.
                runtime.Path(f"{runtime.sys.argv[0]}.cpu-child-{'burn' if kind == 'burn' else 'idle'}.json").unlink(missing_ok=True)
                report_outcome(thread_id)
                finish(thread_id, turn_id, f"Finished the {kind} command.")
    for _, child, _ in running.values():
        child.kill()
    return 0


def run_reattach_server(runtime):
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
    base = str(runtime.sys.argv[0])
    threads_path = runtime.Path(f"{base}.reattach-threads")
    active = {}
    buffer = b""

    def save_threads():
        # Like Codex's rollout files: a later server process reads what an earlier one wrote.
        threads_path.write_text(runtime.json.dumps(threads), encoding="utf-8")

    threads = {}
    if threads_path.is_file():
        threads = runtime.json.loads(threads_path.read_text(encoding="utf-8"))
        for thread in threads.values():
            for turn in thread["turns"]:
                if turn["status"] == "inProgress":
                    turn["status"] = "interrupted"

    def emit_message(thread_id, turn_id, item_id, text):
        item = {"id": item_id, "type": "agentMessage", "phase": "commentary", "text": text}
        runtime.write({"jsonrpc": "2.0", "method": "item/started", "params": {
            "threadId": thread_id, "turnId": turn_id, "item": {**item, "text": ""}}})
        runtime.write({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {
            "threadId": thread_id, "turnId": turn_id, "itemId": item_id, "delta": text}})
        runtime.write({"jsonrpc": "2.0", "method": "item/completed", "params": {
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
        return runtime.subprocess.Popen(runtime.shlex.split(line.replace("<completed|waiting-response|blocked>", "waiting-response")),
                                stdout=runtime.subprocess.DEVNULL, stderr=runtime.subprocess.DEVNULL)

    def complete(thread_id, status="completed"):
        turn_id = active.pop(thread_id)["turn"]
        set_status(thread_id, turn_id, status)
        runtime.write({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "threadId": thread_id, "turn": {"id": turn_id, "status": status}}})

    def log(name, value):
        with open(f"{base}.{name}", "a", encoding="utf-8") as handle:
            handle.write(runtime.json.dumps(value) + "\n")

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
        reply = lambda result: runtime.write({"jsonrpc": "2.0", "id": message["id"], "result": result})
        if method in runtime.ACCOUNT_METHODS:
            runtime.handle_account_request(message)
        elif method == "initialize":
            reply({"serverInfo": {"name": "playhouse-reattach-fixture", "version": "1"}})
        elif method == "model/list":
            reply({"data": [{"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True,
                             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]}]})
        elif method in ("thread/start", "thread/resume"):
            thread_id = params.get("threadId") or str(runtime.uuid.uuid4())
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
            turn_id = f"turn-{runtime.uuid.uuid4()}"
            text = next((item.get("text") for item in params.get("input", []) if item.get("type") == "text"), "") or ""
            thread["items"].append({"turnId": turn_id, "item": {
                "id": f"item_{turn_id}_user", "type": "userMessage", "content": [{"type": "text", "text": text}]}})
            thread["turns"].append({"id": turn_id, "status": "inProgress"})
            save_threads()
            reply({"turn": {"id": turn_id, "status": "inProgress"}})
            runtime.write({"jsonrpc": "2.0", "method": "turn/started", "params": {
                "threadId": thread_id, "turn": {"id": turn_id, "status": "inProgress"}}})
            if text.startswith("Write a concise task title") or "outcome nudge" in text.lower():
                emit_message(thread_id, turn_id, f"item_{turn_id}_answer", "Reattach fixture task")
                active[thread_id] = {"turn": turn_id, "reporting": None if text.startswith("Write") else report_outcome(thread_id)}
                if active[thread_id]["reporting"] is None:
                    complete(thread_id)
                return
            emit_message(thread_id, turn_id, f"item_{turn_id}_before", "Before restart.")
            active[thread_id] = {"turn": turn_id}
            runtime.Path(f"{base}.reattach-ready").write_text(runtime.json.dumps({"threadId": thread_id, "turnId": turn_id, "text": text}), encoding="utf-8")
        elif method == "turn/steer":
            thread_id = params.get("threadId")
            turn = active.get(thread_id)
            if not turn or params.get("expectedTurnId") != turn["turn"]:
                runtime.write({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32010, "message": "The expected turn ID is stale."}})
                return
            text = "".join(item.get("text", "") for item in params.get("input", []) if item.get("type") == "text")
            log("reattach-steers", {"threadId": thread_id, "text": text})
            threads[thread_id]["items"].append({"turnId": turn["turn"], "item": {
                "id": f"item_steer_{runtime.uuid.uuid4()}", "type": "userMessage", "content": [{"type": "text", "text": text}]}})
            save_threads()
            reply({"turnId": turn["turn"]})
            # A question on a thread no conversation owns, raised while a client is connected: the
            # client must leave it for its owner rather than reject it.
            runtime.write({"jsonrpc": "2.0", "id": "question-foreign", "method": "item/tool/requestUserInput", "params": {
                "threadId": "thread-owned-by-no-conversation", "turnId": "turn-foreign", "itemId": "call-foreign", "isBlocking": True,
                "questions": [{"id": "color", "header": "Color", "question": "Which color?", "isOther": False,
                               "isSecret": False, "options": [{"label": "red"}]}]}})
        elif method == "turn/interrupt":
            reply({})
            thread_id = params.get("threadId")
            if thread_id in active:
                runtime.Path(f"{base}.reattach-interrupted").write_text("interrupted\n", encoding="utf-8")
                complete(thread_id, status="interrupted")
        else:
            reply({})

    while True:
        ready, _, _ = runtime.select.select([runtime.sys.stdin.fileno()], [], [], 0.05)
        if ready:
            chunk = runtime.os.read(runtime.sys.stdin.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                try:
                    handle(runtime.json.loads(line))
                except runtime.json.JSONDecodeError:
                    continue
        for thread_id, turn in list(active.items()):
            raise_marker = runtime.Path(f"{base}.reattach-raise")
            if raise_marker.exists() and "question" not in turn:
                raise_marker.unlink()
                turn["approval"] = f"approval-{turn['turn']}"
                turn["question"] = f"question-{turn['turn']}"
                runtime.write({"jsonrpc": "2.0", "id": turn["approval"], "method": "item/commandExecution/requestApproval", "params": {
                    "threadId": thread_id, "turnId": turn["turn"], "itemId": f"exec-{turn['turn']}",
                    "command": "touch reattach-marker.txt", "cwd": runtime.os.getcwd()}})
                runtime.write({"jsonrpc": "2.0", "id": turn["question"], "method": "item/tool/requestUserInput", "params": {
                    "threadId": thread_id, "turnId": turn["turn"], "itemId": f"call-{turn['turn']}", "isBlocking": True,
                    "questions": [{"id": "color", "header": "Color", "question": "Which color?", "isOther": False,
                                   "isSecret": False, "options": [{"label": "red"}, {"label": "blue"}]}]}})
                runtime.Path(f"{base}.reattach-raised").write_text("raised\n", encoding="utf-8")
            close_turn_marker = runtime.Path(f"{base}.reattach-close-turn")
            if close_turn_marker.exists():
                title = close_turn_marker.read_text(encoding="utf-8").strip()
                close_turn_marker.unlink()
                instructions = threads[thread_id].get("instructions") or ""
                command = next((line.strip() for line in instructions.splitlines()
                                if " chat page close-turn " in line and "--continues true" in line), None)
                if command and title:
                    command = command.replace("--continues true", f"--continues false --new-title {runtime.shlex.quote(title)}")
                # Like a tool call, it runs while the server keeps answering: with no daemon up,
                # the command starts one, which resumes this thread first.
                turn["closing"] = (command, runtime.subprocess.Popen(runtime.shlex.split(command), stdout=runtime.subprocess.PIPE,
                                                             stderr=runtime.subprocess.DEVNULL, text=True) if command else None)
            if turn.get("closing") and (turn["closing"][1] is None or turn["closing"][1].poll() is not None):
                command, process = turn.pop("closing")
                log("reattach-close-turn-output", {
                    "command": command,
                    "returncode": process.returncode if process else None,
                    "output": process.stdout.read() if process else "",
                })
            if runtime.Path(f"{base}.reattach-die").exists():
                # Consumed, so a later server of the same fixture runs normally.
                runtime.Path(f"{base}.reattach-die").unlink(missing_ok=True)
                runtime.os._exit(3)
            quiet = runtime.Path(f"{base}.reattach-release-quiet")
            if quiet.exists() and "reporting" not in turn:
                quiet.unlink()
                emit_message(thread_id, turn["turn"], f"item_{turn['turn']}_after", "After restart.")
                turn["reporting"] = None
                complete(thread_id)
                continue
            release = runtime.Path(f"{base}.reattach-release")
            if release.exists() and "reporting" not in turn:
                release.unlink()
                emit_message(thread_id, turn["turn"], f"item_{turn['turn']}_after", "After restart.")
                turn["reporting"] = report_outcome(thread_id)
                if turn["reporting"] is None:
                    complete(thread_id)
            elif turn.get("reporting") is not None and turn["reporting"].poll() is not None:
                complete(thread_id)
    return 0


def serve_unix_socket(runtime, path):
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

    arguments = runtime.sys.argv[1:]
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
    log_path = runtime.Path(str(runtime.sys.argv[0]) + ".socket-log")

    def log(entry):
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(runtime.json.dumps({"time": runtime.time.time(), **entry}) + "\n")

    # Listen before starting the stdio child: Popen waits for the child's exec, which can stall
    # under load past the app's connect timeout, and clients simply queue until the loop accepts.
    try:
        runtime.os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    runtime.os.chmod(path, 0o600)
    server.listen(8)
    log({"event": "listening", "pid": runtime.os.getpid()})
    child = runtime.subprocess.Popen([runtime.sys.executable, runtime.sys.argv[0], *child_arguments, "--listen", "stdio://"],
                             stdin=runtime.subprocess.PIPE, stdout=runtime.subprocess.PIPE)
    signal.signal(signal.SIGTERM, lambda *_: (child.kill(), runtime.os._exit(0)))

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
        send_frame(connection, runtime.json.dumps(value, separators=(",", ":")).encode())

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
        child.stdin.write((runtime.json.dumps(message, separators=(",", ":")) + "\n").encode())
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
                        message = runtime.json.loads(connection.message)
                    except runtime.json.JSONDecodeError:
                        message = None
                    connection.message = b""
                    if message is not None:
                        from_client(connection, message)

    while True:
        readable, _, _ = runtime.select.select([server, child.stdout] + [c.sock for c in connections], [], [], 0.25)
        if child.poll() is not None and not readable:
            break
        for source in readable:
            if source is server:
                sock, _ = server.accept()
                connections.append(Connection(sock))
            elif source is child.stdout:
                chunk = runtime.os.read(child.stdout.fileno(), 65536)
                if not chunk:
                    child.wait()
                    return child.returncode or 0
                child_buffer += chunk
                while b"\n" in child_buffer:
                    line, child_buffer = child_buffer.split(b"\n", 1)
                    try:
                        from_child(runtime.json.loads(line))
                    except runtime.json.JSONDecodeError:
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


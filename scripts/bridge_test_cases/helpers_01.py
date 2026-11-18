from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestHelpers01:
    def agent_manifests(self):
        """The shared Codex servers and Claude runs this case's data folder recorded. They outlive
        the bridge daemon on purpose, so a case stops its own when it ends."""
        manifests = []
        for path in sorted((self.data_directory / "codex-runs").glob("*.json")):
            manifests.append(("codex", path, json.loads(path.read_text(encoding="utf-8"))))
        for path in sorted((self.data_directory / "provider-runs").glob("*/run.json")):
            manifests.append(("claude", path, json.loads(path.read_text(encoding="utf-8"))))
        return manifests
    def agent_process_alive(self, process):
        """Whether a manifest's process still runs as the process it recorded (by start time)."""
        if not process:
            return False
        completed = subprocess.run(["ps", "-o", "stat=,lstart=,command=", "-p", str(process["pid"])],
                                   capture_output=True, text=True, check=False)
        line = completed.stdout.strip()
        return bool(line) and not line.startswith("Z") and str(self.data_directory) in line
    def stop_surviving_agents(self):
        for _, _, manifest in self.agent_manifests():
            process = manifest.get("process")
            if self.agent_process_alive(process):
                try:
                    os.killpg(process["pid"], signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
    def conversation_database(self):
        return self.data_directory / "Conversations-v1.sqlite"
    def conversation_state(self, task_id):
        """The task's stored conversation state row, or None before anything is recorded."""
        path = self.conversation_database()
        if not path.exists():
            return None
        with sqlite3.connect(path, timeout=30) as connection:
            row = connection.execute("SELECT payload FROM conversation_state WHERE task_id = ?", (task_id.upper(),)).fetchone()
        return json.loads(row[0]) if row else None
    def write_conversation_state(self, task_id, state):
        with sqlite3.connect(self.conversation_database(), timeout=30) as connection:
            connection.execute(
                "INSERT INTO conversation_state (task_id, payload) VALUES (?, ?) "
                "ON CONFLICT(task_id) DO UPDATE SET payload = excluded.payload",
                (task_id.upper(), json.dumps(state)),
            )
    def seed_long_history(self, task_id, sent_prompt=False, mid_history_command=False, tall_latest_answer=False,
                          switch_after_turn=None, latest_commentary=False):
        """Replaces the task's stored turns with 60 settled question-and-answer turns in its newest
        provider segment, as earlier sessions would have recorded them. Playhouse keeps the transcript
        itself, so a long history is written into its store rather than read from a provider. The
        UI suite's `seedLongHistory` writes the same rows.

        With `switch_after_turn`, the turns up to it belong to the previous segment and the rest to
        the newest, with a switch to the newest provider and back stored between them with nothing
        sent in between, as older conversations recorded an undone switch. `latest_commentary` gives
        the newest turn a commentary message before its answer."""
        key = task_id.upper()
        with sqlite3.connect(self.conversation_database(), timeout=30) as connection:
            state = json.loads(connection.execute("SELECT payload FROM conversation_state WHERE task_id = ?", (key,)).fetchone()[0])
            segment = state["segments"][-1]
            earlier_segment = segment
            if switch_after_turn is not None:
                earlier_segment = state["segments"][-2]
                undone = [
                    dict(segment, id="segment_undone_switch", codexTurnIDs=[], codexTurnModelIDs={}),
                    dict(earlier_segment, id="segment_undone_switch_back", codexTurnIDs=[], codexTurnModelIDs={}),
                ]
                state["segments"][-1:-1] = undone
                connection.execute("UPDATE conversation_state SET payload = ? WHERE task_id = ?", (json.dumps(state), key))
            for table in ("conversation_turns", "conversation_messages", "conversation_activities"):
                connection.execute(f"DELETE FROM {table} WHERE task_id = ?", (key,))
            turns = []
            if sent_prompt:
                # The sent prompt is the first stored user message, outside the newest history page.
                turns.append(("turn_sent_prompt", [("item_sent_prompt", "user", "Create a long history.")], []))
            for index in range(1, 61):
                answer = f"Long history assistant {index:02d}."
                if index == 60 and tall_latest_answer:
                    # A newest answer taller than the transcript viewport, so a conversation opened
                    # on its question differs visibly from one opened at its end.
                    answer = "\n\n".join([answer, *(f"Long history closing paragraph {number:02d}." for number in range(1, 31))])
                activities = []
                if index == 21 and mid_history_command:
                    # A mid-history call whose output runs past the clipped lines, so the UI can
                    # expand it and check it stays expanded after its row is rendered lazily again.
                    activities.append({
                        "id": "item_long_history_command_21", "tool": "Bash", "title": "Running ls fixture-history",
                        "input": "ls fixture-history", "detail": "ls fixture-history", "summary": "in /tmp/playhouse-fixture", "status": "completed",
                        "durationMs": 5, "isContextCompaction": False, "afterMessageID": "item_long_history_user_21",
                        "output": "".join(f"history-file-{line}.txt\n" for line in range(1, 7)),
                    })
                messages = [(f"item_long_history_user_{index}", "user", f"Long history user {index:02d}.")]
                if index == 60 and latest_commentary:
                    messages.append(("item_long_history_commentary_60", "commentary", "Long history commentary 60."))
                messages.append((f"item_long_history_assistant_{index}", "assistant", answer))
                turns.append((f"turn_long_history_{index}", messages, activities))
            for seq, (turn_id, messages, activities) in enumerate(turns, start=1):
                turn_segment = earlier_segment if switch_after_turn is not None and seq <= switch_after_turn else segment
                connection.execute("INSERT INTO conversation_turns (task_id, id, segment_id, seq) VALUES (?, ?, ?, ?)",
                                   (key, turn_id, turn_segment["id"], seq))
                for position, (message_id, role, text) in enumerate(messages):
                    payload = {"id": message_id, "role": "assistant" if role == "commentary" else role, "text": text,
                               "turnID": turn_id, "imageDataURLs": [], "provider": turn_segment["provider"]}
                    if role != "user":
                        payload["phase"] = role if role == "commentary" else "final_answer"
                    connection.execute(
                        "INSERT INTO conversation_messages (task_id, turn_id, id, position, payload) VALUES (?, ?, ?, ?, ?)",
                        (key, turn_id, message_id, position, json.dumps(payload)),
                    )
                for position, activity in enumerate(activities):
                    connection.execute(
                        "INSERT INTO conversation_activities (task_id, turn_id, id, position, payload) VALUES (?, ?, ?, ?, ?)",
                        (key, turn_id, activity["id"], position, json.dumps({**activity, "turnID": turn_id})),
                    )
    def conversation_row_counts(self, task_id):
        path = self.conversation_database()
        if not path.exists():
            return {"turns": 0, "messages": 0, "activities": 0}
        with sqlite3.connect(path, timeout=30) as connection:
            return {
                name: connection.execute(f"SELECT COUNT(*) FROM conversation_{name} WHERE task_id = ?", (task_id.upper(),)).fetchone()[0]
                for name in ("turns", "messages", "activities")
            }
    def finish_cli(self, process, command, expected_status=0, timeout=90):
        stdout, stderr = process.communicate(timeout=timeout)
        self.assertEqual(
            process.returncode,
            expected_status,
            f"CLI exit mismatch for {command}: stdout={stdout!r}; stderr={stderr!r}",
        )
        lines = [line for line in stdout.splitlines() if line.strip()]
        self.assertTrue(lines, f"CLI returned no JSON output for {command}: {stderr}")
        response = json.loads(lines[-1])
        self.assertEqual(response.get("version"), 1)
        self.assertIn("id", response)
        return response, [json.loads(line) for line in lines[:-1]]
    def restart_provider(self, executable):
        # The bridge daemon keeps one provider process alive across CLI calls, so
        # a fresh CLI read no longer implies a fresh provider. Stop this test's own
        # fixture provider (its path is unique to the test) so the next call
        # relaunches it and loads the thread again, as after a provider restart.
        subprocess.run(["pkill", "-f", str(executable)], check=False)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if subprocess.run(["pgrep", "-f", str(executable)], capture_output=True).returncode != 0:
                return
            time.sleep(0.05)
        self.fail(f"The fixture provider did not stop: {executable}")
    def assert_success(self, response):
        self.assertTrue(response.get("ok"), response.get("error"))
        return response.get("result")
    def assert_failure(self, response, code):
        self.assertFalse(response.get("ok"))
        self.assertEqual(response.get("error", {}).get("code"), code)
    def diagnostic_events(self):
        path = self.data_directory / "Diagnostics.jsonl"
        if not path.is_file():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    def create_task(self, title="Bridge task", roots=None, provider=None):
        if roots is None:
            roots = [self.primary]
        command = ["task", "create", "--title", title, "--prompt", "Fixture task description."]
        for root in roots:
            command.extend(["--root", root])
        if provider:
            command.extend(["--provider", provider])
        response, _ = self.call_cli(*command)
        return self.assert_success(response)
    def assert_user_stop_pauses_provider_turn(self, title, provider, environment_name, fixture_name):
        task = self.create_task(title, provider=provider)
        fixture_source = Path(__file__).resolve().parent / "fixtures" / fixture_name
        executable = self.data_directory / f"{provider}-fixture-hold-interrupt"
        copy_file(fixture_source, executable)
        executable.chmod(0o755)
        marker_name, marker_value = (
            (".playhouse-codex-fixture-owner", "Playhouse test owns this Codex protocol fixture (v1).\n")
            if provider == "codex" else
            (".playhouse-claude-fixture-owner", "Playhouse test owns this Claude Code protocol fixture (v1).\n")
        )
        (self.data_directory / marker_name).write_text(marker_value, encoding="utf-8")
        environment = {environment_name: str(executable)}
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        release = Path(str(executable) + ".interrupt-release")
        send_results = {}
        send_failures = []
        stop_results = {}
        stop_failures = []

        def send_turn():
            try:
                send_results["response"], send_results["events"] = self.call_cli(
                    "conversation", "send", task["id"], "--message", "Hold until stopped.",
                    expected_status=1, timeout=45, extra_environment=environment,
                )
            except Exception as error:
                send_failures.append(error)

        sender = threading.Thread(target=send_turn, daemon=True)
        sender.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), f"{provider} should reach its active thinking fixture before Stop.")
        active = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(active["status"], "In Progress")
        thread_id = active["codexThreadID"] if provider == "codex" else active["claudeSessionID"]
        self.assertTrue(thread_id, f"The {provider} turn should have a native conversation ID while it thinks.")
        thinking = self.assert_success(self.call_cli("conversation", "runtime")[0])
        self.assertIn(thread_id, thinking["activeThreadIDs"], "The daemon should report the thinking turn as active.")
        self.assertIn(thread_id, thinking["interruptibleThreadIDs"], "The daemon should report the thinking turn as interruptible.")

        def stop_turn():
            try:
                stop_results["response"] = self.call_cli(
                    "conversation", "stop", task["id"], timeout=20, extra_environment=environment,
                )[0]
            except Exception as error:
                stop_failures.append(error)

        stopper = threading.Thread(target=stop_turn, daemon=True)
        stopper.start()
        interrupt_deadline = time.monotonic() + 10
        while not received.is_file() and time.monotonic() < interrupt_deadline:
            time.sleep(0.02)
        self.assertTrue(received.is_file(), f"{provider} should receive its native interrupt before acknowledging it.")
        stopping = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopping["status"], "Waiting Response", "The task should leave In Progress before the provider acknowledges Stop.")
        release.write_text("acknowledge interrupt\n", encoding="utf-8")
        stopper.join(timeout=20)
        self.assertFalse(stopper.is_alive(), f"The {provider} interrupt acknowledgment should settle.")
        self.assertEqual(stop_failures, [])
        stopped = self.assert_success(stop_results["response"])
        self.assertTrue(stopped["interrupted"], f"{provider} should acknowledge its native turn interrupt.")
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), f"The {provider} send should finish after its active turn is interrupted.")
        self.assertEqual(send_failures, [])
        self.assertTrue(received.is_file(), f"The {provider} fixture should confirm it received the native interrupt.")
        persisted = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(persisted["status"], "Waiting Response")
        restored = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        user = next(message for message in restored["messages"] if message["role"] == "user")
        self.assertIsNotNone(user.get("createdAt"), "Interrupted turns keep the stored time of their prompt.")
        again = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        self.assertEqual(user["createdAt"], next(message for message in again["messages"] if message["id"] == user["id"])["createdAt"])
        settled = self.assert_success(self.call_cli("conversation", "runtime")[0])
        self.assertNotIn(thread_id, settled["activeThreadIDs"], "A stopped turn is no longer active in the daemon.")
        self.assertIn(thread_id, settled["interruptedThreadIDs"], "The daemon should remember that the turn was paused.")
        events = self.diagnostic_events()
        self.assertTrue(any(
            event.get("event") == "conversation.interrupt.finished"
            and event.get("taskID") == task["id"]
            and event.get("interrupted") == "true"
            for event in events
        ), f"The {provider} stop should be recorded as accepted.")
        failed_send = next((event for event in events
                            if event.get("event") == "conversation.send.failed"
                            and event.get("taskID") == task["id"]), None)
        self.assertIsNotNone(failed_send, "The stopped provider turn should settle through the send failure path.")
        self.assertIsNone(persisted.get("statusMessage"))
    def read_watcher_snapshot(self, watcher, predicate, timeout=15, event_type="runtime_state"):
        """Reads `--watch` event lines until one `event_type` snapshot satisfies `predicate`."""
        deadline = time.monotonic() + timeout
        seen = []
        while time.monotonic() < deadline:
            readable, _, _ = select.select([watcher.stdout], [], [], 0.1)
            if not readable:
                continue
            line = watcher.stdout.readline()
            if not line.strip():
                continue
            event = json.loads(line.decode("utf-8"))
            if event.get("type") != event_type:
                continue
            seen.append(event["payload"])
            if predicate(event["payload"]):
                return event["payload"]
        self.fail(f"No matching {event_type} snapshot arrived within {timeout}s; saw {seen}")
    @staticmethod
    def process_is_running(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True
    @staticmethod
    def daemon_log_pids(service):
        """Every daemon process that wrote to this service's socket log (each logs on start)."""
        digest = hashlib.sha256(service.encode("utf-8")).hexdigest()[:32]
        log = Path("/tmp/playhouse-bridge") / str(os.getuid()) / f"{digest}.sock.log"
        text = log.read_text(encoding="utf-8") if log.is_file() else ""
        return {int(pid) for pid in re.findall(r"playhouse-daemon\[(\d+)\]", text)}
    def wait_until_process_exits(self, pid, timeout):
        deadline = time.monotonic() + timeout
        while self.process_is_running(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        return not self.process_is_running(pid)
    def install_provider_fixture(self, provider, name):
        """A copy of the provider fixture under this case's data folder, owned by this case."""
        fixture_name = "codex-app-server-fixture.py" if provider == "codex" else "claude-code-fixture.py"
        executable = self.data_directory / name
        copy_file(Path(__file__).resolve().parent / "fixtures" / fixture_name, executable)
        executable.chmod(0o755)
        marker_name, marker_value = (
            (".playhouse-codex-fixture-owner", "Playhouse test owns this Codex protocol fixture (v1).\n")
            if provider == "codex" else
            (".playhouse-claude-fixture-owner", "Playhouse test owns this Claude Code protocol fixture (v1).\n")
        )
        (self.data_directory / marker_name).write_text(marker_value, encoding="utf-8")
        return executable
    def wait_for(self, condition, message, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = condition()
            if value:
                return value
            time.sleep(0.05)
        self.fail(message)
    def kill_daemon(self, environment):
        """SIGKILLs the private service's daemon, as a crash or a rebuild would end it."""
        pid = self.assert_success(self.call_cli("status", extra_environment=environment)[0])["processID"]
        os.kill(pid, signal.SIGKILL)
        self.wait_for(lambda: not self.process_is_running(pid), "The killed daemon should exit.")
        return pid
    def jsonl(self, path):
        path = Path(path)
        if not path.is_file():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    def task_for(self, task_id, environment):
        return self.assert_success(self.call_cli("task", "get", task_id, extra_environment=environment)[0])
    def history_texts(self, task_id, environment):
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        return [message["text"] for message in history["messages"]], history
    def claude_runs(self, environment):
        return [(path.parent, m) for kind, path, m in self.agent_manifests()
                if kind == "claude" and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]]
    def start_reattach_chat(self, name, provider="claude"):
        """A chat on a private service whose turns run in the provider's daemon-restart fixture."""
        executable = self.install_provider_fixture(provider, name)
        environment = self.restart_service_environment(provider, executable)
        self.assert_success(self.call_cli("settings", "set-default-provider", provider, extra_environment=environment)[0])
        self.assert_success(self.call_cli("settings", "clear-parent", extra_environment=environment)[0])
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        return executable, environment, chat_id
    def close_held_chat_turn(self, executable, new_title=None):
        """Has the held chat turn run its real close-turn (a new titled page when `new_title` is
        set) and returns that command's logged result; the turn itself keeps running."""
        output = Path(str(executable) + ".reattach-close-turn-output")
        before = len(self.jsonl(output))
        Path(str(executable) + ".reattach-close-turn").write_text(new_title or "", encoding="utf-8")
        self.wait_for(lambda: len(self.jsonl(output)) > before, "The held chat turn runs close-turn.")
        result = self.jsonl(output)[-1]
        self.assertEqual(result["returncode"], 0, result)
        self.assertTrue(json.loads(result["output"].splitlines()[-1])["ok"], result)
        return result
    def send_filed_chat_turn(self, executable, environment, chat_id, message, new_title=None):
        """One ordinary chat turn that runs close-turn (opening a new page titled `new_title` when
        set) and is filed by the daemon that sent it. Returns the text the provider received."""
        ready = Path(str(executable) + ".reattach-ready")
        ready.unlink(missing_ok=True)
        sender = self.start_cli("conversation", "send", chat_id, "--message", message, extra_environment=environment)
        self.wait_for(ready.is_file, f"The chat turn {message!r} runs.")
        received = self.reattach_prompt_text(ready)
        self.close_held_chat_turn(executable, new_title)
        Path(str(executable) + ".reattach-release-quiet").touch()
        self.assert_success(self.finish_cli(sender, "conversation send", timeout=60)[0])
        if "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE" in environment:
            self.wait_for(lambda: not self.claude_runs(environment), "The finished chat turn's run is removed.")
        return received
    @staticmethod
    def reattach_prompt_text(ready):
        """The prompt the restart fixture's running turn received: Claude's ready file holds the
        text itself, Codex's a JSON record with it."""
        text = ready.read_text(encoding="utf-8")
        try:
            return json.loads(text)["text"]
        except (ValueError, KeyError, TypeError):
            return text
    def reattach_agent(self, environment):
        """The process running the private service's agent: the Claude run, or the Codex server."""
        if "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE" in environment:
            return self.claude_runs(environment)[0][1]["process"]
        return next(m["process"] for kind, _, m in self.agent_manifests()
                    if kind == "codex" and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"])
    def start_chat_turn_and_kill_daemon(self, executable, environment, chat_id, message, close_turn_title=None):
        """Sends a chat turn, optionally has it run close-turn, then kills the daemon mid-turn."""
        ready = Path(str(executable) + ".reattach-ready")
        ready.unlink(missing_ok=True)
        sent = {}
        sender = threading.Thread(target=lambda: sent.setdefault("turn", self.call_cli(
            "conversation", "send", chat_id, "--message", message,
            expected_status=69, timeout=60, extra_environment=environment)), daemon=True)
        sender.start()
        self.wait_for(ready.is_file, "The chat turn should be running before the daemon dies.")
        if close_turn_title:
            self.close_held_chat_turn(executable, close_turn_title)
        agent = self.reattach_agent(environment)
        self.kill_daemon(environment)
        sender.join(timeout=20)
        self.assert_failure(sent["turn"][0], "service_unavailable")
        self.assertTrue(self.agent_process_alive(agent), "The agent outlives the daemon that started the chat turn.")
        return agent
    def chat_page_texts(self, page_id, environment):
        page = self.assert_success(self.call_cli("chat", "page", "read", page_id, extra_environment=environment)[0])
        return [message["text"] for message in page["messages"]]
    def chat_pages(self, environment):
        return self.assert_success(self.call_cli("chat", "page", "list", extra_environment=environment)[0])["pages"]
    def assert_rejected_stop_restores_active_status(self, provider, environment_name, fixture_name):
        task = self.create_task(f"{provider.title()} rejected stop", provider=provider)
        fixture_source = Path(__file__).resolve().parent / "fixtures" / fixture_name
        executable = self.data_directory / f"{provider}-fixture-hold-reject-interrupt"
        copy_file(fixture_source, executable)
        executable.chmod(0o755)
        marker_name, marker_value = (
            (".playhouse-codex-fixture-owner", "Playhouse test owns this Codex protocol fixture (v1).\n")
            if provider == "codex" else
            (".playhouse-claude-fixture-owner", "Playhouse test owns this Claude Code protocol fixture (v1).\n")
        )
        (self.data_directory / marker_name).write_text(marker_value, encoding="utf-8")
        environment = {environment_name: str(executable)}
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        reject = Path(str(executable) + ".interrupt-reject")
        release = Path(str(executable) + ".interrupt-release")
        send_result = {}
        send_failures = []

        def send_turn():
            try:
                send_result["response"], _ = self.call_cli(
                    "conversation", "send", task["id"], "--message", "Hold until stopped.",
                    timeout=45, extra_environment=environment,
                )
            except Exception as error:
                send_failures.append(error)

        sender = threading.Thread(target=send_turn, daemon=True)
        sender.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), f"{provider} should be thinking before rejected Stop.")
        stop_result = {}
        stop_failures = []

        def reject_stop():
            try:
                stop_result["response"], _ = self.call_cli(
                    "conversation", "stop", task["id"], expected_status=1, timeout=20, extra_environment=environment,
                )
            except Exception as error:
                stop_failures.append(error)

        stopper = threading.Thread(target=reject_stop, daemon=True)
        stopper.start()
        interrupt_deadline = time.monotonic() + 10
        while not received.is_file() and time.monotonic() < interrupt_deadline:
            time.sleep(0.02)
        self.assertTrue(received.is_file(), f"{provider} should receive its native interrupt before rejecting it.")
        stopping = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopping["status"], "Waiting Response", "The optimistic pause should persist while rejection is pending.")
        reject.write_text("reject interrupt\n", encoding="utf-8")
        stopper.join(timeout=20)
        self.assertFalse(stopper.is_alive(), f"{provider} should return its interrupt rejection.")
        self.assertEqual(stop_failures, [])
        failed_stop = stop_result["response"]
        self.assertFalse(failed_stop.get("ok", True), f"{provider} rejection should reach the caller as a failed stop.")
        active = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(active["status"], "In Progress", "A rejected interrupt must restore the active task while its turn continues.")
        release.write_text("finish active turn\n", encoding="utf-8")
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), f"{provider} should complete after the fixture releases its still-active turn.")
        self.assertEqual(send_failures, [])
        self.assert_success(send_result["response"])
        completed = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(completed["status"], "Waiting Response", "The non-interrupted turn should finish normally and return the task for review.")
    def create_repo_task(self, title, repositories, branches=None, branch_from=None, roots=None, merge_targets=None, materialize=False):
        command = ["task", "create", "--title", title, "--prompt", "Fixture task description."]
        for repository in repositories:
            command.extend(["--repo", repository])
        for repository, branch in (branches or {}).items():
            command.extend(["--branch", f"{repository}={branch}"])
        for repository, branch in (branch_from or {}).items():
            command.extend(["--branch-from", f"{repository}={branch}"])
        for repository, branch in (merge_targets or {}).items():
            command.extend(["--merge-target", f"{repository}={branch}"])
        for root in roots or []:
            command.extend(["--root", root])
        response, _ = self.call_cli(*command)
        task = self.assert_success(response)
        if materialize:
            self.complete_fixture_turn(task["id"])
            task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        return task
    def complete_fixture_turn(self, task_id, executable_name="codex-fixture", message="Complete this task.", expected_status="Review", extra_environment=None, while_turn_held=None, outcome="completed"):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / executable_name
        hold_marker = Path(str(executable) + ".hold-release")
        hold_marker.touch()
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        environment = {
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
            **(extra_environment or {}),
        }
        command = [
            "conversation", "send", task_id, "--message", message,
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
        ]
        active = Path(str(executable) + ".turn-active")
        release = Path(str(executable) + ".turn-release")
        active.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        process = self.start_cli(*command, extra_environment=environment)
        try:
            deadline = time.monotonic() + 90
            outcome_count = 0
            while process.poll() is None and time.monotonic() < deadline:
                if active.exists() and not release.exists():
                    if while_turn_held is not None:
                        # Runs once while the provider turn holds the task, as an agent's own command would.
                        held, while_turn_held = while_turn_held, None
                        held()
                    response, _ = self.call_cli(
                        "task", "outcome", task_id, outcome, extra_environment=environment,
                    )
                    self.assertEqual(self.assert_success(response)["outcome"], outcome)
                    outcome_count += 1
                    release.write_text("Release the completed fixture turn.\n", encoding="utf-8")
                time.sleep(0.02)
            self.assertGreater(outcome_count, 0, "The fixture should hold each turn until its explicit outcome is reported.")
            response, _ = self.finish_cli(process, command)
        finally:
            if process.poll() is None:
                release.write_text("Release the fixture turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            hold_marker.unlink(missing_ok=True)
        result = self.assert_success(response)
        current, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(current)["status"], expected_status)
        return result
    def complete_standalone_chat_fixture_turn(self, chat_task_id, message, continues=True, new_title=None, executable_name="codex-fixture-chat", skip_close_turn=False):
        """Drive one real provider turn on the hidden standalone chat task, simulating the
        agent's mandatory `chat page close-turn` tool call instead of `task outcome`.
        `skip_close_turn=True` simulates an agent that forgets to classify the turn, so the
        missed-signal compliance tracking can be exercised."""
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / executable_name
        hold_marker = Path(str(executable) + ".hold-release")
        hold_marker.touch()
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        command = ["conversation", "send", chat_task_id, "--message", message]
        active = Path(str(executable) + ".turn-active")
        release = Path(str(executable) + ".turn-release")
        active.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        process = self.start_cli(*command, extra_environment=environment)
        try:
            deadline = time.monotonic() + 90
            close_turn_count = 0
            while process.poll() is None and time.monotonic() < deadline:
                if active.exists() and not release.exists():
                    if not skip_close_turn:
                        close_turn_args = [
                            "chat", "page", "close-turn", chat_task_id,
                            "--continues", "true" if continues else "false",
                        ]
                        if new_title:
                            close_turn_args += ["--new-title", new_title]
                        response, _ = self.call_cli(*close_turn_args, extra_environment=environment)
                        self.assert_success(response)
                        close_turn_count += 1
                    release.write_text("Release the completed fixture turn.\n", encoding="utf-8")
                time.sleep(0.02)
            if not skip_close_turn:
                self.assertGreater(close_turn_count, 0, "The fixture should hold the turn until its chat page close-turn signal.")
            response, _ = self.finish_cli(process, command)
        finally:
            if process.poll() is None:
                release.write_text("Release the fixture turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            hold_marker.unlink(missing_ok=True)
        return self.assert_success(response)
    def seed_legacy_standalone_chat_task(self, session_id="legacy-chat-session"):
        """Recreate a standalone chat stored as a hidden board task, as before the split."""
        repository_root = Path(__file__).resolve().parent.parent
        executable = self.data_directory / "seed-legacy-standalone-chat-task"
        subprocess.run(
            [
                # Self-contained: it declares the pre-split BoardTask itself, so compiling it
                # against the current models would redeclare the entity.
                "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
                str(repository_root / "scripts" / "seed-legacy-standalone-chat-task.swift"),
                "-o", str(executable),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        result = subprocess.run(
            [str(executable), str(self.data_directory), session_id],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip().splitlines()[-1]
    def seed_done_task_pull_request(self, task_id, number=123, repository_index=0):
        repository_root = Path(__file__).resolve().parent.parent
        executable = self.data_directory / "seed-task-pr-link"
        subprocess.run(
            [
                "xcrun", "swiftc", "-module-name", "Playhouse",
                str(repository_root / "Playhouse" / "App" / "BoardTask.swift"),
                str(repository_root / "Playhouse" / "App" / "ConversationSubject.swift"),
                str(repository_root / "scripts" / "seed-task-pr-link.swift"),
                "-o", str(executable),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        seeded_url = f"https://github.com/playhouse-test/fixture/pull/{number}"
        command = [str(executable), str(self.data_directory), task_id, str(number), seeded_url]
        if repository_index:
            command.append(str(repository_index))
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn(f"Seeded linked PR #{number}", result.stdout)
        return seeded_url
    def seed_legacy_plugin_task(self, task_id, plugin_id):
        root = Path(__file__).resolve().parent.parent
        executable = self.data_directory / "seed-legacy-plugin"
        subprocess.run(["xcrun", "swiftc", "-module-name", "Playhouse",
                        str(root / "Playhouse/App/BoardTask.swift"),
                        str(root / "Playhouse/App/ConversationSubject.swift"),
                        str(root / "scripts/seed-task-pr-link.swift"), "-o", str(executable)],
                       check=True, capture_output=True, text=True)
        subprocess.run([str(executable), str(self.data_directory), task_id, "--legacy-plugin",
                        plugin_id, str(self.plugins_folder())], check=True, capture_output=True, text=True)
    def clear_task_provider_session(self, task_id):
        executable = self.data_directory / "seed-task-pr-link"
        if not executable.exists():
            repository_root = Path(__file__).resolve().parent.parent
            subprocess.run(
                [
                    "xcrun", "swiftc", "-module-name", "Playhouse",
                    str(repository_root / "Playhouse" / "App" / "BoardTask.swift"),
                    str(repository_root / "Playhouse" / "App" / "ConversationSubject.swift"),
                    str(repository_root / "scripts" / "seed-task-pr-link.swift"),
                    "-o", str(executable),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
        result = subprocess.run(
            [str(executable), str(self.data_directory), task_id, "--clear-provider-session"],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("Cleared provider sessions", result.stdout)
    def wait_for_marker(self, marker, present, message, timeout=10):
        deadline = time.monotonic() + timeout
        while marker.exists() != present and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(marker.exists(), present, message)
    def prepare_workspace_changes(self):
        marker = self.fixture / ".playhouse-bridge-fixture"
        if not marker.is_file() or marker.read_text(encoding="utf-8") != "Playhouse bridge tests own this deterministic fixture (v1).\n":
            raise RuntimeError(f"Refusing to modify the Git fixture without its ownership marker: {self.fixture}")

        self.run_git(self.changes, "reset", "--mixed", "HEAD")
        self.run_git(self.changes, "checkout", "--", ".")
        # Earlier cases can leave untracked files (for example a recreated ephemeral.txt);
        # the ownership marker lives outside this repository, so cleaning cannot remove it.
        self.run_git(self.changes, "clean", "-fd")
        (self.changes / "staged.txt").write_text("Staged index version.\n", encoding="utf-8")
        (self.changes / "shared.txt").write_text("Shared index version.\n", encoding="utf-8")
        (self.changes / "syntax.json").write_text('{"value":"working version"}\n', encoding="utf-8")
        for path in ["staged.txt", "shared.txt"]:
            self.run_git(self.changes, "add", path)
        (self.changes / "shared.txt").write_text("Shared working version.\n", encoding="utf-8")
        (self.changes / "working.txt").write_text("Working tree version.\n", encoding="utf-8")
        (self.changes / "deleted.txt").unlink(missing_ok=True)
        (self.changes / "untracked.txt").write_text("Untracked file.\n", encoding="utf-8")
        if (self.changes / "staged-deleted.txt").exists():
            self.run_git(self.changes, "rm", "staged-deleted.txt")
    def branch_exists(self, repository, branch):
        return subprocess.run(
            ["git", "-C", str(repository), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
            check=False,
            capture_output=True,
            text=True,
        ).returncode == 0
    def changes_diff(self, task_id, path, group, expected_status=0, repository=None):
        response, _ = self.call_cli(
            "task", "changes", "diff", task_id,
            "--repository", repository or self.changes,
            "--path", path,
            "--group", group,
            expected_status=expected_status,
        )
        return response
    def drive_held_fixture_command(self, task_id, command, outcome, executable_name="codex-fixture", on_hold=None, extra_environment=None):
        """Runs a CLI command whose provider turn holds in the Codex fixture, calls
        `on_hold` while the turn is active, reports `outcome`, and returns the
        command's result."""
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / executable_name
        hold_marker = Path(str(executable) + ".hold-release")
        hold_marker.touch()
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable), **(extra_environment or {})}
        active = Path(str(executable) + ".turn-active")
        release = Path(str(executable) + ".turn-release")
        active.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        process = self.start_cli(*command, extra_environment=environment)
        held = 0
        try:
            deadline = time.monotonic() + 90
            while process.poll() is None and time.monotonic() < deadline:
                if active.exists() and not release.exists():
                    if held == 0 and on_hold is not None:
                        on_hold(environment)
                    response, _ = self.call_cli("task", "outcome", task_id, outcome, extra_environment=environment)
                    self.assertEqual(self.assert_success(response)["outcome"], outcome)
                    held += 1
                    release.write_text("Release the fixture turn.\n", encoding="utf-8")
                time.sleep(0.02)
            self.assertGreater(held, 0, "The command should have run a held provider turn.")
            response, _ = self.finish_cli(process, command)
        finally:
            if process.poll() is None:
                release.write_text("Release the fixture turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            hold_marker.unlink(missing_ok=True)
        return self.assert_success(response)
    def open_side_chat_task(self, provider, executable_name):
        """A repository task whose first conversation turn already ran through `provider`'s fixture."""
        task = self.create_repo_task(f"Side chat {provider}", [self.primary])
        self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", provider)[0])
        executable = self.install_provider_fixture(provider, executable_name)
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE" if provider == "codex" else "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        self.assert_failure(self.call_cli(
            "conversation", "side-chat", task["id"], "--selection", "parser", "--message", "Too early?",
            extra_environment=environment, expected_status=1,
        )[0], "invalid_transition")
        self.assert_success(self.call_cli(
            "conversation", "send", task["id"], "--message", "Explain the design of the parser.",
            extra_environment=environment,
        )[0])
        return self.task_for(task["id"], environment), executable, environment
    def assert_side_chat_leaves_task_alone(self, task, before, environment):
        after = self.task_for(task["id"], environment)
        for field in ("status", "codexThreadID", "claudeSessionID", "savedPrompt"):
            self.assertEqual(after.get(field), before.get(field), f"The side chat must not change the task's {field}.")
        return after
    def assert_side_chat_validation(self, task, environment, side_chat_id, fork_id):
        self.assert_failure(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", side_chat_id, "--message", "   ",
            extra_environment=environment, expected_status=2,
        )[0], "invalid_argument")
        self.assert_failure(self.call_cli(
            "conversation", "side-chat", task["id"], "--selection", "   ", "--message", "Why?",
            extra_environment=environment, expected_status=2,
        )[0], "invalid_argument")
        for flag, value in (("--model", "bad model!"), ("--effort", "extreme")):
            self.assert_failure(self.call_cli(
                "conversation", "side-chat", task["id"], "--side-chat", side_chat_id, "--message", "Which model?", flag, value,
                extra_environment=environment, expected_status=2,
            )[0], "invalid_argument")
        self.assert_failure(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", "no-such-side-chat", "--message", "Hello?",
            extra_environment=environment, expected_status=3,
        )[0], "not_found")
        saved_before = next(chat for chat in self.assert_success(self.call_cli(
            "conversation", "side-chats", task["id"], extra_environment=environment)[0]) if chat["id"] == side_chat_id)
        closed = self.assert_success(self.call_cli("conversation", "side-chat-close", task["id"], side_chat_id, extra_environment=environment)[0])
        self.assertEqual(closed, {"closed": True})
        # Closing ends the live session only: the saved side chat continues its forked conversation.
        resumed = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", side_chat_id, "--message", "Still there?",
            extra_environment=environment,
        )[0])
        self.assertEqual(resumed["sideChatID"], side_chat_id)
        self.assertRegex(resumed["reply"], rf"^Side chat follow-up \d+ on {re.escape(fork_id)}: Still there\?$",
                         "A closed side chat must continue the same forked provider conversation.")
        saved_after = next(chat for chat in self.assert_success(self.call_cli(
            "conversation", "side-chats", task["id"], extra_environment=environment)[0]) if chat["id"] == side_chat_id)
        self.assertEqual(saved_after["threadID"], fork_id)
        self.assertEqual(saved_after["messages"], saved_before["messages"] + [
            {"isUser": True, "text": "Still there?"}, {"isUser": False, "text": resumed["reply"]}])
        self.assertEqual(resumed["sideChat"], saved_after, "The reply carries the side chat as saved.")

from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases01:
    # case-contract: test_codex_stop_interrupts_thinking_turn_and_waits_for_response | Clicking Stop during Codex reasoning immediately moves the task to Waiting Response and sends Codex's turn-scoped turn/interrupt request. The accepted interruption settles the send without changing the task to Blocked, and a fresh CLI/XPC read confirms the status persisted. A fresh `conversation runtime` read from the daemon reports the turn active and interruptible while it thinks, and interrupted but no longer active once the stop settles. The turn's activity section renders open for as long as the daemon reports the turn active, and folds once the stop settles with no final answer. The observed Codex message time survives interruption and reload. In the window Continue replaces Stop at once, before the provider acknowledges the interrupt.
    def test_codex_stop_interrupts_thinking_turn_and_waits_for_response(self):
        self.assert_user_stop_pauses_provider_turn(
            "Codex stop while thinking", "codex", "PLAYHOUSE_E2E_CODEX_EXECUTABLE", "codex-app-server-fixture.py"
        )
    # case-contract: test_claude_stop_interrupts_thinking_turn_and_waits_for_response | Clicking Stop during Claude reasoning immediately moves the task to Waiting Response and sends Claude's session-scoped control interrupt. The accepted interruption settles the send without changing the task to Blocked, and a fresh CLI/XPC read confirms the status persisted. A fresh `conversation runtime` read from the daemon reports the turn active and interruptible while it thinks, and interrupted but no longer active once the stop settles. The turn's activity section renders open for as long as the daemon reports the turn active, and folds once the stop settles with no final answer. In the window Continue replaces Stop at once, before the provider acknowledges the interrupt.
    def test_claude_stop_interrupts_thinking_turn_and_waits_for_response(self):
        self.assert_user_stop_pauses_provider_turn(
            "Claude stop while thinking", "claude", "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE", "claude-code-fixture.py"
        )
    # case-contract: test_bridge_daemon_starts_on_demand_serves_watchers_and_exits_when_idle | The bridge daemon starts on the first request, exactly once even when callers race to start it, serves later requests from the same process, and stays alive while any connection (such as a window's runtime or CPU usage watcher) is open. A watcher receives the daemon's runtime snapshots as a turn starts and stops, and the daemon exits by itself once the last connection closes and no request is running; the next request starts a fresh daemon on demand without any manual step.
    def test_bridge_daemon_starts_on_demand_serves_watchers_and_exits_when_idle(self):
        service = f"{arguments.service_name}.lifecycle-{uuid.uuid4().hex[:8]}"
        fixture_source = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-hold-interrupt"
        copy_file(fixture_source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": service,
            "PLAYHOUSE_BRIDGE_IDLE_GRACE_SECONDS": "3",
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
        }
        task = self.create_task("Daemon watcher", provider="codex")

        # Callers that race to start the daemon start exactly one.
        racing = [self.start_cli("status", extra_environment=environment) for _ in range(4)]
        racing_pids = set()
        for process in racing:
            stdout, _ = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, stdout)
            racing_pids.add(json.loads(stdout.strip().splitlines()[-1])["result"]["processID"])
        self.assertEqual(len(racing_pids), 1, f"Racing first requests should share one daemon: {racing_pids}")
        daemon_pid = racing_pids.pop()
        self.assertEqual(self.daemon_log_pids(service), {daemon_pid}, "Only one daemon should have been started.")
        self.assertTrue(self.process_is_running(daemon_pid), "The first request should have started a daemon.")
        second = self.assert_success(self.call_cli("status", extra_environment=environment)[0])
        self.assertEqual(second["processID"], daemon_pid, "Later requests should reuse the running daemon.")

        watcher = self.start_cli("conversation", "runtime", "--watch", extra_environment=environment, binary_output=True)
        # A window also streams CPU usage; that subscription must end with its connection too.
        cpu_watcher = self.start_cli("conversation", "cpu-usage", "--watch", extra_environment=environment, binary_output=True)
        try:
            idle = self.read_watcher_snapshot(watcher, lambda snapshot: True)
            self.assertEqual(idle["activeThreadIDs"], [], "A daemon with no turns reports nothing active.")
            cpu_idle = self.read_watcher_snapshot(cpu_watcher, lambda snapshot: True, event_type="cpu_usage_state")
            self.assertEqual(cpu_idle["percentByThreadID"], {}, "A daemon with no turns samples no CPU usage.")
            time.sleep(4.5)
            self.assertTrue(self.process_is_running(daemon_pid), "An open watcher keeps the daemon alive past its idle grace.")
            self.assertEqual(
                self.assert_success(self.call_cli("status", extra_environment=environment)[0])["processID"], daemon_pid
            )

            ready = Path(str(executable) + ".interrupt-ready")
            release = Path(str(executable) + ".interrupt-release")
            sent = {}

            def send_turn():
                sent["response"], _ = self.call_cli(
                    "conversation", "send", task["id"], "--message", "Hold until stopped.",
                    expected_status=1, timeout=45, extra_environment=environment,
                )

            sender = threading.Thread(target=send_turn, daemon=True)
            sender.start()
            deadline = time.monotonic() + 15
            while not ready.is_file() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.is_file(), "The held turn should be thinking before the watcher is checked.")
            thread_id = self.assert_success(self.call_cli("task", "get", task["id"])[0])["codexThreadID"]
            running = self.read_watcher_snapshot(watcher, lambda snapshot: thread_id in snapshot["activeThreadIDs"])
            self.assertIn(thread_id, running["interruptibleThreadIDs"])

            stopper = threading.Thread(
                target=lambda: self.call_cli("conversation", "stop", task["id"], timeout=20, extra_environment=environment),
                daemon=True,
            )
            stopper.start()
            received = Path(str(executable) + ".interrupt-received")
            deadline = time.monotonic() + 10
            while not received.is_file() and time.monotonic() < deadline:
                time.sleep(0.02)
            release.write_text("acknowledge interrupt\n", encoding="utf-8")
            stopper.join(timeout=20)
            sender.join(timeout=20)
            stopped = self.read_watcher_snapshot(watcher, lambda snapshot: thread_id not in snapshot["activeThreadIDs"])
            self.assertIn(thread_id, stopped["interruptedThreadIDs"])
        finally:
            for open_watcher in (watcher, cpu_watcher):
                open_watcher.terminate()
                open_watcher.wait(timeout=10)

        self.assertTrue(
            self.wait_until_process_exits(daemon_pid, timeout=20),
            "The daemon should exit by itself once its last connection closes and no request is running.",
        )
        restarted = self.assert_success(self.call_cli("status", extra_environment=environment)[0])
        self.assertNotEqual(restarted["processID"], daemon_pid, "The next request should start a fresh daemon on demand.")
        self.assertTrue(self.process_is_running(restarted["processID"]))
    # case-contract: test_bridge_daemon_death_fails_the_turn_and_recovers_on_next_request | When the bridge daemon dies in the middle of a turn, that turn's send fails with a connection error instead of hanging, but the provider keeps running in its own session. The next request starts a fresh daemon on demand, which reattaches the running turn so the task stays In Progress with no restart notice, stops that reattached turn, and can then run and stop a new turn.
    def test_bridge_daemon_death_fails_the_turn_and_recovers_on_next_request(self):
        service = f"{arguments.service_name}.death-{uuid.uuid4().hex[:8]}"
        fixture_source = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-hold-interrupt"
        copy_file(fixture_source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": service,
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
        }
        task = self.create_task("Daemon death", provider="codex")
        first_pid = self.assert_success(self.call_cli("status", extra_environment=environment)[0])["processID"]
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        release = Path(str(executable) + ".interrupt-release")
        sent = {}

        def send_turn(key, expected_status):
            sent[key], _ = self.call_cli(
                "conversation", "send", task["id"], "--message", "Hold until the daemon dies.",
                expected_status=expected_status, timeout=45, extra_environment=environment,
            )

        sender = threading.Thread(target=send_turn, args=("first", 69), daemon=True)
        sender.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), "The turn should be running before the daemon dies.")
        self.assertEqual(self.task_for(task["id"], environment)["status"], "In Progress")
        server = next(m["process"] for kind, _, m in self.agent_manifests() if kind == "codex" and m["serviceName"] == service)

        os.kill(first_pid, signal.SIGKILL)
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), "A send must fail promptly when its daemon dies, not hang.")
        self.assert_failure(sent["first"], "service_unavailable")
        self.assertTrue(self.agent_process_alive(server), "The provider outlives the daemon, so its turn keeps running.")

        # The next request starts a fresh daemon, which goes back to the running turn.
        self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        recovered = self.task_for(task["id"], environment)
        self.assertEqual(recovered["status"], "In Progress", "The turn survives the daemon's death.")
        self.assertNotIn("closed while", recovered.get("statusMessage") or "")
        self.assertNotIn("restarting", recovered.get("statusMessage") or "")
        second_pid = self.assert_success(self.call_cli("status", extra_environment=environment)[0])["processID"]
        self.assertNotEqual(second_pid, first_pid)
        self.assertTrue(self.process_is_running(second_pid))
        runtime = self.assert_success(self.call_cli("conversation", "runtime", extra_environment=environment)[0])
        self.assertTrue(runtime["activeThreadIDs"], "The fresh daemon owns the reattached turn.")

        # The fresh daemon stops the reattached turn, then runs and stops a new one.
        stopper = threading.Thread(
            target=lambda: self.call_cli("conversation", "stop", task["id"], timeout=20, extra_environment=environment),
            daemon=True,
        )
        stopper.start()
        deadline = time.monotonic() + 10
        while not received.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(received.is_file(), "Stop reaches the reattached turn.")
        release.write_text("acknowledge interrupt\n", encoding="utf-8")
        stopper.join(timeout=20)
        self.wait_for(lambda: self.task_for(task["id"], environment)["status"] == "Waiting Response",
                      "The stopped reattached turn settles.")
        for marker in (ready, received, release):
            marker.unlink(missing_ok=True)
        rerun = threading.Thread(target=send_turn, args=("second", 1), daemon=True)
        rerun.start()
        deadline = time.monotonic() + 15
        while not ready.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.is_file(), "The fresh daemon should run a new turn.")
        stopper = threading.Thread(
            target=lambda: self.call_cli("conversation", "stop", task["id"], timeout=20, extra_environment=environment),
            daemon=True,
        )
        stopper.start()
        deadline = time.monotonic() + 10
        while not received.is_file() and time.monotonic() < deadline:
            time.sleep(0.02)
        release.write_text("acknowledge interrupt\n", encoding="utf-8")
        stopper.join(timeout=20)
        rerun.join(timeout=20)
        self.assertFalse(rerun.is_alive())
        self.assertEqual(self.task_for(task["id"], environment)["status"], "Waiting Response")
    # case-contract: test_codex_turn_reattaches_after_daemon_restart | A Codex turn keeps running in its shared socket app-server when the daemon is killed: the next daemon reconnects to the same server (no second server, one connection per daemon), keeps the task In Progress with no restart notice, shows the output written before the restart exactly once, saves the question the server re-sends on resume and answers the re-sent approval exactly once, accepts a steered follow-up, streams the rest of the turn to a watcher, and settles it through the normal outcome path. A turn that finished while no daemon was connected settles from the server's state, which the next daemon reads once to record the output it missed, exactly once and without an outcome command its answer echoed. A question the shared server raises on a thread no conversation owns gets no reply from the connected client, which leaves it for its owner instead of rejecting it.
    def test_codex_turn_reattaches_after_daemon_restart(self):
        executable = self.install_provider_fixture("codex", "codex-fixture-reattach")
        environment = self.restart_service_environment("codex", executable, PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS="3")
        task = self.create_task("Codex reattach", provider="codex")
        ready = Path(str(executable) + ".reattach-ready")
        sent = {}
        sender = threading.Thread(target=lambda: sent.setdefault("first", self.call_cli(
            "conversation", "send", task["id"], "--message", "Keep working across a restart.",
            expected_status=69, timeout=60, extra_environment=environment)), daemon=True)
        sender.start()
        self.wait_for(ready.is_file, "The turn should be running before the daemon dies.")
        manifests = [m for kind, _, m in self.agent_manifests() if kind == "codex" and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]]
        self.assertEqual(len(manifests), 1, "One shared app-server serves the private service.")
        server = manifests[0]["process"]
        self.assertTrue(self.agent_process_alive(server))

        self.kill_daemon(environment)
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), "The send fails promptly once its daemon is gone.")
        self.assert_failure(sent["first"][0], "service_unavailable")
        self.assertTrue(self.agent_process_alive(server), "The app-server outlives the daemon that started it.")
        # An approval and a question raised while no daemon is connected wait for the next one.
        Path(str(executable) + ".reattach-raise").touch()
        self.wait_for(Path(str(executable) + ".reattach-raised").is_file, "The fixture should raise its requests.")

        # A watcher's request starts the fresh daemon, which reattaches before answering anything.
        watcher = self.start_cli("conversation", "watch", task["id"], extra_environment=environment)
        recovered = self.wait_for(
            lambda: (lambda record: record if record["status"] == "Waiting Response" else None)(self.task_for(task["id"], environment)),
            "The re-sent question should park the reattached turn on the user.")
        self.assertNotIn("restarting", recovered.get("statusMessage") or "")
        self.assertNotIn("closed while", recovered.get("statusMessage") or "")
        self.assertEqual([m["process"] for kind, _, m in self.agent_manifests() if kind == "codex"
                          and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]], [server],
                         "The fresh daemon reconnects to the same app-server instead of starting another.")
        texts, history = self.history_texts(task["id"], environment)
        self.assertEqual(texts.count("Before restart."), 1, "Output written before the restart appears once.")
        pending = history.get("pendingUserInputRequest")
        self.assertIsNotNone(pending, "The re-sent question is saved for the user.")
        self.assertEqual(pending["questions"][0]["question"], "Which color?")
        answered = self.assert_success(self.call_cli(
            "conversation", "answer-user-input", task["id"], pending["id"], "--answer", "color=blue",
            extra_environment=environment)[0])
        self.assertTrue(answered.get("accepted"), answered)
        self.assertEqual(self.task_for(task["id"], environment)["status"], "In Progress")
        steered = self.assert_success(self.call_cli(
            "conversation", "steer", task["id"], "--message", "Also check the README.", extra_environment=environment)[0])
        self.assertTrue(steered.get("accepted"), steered)
        self.wait_for(lambda: self.jsonl(str(executable) + ".reattach-steers"), "The steer reaches the reattached turn.")
        # The steer also makes the server raise a question on a thread no conversation owns. The
        # connected client leaves it for its owner; rejecting it could fail another client's turn.
        self.wait_for(lambda: any(
            event.get("event") == "codex.user_input.unowned_ignored" and event.get("threadID") == "thread-owned-by-no-conversation"
            for event in self.diagnostic_events()
        ), "The connected client should leave an unowned question unanswered.")
        self.assertFalse([r for r in self.jsonl(str(executable) + ".reattach-replies") if r["id"] == "question-foreign"],
                         "No client should reply to a question it does not own.")
        replies = self.jsonl(str(executable) + ".reattach-replies")
        approval_replies = [r for r in replies if str(r["id"]).startswith("approval-")]
        question_replies = [r for r in replies if str(r["id"]).startswith("question-")]
        self.assertEqual(len(approval_replies), 1, f"The re-sent approval is answered exactly once: {replies}")
        self.assertEqual(approval_replies[0]["result"], {"decision": "decline"})
        self.assertEqual(len(question_replies), 1, f"The question is answered exactly once: {replies}")
        connections = [e for e in self.jsonl(str(executable) + ".socket-log") if e["event"] == "connected"]
        self.assertEqual(len(connections), 2, "Each daemon opens one connection; none is duplicated.")

        Path(str(executable) + ".reattach-release").touch()
        response, events = self.finish_cli(watcher, "conversation watch", timeout=60)
        self.assertTrue(self.assert_success(response)["watched"])
        types = [event["type"] for event in events]
        self.assertIn("completed", types)
        self.assertIn("After restart.", "".join(event["payload"].get("text") or "" for event in events if event["type"] == "text_delta"),
                      "The watcher streams the reattached turn's live text.")
        final = self.task_for(task["id"], environment)
        self.assertEqual(final["status"], "Waiting Response", "The turn's reported outcome settles it.")
        self.assertNotIn("restarting", final.get("statusMessage") or "")
        texts, _ = self.history_texts(task["id"], environment)
        # Consecutive agent messages share one history entry, so count within the joined text.
        joined = "\n".join(texts)
        for text in ("Before restart.", "Answer received: blue.", "After restart."):
            self.assertEqual(joined.count(text), 1, f"{text!r} appears exactly once: {texts}")
        self.assertIn("Also check the README.", texts)

        # A turn that finished while no daemon was connected shows its result on reattach.
        ready.unlink()
        second = threading.Thread(target=lambda: sent.setdefault("second", self.call_cli(
            "conversation", "send", task["id"], "--message", "Finish while Playhouse is down.",
            expected_status=69, timeout=60, extra_environment=environment)), daemon=True)
        second.start()
        self.wait_for(ready.is_file, "The second turn should be running.")
        self.kill_daemon(environment)
        second.join(timeout=20)
        # Its answer also echoes the outcome command, which the backfill records without.
        Path(str(executable) + ".reattach-leak-outcome").touch()
        Path(str(executable) + ".reattach-release").touch()
        # The fixture's outcome report starts a daemon of its own; either way the turn settles.
        settled = self.wait_for(
            lambda: (lambda record: record if record["status"] != "In Progress" else None)(self.task_for(task["id"], environment)),
            "The turn that finished during the restart settles.", timeout=40)
        self.assertEqual(settled["status"], "Waiting Response")
        self.assertNotIn("restarting", settled.get("statusMessage") or "")
        texts, _ = self.history_texts(task["id"], environment)
        joined = "\n".join(texts)
        self.assertEqual(joined.count("After restart."), 2, f"The result written during the restart appears: {texts}")
        self.assertEqual([text for text in texts if "After restart." in text], ["After restart.", "After restart."],
                         "The backfilled answer is recorded without the outcome command it echoed.")

        # Idle, the server stops by itself and leaves no files behind.
        self.wait_for(lambda: not self.agent_process_alive(server), "The idle app-server stops.", timeout=40)
        self.wait_for(lambda: not list((self.data_directory / "codex-runs").glob("*.json")), "Its manifest is removed.")
    # case-contract: test_claude_turn_reattaches_after_daemon_restart | A Claude Code turn with file-backed stdio keeps running when the daemon is killed: the next daemon replays the handled log without repeating its writes, keeps the task In Progress, shows the output written before the restart once, restores the still unanswered question and never answers an answered request again, ignores a late reply to the old daemon's request and numbers its own requests past the old ones, delivers a steered follow-up, streams the rest of the turn to a watcher, records the turn's usage once, settles it through its outcome, and removes the finished run.
    def test_claude_turn_reattaches_after_daemon_restart(self):
        executable = self.install_provider_fixture("claude", "claude-fixture-reattach")
        environment = self.restart_service_environment("claude", executable)
        task = self.create_task("Claude reattach", provider="claude")
        ready = Path(str(executable) + ".reattach-ready")
        sent = {}
        sender = threading.Thread(target=lambda: sent.setdefault("first", self.call_cli(
            "conversation", "send", task["id"], "--message", "Keep working across a restart.",
            expected_status=69, timeout=60, extra_environment=environment)), daemon=True)
        sender.start()
        self.wait_for(ready.is_file, "The turn should be running before the daemon dies.")
        # Answered before the restart: the run's own approval.
        Path(str(executable) + ".reattach-ask").touch()
        self.wait_for(lambda: any(r["id"] == "reattach-approval-1" for r in self.jsonl(str(executable) + ".reattach-replies")),
                      "The approval is answered before the restart.")
        runs = self.claude_runs(environment)
        self.assertEqual(len(runs), 1, "The turn runs with file-backed stdio in its own run folder.")
        run_directory, manifest = runs[0]
        agent = manifest["process"]
        self.assertTrue((run_directory / "agent.in").is_fifo())
        self.wait_for(lambda: json.loads((run_directory / "run.json").read_text())["pendingRequestIDs"] == ["reattach-question-1"],
                      "The unanswered question is recorded in the run.")

        self.kill_daemon(environment)
        sender.join(timeout=20)
        self.assert_failure(sent["first"][0], "service_unavailable")
        self.assertTrue(self.agent_process_alive(agent), "Claude Code outlives the daemon that started it.")
        # A reply to the old daemon's first control request arrives late.
        Path(str(executable) + ".reattach-late-reply").touch()

        watcher = self.start_cli("conversation", "watch", task["id"], extra_environment=environment)
        recovered = self.wait_for(
            lambda: (lambda record: record if record["status"] == "Waiting Response" else None)(self.task_for(task["id"], environment)),
            "The reattached turn waits on its still unanswered question.")
        self.assertNotIn("restarting", recovered.get("statusMessage") or "")
        self.assertEqual([m["process"] for _, m in self.claude_runs(environment)], [agent], "The same run carries on.")
        texts, history = self.history_texts(task["id"], environment)
        self.assertEqual(texts.count("Before restart."), 1, "Output from before the restart appears once.")
        pending = history.get("pendingUserInputRequest")
        self.assertEqual(pending["id"], "reattach-question-1")
        self.assertTrue(self.assert_success(self.call_cli(
            "conversation", "answer-user-input", task["id"], pending["id"], "--answer", "question-1=blue",
            extra_environment=environment)[0]).get("accepted"))
        steered = self.assert_success(self.call_cli(
            "conversation", "steer", task["id"], "--message", "Also check the README.", extra_environment=environment)[0])
        self.assertTrue(steered.get("accepted"), steered)
        self.wait_for(lambda: self.jsonl(str(executable) + ".reattach-steers"), "The steer reaches the running process.")
        Path(str(executable) + ".reattach-release").touch()
        response, events = self.finish_cli(watcher, "conversation watch", timeout=60)
        self.assertTrue(self.assert_success(response)["watched"])
        self.assertIn("completed", [event["type"] for event in events])
        self.assertIn("After restart.", "".join(event["payload"].get("text") or "" for event in events if event["type"] == "text_delta"))

        replies = self.jsonl(str(executable) + ".reattach-replies")
        self.assertEqual([r["id"] for r in replies].count("reattach-approval-1"), 1, f"Answered requests aren't repeated: {replies}")
        self.assertEqual([r["id"] for r in replies].count("reattach-question-1"), 1, replies)
        inputs = [json.loads(line) for line in self.jsonl(str(executable) + ".reattach-stdin") if line.strip()]
        request_numbers = [int(m["request_id"].split("-")[1]) for m in inputs
                           if m.get("type") == "control_request" and str(m.get("request_id", "")).startswith("playhouse-")]
        self.assertEqual(request_numbers[:1], [1], "The first daemon numbered its requests from 1.")
        self.assertTrue(all(number == 1 or number >= 1001 for number in request_numbers), request_numbers)
        final = self.task_for(task["id"], environment)
        self.assertEqual(final["status"], "Waiting Response")
        self.assertNotIn("restarting", final.get("statusMessage") or "")
        texts, history = self.history_texts(task["id"], environment)
        for text in ("Before restart.", "Answer received: blue.", "After restart."):
            self.assertEqual(texts.count(text), 1, f"{text!r} appears exactly once: {texts}")
        self.assertIn("Also check the README.", texts)
        usage = self.assert_success(self.call_cli("task", "token-usage", task["id"], extra_environment=environment)[0])
        self.assertEqual(len([turn for turn in usage.get("turns", []) if turn.get("provider") == "claude"]), 1,
                         "The reattached turn records its usage once.")
        self.wait_for(lambda: not self.agent_process_alive(agent), "The finished run stops.")
        self.wait_for(lambda: not run_directory.exists(), "The finished run's folder is removed.")
    # case-contract: test_agent_finished_while_daemon_was_down_shows_result | A Claude Code turn that writes its result while no daemon is running is finished by the next daemon from the run's log: the task leaves In Progress through the normal outcome path without a restart notice, and the result written during the downtime appears exactly once.
    def test_agent_finished_while_daemon_was_down_shows_result(self):
        executable = self.install_provider_fixture("claude", "claude-fixture-reattach")
        environment = self.restart_service_environment("claude", executable)
        task = self.create_task("Claude finished while down", provider="claude")
        ready = Path(str(executable) + ".reattach-ready")
        sender = threading.Thread(target=lambda: self.call_cli(
            "conversation", "send", task["id"], "--message", "Finish while Playhouse is down.",
            expected_status=69, timeout=60, extra_environment=environment), daemon=True)
        sender.start()
        self.wait_for(ready.is_file, "The turn should be running.")
        run_directory, manifest = self.claude_runs(environment)[0]
        self.kill_daemon(environment)
        sender.join(timeout=20)
        # The turn ends with no daemon reading it: its result waits in the run's log.
        Path(str(executable) + ".reattach-release-quiet").touch()
        self.wait_for(lambda: '"type": "result"' in (run_directory / "agent.out").read_text(), "The result is logged.")
        self.wait_for(
            lambda: self.task_for(task["id"], environment)["status"] == "Waiting Response",
            "The next request's daemon finishes the turn from its logged result.", timeout=40)
        texts, _ = self.history_texts(task["id"], environment)
        self.assertEqual(texts.count("After restart."), 1, "The result written while Playhouse was down is shown once.")
        record = self.task_for(task["id"], environment)
        self.assertNotIn("restarting", record.get("statusMessage") or "")
    # case-contract: test_agent_died_without_result_is_marked_interrupted | When a Codex app-server or a Claude Code run exits without finishing its turn while no daemon is connected, the next daemon settles the task as Waiting Response with 'The agent stopped while Playhouse was restarting. Your conversation is saved; send a follow-up to continue.', keeps the conversation up to the restart, and removes the dead agent's files.
    def test_agent_died_without_result_is_marked_interrupted(self):
        for provider, die_marker in (("codex", ".reattach-die"), ("claude", ".reattach-exit")):
            with self.subTest(provider=provider):
                name = "codex-fixture-reattach" if provider == "codex" else "claude-fixture-reattach"
                executable = self.install_provider_fixture(provider, f"{name}-died")
                environment = self.restart_service_environment(provider, executable)
                task = self.create_task(f"{provider} agent died", provider=provider)
                ready = Path(str(executable) + ".reattach-ready")
                sender = threading.Thread(target=lambda: self.call_cli(
                    "conversation", "send", task["id"], "--message", "Die while Playhouse is down.",
                    expected_status=69, timeout=60, extra_environment=environment), daemon=True)
                sender.start()
                self.wait_for(ready.is_file, f"The {provider} turn should be running.")
                agent = next(m["process"] for kind, _, m in self.agent_manifests()
                             if kind == provider and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"])
                self.kill_daemon(environment)
                sender.join(timeout=20)
                Path(str(executable) + die_marker).touch()
                self.wait_for(lambda: not self.agent_process_alive(agent), f"The {provider} agent exits without a result.")
                settled = self.wait_for(
                    lambda: (lambda record: record if record["status"] != "In Progress" else None)(self.task_for(task["id"], environment)),
                    f"The {provider} turn whose agent died settles.", timeout=40)
                self.assertEqual(settled["status"], "Waiting Response")
                self.assertEqual(settled["statusMessage"],
                                 "The agent stopped while Playhouse was restarting. Your conversation is saved; send a follow-up to continue.")
                self.assertFalse([m for kind, _, m in self.agent_manifests()
                                  if kind == provider and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]],
                                 f"The dead {provider} agent's files are removed.")
                # Reading history comes after: Codex starts a fresh server to read its saved thread.
                texts, _ = self.history_texts(task["id"], environment)
                self.assertIn("Die while Playhouse is down.", texts, "The conversation up to the restart is kept.")
                if provider == "codex":
                    self.assertIn("Before restart.", texts, "Codex keeps the output its thread saved before the agent died.")
    # case-contract: test_standalone_chat_turn_filed_after_daemon_restart | A standalone chat turn that is still running when its daemon dies is followed by the next daemon, and when it ends with close-turn --continues false that daemon files the turn's question and answers on the new titled page the close-turn opened, exactly once, leaving the earlier page as it was and no page decision pending. The page's first session is seeded with that turn, so the next question reaches the provider with the turn's question and answer. Filing reads Playhouse's own close-turn record and turn transcript, shared by Claude and Codex once a reattached turn ends, so one representative provider (Claude) covers this case.
    def test_standalone_chat_turn_filed_after_daemon_restart(self):
        executable, environment, chat_id = self.start_reattach_chat("claude-fixture-reattach-chat-filed")
        self.send_filed_chat_turn(executable, environment, chat_id, "Name a moon of Mars.")
        earlier = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]
        self.assertEqual(self.chat_page_texts(earlier["id"], environment), ["Name a moon of Mars.", "Before restart.", "After restart."],
                         "The daemon that sent the first turn files it.")

        question = "Could the Android build be split into parallel steps?"
        self.start_chat_turn_and_kill_daemon(executable, environment, chat_id, question)
        # The next daemon follows the turn; its agent opens a new page and finishes the answer.
        self.close_held_chat_turn(executable, "Parallel Android build")
        Path(str(executable) + ".reattach-release-quiet").touch()
        self.wait_for(lambda: "After restart." in self.history_texts(chat_id, environment)[0], "The reattached turn finishes.", timeout=40)
        self.wait_for(lambda: self.chat_page_texts(
            self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]["id"], environment)[-1:] == ["After restart."],
            "The daemon that followed the turn files it.")
        status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertEqual(status["activePage"]["title"], "Parallel Android build", "close-turn opened the new page.")
        self.assertFalse(status["missedPreviousPageSignal"], "The reattached turn's close-turn settles its page decision.")
        page = status["activePage"]
        self.assertEqual(self.chat_page_texts(page["id"], environment), [question, "Before restart.", "After restart."],
                         "The reattached turn is filed once on the page its close-turn opened.")
        self.assertEqual(self.chat_page_texts(earlier["id"], environment), ["Name a moon of Mars.", "Before restart.", "After restart."],
                         "The earlier page keeps only its own turn.")
        filed = self.wait_for(lambda: [event for event in self.diagnostic_events()
                                       if event.get("event") == "chat.page.reattached_turn.filed" and event.get("taskID") == chat_id],
                              "The reattached filing is recorded in diagnostics.")
        self.assertEqual([(event["pageID"], event["signal"]) for event in filed], [(page["id"], "close-turn")])

        # The new page's first session is seeded with the turn that opened it.
        seeded = self.send_filed_chat_turn(executable, environment, chat_id, "Which step would be slowest?")
        self.assertIn(question, seeded, "The new page's session carries the reattached turn's question.")
        self.assertIn("After restart.", seeded, "The new page's session carries the reattached turn's answer.")
        self.assertNotIn("Name a moon of Mars.", seeded, "An earlier page never reaches the new page's session.")
        self.assertEqual(self.chat_page_texts(page["id"], environment)[:3], [question, "Before restart.", "After restart."],
                         "A later turn never files the reattached turn again.")
    # case-contract: test_standalone_chat_orphaned_turn_recovered_on_startup | A standalone chat turn that ran close-turn --continues false and then lost both its daemon and its agent before it was filed is filed, question included, by the next daemon on the page that close-turn opened, found from Playhouse's durable close-turn record. An answered turn that an earlier build left unfiled after its close-turn opened a new page, with no close-turn record, is filed by the next daemon as it starts onto the page opened while that turn ran. Both recoveries are recorded in diagnostics, a further daemon restart files nothing again, and the next question's fresh page session is seeded with the recovered turn. Recovery reads only Playhouse's own transcript, close-turn record and page store, so provider selection cannot change it; one representative provider (Claude) covers this case.
    def test_standalone_chat_orphaned_turn_recovered_on_startup(self):
        executable, environment, chat_id = self.start_reattach_chat("claude-fixture-reattach-chat-orphan")
        self.send_filed_chat_turn(executable, environment, chat_id, "Name a moon of Mars.")
        earlier = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]
        earlier_texts = ["Name a moon of Mars.", "Before restart.", "After restart."]

        def recoveries(reason):
            return [(event["pageID"], event["source"]) for event in self.diagnostic_events()
                    if event.get("event") == "chat.page.turn_recovered" and event.get("taskID") == chat_id and event.get("reason") == reason]

        # The turn opens a new page with close-turn; then its daemon dies, and its agent too.
        question = "Could the iOS build run its tests in parallel?"
        agent = self.start_chat_turn_and_kill_daemon(executable, environment, chat_id, question, close_turn_title="Parallel iOS tests")
        Path(str(executable) + ".reattach-exit").touch()
        self.wait_for(lambda: not self.agent_process_alive(agent), "The chat turn's agent exits without a result.")
        lost_page = self.wait_for(
            lambda: next((page for page in self.chat_pages(environment) if page["title"] == "Parallel iOS tests"), None),
            "The close-turn page should be visible after the agent exits.",
        )
        self.wait_for(lambda: self.chat_page_texts(lost_page["id"], environment) == [question],
                      "The next daemon files the lost turn's question on the page its close-turn opened.")
        self.assertEqual(self.wait_for(lambda: recoveries("reattach-lost"), "The lost turn's filing is recorded."),
                         [(lost_page["id"], "close-turn")])

        # An answered turn an earlier build left unfiled, as in the incident: its close-turn opened
        # a page, but no page holds the turn and no close-turn record names it.
        legacy_question = "Could the Android build be split into parallel steps?"
        self.send_filed_chat_turn(executable, environment, chat_id, legacy_question, new_title="Parallel Android build")
        legacy_page = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]
        self.assertEqual(legacy_page["title"], "Parallel Android build")
        legacy_texts = [legacy_question, "Before restart.", "After restart."]
        self.assertEqual(self.chat_page_texts(legacy_page["id"], environment), legacy_texts)
        self.kill_daemon(environment)
        with sqlite3.connect(self.data_directory / "StandaloneChat-v1.sqlite") as store:
            store.execute("DELETE FROM chat_messages WHERE page_id = ?", (legacy_page["id"],))
            store.execute("UPDATE chat_pages SET message_count = 0 WHERE id = ?", (legacy_page["id"],))
            store.execute("DELETE FROM chat_turn_signals WHERE page_id = ?", (legacy_page["id"],))
        self.assertEqual(self.chat_page_texts(legacy_page["id"], environment), legacy_texts,
                         "The starting daemon files the unfiled turn on the page opened while it ran.")
        self.assertEqual(self.wait_for(lambda: recoveries("startup"), "The startup recovery is recorded."),
                         [(legacy_page["id"], "page-opened-in-turn")])
        self.assertEqual(self.chat_page_texts(earlier["id"], environment), earlier_texts, "The earlier page keeps only its own turn.")
        self.assertEqual(self.chat_page_texts(lost_page["id"], environment), [question])

        # Another restart recovers nothing more.
        self.kill_daemon(environment)
        self.assertEqual(self.chat_page_texts(legacy_page["id"], environment), legacy_texts,
                         "A later daemon never files the recovered turn twice.")
        time.sleep(1)
        self.assertEqual(len(recoveries("startup")) + len(recoveries("reattach-lost")), 2, "Recovery is idempotent across restarts.")

        seeded = self.send_filed_chat_turn(executable, environment, chat_id, "Which step would be slowest?")
        self.assertIn(legacy_question, seeded, "The recovered turn seeds its page's first session.")
        self.assertIn("After restart.", seeded)
        self.assertNotIn(question, seeded, "Another page's turn never reaches this page's session.")
        self.assertEqual(self.chat_page_texts(legacy_page["id"], environment)[:3], legacy_texts)
    # case-contract: test_standalone_chat_codex_turns_survive_daemon_restart | A Codex standalone chat turn survives daemon restarts, each of its agent messages stored on its own as the turn streamed it. A turn still running in its shared app-server when its daemon dies is followed by the next daemon, and when it ends with close-turn --continues false that daemon files its question and answers once on the new titled page, found from the turn's durable in-flight record and close-turn record, with no page decision left pending. A turn whose daemon and app-server both die after its close-turn opened a new page is filed on that page, with what its stored transcript holds, by the next daemon as it starts, before the next send seeds; that send's fresh page session carries the recovered turn, and the recovery is recorded in diagnostics.
    def test_standalone_chat_codex_turns_survive_daemon_restart(self):
        executable, environment, chat_id = self.start_reattach_chat("codex-fixture-reattach-chat", provider="codex")
        self.send_filed_chat_turn(executable, environment, chat_id, "Name a moon of Mars.")
        earlier = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]
        # Each agent message is stored on its own, as the turn streamed it.
        answer = ["Before restart.", "After restart."]
        earlier_texts = ["Name a moon of Mars.", *answer]
        self.assertEqual(self.chat_page_texts(earlier["id"], environment), earlier_texts, "The daemon that sent the first turn files it.")

        # The next daemon follows the running turn, whose agent opens a new page and finishes.
        question = "Could the Android build be split into parallel steps?"
        self.start_chat_turn_and_kill_daemon(executable, environment, chat_id, question)
        self.close_held_chat_turn(executable, "Parallel Android build")
        Path(str(executable) + ".reattach-release-quiet").touch()
        self.wait_for(lambda: self.chat_page_texts(
            self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]["id"], environment)
            == [question, *answer],
            "The daemon that followed the Codex turn files it once on the page its close-turn opened.", timeout=40)
        status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertEqual(status["activePage"]["title"], "Parallel Android build")
        self.assertFalse(status["missedPreviousPageSignal"], "The reattached turn's close-turn settles its page decision.")
        self.assertEqual(self.chat_page_texts(earlier["id"], environment), earlier_texts, "The earlier page keeps only its own turn.")
        filed = self.wait_for(lambda: [event for event in self.diagnostic_events()
                                       if event.get("event") == "chat.page.reattached_turn.filed" and event.get("taskID") == chat_id],
                              "The reattached filing is recorded in diagnostics.")
        self.assertEqual([(event["pageID"], event["signal"]) for event in filed], [(status["activePage"]["id"], "close-turn")])

        # A turn opens a new page with close-turn; then its daemon dies, and its app-server too.
        lost_question = "Could the iOS build run its tests in parallel?"
        server = self.start_chat_turn_and_kill_daemon(executable, environment, chat_id, lost_question, close_turn_title="Parallel iOS tests")
        Path(str(executable) + ".reattach-die").touch()
        self.wait_for(lambda: not self.agent_process_alive(server), "The Codex app-server exits with the turn unfinished.")
        lost_page = self.wait_for(
            lambda: next((page for page in self.chat_pages(environment) if page["title"] == "Parallel iOS tests"), None),
            "The close-turn page should be visible after the app-server exits.",
        )
        # The next daemon files the lost turn from its stored transcript as it starts, before the
        # next send seeds its page's session.
        seeded = self.send_filed_chat_turn(executable, environment, chat_id, "Which suite is slowest?")
        self.assertEqual(self.chat_page_texts(lost_page["id"], environment)[:2], [lost_question, "Before restart."],
                         "The lost Codex turn is filed on the page its close-turn opened.")
        self.assertIn(lost_question, seeded, "The recovered turn seeds its page's first session.")
        self.assertIn("Before restart.", seeded)
        self.assertNotIn(question, seeded, "Another page's turn never reaches this page's session.")
        recovered = [(event["pageID"], event["source"], event["reason"]) for event in self.diagnostic_events()
                     if event.get("event") == "chat.page.turn_recovered" and event.get("taskID") == chat_id]
        self.assertEqual(recovered, [(lost_page["id"], "close-turn", "startup")], "The daemon's startup recovery is recorded once.")
    # case-contract: test_standalone_chat_reattached_turn_without_close_turn_uses_fallback | A standalone chat turn that is still running when its daemon dies and then ends without close-turn is filed by the daemon that followed it on the active page, marked as a missed page signal, and handed to the background page classifier, which moves it to the new page it titles; the earlier page keeps only its own turn and nothing stays pending. When the daemon instead dies during the close-turn nudge that follows a turn without close-turn, the daemon that follows the nudge files the user's turn, never the nudge, hands it to the classifier the same way, and the chat keeps accepting sends. The missed-signal and classifier path is shared by Claude and Codex once a reattached turn ends, so one representative provider (Claude) covers this case.
    def test_standalone_chat_reattached_turn_without_close_turn_uses_fallback(self):
        executable, environment, chat_id = self.start_reattach_chat("claude-fixture-reattach-chat-fallback")
        self.send_filed_chat_turn(executable, environment, chat_id, "Name a moon of Mars.")
        earlier = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]

        question = "How do I rotate a signing key?"
        self.start_chat_turn_and_kill_daemon(executable, environment, chat_id, question)
        # The next daemon follows the turn, which ends with no close-turn.
        self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        Path(str(executable) + ".reattach-release-quiet").touch()

        status = self.wait_for(lambda: (lambda value: value if value["activePage"]["title"] == "Restart fallback"
                                        and not value["missedPreviousPageSignal"] else None)(
            self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])),
            "The background classifier decides the reattached turn's page.", timeout=40)
        self.assertEqual(self.chat_page_texts(status["activePage"]["id"], environment), [question, "Before restart.", "After restart."],
                         "The classifier moves the reattached turn to its new page.")
        self.assertEqual(self.chat_page_texts(earlier["id"], environment), ["Name a moon of Mars.", "Before restart.", "After restart."])
        events = self.diagnostic_events()
        filed = [event for event in events if event.get("event") == "chat.page.reattached_turn.filed" and event.get("taskID") == chat_id]
        self.assertEqual([event["signal"] for event in filed], ["missed"], "No close-turn ran, so the filing marks a missed signal.")
        self.assertTrue(any(event.get("event") == "chat.page.fallback.scheduled" and event.get("taskID") == chat_id for event in events),
                        "The missed signal schedules the background classifier.")

        # The next turn skips close-turn in a live daemon, which then dies during the nudge.
        first_fallback = status["activePage"]
        nudged_question = "Which key size should I use?"
        ready = Path(str(executable) + ".reattach-ready")
        ready.unlink(missing_ok=True)
        Path(str(executable) + ".reattach-hold-nudge").touch()
        sent = {}
        sender = threading.Thread(target=lambda: sent.setdefault("turn", self.call_cli(
            "conversation", "send", chat_id, "--message", nudged_question,
            expected_status=69, timeout=60, extra_environment=environment)), daemon=True)
        sender.start()
        self.wait_for(ready.is_file, "The chat turn runs.")
        ready.unlink()
        Path(str(executable) + ".reattach-release-quiet").touch()
        self.wait_for(lambda: ready.is_file() and "outcome nudge" in ready.read_text(encoding="utf-8").lower(),
                      "The turn without close-turn gets its nudge, which holds.")
        self.kill_daemon(environment)
        sender.join(timeout=20)
        self.assert_failure(sent["turn"][0], "service_unavailable")
        self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        Path(str(executable) + ".reattach-release-quiet").touch()
        nudged = self.wait_for(lambda: (lambda value: value if value["activePage"]["id"] != first_fallback["id"]
                                        and value["activePage"]["title"] == "Restart fallback"
                                        and not value["missedPreviousPageSignal"] else None)(
            self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])),
            "The classifier decides the page of the user's turn behind the followed nudge.", timeout=40)
        self.assertEqual(self.chat_page_texts(nudged["activePage"]["id"], environment),
                         [nudged_question, "Before restart.", "After restart."],
                         "The user's turn is filed, never the nudge or its reply.")
        filed = [event["signal"] for event in self.diagnostic_events()
                 if event.get("event") == "chat.page.reattached_turn.filed" and event.get("taskID") == chat_id]
        self.assertEqual(filed, ["missed", "missed"])
        self.send_filed_chat_turn(executable, environment, chat_id, "Thanks, that settles it.")
        self.assertEqual(self.chat_page_texts(nudged["activePage"]["id"], environment)[-3:],
                         ["Thanks, that settles it.", "Before restart.", "After restart."],
                         "The chat keeps accepting sends.")
    # case-contract: test_stop_kills_reattached_agent | Stop works on a turn a fresh daemon reattached: for Codex it sends turn/interrupt over the reconnected socket and leaves the shared server running; for Claude it sends the interrupt with a request number past the old daemon's and then kills the run by its verified process identity and removes its folder. Either way the task settles in Waiting Response without a restart notice.
    def test_stop_kills_reattached_agent(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                name = "codex-fixture-reattach" if provider == "codex" else "claude-fixture-reattach"
                executable = self.install_provider_fixture(provider, f"{name}-stop")
                environment = self.restart_service_environment(provider, executable)
                task = self.create_task(f"{provider} reattached stop", provider=provider)
                ready = Path(str(executable) + ".reattach-ready")
                sender = threading.Thread(target=lambda: self.call_cli(
                    "conversation", "send", task["id"], "--message", "Run until stopped.",
                    expected_status=69, timeout=60, extra_environment=environment), daemon=True)
                sender.start()
                self.wait_for(ready.is_file, f"The {provider} turn should be running.")
                manifest_path, manifest = next((path, m) for kind, path, m in self.agent_manifests()
                                               if kind == provider and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"])
                agent = manifest["process"]
                self.kill_daemon(environment)
                sender.join(timeout=20)
                self.assertEqual(self.task_for(task["id"], environment)["status"], "In Progress",
                                 f"The fresh daemon reattaches the running {provider} turn.")
                stopped = self.assert_success(self.call_cli("conversation", "stop", task["id"], extra_environment=environment)[0])
                self.assertTrue(stopped.get("interrupted", stopped.get("accepted", True)), stopped)
                self.wait_for(Path(str(executable) + ".reattach-interrupted").is_file,
                              f"Stop reaches the reattached {provider} agent.")
                settled = self.wait_for(
                    lambda: (lambda record: record if record["status"] != "In Progress" else None)(self.task_for(task["id"], environment)),
                    f"The stopped {provider} turn settles.")
                self.assertEqual(settled["status"], "Waiting Response")
                self.assertNotIn("restarting", settled.get("statusMessage") or "")
                if provider == "codex":
                    # Codex stops the turn, not the shared server.
                    self.assertTrue(self.agent_process_alive(agent), "The shared app-server keeps running after Stop.")
                else:
                    self.assertTrue(int(Path(str(executable) + ".reattach-interrupted").read_text().split("-")[1]) >= 1001,
                                    "The reattached runner numbers its requests past the old daemon's.")
                    self.wait_for(lambda: not self.agent_process_alive(agent), "The stopped Claude run is killed by its verified pid.")
                    self.wait_for(lambda: not manifest_path.parent.exists(), "The stopped run's folder is removed.")
    # case-contract: test_turn_events_stream_to_a_watcher_that_did_not_send | `conversation watch` (conversation.events.subscribe) on a task with no running turn returns at once with watched=false, and fails for an unknown task. While a turn another caller sent is running, a watcher receives a `watching` event, the turn's live text deltas and its final `completed` history, while the sender still gets its own stream; the window streams such a turn the same way.
    def test_turn_events_stream_to_a_watcher_that_did_not_send(self):
        executable = self.install_provider_fixture("claude", "claude-fixture-reattach-watch")
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        task = self.create_task("Watched turn", provider="claude")
        idle, idle_events = self.call_cli("conversation", "watch", task["id"], extra_environment=environment)
        self.assertEqual(self.assert_success(idle), {"watched": False}, "A watch on a task with no turn ends at once.")
        self.assertEqual(idle_events, [])
        missing, _ = self.call_cli("conversation", "watch", str(uuid.uuid4()).upper(), expected_status=3, extra_environment=environment)
        self.assertEqual(missing["error"]["code"], "not_found")
        ready = Path(str(executable) + ".reattach-ready")
        sender = self.start_cli("conversation", "send", task["id"], "--message", "Stream to a watcher.", extra_environment=environment)
        self.wait_for(ready.is_file, "The sent turn should be running.")
        watcher = self.start_cli("conversation", "watch", task["id"], extra_environment=environment)
        self.wait_for(lambda: self.assert_success(self.call_cli("conversation", "runtime", extra_environment=environment)[0])["activeThreadIDs"],
                      "The turn is active.")
        time.sleep(0.5)
        Path(str(executable) + ".reattach-release").touch()
        sent, sent_events = self.finish_cli(sender, "conversation send", timeout=60)
        self.assert_success(sent)
        watched, events = self.finish_cli(watcher, "conversation watch", timeout=60)
        self.assertEqual(self.assert_success(watched), {"watched": True})
        self.assertEqual(events[0]["type"], "watching")
        streamed = "".join(event["payload"].get("text") or "" for event in events if event["type"] == "text_delta")
        self.assertIn("After restart.", streamed, "The watcher streams the text of a turn it didn't send.")
        self.assertEqual(events[-1]["type"], "completed")
        self.assertIn("After restart.", [m["text"] for m in events[-1]["payload"]["history"]["messages"]])
        sender_text = "".join(event["payload"].get("text") or "" for event in sent_events if event["type"] == "text_delta")
        self.assertIn("After restart.", sender_text, "The sender still gets its own stream.")
    # case-contract: test_untracked_agent_process_is_stopped_on_startup | On a daemon's first request for a data folder, a process whose standard streams point into the folder's Claude or Codex run directories but that no run or server manifest accounts for is stopped, while a process writing into a run or server whose spawn is still being recorded is left alone.
    def test_untracked_agent_process_is_stopped_on_startup(self):
        runs = self.data_directory / "provider-runs"
        codex_runs = self.data_directory / "codex-runs"
        (runs / "stray").mkdir(parents=True)
        (runs / "young").mkdir()
        codex_runs.mkdir()
        service = f"{arguments.service_name}.sweep-{uuid.uuid4().hex[:8]}"
        environment = {"PLAYHOUSE_BRIDGE_SERVICE_NAME": service}
        sleeper = Path(self.data_directory / "agent-sleeper")
        sleeper.write_text("#!/bin/sh\nexec sleep 60\n", encoding="utf-8")
        sleeper.chmod(0o755)
        outputs = {
            "stray": runs / "stray" / "agent.out", "young": runs / "young" / "agent.out",
            "codex-stray": codex_runs / "stray.log", "codex-young": codex_runs / "young.log",
        }
        handles = {name: open(path, "ab") for name, path in outputs.items()}
        processes = {name: subprocess.Popen([str(sleeper)], stdout=handle, stderr=subprocess.DEVNULL, start_new_session=True)
                     for name, handle in handles.items()}
        try:
            # A spawn its daemon is still recording: a manifest with no identity yet.
            (runs / "young" / "run.json").write_text(json.dumps({
                "version": 1, "serviceName": service, "sessionID": "young",
                "state": "spawning", "createdAt": time.time() - 978307200, "mode": "default",
                "consumedOffset": 0, "maxRequestID": 0, "pendingRequestIDs": [], "answeredRequestIDs": [],
                "writeInProgress": False}), encoding="utf-8")
            # The same for a Codex server: its log is named by the manifest's key hash.
            (codex_runs / "young.json").write_text(json.dumps({
                "version": 1, "serviceName": service, "keyHash": "young", "keyParts": [], "state": "spawning",
                "createdAt": time.time() - 978307200, "socketPath": str(codex_runs / "young.sock"),
                "resolvedExecutablePath": "/usr/bin/true", "flags": [], "threads": {}}), encoding="utf-8")
            self.assert_success(self.call_cli("task", "list", extra_environment=environment)[0])
            for name in ("stray", "codex-stray"):
                self.wait_for(lambda name=name: processes[name].poll() is not None, f"The {name} process no manifest accounts for is stopped.")
            time.sleep(0.5)
            for name in ("young", "codex-young"):
                self.assertIsNone(processes[name].poll(), f"A {name} spawn still being recorded is left alone.")
        finally:
            for process in processes.values():
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)
            for handle in handles.values():
                handle.close()
    # case-contract: test_codex_stop_rejection_restores_active_task | If Codex rejects turn/interrupt while its turn is still active, Stop reports the provider failure and the task returns to In Progress; in the window Continue replaces Stop at once and gives way to Stop again when the provider refuses; releasing the fixture lets the original turn complete normally into Waiting Response.
    def test_codex_stop_rejection_restores_active_task(self):
        self.assert_rejected_stop_restores_active_status("codex", "PLAYHOUSE_E2E_CODEX_EXECUTABLE", "codex-app-server-fixture.py")
    # case-contract: test_claude_stop_rejection_restores_active_task | If Claude rejects its session control interrupt while its turn is still active, Stop reports the provider failure and the task returns to In Progress; in the window Continue replaces Stop at once and gives way to Stop again when the provider refuses; releasing the fixture lets the original turn complete normally into Waiting Response.
    def test_claude_stop_rejection_restores_active_task(self):
        self.assert_rejected_stop_restores_active_status("claude", "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE", "claude-code-fixture.py")
    # case-contract: test_standalone_chat_legacy_hidden_task_migrates | A standalone chat left in the store as a hidden board task is converted once into its own model: it keeps its ID so the existing conversation transcript stays attached, keeps its provider session, carries its in-flight turn state across with the status message and progress report that explain it, is removed from the board so it never lists or resolves as a task, and reopening the chat returns that same migrated chat rather than creating a second one.
    def test_standalone_chat_legacy_hidden_task_migrates(self):
        # The seeded row is a real hidden board task, exactly as the old design stored it.
        # Reading the board is itself a migration trigger, so the first read already asserts
        # the converted state rather than the pre-migration one.
        legacy_id = self.seed_legacy_standalone_chat_task(session_id="legacy-chat-session")

        opened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(
            opened["id"], legacy_id,
            "The migrated chat must keep its ID so its existing transcript stays attached.",
        )
        self.assertEqual(opened["claudeSessionID"], "legacy-chat-session", "The chat's provider session must survive migration.")
        # The turn state must arrive with its explanation, not just the raw status.
        self.assertEqual(opened["status"], "In Progress")
        self.assertEqual(opened["statusMessage"], "Carried from the legacy chat task.")
        self.assertEqual(opened["progressType"], "searching")
        self.assertEqual(opened["progressLabel"], "Searching")
        self.assertEqual(opened["progressDetail"], "Looking into volcanoes")
        self.assertEqual(opened["repositoryWorktrees"], [])

        self.assertEqual(
            self.assert_success(self.call_cli("task", "list")[0])["tasks"], [],
            "The migrated chat must no longer be a board task.",
        )
        response, _ = self.call_cli("task", "get", legacy_id, expected_status=3)
        self.assert_failure(response, "not_found")

        reopened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(reopened["id"], legacy_id, "Migration must run once, not create a second chat.")

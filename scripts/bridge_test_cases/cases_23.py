from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases23:
    # case-contract: test_codex_stop_during_turn_launch_stops_before_agent_starts | A Stop that arrives while Codex is still starting the thread moves the task out of In Progress at once, before Codex answers. Nothing of the message is sent: the send ends with turn_stopped, no turn starts, the prompt returns to the draft with no failure reason, and the task returns to the status it had before the send. A steer sent for that message before the Stop is stopped with it: it ends with turn_stopped, is not queued and never runs as a turn of its own. A follow-up queued during that launch stays in the queue, marked as needing the user's action, and does not run. A Stop that arrives after turn/start was sent but before Codex acknowledged the turn also leaves In Progress at once, and Codex's turn/interrupt follows as soon as the turn has its ID, leaving the task in Waiting Response. In the window Stop is enabled as soon as the message is sent, and clicking it replaces Stop at once while the provider is still held; the stopped steer's bubble leaves the transcript and its text returns to the composer with the stopped message, without an error.
    def test_codex_stop_during_turn_launch_stops_before_agent_starts(self):
        task = self.create_task("Codex stop during launch", provider="codex")
        executable = self.install_provider_fixture("codex", "codex-fixture-launch-hold-interrupt")
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        prior_status = self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"]
        prompt = "Hold until stopped."

        # Stopped while the thread is starting: nothing was sent yet.
        self.launch_marker(executable, "thread-start-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", prompt, expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "thread-start-ready").is_file, "Codex should be held while starting the thread.")
        steer_text = "Steer the message that is about to be stopped."
        steer = self.start_background_cli("conversation", "steer", task["id"], "--message", steer_text, expected_status=1, environment=environment)
        follow_up_text = "Run this follow-up after the stopped message."
        follow_up = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", follow_up_text)[0])
        time.sleep(0.5)
        self.assertTrue(steer["thread"].is_alive(), "A steer sent during the launch waits for the turn.")
        stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(
            lambda: self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"] != "In Progress",
            "Stop should move the task out of In Progress while Codex is still starting.", timeout=5,
        )
        self.launch_marker(executable, "thread-start-pause").unlink()
        self.launch_marker(executable, "thread-start-release").write_text("release\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(stop))["interrupted"], "Stopping a launching turn counts as an interruption.")
        self.assertEqual(self.finish_background_cli(send)["error"]["code"], "turn_stopped")
        self.assertEqual(self.finish_background_cli(steer)["error"]["code"], "turn_stopped", "A steer for a stopped message is stopped with it.")
        kept = self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0])
        self.assertEqual(
            [(item["id"], item["text"], item["state"]) for item in kept], [(follow_up["id"], follow_up_text, "needsAction")],
            "The stopped steer must not be queued, and the queued follow-up waits for the user instead of running.",
        )
        self.assert_success(self.call_cli("conversation", "queue-remove", task["id"], follow_up["id"])[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0]), [])
        returned = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(returned["status"], prior_status, "A message stopped before it was sent leaves the task where it was.")
        self.assertTrue(returned["hasUnsentDraft"], "The stopped message returns to the draft.")
        self.assertTrue(returned["savedPrompt"].startswith(prompt), "The draft should hold the stopped message again.")
        self.assertIsNone(returned.get("pendingSubmittedPrompt"))
        self.assertIsNone(returned.get("statusMessage"), "A user's stop leaves no failure reason.")
        self.assertFalse(self.launch_marker(executable, "interrupt-ready").exists(), "No Codex turn may start for a message stopped before it was sent.")

        # Stopped after turn/start was sent, before Codex acknowledged the turn.
        self.launch_marker(executable, "turn-start-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", prompt, expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "turn-start-ready").is_file, "Codex should hold its turn/start answer.")
        stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(
            lambda: self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"] == "Waiting Response",
            "Stop should move the task to Waiting Response before Codex acknowledges the turn.", timeout=5,
        )
        self.assertFalse(self.launch_marker(executable, "interrupt-received").exists(), "Codex cannot be interrupted before the turn has an ID.")
        self.launch_marker(executable, "turn-start-release").write_text("release\n", encoding="utf-8")
        self.wait_for(self.launch_marker(executable, "interrupt-received").is_file, "The interrupt should follow as soon as the turn has its ID.")
        self.launch_marker(executable, "interrupt-release").write_text("acknowledge interrupt\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(stop))["interrupted"])
        self.finish_background_cli(send)
        stopped = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopped["status"], "Waiting Response")
        self.assertIsNone(stopped.get("statusMessage"))

    # case-contract: test_claude_stop_during_turn_launch_interrupts_once_started | A Stop that arrives while Claude Code is still starting the session moves the task to Waiting Response at once, before the session answers. The control interrupt follows as soon as the turn has started, the send settles as stopped without a failure reason, and the task stays in Waiting Response. In the window Stop is enabled as soon as the message is sent, and clicking it replaces Stop with Continue at once while the session is still starting.
    def test_claude_stop_during_turn_launch_interrupts_once_started(self):
        task = self.create_task("Claude stop during launch", provider="claude")
        executable = self.install_provider_fixture("claude", "claude-fixture-launch-stop")
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        self.launch_marker(executable, "launch-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", "Hold until stopped.", expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "launch-ready").is_file, "Claude Code should be held while starting the session.")
        stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(
            lambda: self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"] == "Waiting Response",
            "Stop should move the task to Waiting Response while Claude Code is still starting.", timeout=5,
        )
        self.assertFalse(self.launch_marker(executable, "interrupt-received").exists(), "A session that has not started cannot be interrupted yet.")
        self.launch_marker(executable, "launch-release").write_text("release\n", encoding="utf-8")
        self.wait_for(self.launch_marker(executable, "interrupt-received").is_file, "The interrupt should follow as soon as the turn has started.")
        self.launch_marker(executable, "interrupt-release").write_text("acknowledge interrupt\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(stop))["interrupted"])
        self.finish_background_cli(send)
        stopped = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopped["status"], "Waiting Response")
        self.assertIsNone(stopped.get("statusMessage"), "A user's stop leaves no failure reason.")

    # case-contract: test_codex_steer_during_turn_launch_reaches_started_turn | A steer sent while Codex is still starting the thread waits for the turn instead of missing it: once the turn has its ID the steer reaches that turn through turn/steer and is not queued for a turn of its own. A follow-up can be queued during the same launch, before Codex has named the conversation; steered, it reaches that turn the same way and leaves the queue. One left in the queue runs once as a turn of its own after that turn ends. In the window the steer's bubble joins the transcript and the composer clears at once, a follow-up typed with Return joins the queue at once without an error, and its row gives way to its bubble at once when steered, while Codex is still held and has not received either.
    def test_codex_steer_during_turn_launch_reaches_started_turn(self):
        task = self.create_repo_task("Codex steer during launch", [self.primary])
        executable = self.install_provider_fixture("codex", "codex-fixture-launch-steer-serial-success-wait")
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        steer_text = "Steer the turn that is still starting."
        self.launch_marker(executable, "thread-start-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", "Start a turn slowly.", environment=environment)
        self.wait_for(self.launch_marker(executable, "thread-start-ready").is_file, "Codex should be held while starting the thread.")
        steer = self.start_background_cli("conversation", "steer", task["id"], "--message", steer_text, environment=environment)
        row_text = "Steer this queued follow-up into the starting turn."
        row = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", row_text)[0])
        row_steer = self.start_background_cli("conversation", "queue-steer", task["id"], row["id"], environment=environment)
        later_text = "Run this follow-up after the starting turn."
        later = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", later_text)[0])
        time.sleep(0.5)
        self.assertTrue(steer["thread"].is_alive(), "A steer sent during the launch waits for the turn instead of missing it.")
        self.assertTrue(row_steer["thread"].is_alive(), "A queued follow-up steered during the launch waits for the turn too.")
        self.assertFalse(self.launch_marker(executable, "resolve-ready").exists(), "Codex has not started the turn, so it cannot have either steer yet.")
        self.launch_marker(executable, "thread-start-release").write_text("release\n", encoding="utf-8")
        steered = self.assert_success(self.finish_background_cli(steer))
        self.assertTrue(steered["accepted"])
        self.assertFalse(steered["queued"], "The steer should reach the launching turn, not a turn of its own.")
        row_steered = self.assert_success(self.finish_background_cli(row_steer))
        self.assertTrue(row_steered["accepted"])
        self.assertFalse(row_steered["queued"], "The steered follow-up should reach the launching turn, not a turn of its own.")
        self.assertEqual(
            [item["id"] for item in self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0])], [later["id"]],
            "Only the follow-up that was not steered stays queued.",
        )
        self.wait_for(self.launch_marker(executable, "resolve-ready").is_file, "The steered turn should be active.")
        self.launch_marker(executable, "resolve-continue").write_text("Release the active turn.\n", encoding="utf-8")
        self.assert_success(self.finish_background_cli(send))
        protocol_history = json.loads(self.launch_marker(executable, "history").read_text(encoding="utf-8"))
        self.assertCountEqual(
            [request["input"] for request in protocol_history["steerRequests"]],
            [[{"type": "text", "text": steer_text}], [{"type": "text", "text": row_text}]],
            "Codex should have received both steers through turn/steer.",
        )
        for request in protocol_history["steerRequests"]:
            self.assertEqual(request["expectedTurnId"], protocol_history["messages"][0]["turnID"])
        turn_prompts = [turn["userMessage"] for turn in protocol_history["messages"]]
        self.assertNotIn(steer_text, turn_prompts, "The steer must not have started a turn of its own.")
        self.assertNotIn(row_text, turn_prompts, "The steered follow-up must not have started a turn of its own.")
        self.assertEqual(turn_prompts.count(later_text), 1, "The follow-up left in the queue runs once as a turn of its own.")
        self.assertEqual(turn_prompts.index(later_text), 1, "It runs right after the turn that was starting.")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0]), [], "A delivered follow-up leaves the queue.")

    # case-contract: test_codex_stop_reaches_message_waiting_behind_stopping_turn | A message sent while the task's earlier turn is still being stopped waits for that turn, and a Stop that arrives while it waits stops it too. That Stop answers at once without asking Codex to interrupt a second time; once the earlier turn is over the waiting send ends with turn_stopped, no second turn starts, and the task stays in Waiting Response with no failure reason. In the window Continue replaces Stop at once, the stopped Continue's message leaves the transcript without an error, and Continue stays available for the turn that was stopped first. The stopped message is saved neither as a draft nor as a prompt still being sent.
    def test_codex_stop_reaches_message_waiting_behind_stopping_turn(self):
        task = self.create_task("Codex stop while a message waits", provider="codex")
        executable = self.install_provider_fixture("codex", "codex-fixture-waiting-hold-interrupt")
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}

        def events(name):
            return [event for event in self.diagnostic_events()
                    if event.get("event") == name and str(event.get("taskID", "")).lower() == task["id"].lower()]

        first = self.start_background_cli("conversation", "send", task["id"], "--message", "Hold until stopped.", expected_status=1, environment=environment)
        self.wait_for(self.launch_marker(executable, "interrupt-ready").is_file, "The first turn should be running.")
        first_stop = self.start_background_cli("conversation", "stop", task["id"], environment=environment)
        self.wait_for(self.launch_marker(executable, "interrupt-received").is_file, "Codex should hold its answer to the first Stop.")
        waiting_text = "Continue with the same request from where you left off."
        waiting = self.start_background_cli(
            "conversation", "send", task["id"], "--message", waiting_text,
            expected_status=1, environment=environment,
        )
        self.wait_for(lambda: len(events("conversation.send.accepted")) == 2, "The second message should be accepted while the first turn is still being stopped.")
        started = time.monotonic()
        second_stop = self.assert_success(self.call_cli("conversation", "stop", task["id"], timeout=10, extra_environment=environment)[0])
        self.assertTrue(second_stop["interrupted"], "Stopping a message that waits for its turn counts as an interruption.")
        self.assertLess(time.monotonic() - started, 5, "The Stop answers without waiting for the turn that is still being stopped.")
        self.assertTrue(first_stop["thread"].is_alive(), "Codex still holds its answer to the first Stop.")
        self.assertTrue(waiting["thread"].is_alive(), "The stopped message still waits for the earlier turn to end.")
        self.assertEqual(
            self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Waiting Response",
            "The task leaves In Progress as soon as the waiting message is stopped.",
        )
        self.launch_marker(executable, "interrupt-release").write_text("acknowledge interrupt\n", encoding="utf-8")
        self.assertTrue(self.assert_success(self.finish_background_cli(first_stop))["interrupted"])
        self.finish_background_cli(first)
        self.assertEqual(self.finish_background_cli(waiting)["error"]["code"], "turn_stopped")
        stopped = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stopped["status"], "Waiting Response")
        self.assertIsNone(stopped.get("statusMessage"), "A user's stop leaves no failure reason.")
        self.assertEqual(
            (stopped.get("savedPrompt"), stopped["hasUnsentDraft"]), (task.get("savedPrompt"), task["hasUnsentDraft"]),
            "A stopped message is not saved as a draft: the task's own draft is as it was.",
        )
        self.assertNotEqual(stopped.get("savedPrompt"), waiting_text)
        self.assertIsNone(stopped.get("pendingSubmittedPrompt"), "A stopped message is not a prompt still being sent.")
        self.assertFalse(self.launch_marker(executable, "interrupt-ready").exists(), "Codex must not be running a second turn.")
        self.assertEqual(
            len(self.launch_marker(executable, "held-turns").read_text(encoding="utf-8").splitlines()), 1,
            "Codex should have received one turn only.",
        )

    # case-contract: test_claude_steer_during_turn_launch_reaches_started_turn | A steer sent while Claude Code is still starting the session waits for the turn instead of missing it: once the turn has started the steer reaches it as a next-priority message, the turn answers it, and it is not queued for a turn of its own. In the window the steer's bubble joins the transcript and the composer clears at once, while the session is still starting and has not received it.
    def test_claude_steer_during_turn_launch_reaches_started_turn(self):
        task = self.create_task("Claude steer during launch", provider="claude")
        executable = self.install_provider_fixture("claude", "claude-fixture-launch-steer")
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        steer_text = "Steer the session that is still starting."
        self.launch_marker(executable, "launch-pause").write_text("hold\n", encoding="utf-8")
        send = self.start_background_cli("conversation", "send", task["id"], "--message", "Hold for a steer.", environment=environment)
        self.wait_for(self.launch_marker(executable, "launch-ready").is_file, "Claude Code should be held while starting the session.")
        steer = self.start_background_cli("conversation", "steer", task["id"], "--message", steer_text, environment=environment)
        time.sleep(0.5)
        self.assertTrue(steer["thread"].is_alive(), "A steer sent during the launch waits for the turn instead of missing it.")
        self.launch_marker(executable, "launch-release").write_text("release\n", encoding="utf-8")
        steered = self.assert_success(self.finish_background_cli(steer))
        self.assertTrue(steered["accepted"])
        self.assertFalse(steered["queued"], "The steer should reach the launching turn, not a turn of its own.")
        self.assert_success(self.finish_background_cli(send))
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task["id"])[0]), [])
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        texts = [message["text"] for message in history["messages"]]
        self.assertEqual(texts.count(steer_text), 1, f"The steer should appear once in the turn it steered: {texts}")
        self.assertIn(f"STEERED: {steer_text}", texts, "Claude Code should have answered the steer inside the launched turn.")

    def launch_marker(self, executable, suffix):
        return Path(f"{executable}.{suffix}")

    def start_background_cli(self, *command, expected_status=0, environment=None):
        """Runs a CLI call that blocks on the provider while the case drives the fixture."""
        call = {}

        def run():
            try:
                call["response"] = self.call_cli(*command, expected_status=expected_status, timeout=60, extra_environment=environment)[0]
            except Exception as error:
                call["failure"] = error

        call["thread"] = threading.Thread(target=run, daemon=True)
        call["thread"].start()
        return call

    def finish_background_cli(self, call):
        call["thread"].join(timeout=60)
        self.assertFalse(call["thread"].is_alive(), "The CLI call should settle.")
        self.assertIsNone(call.get("failure"), f"The CLI call failed: {call.get('failure')}")
        return call["response"]

from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases07:
    # case-contract: test_task_stopping_outcomes_and_single_recovery_prompt | A turn has three stopping outcomes and none for unfinished work. A blocked report needs a reason and settles the task in Blocked with that reason; a blocked report without one, or with one longer than 500 characters, is rejected, as is a reason on any other outcome; a legacy in-progress report is answered with guidance, records nothing, withdraws an outcome staged earlier in the turn, and leaves the task In Progress. A turn that ends with no stopping outcome and nothing running gets exactly one private recovery prompt, during which the task stays In Progress; a completed report in that turn settles the task in Review, and a recovery turn that also ends unsettled leaves the task Blocked with a missing-outcome reason and no further prompts. The recovery prompt and its reply appear in the conversation history as a Playhouse-sent message and its reply. The user taking the work back ends Playhouse's private driving: stopping the recovery turn keeps the Stop's Waiting Response with no failure reason, and a queued follow-up runs next instead of a recovery prompt.
    def test_task_stopping_outcomes_and_single_recovery_prompt(self):
        recovery_marker = "ended without reporting a task outcome"

        def recovery_turns(executable):
            turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
            return [turn for turn in turns if recovery_marker in (turn.get("userMessage") or "")]

        task_id = self.create_task("Recovers once", roots=[self.primary])["id"]
        process, executable, active, release = self.start_progress_fixture_turn(
            task_id, "codex-fixture-outcome-recovery-hold-release"
        )
        try:
            # A legacy in-progress report withdraws an outcome staged earlier in the turn: the
            # recovery prompt below is only sent because nothing is left staged.
            staged = self.assert_success(self.call_cli("task", "outcome", task_id, "waiting-response")[0])
            self.assertEqual(staged["recorded"], True)
            legacy = self.assert_success(self.call_cli("task", "outcome", task_id, "in-progress")[0])
            self.assertEqual(legacy["recorded"], False, "in-progress is no longer an outcome, so nothing is staged for it.")
            self.assertEqual(legacy["taskStatus"], "In Progress")
            self.assertIn("no longer a turn outcome", legacy["message"])
            self.assertIn("blocked --reason", legacy["message"])
            unexplained, _ = self.call_cli("task", "outcome", task_id, "blocked", expected_status=2)
            self.assertIn("--reason", unexplained["error"]["message"])
            overlong, _ = self.call_cli("task", "outcome", task_id, "blocked", "--reason", "x" * 501, expected_status=2)
            self.assertIn("1 to 500 characters", overlong["error"]["message"])
            misplaced, _ = self.call_cli("task", "outcome", task_id, "completed", "--reason", "Not a blocker.", expected_status=2)
            self.assertIn("Only a blocked outcome takes --reason", misplaced["error"]["message"])
            release.write_text("Release the unsettled turn.\n", encoding="utf-8")
            self.wait_for_marker(active, False, "The first turn should end without a stopping outcome.")
            self.wait_for_marker(active, True, "Playhouse should send one recovery prompt for a turn that ended unsettled.")
            self.assertEqual(
                self.assert_success(self.call_cli("task", "get", task_id)[0])["status"],
                "In Progress",
                "The task stays In Progress while the recovery turn is running.",
            )
            completed = self.assert_success(self.call_cli("task", "outcome", task_id, "completed")[0])
            self.assertEqual(completed["outcome"], "completed")
            self.assertEqual(completed["recorded"], True)
            self.assertEqual(completed["taskStatus"], "In Progress", "The outcome is staged until the turn completes.")
            release.write_text("Release the recovery turn.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, f"Recovery fixture conversation failed: {stdout}; {stderr}")
            self.assertEqual(
                self.assert_success(self.call_cli("task", "get", task_id)[0])["status"],
                "Review",
                "A completed report during the recovery turn settles the task in Review.",
            )
        finally:
            if process.poll() is None:
                release.write_text("Release the recovery turn.\n", encoding="utf-8")
                process.communicate(timeout=30)
        self.assertEqual(len(recovery_turns(executable)), 1, "An unsettled turn earns exactly one recovery prompt.")
        self.assertIn("This is the only recovery prompt", recovery_turns(executable)[0]["userMessage"])

        blocked_id = self.create_task("Blocked with a reason", roots=[self.primary])["id"]
        blocked, blocked_executable, _, blocked_release = self.start_progress_fixture_turn(
            blocked_id, "codex-fixture-outcome-blocked-hold-release"
        )
        try:
            reported = self.assert_success(self.call_cli(
                "task", "outcome", blocked_id, "blocked", "--reason", "The signing certificate expired."
            )[0])
            self.assertEqual(reported["outcome"], "blocked")
            self.assertEqual(reported["taskStatus"], "In Progress", "A blocked outcome is staged until the turn completes.")
            blocked_release.write_text("Release the blocked turn.\n", encoding="utf-8")
            blocked_stdout, blocked_stderr = blocked.communicate(timeout=30)
            self.assertEqual(blocked.returncode, 0, f"Blocked fixture conversation failed: {blocked_stdout}; {blocked_stderr}")
        finally:
            if blocked.poll() is None:
                blocked_release.write_text("Release the blocked turn.\n", encoding="utf-8")
                blocked.communicate(timeout=30)
        blocked_record = self.assert_success(self.call_cli("task", "get", blocked_id)[0])
        self.assertEqual(blocked_record["status"], "Blocked")
        self.assertEqual(blocked_record.get("statusMessage"), "The signing certificate expired.")
        self.assertEqual(len(recovery_turns(blocked_executable)), 0, "A reported stopping outcome needs no recovery prompt.")

        unanswered_id = self.create_task("Never settles", roots=[self.primary])["id"]
        unanswered, unanswered_executable, unanswered_active, unanswered_release = self.start_progress_fixture_turn(
            unanswered_id, "codex-fixture-outcome-unanswered-hold-release"
        )
        try:
            unanswered_release.write_text("Release the unsettled turn.\n", encoding="utf-8")
            self.wait_for_marker(unanswered_active, False, "The first turn should end without a stopping outcome.")
            self.wait_for_marker(unanswered_active, True, "Playhouse should send its one recovery prompt.")
            self.assertEqual(
                self.assert_success(self.call_cli("task", "get", unanswered_id)[0])["status"],
                "In Progress",
                "A recovery turn that is running keeps the task In Progress.",
            )
            unanswered_release.write_text("Release the recovery turn.\n", encoding="utf-8")
            unanswered_stdout, unanswered_stderr = unanswered.communicate(timeout=60)
            self.assertEqual(unanswered.returncode, 0, f"Unanswered recovery conversation failed: {unanswered_stdout}; {unanswered_stderr}")
        finally:
            if unanswered.poll() is None:
                unanswered_release.write_text("Release the recovery turn.\n", encoding="utf-8")
                unanswered.communicate(timeout=60)
        unanswered_record = self.assert_success(self.call_cli("task", "get", unanswered_id)[0])
        self.assertEqual(unanswered_record["status"], "Blocked", "An unanswered recovery prompt is Blocked, not Waiting Response.")
        self.assertIn("one recovery prompt went unanswered", unanswered_record.get("statusMessage") or "")
        self.assertEqual(len(recovery_turns(unanswered_executable)), 1, "Playhouse sends no second recovery prompt.")

        # Stopping the recovery turn is the user taking the work back, not a
        # Playhouse failure, so the Stop's own paused state must survive.
        stop_id = self.create_task("Stopped mid recovery", roots=[self.primary])["id"]
        stopped, stop_executable, stop_active, stop_release = self.start_progress_fixture_turn(
            stop_id, "codex-fixture-outcome-stop-hold-release"
        )
        try:
            stop_release.write_text("Release the unsettled turn.\n", encoding="utf-8")
            self.wait_for_marker(stop_active, False, "The first turn should end without a stopping outcome.")
            self.wait_for_marker(stop_active, True, "Playhouse should send its recovery prompt before the Stop.")
            # Stop persists the paused state before the provider answers, so the
            # held fixture turn is released once that intent has landed.
            stop_results = []
            stopper = threading.Thread(
                target=lambda: stop_results.append(self.call_cli("conversation", "stop", stop_id, timeout=30)[0]),
                daemon=True,
            )
            stopper.start()
            paused = False
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if self.assert_success(self.call_cli("task", "get", stop_id)[0])["status"] == "Waiting Response":
                    paused = True
                    break
                time.sleep(0.2)
            self.assertTrue(paused, "Stop should persist the paused state before the provider acknowledges it.")
            stop_release.write_text("Release the stopped recovery turn.\n", encoding="utf-8")
            stopper.join(timeout=30)
            self.assertFalse(stopper.is_alive(), "The stop request should settle once the held turn is released.")
            self.assertEqual(len(stop_results), 1)
            self.assert_success(stop_results[0])
            stopped.communicate(timeout=60)
        finally:
            if stopped.poll() is None:
                stop_release.write_text("Release the stopped recovery turn.\n", encoding="utf-8")
                stopped.communicate(timeout=60)
        stop_record = self.assert_success(self.call_cli("task", "get", stop_id)[0])
        self.assertEqual(stop_record["status"], "Waiting Response", "A Stop during the recovery turn keeps the user's paused state.")
        self.assertIsNone(stop_record.get("statusMessage"), "A user-requested Stop must not be reported as a Playhouse failure.")
        self.assertEqual(len(recovery_turns(stop_executable)), 1, "Playhouse must not restart the work once the user stops it.")

        # A queued follow-up is also the user taking over: their message runs next
        # instead of a recovery prompt.
        queued_id = self.create_task("Queued over recovery", roots=[self.primary])["id"]
        queued_turn, queued_executable, _, queued_release = self.start_progress_fixture_turn(
            queued_id, "codex-fixture-outcome-queue-hold-release"
        )
        try:
            self.assert_success(self.call_cli("conversation", "queue", queued_id, "--message", "Follow-up from the user.")[0])
            deadline = time.monotonic() + 60
            while queued_turn.poll() is None and time.monotonic() < deadline:
                queued_release.write_text("Release the next turn.\n", encoding="utf-8")
                time.sleep(0.05)
            queued_turn.communicate(timeout=60)
        finally:
            if queued_turn.poll() is None:
                queued_release.write_text("Release the next turn.\n", encoding="utf-8")
                queued_turn.communicate(timeout=60)
        queued_turns = json.loads(Path(str(queued_executable) + ".history").read_text(encoding="utf-8"))["turns"]
        self.assertGreaterEqual(len(queued_turns), 2)
        self.assertIn(
            "Follow-up from the user.", queued_turns[1].get("userMessage") or "",
            "A queued follow-up must be the next turn the provider receives, ahead of any recovery prompt.",
        )

        unanswered_history = self.assert_success(self.call_cli(
            "conversation", "history", unanswered_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(unanswered_executable)},
        )[0])
        self.assertTrue(
            any(message["role"] == "user" and recovery_marker in message.get("text", "") for message in unanswered_history["messages"]),
            "The recovery prompt Playhouse sent appears in conversation history.",
        )
        self.assertTrue(
            any("Fixture internal reminder reply." in message.get("text", "") for message in unanswered_history["messages"]),
            "The reply to the recovery prompt appears in conversation history.",
        )
        self.assertFalse(
            any(
                hidden in message.get("text", "")
                for message in unanswered_history["messages"]
                for hidden in ("private outcome reminder hidden", "private outcome response hidden")
            ),
            "No placeholder replaces the recovery prompt or its reply.",
        )
    def start_background_fixture_turn(self, task_id, fixture_name, **extra_environment):
        """Sends a turn to a Codex fixture that starts a required command and ends while it runs."""
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / fixture_name
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        process = self.start_cli(
            "conversation", "send", task_id, "--message", "Run the required UI test.",
            extra_environment={
                "PLAYHOUSE_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
                "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
                "PLAYHOUSE_E2E_CODEX_BACKGROUND_RECONCILE_SECONDS": "0.2",
                **extra_environment,
            },
        )
        return process, executable

    def background_fixture_state(self, executable):
        path = Path(str(executable) + ".background-state")
        return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {"running": {}, "started": 0, "listCalls": 0, "terminated": []}

    def wait_for_background_fixture(self, executable, predicate, message, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                if predicate(self.background_fixture_state(executable)):
                    return
            except json.JSONDecodeError:
                pass
            time.sleep(0.05)
        self.fail(f"{message} State: {self.background_fixture_state(executable)}")

    def release_background_fixture(self, executable, **result):
        Path(str(executable) + ".background-release").write_text(json.dumps(result), encoding="utf-8")

    def background_fixture_turns(self, executable):
        return json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]

    # case-contract: test_codex_background_command_holds_task_in_progress_until_its_result | A Codex turn that ends without a stopping outcome while a required command it started is still running keeps the task In Progress, with no private prompt, for as long as the command runs, across many more reconciliations of the provider's background terminals than the old five-continuation allowance. When the command ends, Playhouse delivers its real exit status and output to Codex in exactly one private results turn, and the outcome Codex reports there settles the task: Review after a passing command; after a failing command either In Progress again while the agent's rerun is running and Review once the rerun passes, or Blocked with the agent's reason. A command that disappears without a result is reported to the agent as unknown, never as successful. A command still running when Playhouse's wait ceiling passes is reported as still running in the one results turn, is neither terminated nor waited for again, and a turn that ends unsettled after it leaves the task Blocked with the missing-outcome reason. Stopping the task while it waits terminates the command, leaves the task in Waiting Response with no failure reason, and starts no further turn. A turn that reports completed while leaving a command running, as with a dev server, settles in Review at once with no wait, no termination, and no results turn.
    def test_codex_background_command_holds_task_in_progress_until_its_result(self):
        results_marker = "background work results"

        def status(task_id):
            return self.assert_success(self.call_cli("task", "get", task_id)[0])

        passing_id = self.create_task("Waits for the UI test", roots=[self.primary])["id"]
        passing, passing_executable = self.start_background_fixture_turn(passing_id, "codex-fixture-unique-turns-background-pass")
        try:
            # Far more reconciliations than the five continuation turns that used to end in Blocked.
            self.wait_for_background_fixture(
                passing_executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= 12,
                "Playhouse should keep reconciling the running command through the app-server.",
            )
            self.assertEqual(status(passing_id)["status"], "In Progress", "A required command still running keeps the task In Progress.")
            self.assertIsNone(passing.poll(), "The send stays open while the command it waits for runs.")
            self.assertEqual(len(self.background_fixture_turns(passing_executable)), 1, "Waiting for a command sends the model no prompts.")
            self.release_background_fixture(passing_executable, exitCode=0, output="Executed 1 test, with 0 failures\n")
            stdout, stderr = passing.communicate(timeout=60)
            self.assertEqual(passing.returncode, 0, f"Background fixture conversation failed: {stdout}; {stderr}")
        finally:
            if passing.poll() is None:
                self.release_background_fixture(passing_executable, exitCode=0, output="")
                passing.communicate(timeout=60)
        self.assertEqual(status(passing_id)["status"], "Review", "The outcome reported from the command's result settles the task.")
        passing_turns = self.background_fixture_turns(passing_executable)
        self.assertEqual(len(passing_turns), 2, "The command's result is delivered in exactly one private turn.")
        delivered = passing_turns[1]["userMessage"]
        self.assertIn(results_marker, delivered)
        self.assertIn("scripts/test-ui-tart.sh --case fixture", delivered)
        self.assertIn("completed, exit code 0", delivered)
        self.assertIn("Executed 1 test, with 0 failures", delivered)
        self.assertEqual(self.background_fixture_state(passing_executable)["terminated"], [], "A command that ends on its own is never terminated.")

        retry_id = self.create_task("Fixes the failing UI test", roots=[self.primary])["id"]
        retry, retry_executable = self.start_background_fixture_turn(retry_id, "codex-fixture-unique-turns-background-retry")
        try:
            self.wait_for_background_fixture(retry_executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= 2, "The first run should be waited for.")
            self.release_background_fixture(retry_executable, exitCode=1, output="XCTAssertEqual failed: fixture regression\n")
            self.wait_for_background_fixture(
                retry_executable, lambda state: state["started"] == 2 and len(state["running"]) == 1,
                "The agent should rerun the command after reading its failure.",
            )
            self.assertEqual(status(retry_id)["status"], "In Progress", "A rerun that is running keeps the task In Progress.")
            self.release_background_fixture(retry_executable, exitCode=0, output="Executed 1 test, with 0 failures\n")
            retry_stdout, retry_stderr = retry.communicate(timeout=60)
            self.assertEqual(retry.returncode, 0, f"Retry fixture conversation failed: {retry_stdout}; {retry_stderr}")
        finally:
            if retry.poll() is None:
                self.release_background_fixture(retry_executable, exitCode=0, output="")
                retry.communicate(timeout=60)
        self.assertEqual(status(retry_id)["status"], "Review")
        retry_turns = self.background_fixture_turns(retry_executable)
        self.assertEqual(len(retry_turns), 3, "Each command result is delivered once: the failure, then the passing rerun.")
        self.assertIn("failed, exit code 1", retry_turns[1]["userMessage"])
        self.assertIn("XCTAssertEqual failed: fixture regression", retry_turns[1]["userMessage"])
        self.assertIn("completed, exit code 0", retry_turns[2]["userMessage"])
        self.assertNotIn("XCTAssertEqual failed", retry_turns[2]["userMessage"], "A delivered result is not delivered again.")

        failing_id = self.create_task("Cannot fix the UI test", roots=[self.primary])["id"]
        failing, failing_executable = self.start_background_fixture_turn(failing_id, "codex-fixture-unique-turns-background-fail")
        try:
            self.wait_for_background_fixture(failing_executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= 2, "The failing run should be waited for.")
            self.release_background_fixture(failing_executable, exitCode=1, output="XCTAssertEqual failed: fixture regression\n")
            failing.communicate(timeout=60)
        finally:
            if failing.poll() is None:
                self.release_background_fixture(failing_executable, exitCode=1, output="")
                failing.communicate(timeout=60)
        failing_record = status(failing_id)
        self.assertEqual(failing_record["status"], "Blocked")
        self.assertIn("The required UI test failed", failing_record.get("statusMessage") or "")
        self.assertEqual(len(self.background_fixture_turns(failing_executable)), 2)

        vanished_id = self.create_task("Loses the UI test", roots=[self.primary])["id"]
        vanished, vanished_executable = self.start_background_fixture_turn(vanished_id, "codex-fixture-unique-turns-background-vanish")
        try:
            self.wait_for_background_fixture(vanished_executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= 2, "The vanishing run should be waited for.")
            self.release_background_fixture(vanished_executable, vanish=True)
            vanished.communicate(timeout=60)
        finally:
            if vanished.poll() is None:
                self.release_background_fixture(vanished_executable, vanish=True)
                vanished.communicate(timeout=60)
        vanished_turns = self.background_fixture_turns(vanished_executable)
        self.assertEqual(len(vanished_turns), 2)
        self.assertIn("Playhouse did not see its result", vanished_turns[1]["userMessage"])
        self.assertNotIn("exit code 0", vanished_turns[1]["userMessage"], "A command gone from the list is not assumed to have passed.")
        vanished_record = status(vanished_id)
        self.assertEqual(vanished_record["status"], "Blocked")
        self.assertIn("without a result", vanished_record.get("statusMessage") or "")

        stopped_id = self.create_task("Stopped while waiting", roots=[self.primary])["id"]
        stopped, stopped_executable = self.start_background_fixture_turn(stopped_id, "codex-fixture-unique-turns-background-stop")
        try:
            self.wait_for_background_fixture(stopped_executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= 2, "The run should be waited for before the Stop.")
            self.assert_success(self.call_cli("conversation", "stop", stopped_id, timeout=30)[0])
            stopped.communicate(timeout=60)
        finally:
            if stopped.poll() is None:
                self.release_background_fixture(stopped_executable, exitCode=0, output="")
                stopped.communicate(timeout=60)
        stopped_record = status(stopped_id)
        self.assertEqual(stopped_record["status"], "Waiting Response", "A Stop during the wait keeps the user's paused state.")
        self.assertIsNone(stopped_record.get("statusMessage"), "A user-requested Stop must not be reported as a failure.")
        stopped_state = self.background_fixture_state(stopped_executable)
        self.assertEqual(stopped_state["terminated"], ["49264"], "Stop ends the command the task was waiting for.")
        self.assertEqual(len(self.background_fixture_turns(stopped_executable)), 1, "Nothing restarts the work after a Stop.")
        time.sleep(1.5)
        self.assertEqual(len(self.background_fixture_turns(stopped_executable)), 1, "Nothing restarts the work after a Stop.")
        self.assertEqual(status(stopped_id)["status"], "Waiting Response")

        server_id = self.create_task("Leaves a dev server running", roots=[self.primary])["id"]
        server, server_executable = self.start_background_fixture_turn(server_id, "codex-fixture-unique-turns-background-server")
        try:
            server_stdout, server_stderr = server.communicate(timeout=30)
            self.assertEqual(server.returncode, 0, f"Dev server fixture conversation failed: {server_stdout}; {server_stderr}")
        finally:
            if server.poll() is None:
                self.release_background_fixture(server_executable, exitCode=0, output="")
                server.communicate(timeout=60)
        self.assertEqual(status(server_id)["status"], "Review", "A completed outcome settles the task even with a command left running.")
        server_state = self.background_fixture_state(server_executable)
        self.assertEqual(len(server_state["running"]), 1, "The dev server keeps running.")
        self.assertEqual(server_state["terminated"], [])
        self.assertEqual(len(self.background_fixture_turns(server_executable)), 1, "A settled task gets no results turn.")

        outlasting_id = self.create_task("Outlasts the wait", roots=[self.primary])["id"]
        outlasting, outlasting_executable = self.start_background_fixture_turn(
            outlasting_id, "codex-fixture-unique-turns-background-timeout", PLAYHOUSE_E2E_BACKGROUND_JOB_WAIT_SECONDS="1.5"
        )
        try:
            outlasting.communicate(timeout=60)
        finally:
            if outlasting.poll() is None:
                self.release_background_fixture(outlasting_executable, exitCode=0, output="")
                outlasting.communicate(timeout=60)
        outlasting_turns = self.background_fixture_turns(outlasting_executable)
        self.assertEqual(len(outlasting_turns), 2, "A command that outlasts the wait earns one prompt and is not waited for again.")
        self.assertIn(results_marker, outlasting_turns[1]["userMessage"])
        self.assertIn("still running. Playhouse stopped waiting for it.", outlasting_turns[1]["userMessage"])
        self.assertIn("ran longer than Playhouse waits for a command", outlasting_turns[1]["userMessage"])
        self.assertNotIn("exit code", outlasting_turns[1]["userMessage"], "A command still running has no result to report.")
        outlasting_record = status(outlasting_id)
        self.assertEqual(outlasting_record["status"], "Blocked", "An unsettled turn after the wait ran out is not left In Progress.")
        self.assertIn("stopped without reporting a stopping outcome", outlasting_record.get("statusMessage") or "")
        outlasting_state = self.background_fixture_state(outlasting_executable)
        self.assertEqual(len(outlasting_state["running"]), 1, "Playhouse does not end a command it merely stopped waiting for.")
        self.assertEqual(outlasting_state["terminated"], [])

    # case-contract: test_codex_follow_up_queued_during_background_wait_runs_next | A follow-up the user queues while a task waits for a command its Codex turn left running ends the wait at once: the follow-up is the next turn the provider receives, ahead of any results or recovery prompt, and the command is neither terminated nor forgotten. When the follow-up's turn ends without a stopping outcome the task stays In Progress and Playhouse waits for the same command again, with no further prompt. When the command ends, its real exit status and output are delivered once in one private results turn, and the outcome Codex reports there settles the task in Review. The follow-up appears once in history.
    def test_codex_follow_up_queued_during_background_wait_runs_next(self):
        results_marker = "background work results"
        recovery_marker = "ended without reporting a task outcome"
        follow_up = "Also keep the fixture log."
        task_id = self.create_task("Follow-up while waiting", roots=[self.primary])["id"]
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture-unique-turns-background-queue")}

        def status():
            return self.assert_success(self.call_cli("task", "get", task_id)[0])["status"]

        turn, executable = self.start_background_fixture_turn(task_id, "codex-fixture-unique-turns-background-queue")
        try:
            self.wait_for_background_fixture(executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= 2, "The command should be waited for before the follow-up.")
            self.assertEqual(len(self.background_fixture_turns(executable)), 1)
            self.assert_success(self.call_cli("conversation", "queue", task_id, "--message", follow_up)[0])
            turns = self.wait_for(
                lambda: (lambda turns: turns if len(turns) >= 2 else None)(self.background_fixture_turns(executable)),
                "The queued follow-up should end the wait and run as the next turn.", timeout=30)
            self.assertIn(follow_up, turns[1]["userMessage"], "The follow-up is the next turn the provider receives.")
            self.assertNotIn(results_marker, turns[1]["userMessage"])
            self.assertNotIn(recovery_marker, turns[1]["userMessage"])
            calls_after_follow_up = self.background_fixture_state(executable)["listCalls"]
            self.wait_for_background_fixture(
                executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= calls_after_follow_up + 3,
                "The same command should be waited for again after the follow-up's turn.",
            )
            waiting_state = self.background_fixture_state(executable)
            self.assertEqual(waiting_state["started"], 1, "The follow-up starts no second command.")
            self.assertEqual(waiting_state["terminated"], [], "A queued follow-up does not terminate the command.")
            self.assertEqual(status(), "In Progress", "The command still running keeps the task In Progress after the follow-up.")
            self.assertEqual(len(self.background_fixture_turns(executable)), 2, "Waiting again sends the model no prompt.")
            self.release_background_fixture(executable, exitCode=0, output="Executed 1 test, with 0 failures\n")
            self.wait_for(lambda: status() == "Review", "The outcome reported from the command's result should settle the task.", timeout=60)
        finally:
            if turn.poll() is None:
                self.release_background_fixture(executable, exitCode=0, output="")
            turn.communicate(timeout=60)
        turns = self.background_fixture_turns(executable)
        self.assertEqual(len(turns), 3, "The command's result is delivered in exactly one private turn after the follow-up.")
        self.assertEqual(sum(results_marker in (entry.get("userMessage") or "") for entry in turns), 1)
        self.assertIn("completed, exit code 0", turns[2]["userMessage"])
        self.assertIn("Executed 1 test, with 0 failures", turns[2]["userMessage"])
        self.assertFalse(any(recovery_marker in (entry.get("userMessage") or "") for entry in turns), "No recovery prompt is sent while a command is waited for.")
        self.assertEqual(self.background_fixture_state(executable)["terminated"], [])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        self.assertEqual(
            sum(message["role"] == "user" and follow_up in message.get("text", "") for message in history["messages"]), 1,
            "The follow-up appears once in history.",
        )

    # case-contract: test_codex_background_wait_survives_daemon_restart | A daemon killed while a task waits for a command its Codex turn left running does not strand the task: the next daemon finds the persisted wait, reconnects to the same app-server, keeps the task In Progress with no new prompt, and resumes reconciling the provider's background terminals. A command that ends after the restart has its real exit status and output delivered once, and the agent's rerun is waited for again. A command that ended while no daemon was connected is reported to the agent as having no result Playhouse saw, never as successful, and the agent's blocked outcome settles the task in Blocked with its reason. The user's message appears once in history across both restarts.
    def test_codex_background_wait_survives_daemon_restart(self):
        executable = self.install_provider_fixture("codex", "codex-fixture-unique-turns-background-retry-daemon")
        environment = self.restart_service_environment(
            "codex", executable,
            PLAYHOUSE_E2E_WORKTREE_DIRECTORY=str(self.worktree_directory),
            PLAYHOUSE_E2E_CODEX_BACKGROUND_RECONCILE_SECONDS="0.2",
        )
        task_id = self.create_task("Waits across a restart", roots=[self.primary], provider="codex")["id"]
        sent = {}
        sender = threading.Thread(target=lambda: sent.setdefault("first", self.call_cli(
            "conversation", "send", task_id, "--message", "Run the required UI test.",
            expected_status=69, timeout=90, extra_environment=environment)), daemon=True)
        sender.start()
        self.wait_for_background_fixture(executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= 2, "The command should be waited for before the daemon dies.")
        servers = lambda: [m["process"] for kind, _, m in self.agent_manifests()
                           if kind == "codex" and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]]
        server = servers()
        self.assertEqual(len(server), 1, "One shared app-server serves the private service.")

        self.kill_daemon(environment)
        sender.join(timeout=20)
        self.assertFalse(sender.is_alive(), "The send fails promptly once its daemon is gone.")
        self.assert_failure(sent["first"][0], "service_unavailable")
        calls_before_restart = self.background_fixture_state(executable)["listCalls"]
        # This request starts the fresh daemon, which picks the wait up before answering.
        self.assertEqual(self.task_for(task_id, environment)["status"], "In Progress", "A wait cut off by a restart keeps the task In Progress.")
        self.wait_for_background_fixture(
            executable, lambda state: len(state["running"]) == 1 and state["listCalls"] >= calls_before_restart + 3,
            "The fresh daemon should resume reconciling the running command.",
        )
        self.assertEqual(servers(), server, "The fresh daemon reconnects to the same app-server.")
        self.assertEqual(self.task_for(task_id, environment)["status"], "In Progress")
        self.assertEqual(len(self.background_fixture_turns(executable)), 1, "Resuming the wait sends the model no prompt.")
        self.release_background_fixture(executable, exitCode=1, output="XCTAssertEqual failed: fixture regression\n")
        self.wait_for_background_fixture(
            executable, lambda state: state["started"] == 2 and len(state["running"]) == 1 and state["listCalls"] >= 2,
            "The agent should rerun the command after reading the failure delivered after the restart.",
        )
        turns = self.background_fixture_turns(executable)
        self.assertEqual(len(turns), 2, "The result is delivered in exactly one private turn.")
        self.assertIn("failed, exit code 1", turns[1]["userMessage"])
        self.assertIn("XCTAssertEqual failed: fixture regression", turns[1]["userMessage"])
        rerun_calls = self.background_fixture_state(executable)["listCalls"]
        self.wait_for_background_fixture(executable, lambda state: state["listCalls"] >= rerun_calls + 3, "The rerun should be waited for before the second restart.")
        self.assertEqual(self.task_for(task_id, environment)["status"], "In Progress", "A rerun that is running keeps the task In Progress.")

        # The rerun ends with no daemon connected: its completion event reaches nobody.
        self.kill_daemon(environment)
        self.release_background_fixture(executable, vanish=True)
        settled = self.wait_for(
            lambda: (lambda record: record if record["status"] == "Blocked" else None)(self.task_for(task_id, environment)),
            "The agent's outcome for the lost result should settle the task.", timeout=60)
        self.assertIn("without a result", settled.get("statusMessage") or "")
        turns = self.background_fixture_turns(executable)
        self.assertEqual(len(turns), 3, "The lost result is reported in exactly one more private turn.")
        self.assertIn("Playhouse did not see its result", turns[2]["userMessage"])
        self.assertNotIn("exit code 0", turns[2]["userMessage"], "A command that ended unseen is not assumed to have passed.")
        self.assertNotIn("XCTAssertEqual failed", turns[2]["userMessage"], "A delivered result is not delivered again.")
        self.assertEqual(self.background_fixture_state(executable)["terminated"], [])
        texts, _ = self.history_texts(task_id, environment)
        self.assertEqual(texts.count("Run the required UI test."), 1, "The user's message appears once across both restarts.")

    # case-contract: test_task_progress_reports_clear_on_failed_turns_and_questions | Progress reports clear when turns fail or are interrupted and when Codex requests user input; a staged completed outcome is discarded if its turn fails, leaving the task Blocked. The task card removes the report while lifecycle states remain Blocked or In Progress. A blocking structured question appears inline and moves the task to Waiting Response; its answer resumes the active turn in In Progress, and the answered turn finishes in Waiting Response. First-thread instructions distinguish source repository paths from active task worktree paths, allow read-only inspection without attaching a repo, and reserve repository add APIs for changes that need a worktree.
    def test_task_progress_reports_clear_on_failed_turns_and_questions(self):
        for fixture_name, expected_reason in [
            ("codex-fixture-progress-hold-release-failed", "failed"),
            ("codex-fixture-progress-hold-release-interrupted", "interrupted"),
        ]:
            task_id = self.create_task(f"Progress {expected_reason}", roots=[self.primary])["id"]
            process, executable, active, release = self.start_progress_fixture_turn(task_id, fixture_name)
            try:
                report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "testing", "--detail", "Waiting for the result")
                self.assertEqual(self.assert_success(report)["progressLabel"], "Testing")
                staged, _ = self.call_cli("task", "outcome", task_id, "completed")
                staged_record = self.assert_success(staged)
                self.assertEqual(staged_record["outcome"], "completed")
                self.assertEqual(staged_record["taskStatus"], "In Progress")
                release.write_text("Release the active turn.\n", encoding="utf-8")
                stdout, stderr = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 1, f"Expected the fixture {expected_reason} turn to fail: {stdout}; {stderr}")
                final_response = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
                self.assert_failure(final_response, "operation_failed")
                current, _ = self.call_cli("task", "get", task_id)
                current_record = self.assert_success(current)
                self.assertEqual(current_record["status"], "Blocked")
                self.assertIsNone(current_record.get("progressLabel"))
            finally:
                if process.poll() is None:
                    release.write_text("Release the active turn.\n", encoding="utf-8")
                    process.communicate(timeout=20)
                active.unlink(missing_ok=True)
                release.unlink(missing_ok=True)

        task_id = self.create_repo_task("Progress question", [self.primary])["id"]
        process, executable, active, release = self.start_progress_fixture_turn(
            task_id, "codex-fixture-progress-user-question",
            answers=["question_action=Continue"],
        )
        outcome_hold = Path(str(executable) + ".outcome-hold")
        outcome_active = Path(str(executable) + ".outcome-active")
        outcome_release = Path(str(executable) + ".outcome-release")
        try:
            report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "reviewing")
            self.assertEqual(self.assert_success(report)["progressLabel"], "Reviewing")
            outcome_hold.write_text("Hold final turn completion for answer status verification.\n", encoding="utf-8")
            release.write_text("Release the active turn.\n", encoding="utf-8")
            deadline = time.monotonic() + 10
            while not outcome_active.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(outcome_active.is_file(), "The fixture should acknowledge the answer and hold final completion.")
            current, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(current)["status"], "In Progress", "The accepted answer should resume the active task in In Progress.")
            outcome_release.write_text("Release final turn completion.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, f"Answering the fixture question should complete the turn: {stdout}; {stderr}")
            final_response = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
            self.assertTrue(final_response["ok"], final_response.get("error"))
            current, _ = self.call_cli("task", "get", task_id)
            current_record = self.assert_success(current)
            self.assertEqual(current_record["status"], "Waiting Response")
            self.assertEqual([item["repositoryPath"] for item in current_record["repositoryWorktrees"]], [str(self.primary)])
            self.assertIsNone(current_record.get("progressLabel"))
            history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            instructions = history["threadStartDeveloperInstructions"]
            self.assertIn("read-only inspection of returned source paths", instructions)
            self.assertIn("Add a repository to this task only when you intend to create or commit changes in it", instructions)
            self.assertIn("workspace repos list", instructions)
            self.assertIn("task repository add", instructions)
            self.assertIn("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated.", instructions)
            self.assertFalse(Path(str(executable) + ".assessment.history").exists())
        finally:
            if process.poll() is None:
                release.write_text("Release the active turn.\n", encoding="utf-8")
                outcome_release.write_text("Release final turn completion.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            outcome_hold.unlink(missing_ok=True)
            outcome_active.unlink(missing_ok=True)
            outcome_release.unlink(missing_ok=True)
    # case-contract: test_task_rename_persists_and_rejects_blank_title | A rename waits for the real per-task operation lock, then persists across fresh CLI/XPC reads; rejecting a blank rename preserves the last valid title.
    def test_task_rename_persists_and_rejects_blank_title(self):
        task_id = self.create_task()["id"]
        barrier = TaskOperationLockBarrier(self.data_directory, task_id)
        process = self.start_cli("task", "rename", task_id, "--title", "Renamed through XPC")
        try:
            time.sleep(0.25)
            waited_for_lock = process.poll() is None
        finally:
            barrier.release()
        response, _ = self.finish_cli(process, ("task", "rename", task_id, "--title", "Renamed through XPC"))
        self.assertTrue(waited_for_lock, "Rename should wait while another process holds the real task-operation lock.")
        self.assertEqual(self.assert_success(response)["title"], "Renamed through XPC")
        response, _ = self.call_cli("task", "rename", task_id, "--title", " ", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["title"], "Renamed through XPC")
    # case-contract: test_task_title_is_selectable_and_matches_persisted_title | The conversation title has no copy button and its text is selectable: selecting and copying it places the task's exact persisted title on the pasteboard, including spaces, an ampersand and non-ASCII text, after a rename, and fresh CLI/XPC reads report the same title.
    def test_task_title_is_selectable_and_matches_persisted_title(self):
        task_id = self.create_task()["id"]
        title = "Café & tea: ready ✓"
        response, _ = self.call_cli("task", "rename", task_id, "--title", title)
        self.assertEqual(self.assert_success(response)["title"], title)
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["title"], title)
    # case-contract: test_task_roots_set_get_order_deduplication_and_validation | Root editing preserves order, removes duplicates, rejects an empty list, and waits for an active conversation turn; a stale Git-folder validation is rejected after a newer folder edit, and the newer roots remain saved.
    def test_task_roots_set_get_order_deduplication_and_validation(self):
        task_id = self.create_task()["id"]
        response, _ = self.call_cli(
            "task", "roots", "set", task_id,
            "--root", self.secondary,
            "--root", self.custom,
            "--root", self.primary,
            "--root", self.secondary,
        )
        expected_roots = [str(self.secondary), str(self.custom), str(self.primary)]
        self.assertEqual(self.assert_success(response)["workspaceRoots"], expected_roots)
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], expected_roots)

        reservation_task = self.create_task("Conversation reservation for roots", [self.primary])
        reservation_id = reservation_task["id"]
        reservation = ConversationTurnLockBarrier(self.data_directory, reservation_id)
        roots_command = ["task", "roots", "set", reservation_id, "--root", self.custom]
        roots_process = None
        continue_roots_process = False
        try:
            roots_process = self.start_cli(*roots_command)
            time.sleep(0.25)
            self.assertIsNone(roots_process.poll(), "Workspace-root edits should wait for the active conversation-turn reservation.")
            unchanged, _ = self.call_cli("task", "get", reservation_id)
            self.assertEqual(self.assert_success(unchanged)["workspaceRoots"], [str(self.primary)])
            continue_roots_process = True
        finally:
            reservation.release()
            if not continue_roots_process and roots_process is not None and roots_process.poll() is None:
                roots_process.terminate()
                try:
                    roots_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    roots_process.kill()
                    roots_process.communicate()
        self.assertIsNotNone(roots_process)
        roots_response, _ = self.finish_cli(roots_process, roots_command)
        self.assertEqual(self.assert_success(roots_response)["workspaceRoots"], [str(self.custom)])

        concurrent_task = self.create_repo_task("Concurrent root edit", [self.primary])
        concurrent_id = concurrent_task["id"]
        barrier = GitConfigReadBarrier(self.secondary)
        stale_command = [
            "task", "roots", "set", concurrent_id,
            "--root", self.secondary,
        ]
        stale_process = None
        continue_stale_process = False
        try:
            stale_process = self.start_cli(*stale_command)
            barrier.wait_for_reader()
            newer, _ = self.call_cli("task", "roots", "set", concurrent_id, "--root", self.custom)
            newer_record = self.assert_success(newer)
            self.assertEqual(newer_record["workspaceRoots"], [str(self.custom)])
            self.assertEqual(newer_record["repositoryWorktrees"], [])
            continue_stale_process = True
        finally:
            barrier.release()
            if not continue_stale_process and stale_process is not None and stale_process.poll() is None:
                stale_process.terminate()
                try:
                    stale_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    stale_process.kill()
                    stale_process.communicate()
        self.assertIsNotNone(stale_process)
        stale, _ = self.finish_cli(stale_process, stale_command, expected_status=1)
        self.assert_failure(stale, "invalid_transition")
        final, _ = self.call_cli("task", "get", concurrent_id)
        final_record = self.assert_success(final)
        self.assertEqual(final_record["workspaceRoots"], [str(self.custom)])
        self.assertEqual(final_record["contextFolders"], [str(self.custom)])
        self.assertEqual(final_record["repositoryWorktrees"], [])
        response, _ = self.call_cli("task", "roots", "set", task_id, expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(response)["roots"], expected_roots)
    # case-contract: test_conversation_repository_picker_adds_repository_worktree | Repository suggestions can be filtered and navigated with Up/Down, and Enter selects the highlighted repository; UI selection waits for an active turn and persists a pending auto branch. While the conversation is empty, a prominent theme-colored heading names all selected repositories and updates as repository APIs add or replace context; compact repository labels remain in the header without a duplicate repository summary. Dark and light themes use distinct prominent title colors, the supporting model prompt sits below with generous spacing, and the generic Start a conversation heading is absent. Additional context folders remain identifiable. The task repository API remains available during an active turn, prepares a managed worktree inside the app data directory's task-worktrees folder, updates saved repository selection, replaces repository context safely, and the paired UI shows API additions/removals. The main assistant is instructed to list repositories through Playhouse, inspect listed source paths read-only without attaching them, and add repositories only when it needs a task worktree for changes or commits.
    def test_conversation_repository_picker_adds_repository_worktree(self):
        task = self.create_task("Add repository in conversation", [self.primary])
        task_id = task["id"]
        self.assertEqual(task["repositoryWorktrees"], [])
        self.assertEqual(task["workspaceRoots"], [str(self.primary)])
        reservation = ConversationTurnLockBarrier(self.data_directory, task_id)
        try:
            added_response, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.primary)
            updated = self.assert_success(added_response)
            self.assertEqual(len(updated["repositoryWorktrees"]), 1)
            added = updated["repositoryWorktrees"][0]
            self.assertEqual(added["repositoryPath"], str(self.primary))
            self.assertFalse(added["isPending"], "The AI-facing repository API should prepare an editable worktree immediately.")
            self.assertNotEqual(added["worktreePath"], str(self.primary))
            self.assertTrue(Path(added["worktreePath"]).is_dir())
            self.assertTrue(Path(added["worktreePath"]).is_relative_to(self.worktree_directory))
            replacement_response, _ = self.call_cli(
                "task", "repository", "replace", task_id, "--repo", self.secondary
            )
            replaced = self.assert_success(replacement_response)
            self.assertEqual([item["repositoryPath"] for item in replaced["repositoryWorktrees"]], [str(self.secondary)])
            self.assertFalse(replaced["repositoryWorktrees"][0]["isPending"])
            self.assertTrue(Path(replaced["repositoryWorktrees"][0]["worktreePath"]).is_dir())
            self.assertTrue(Path(added["worktreePath"]).is_dir(), "The active turn must keep its old cwd until it releases the reservation.")
            unchanged, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(unchanged)["repositoryWorktrees"], replaced["repositoryWorktrees"])
        finally:
            reservation.release()
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary)])
        self.assertEqual(added["branch"], "add-repository-in-conversation")
        self.assertTrue(added["branchFrom"])
        self.assertTrue(added["mergeTarget"])
        self.assertEqual(updated["workspaceRoots"], [added["worktreePath"]])
        self.assertEqual(updated["contextFolders"], [])
        duplicate, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.secondary, expected_status=2)
        self.assert_failure(duplicate, "invalid_argument")
        invalid, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.custom, expected_status=1)
        self.assert_failure(invalid, "operation_failed")
        fresh, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(fresh)["repositoryWorktrees"], replaced["repositoryWorktrees"])
    # case-contract: test_conversation_repository_picker_add_and_replace_buttons | Each repository row in the header's Add repository picker adds the repository alongside the selected ones when the row or its plus button is clicked, and its Replace button removes every selected repository and attaches only that one; the task repository API reaches the same add and replace results, duplicates are rejected, and the saved repository selection follows. The catalog's shared Overlay atom contains both actions and reveals them on hover; the UI keeps them visible over the row and buttons and hides them on exit. Both buttons sit clear of the list's overlay scroller and each shows a hover highlight while the pointer is on it.
    def test_conversation_repository_picker_add_and_replace_buttons(self):
        # The catalog exercises the same Overlay atom used by the native picker.
        # Pointer tracking itself is presentation state, checked by the paired UI case.
        rendered, _ = self.call_cli("plugin", "render", "--page", "RepositoryChips")
        tree = self.assert_success(rendered)["tree"]
        row_button = self.plugin_node(tree, "conversation-repository-recent-mre")
        scroll = self.plugin_node(tree, "conversation-repository-list")
        row = next(node for node in scroll["children"] if row_button in node["children"])
        self.assertTrue(row["props"]["revealOnHover"])
        # Inset past the list's overlay scroller, so it never covers the buttons.
        self.assertLessEqual(row["props"]["offsetX"], -16)
        for action in ("add", "replace"):
            button = self.plugin_node(row, f"conversation-repository-recent-mre-{action}")
            self.assertIsNotNone(button)
            self.assertEqual(button["props"].get("emphasis"), 4, f"The {action} button should show the hover highlight.")

        task = self.create_task("Picker add and replace", [self.primary])
        task_id = task["id"]
        response, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.primary)
        self.assertEqual([item["repositoryPath"] for item in self.assert_success(response)["repositoryWorktrees"]], [str(self.primary)])
        response, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.secondary)
        added = self.assert_success(response)
        self.assertEqual([item["repositoryPath"] for item in added["repositoryWorktrees"]], [str(self.primary), str(self.secondary)])
        duplicate, _ = self.call_cli("task", "repository", "add", task_id, "--repo", self.secondary, expected_status=2)
        self.assert_failure(duplicate, "invalid_argument")
        response, _ = self.call_cli("task", "repository", "replace", task_id, "--repo", self.primary)
        replaced = self.assert_success(response)
        self.assertEqual([item["repositoryPath"] for item in replaced["repositoryWorktrees"]], [str(self.primary)])
        fresh, _ = self.call_cli("task", "get", task_id)
        self.assertEqual([item["repositoryPath"] for item in self.assert_success(fresh)["repositoryWorktrees"]], [str(self.primary)])
        settings, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(settings)["lastSelectedRepositories"], [str(self.primary)])
    # case-contract: test_task_repository_settings_validate_persist_and_lock_after_start | Pending repository branch, merge-from, and merge-to settings wait for an active conversation turn, then persist across fresh CLI/XPC reads; invalid settings leave prior values intact, and settings are locked after worktree creation. Each setting is edited in place: the pencil beside a value opens an inline field with a checkmark that saves only that field and keeps the editor open on the saved value, and clicking outside the field or pressing Escape dismisses the edit without saving. The settings popover is wider than before with a larger title, and the repository chip's remove button is a larger target.
    def test_task_repository_settings_validate_persist_and_lock_after_start(self):
        task = self.create_repo_task("Repository settings", [self.primary])
        task_id = task["id"]
        initial = task["repositoryWorktrees"][0]
        edit_command = [
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "settings-edited",
            "--branch-from", "branch-source",
            "--merge-target", "branch-source",
        ]
        reservation = ConversationTurnLockBarrier(self.data_directory, task_id)
        edit_process = None
        continue_edit_process = False
        try:
            edit_process = self.start_cli(*edit_command)
            time.sleep(0.25)
            self.assertIsNone(edit_process.poll(), "Repository settings should wait for the active conversation-turn reservation.")
            unchanged, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(unchanged)["repositoryWorktrees"][0]["branch"], initial["branch"])
            continue_edit_process = True
        finally:
            reservation.release()
            if not continue_edit_process and edit_process is not None and edit_process.poll() is None:
                edit_process.terminate()
                try:
                    edit_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    edit_process.kill()
                    edit_process.communicate()
        self.assertIsNotNone(edit_process)
        changed, _ = self.finish_cli(edit_process, edit_command)
        edited = self.assert_success(changed)["repositoryWorktrees"][0]
        self.assertEqual(edited["branch"], "settings-edited")
        self.assertEqual(edited["branchFrom"], "branch-source")
        self.assertEqual(edited["mergeTarget"], "branch-source")
        self.assertTrue(edited["isPending"])
        self.assertEqual(edited["worktreePath"], self.primary.as_posix())

        invalid, _ = self.call_cli(
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "invalid branch",
            "--branch-from", "branch-source",
            "--merge-target", "branch-source",
            expected_status=2,
        )
        self.assert_failure(invalid, "invalid_argument")
        invalid_target, _ = self.call_cli(
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "settings-edited",
            "--branch-from", "branch-source",
            "--merge-target", "missing-local-branch",
            expected_status=2,
        )
        self.assert_failure(invalid_target, "invalid_argument")
        fresh, _ = self.call_cli("task", "get", task_id)
        unchanged = self.assert_success(fresh)["repositoryWorktrees"][0]
        self.assertEqual(unchanged["branch"], edited["branch"])
        self.assertEqual(unchanged["branchFrom"], edited["branchFrom"])
        self.assertEqual(unchanged["mergeTarget"], edited["mergeTarget"])
        self.assertNotEqual(initial["branch"], unchanged["branch"])

        self.complete_fixture_turn(task_id)
        started, _ = self.call_cli("task", "get", task_id)
        started_record = self.assert_success(started)["repositoryWorktrees"][0]
        self.assertFalse(started_record["isPending"])
        self.assertEqual(started_record["branch"], "settings-edited")
        self.assertTrue(Path(started_record["worktreePath"]).is_dir())
        locked, _ = self.call_cli(
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "changed-after-start",
            "--branch-from", "branch-source",
            "--merge-target", "branch-source",
            expected_status=1,
        )
        self.assert_failure(locked, "invalid_transition")
        final, _ = self.call_cli("task", "get", task_id)
        final_record = self.assert_success(final)["repositoryWorktrees"][0]
        self.assertEqual(final_record["branch"], "settings-edited")
        self.assertEqual(final_record["branchFrom"], "branch-source")
        self.assertEqual(final_record["mergeTarget"], "branch-source")
    # case-contract: test_task_repository_branch_from_fetches_remote_branch | A branch-from that exists only on a Git remote and was never fetched is fetched when repository settings are saved, and the pending record stores its remote-tracking branch; a branch-from missing locally and on every remote is rejected without changing the saved settings; a remote that can't be reached reports the fetch failure instead of a missing branch and also keeps the saved settings; starting the task fetches the remote branch again, so its worktree starts from the remote's latest commit even after the remote branch moved ahead, without making the remote branch the task branch's upstream.
    def test_task_repository_branch_from_fetches_remote_branch(self):
        remote = self.data_directory / "branch-from-origin.git"
        remote_branch = "remote-only/branch-from"
        tracking_ref = f"refs/remotes/origin/{remote_branch}"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
        remote_commit = self.run_git(
            self.primary, "commit-tree", "main^{tree}", "-p", "main", "-m", "Create remote-only branch-from fixture commit",
        ).strip()
        self.run_git(self.primary, "remote", "add", "origin", str(remote))
        try:
            self.run_git(self.primary, "push", "--quiet", "origin", "main", f"{remote_commit}:refs/heads/{remote_branch}")
            # Pushing records the remote-tracking ref; drop it so the branch exists only on the remote.
            self.run_git(self.primary, "update-ref", "-d", tracking_ref)
            unfetched = subprocess.run(
                ["git", "-C", str(self.primary), "rev-parse", "--verify", "--quiet", tracking_ref],
                check=False, capture_output=True, text=True,
            )
            self.assertNotEqual(unfetched.returncode, 0, "The remote branch must start unfetched.")
            self.assertFalse(self.branch_exists(self.primary, remote_branch))

            task = self.create_repo_task("Remote branch-from", [self.primary])
            task_id = task["id"]
            # PR mode would publish the branch on Review, and publishing sets the upstream this case checks.
            self.set_pull_request_mode(task_id, "manual")
            changed, _ = self.call_cli(
                "task", "repository", "edit", task_id,
                "--repo", self.primary,
                "--branch", "remote-branch-from-task",
                "--branch-from", remote_branch,
                "--merge-target", "main",
            )
            edited = self.assert_success(changed)["repositoryWorktrees"][0]
            self.assertEqual(edited["branchFrom"], f"origin/{remote_branch}")
            self.assertTrue(edited["isPending"])
            self.assertEqual(self.run_git(self.primary, "rev-parse", tracking_ref).strip(), remote_commit)
            self.assertFalse(self.branch_exists(self.primary, remote_branch), "Fetching must not create a local branch.")

            missing, _ = self.call_cli(
                "task", "repository", "edit", task_id,
                "--repo", self.primary,
                "--branch", "remote-branch-from-task",
                "--branch-from", "missing-everywhere/branch",
                "--merge-target", "main",
                expected_status=2,
            )
            self.assert_failure(missing, "invalid_argument")
            self.assertIn("missing-everywhere/branch", missing["error"]["message"])
            fresh, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(fresh)["repositoryWorktrees"][0]["branchFrom"], f"origin/{remote_branch}")

            self.run_git(self.primary, "remote", "set-url", "origin", str(self.data_directory / "unreachable-origin.git"))
            unreachable, _ = self.call_cli(
                "task", "repository", "edit", task_id,
                "--repo", self.primary,
                "--branch", "remote-branch-from-task",
                "--branch-from", "unfetched/branch",
                "--merge-target", "main",
                expected_status=1,
            )
            self.assert_failure(unreachable, "operation_failed")
            self.assertIn("couldn't fetch 'unfetched/branch' from origin", unreachable["error"]["message"])
            self.run_git(self.primary, "remote", "set-url", "origin", str(remote))
            fresh, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(fresh)["repositoryWorktrees"][0]["branchFrom"], f"origin/{remote_branch}")

            # The remote branch moves ahead after it was fetched; starting must use the newer commit.
            newer_commit = self.run_git(
                self.primary, "commit-tree", "main^{tree}", "-p", remote_commit, "-m", "Advance remote-only branch-from fixture",
            ).strip()
            self.run_git(self.primary, "push", "--quiet", "origin", f"{newer_commit}:refs/heads/{remote_branch}")
            self.run_git(self.primary, "update-ref", tracking_ref, remote_commit)

            self.complete_fixture_turn(task_id)
            started, _ = self.call_cli("task", "get", task_id)
            started_record = self.assert_success(started)["repositoryWorktrees"][0]
            self.assertFalse(started_record["isPending"])
            self.assertEqual(started_record["branchFrom"], f"origin/{remote_branch}")
            worktree = Path(started_record["worktreePath"])
            self.assertTrue(worktree.is_dir())
            self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), newer_commit)
            upstream = subprocess.run(
                ["git", "-C", str(worktree), "config", "--get", "branch.remote-branch-from-task.remote"],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(upstream.stdout.strip(), "", "The remote branch-from must not become the task branch's upstream.")
        finally:
            self.run_git(self.primary, "remote", "remove", "origin")
    # case-contract: test_task_repository_default_branch_from_uses_fresh_origin | With no branch-from given, a repository without an origin remote keeps its local default branch, while a repository whose origin has the default branch stores origin's remote-tracking branch as the pending branch-from. Starting the task fetches origin first, so the worktree starts from origin's latest commit even when the local default branch and its remote-tracking ref are stale and the local branch holds unpushed commits, without making the remote branch the task branch's upstream. When origin can't be reached at start, the task still starts from the last fetched origin commit.
    def test_task_repository_default_branch_from_uses_fresh_origin(self):
        without_origin = self.create_repo_task("Default branch-from without origin", [self.primary])
        self.assertEqual(without_origin["repositoryWorktrees"][0]["branchFrom"], "main")

        remote = self.data_directory / "default-branch-from-origin.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
        self.run_git(self.primary, "remote", "add", "origin", str(remote))
        try:
            self.run_git(self.primary, "push", "--quiet", "origin", "main")
            stale_tracking = self.run_git(self.primary, "rev-parse", "refs/remotes/origin/main").strip()
            task = self.create_repo_task("Default branch-from from origin", [self.primary])
            task_id = task["id"]
            # Publishing on Review would set the branch's upstream itself and hide a tracked base.
            self.set_pull_request_mode(task_id, "manual")
            pending = task["repositoryWorktrees"][0]
            self.assertTrue(pending["isPending"])
            self.assertEqual(pending["branchFrom"], "origin/main")
            fresh, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(fresh)["repositoryWorktrees"][0]["branchFrom"], "origin/main")

            # Origin moves ahead without this repository fetching, and local main gains an unpushed commit.
            clone = self.data_directory / "default-branch-from-clone"
            subprocess.run(["git", "clone", "--quiet", "--branch", "main", str(remote), str(clone)], check=True, capture_output=True, text=True)
            self.run_git(clone, "config", "user.name", "Playhouse Bridge Test")
            self.run_git(clone, "config", "user.email", "playhouse-bridge-test@example.invalid")
            (clone / "origin-only.txt").write_text("Landed on origin after the task was created.\n", encoding="utf-8")
            self.run_git(clone, "add", "origin-only.txt")
            self.run_git(clone, "commit", "-m", "Origin-only commit")
            self.run_git(clone, "push", "--quiet", "origin", "main")
            origin_head = self.run_git(clone, "rev-parse", "HEAD").strip()
            (self.primary / "local-only.txt").write_text("Unpushed local commit.\n", encoding="utf-8")
            self.run_git(self.primary, "add", "local-only.txt")
            self.run_git(self.primary, "commit", "-m", "Local-only commit")
            local_head = self.run_git(self.primary, "rev-parse", "main").strip()
            self.assertEqual(self.run_git(self.primary, "rev-parse", "refs/remotes/origin/main").strip(), stale_tracking)

            self.complete_fixture_turn(task_id)
            started = self.assert_success(self.call_cli("task", "get", task_id)[0])["repositoryWorktrees"][0]
            self.assertFalse(started["isPending"])
            self.assertEqual(started["branchFrom"], "origin/main")
            worktree = Path(started["worktreePath"])
            self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), origin_head)
            self.assertTrue((worktree / "origin-only.txt").is_file())
            self.assertFalse((worktree / "local-only.txt").exists(), "The local-only commit must not be the task's base.")
            self.assertEqual(self.run_git(self.primary, "rev-parse", "refs/remotes/origin/main").strip(), origin_head)
            self.assertEqual(self.run_git(self.primary, "rev-parse", "main").strip(), local_head, "Starting must not move local main.")
            upstream = subprocess.run(
                ["git", "-C", str(worktree), "config", "--get", f"branch.{started['branch']}.remote"],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(upstream.stdout.strip(), "", "The origin base must not become the task branch's upstream.")

            offline = self.create_repo_task("Default branch-from while offline", [self.primary])
            offline_id = offline["id"]
            self.set_pull_request_mode(offline_id, "manual")
            self.assertEqual(offline["repositoryWorktrees"][0]["branchFrom"], "origin/main")
            self.run_git(self.primary, "remote", "set-url", "origin", str(self.data_directory / "unreachable-origin.git"))
            self.complete_fixture_turn(offline_id)
            offline_started = self.assert_success(self.call_cli("task", "get", offline_id)[0])["repositoryWorktrees"][0]
            self.assertFalse(offline_started["isPending"])
            self.assertEqual(offline_started["branchFrom"], "origin/main")
            self.assertEqual(self.run_git(Path(offline_started["worktreePath"]), "rev-parse", "HEAD").strip(), origin_head)
        finally:
            self.run_git(self.primary, "remote", "remove", "origin")
    # case-contract: test_task_repository_edit_rejects_stale_validation_after_removal | If a pending repository is removed while its settings are being validated, the stale edit is rejected and the newer repository removal and context root remain saved.
    def test_task_repository_edit_rejects_stale_validation_after_removal(self):
        task = self.create_repo_task("Concurrent repository edit", [self.primary], roots=[str(self.custom)])
        task_id = task["id"]
        initial = task["repositoryWorktrees"][0]
        command = [
            "task", "repository", "edit", task_id,
            "--repo", self.primary,
            "--branch", "stale-edit",
            "--branch-from", initial["branchFrom"],
            "--merge-target", initial["mergeTarget"],
        ]
        barrier = GitConfigReadBarrier(self.primary)
        stale_process = None
        continue_stale_process = False
        try:
            stale_process = self.start_cli(*command)
            barrier.wait_for_reader()
            removed, _ = self.call_cli("task", "repository", "remove", task_id, "--repo", self.primary)
            removed_record = self.assert_success(removed)
            self.assertEqual(removed_record["repositoryWorktrees"], [])
            self.assertEqual(removed_record["workspaceRoots"], [str(self.custom)])
            self.assertEqual(removed_record["contextFolders"], [str(self.custom)])
            continue_stale_process = True
        finally:
            barrier.release()
            if not continue_stale_process and stale_process is not None and stale_process.poll() is None:
                stale_process.terminate()
                try:
                    stale_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    stale_process.kill()
                    stale_process.communicate()
        self.assertIsNotNone(stale_process)
        stale, _ = self.finish_cli(stale_process, command, expected_status=1)
        self.assert_failure(stale, "invalid_transition")
        fresh, _ = self.call_cli("task", "get", task_id)
        fresh_record = self.assert_success(fresh)
        self.assertEqual(fresh_record["repositoryWorktrees"], [])
        self.assertEqual(fresh_record["workspaceRoots"], [str(self.custom)])
        self.assertEqual(fresh_record["contextFolders"], [str(self.custom)])
    # case-contract: test_task_repository_removal_preserves_state_on_dirty_worktree | Removing one of two pending repositories leaves the remaining repository in task context and remembered settings, while preserving the removed source repository; the next task restores only the remaining remembered repository. Removing a pending repository preserves other context folders; removing a clean managed worktree through the GUI waits for an active turn, while the task repository API removes it from context immediately and defers clean worktree deletion until the turn releases; a bridge service restart preserves the cleanup intent and a fresh request completes removal; if the active turn writes files before release, deferred cleanup preserves that worktree and its changes; a dirty worktree rejects removal and preserves its task record and files.
    def test_task_repository_removal_preserves_state_on_dirty_worktree(self):
        sole = self.create_repo_task("Two repository removal", [self.primary, self.secondary])
        sole_removed, _ = self.call_cli("task", "repository", "remove", sole["id"], "--repo", self.primary)
        sole_result = self.assert_success(sole_removed)
        self.assertEqual([item["repositoryPath"] for item in sole_result["repositoryWorktrees"]], [str(self.secondary)])
        self.assertEqual(sole_result["workspaceRoots"], [str(self.secondary)])
        self.assertEqual(sole_result["contextFolders"], [])
        self.assertTrue(self.primary.is_dir(), "Removing a pending repository must preserve its source repository.")
        remembered, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(remembered)["lastSelectedRepositories"], [str(self.secondary)])

        pending = self.create_repo_task("Pending repository removal", [self.primary], roots=[self.custom])
        pending_id = pending["id"]
        removed_pending, _ = self.call_cli("task", "repository", "remove", pending_id, "--repo", self.primary)
        pending_result = self.assert_success(removed_pending)
        self.assertEqual(pending_result["repositoryWorktrees"], [])
        self.assertEqual(pending_result["contextFolders"], [str(self.custom)])
        self.assertEqual(pending_result["workspaceRoots"], [str(self.custom)])
        self.assertTrue(self.primary.is_dir(), "Removing a pending repository must preserve its source repository.")
        remembered, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(remembered)["lastSelectedRepositories"], [])

        clean_active = self.create_repo_task("Clean active repository removal", [self.alternate], roots=[self.custom])
        clean_active_id = clean_active["id"]
        self.complete_fixture_turn(clean_active_id)
        clean_active, _ = self.call_cli("task", "get", clean_active_id)
        clean_record = self.assert_success(clean_active)["repositoryWorktrees"][0]
        clean_worktree = Path(clean_record["worktreePath"])
        clean_lock = ConversationTurnLockBarrier(self.data_directory, clean_active_id)
        clean_removed, _ = self.call_cli("task", "repository", "remove", clean_active_id, "--repo", self.alternate)
        self.assertEqual(self.assert_success(clean_removed)["repositoryWorktrees"], [])
        self.assertTrue(clean_worktree.exists())
        scheduled = next(
            event for event in self.diagnostic_events()
            if event.get("event") == "workspace.repository.deferred_removal_scheduled"
            and event.get("taskID") == clean_active_id
        )
        bridge_pid = int(scheduled["processID"])
        try:
            os.kill(bridge_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        service_exit_deadline = time.monotonic() + 5
        while time.monotonic() < service_exit_deadline:
            try:
                os.kill(bridge_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            self.fail("The isolated bridge service should exit before testing durable cleanup recovery.")
        clean_lock.release()
        self.call_cli("task", "get", clean_active_id)
        clean_deadline = time.monotonic() + 30
        while clean_worktree.exists() and time.monotonic() < clean_deadline:
            time.sleep(0.02)
        self.assertFalse(clean_worktree.exists(), "Deferred cleanup should remove an unchanged managed worktree after the turn releases.")

        active = self.create_repo_task("Started repository removal", [self.secondary], roots=[self.custom])
        active_id = active["id"]
        self.complete_fixture_turn(active_id)
        active, _ = self.call_cli("task", "get", active_id)
        record = self.assert_success(active)["repositoryWorktrees"][0]
        self.assertTrue(record["createdByPlayhouse"], "Started task worktrees should be eligible for cleanup after the turn reservation releases.")
        worktree = Path(record["worktreePath"])
        dirty_file = worktree / "repository-removal-dirty.txt"
        dirty_file.write_text("keep this worktree intact\n", encoding="utf-8")

        rejected, _ = self.call_cli(
            "task", "repository", "remove", active_id, "--repo", self.secondary,
            expected_status=1,
        )
        self.assert_failure(rejected, "operation_failed")
        retained, _ = self.call_cli("task", "get", active_id)
        retained_result = self.assert_success(retained)
        self.assertEqual(len(retained_result["repositoryWorktrees"]), 1)
        self.assertEqual(retained_result["repositoryWorktrees"][0]["worktreePath"], str(worktree))
        self.assertEqual(retained_result["workspaceRoots"], [str(worktree), str(self.custom)])
        self.assertTrue(dirty_file.is_file())

        dirty_file.unlink()
        lock_barrier = ConversationTurnLockBarrier(self.data_directory, active_id)
        removed_active, _ = self.call_cli("task", "repository", "remove", active_id, "--repo", self.secondary)
        active_result = self.assert_success(removed_active)
        self.assertEqual(active_result["repositoryWorktrees"], [])
        self.assertEqual(active_result["contextFolders"], [str(self.custom)])
        self.assertEqual(active_result["workspaceRoots"], [str(self.custom)])
        self.assertTrue(worktree.exists(), "The active turn's cwd must remain until the reservation is released.")
        still_attached, _ = self.call_cli("task", "get", active_id)
        self.assertEqual(self.assert_success(still_attached)["repositoryWorktrees"], [])
        in_flight_file = worktree / "written-during-removal.txt"
        in_flight_file.write_text("preserve edits made before the turn ended\n", encoding="utf-8")
        lock_barrier.release()
        self.call_cli("task", "get", active_id)
        cleanup_deadline = time.monotonic() + 30
        while not any(event.get("event") == "workspace.repository.deferred_removal_kept_dirty" for event in self.diagnostic_events()) and time.monotonic() < cleanup_deadline:
            time.sleep(0.02)
        self.assertTrue(any(event.get("event") == "workspace.repository.deferred_removal_kept_dirty" for event in self.diagnostic_events()), "Deferred cleanup should report that active-turn edits were preserved.")
        self.assertTrue(worktree.exists(), "Deferred cleanup must preserve a worktree dirtied by the active turn.")
        self.assertTrue(in_flight_file.is_file(), "Deferred cleanup must preserve files written by the active turn.")

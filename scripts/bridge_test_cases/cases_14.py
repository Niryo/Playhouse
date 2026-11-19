from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases14:
    # case-contract: test_claude_outcome_reminder_rejects_user_questions | A successful Claude turn with an unanswered AskUserQuestion stays In Progress without outcome nudges; after the user answers, the next successful turn receives a hidden CLI status nudge. A question raised during that nudge is rejected through Claude's control protocol with completed, waiting-response, and keep-working instructions, which fails the private turn; the rejected question and the private rejection instructions stay out of the transcript, while a prompt that applied the user's answer is stored and shown as sent. Playhouse then stops driving the work and marks the task Blocked naming that reason.
    def test_claude_outcome_reminder_rejects_user_questions(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-outcome-reminder-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Claude reminder question", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        initial, initial_events = self.call_cli(
            "conversation", "send", task_id, "--message", "Finish while a structured question remains pending.",
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assert_success(initial)
        questions = [event for event in initial_events if event.get("type") == "user_input"]
        self.assertEqual(len(questions), 1, "The successful turn should leave its structured question pending.")
        pending, _ = self.call_cli("conversation", "history", task_id,
                                   extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)})
        pending_history = self.assert_success(pending)
        self.assertIsNotNone(pending_history.get("pendingUserInputRequest"))
        self.assertFalse(any("Playhouse internal outcome nudge:" in turn.get("userText", "")
                             for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress")
        request = questions[0]["payload"]["userInputRequest"]
        answered, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"], "--answer", "question-1=Blue",
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assert_success(answered)
        answered_history, _ = self.call_cli("conversation", "history", task_id,
                                            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)})
        self.assertIsNone(self.assert_success(answered_history).get("pendingUserInputRequest"))
        followup, followup_events = self.call_cli(
            "conversation", "send", task_id, "--message", "Continue after answering.",
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(followup)["messages"])
        events = initial_events + followup_events
        self.assertEqual(sum(event.get("type") == "user_input" for event in events), 1,
                         "Questions from private Claude reminders must not be emitted as user input.")
        turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
        nudges = [turn for turn in turns if "Playhouse internal outcome nudge:" in turn.get("userText", "")]
        self.assertEqual(len(nudges), 1, "Rejecting the question fails the private turn, so Playhouse stops driving the task.")
        self.assertTrue(all("task outcome command" in turn["userText"] for turn in nudges))
        rejections = Path(str(executable) + ".private-reminder-question-rejection").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(rejections), 1)
        self.assertTrue(all(all(outcome in message for outcome in ("completed", "waiting-response", "keep working in this turn")) for message in rejections))
        history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        safe_history = self.assert_success(history)
        self.assertIsNone(safe_history.get("pendingUserInputRequest"))
        serialized_history = json.dumps(safe_history)
        recovery_prompts = [message["text"] for message in safe_history["messages"]
                            if message["role"] == "user" and "Answer: Blue" in message["text"]]
        self.assertEqual(len(recovery_prompts), 1, "The prompt that applied the answer is stored once.")
        self.assertIn("Question: Which color should I use?", recovery_prompts[0], "The answer's prompt is stored as sent.")
        self.assertNotIn("This is a private Playhouse status nudge.", serialized_history,
                         "Claude's private rejection instructions must not enter persisted conversation history.")
        settled = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(settled["status"], "Blocked")
        self.assertIn("couldn't run the private turn", settled.get("statusMessage") or "",
                      "The Blocked reason must name why Playhouse stopped driving the work.")
    # case-contract: test_claude_empty_question_request_is_rejected | Claude AskUserQuestion requests with no questions are rejected through the control protocol, fail the turn, and mark the task Blocked; the UI shows the blocked task and its intervention indicator.
    def test_claude_empty_question_request_is_rejected(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-empty-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Empty Claude question", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask an empty structured question.",
            expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(failed.get("ok", True), failed)
        self.assertIn("question", failed.get("error", {}).get("message", "").lower())
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Blocked")
    # case-contract: test_claude_pending_question_recovers_after_provider_process_restarts | Claude's pending AskUserQuestion is persisted and restored from fresh CLI/XPC history after the provider turn ends; the task remains Waiting Response while unanswered, and answering resumes the saved Claude session in In Progress, delivers the answer, stores and shows the prompt that carried it as sent, clears pending state, and returns to Waiting Response. While the recovery turn applying the answer runs, the answered question is no longer pending in history or shown in the reopened conversation, which still shows the question that started it, and the task is In Progress; if that recovery dies mid-turn, the question returns for retry with the task in Waiting Response, and answering again succeeds.
    def test_claude_pending_question_recovers_after_provider_process_restarts(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-restart-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Restart-safe Claude question", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.",
            expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(failed.get("ok", True), failed)
        restored, _ = self.call_cli("conversation", "history", task_id)
        restored_history = self.assert_success(restored)
        pending = restored_history.get("pendingUserInputRequest")
        self.assertEqual(pending["questions"][0]["question"], "Which color should I use?")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")
        rejected, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=",
            expected_status=2,
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(rejected.get("ok", True), rejected)
        still_pending, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(still_pending).get("pendingUserInputRequest"), pending)
        recovery_pause = Path(str(executable) + ".recovery-pause")
        recovery_ready = Path(str(executable) + ".recovery-ready")
        recovery_release = Path(str(executable) + ".recovery-release")
        recovery_pause.write_text("Hold the recovery turn open.\n", encoding="utf-8")
        answer_process = self.start_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=Green",
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        try:
            deadline = time.monotonic() + 20
            while not recovery_ready.exists() and answer_process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(recovery_ready.exists(), "The fixture should hold the recovery turn open.")
            applying = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
            self.assertIsNone(
                applying.get("pendingUserInputRequest"),
                "An answered question must not stay pending while its recovery turn runs.",
            )
            self.assertTrue(
                any(m["role"] == "user" and m["text"] == "Ask a restart-safe structured question." for m in applying["messages"]),
                "History read mid-recovery must still include the conversation saved before the answer.",
            )
            runtime = self.assert_success(self.call_cli("conversation", "runtime")[0])
            self.assertEqual(
                runtime.get("pendingUserInput", {}), {},
                "The daemon's runtime state must not keep offering an answered question while its recovery turn runs.",
            )
            # A window reopening the task reads one stored page, a separate path from the full history.
            applying_page = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80")[0])
            self.assertTrue(
                any(m["role"] == "user" and m["text"] == "Ask a restart-safe structured question." for m in applying_page["messages"]),
                "The newest history page read mid-recovery must still include the conversation saved before the answer.",
            )
            self.assertIsNone(
                applying_page.get("pendingUserInputRequest"),
                "A paged history read must not bring back the answered question while its recovery turn runs.",
            )
            self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress")
            # The recovery's Claude Code process dies mid-turn. Agents outlive a daemon restart,
            # so killing the daemon would not end the recovery.
            recovery_turn = [
                event for event in self.diagnostic_events() if event.get("event") == "claude.turn.started"
            ][-1]
            recovery_pid = int(recovery_turn["claudePID"])
            try:
                os.kill(recovery_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            exit_deadline = time.monotonic() + 5
            while time.monotonic() < exit_deadline:
                try:
                    os.kill(recovery_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                self.fail("The Claude Code process running the recovery turn should exit.")
            answer_process.communicate(timeout=30)
        finally:
            recovery_release.write_text("Release the orphaned recovery turn.\n", encoding="utf-8")
            if answer_process.poll() is None:
                answer_process.communicate(timeout=30)
        crashed = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        self.assertEqual(
            crashed.get("pendingUserInputRequest"), pending,
            "A recovery that dies mid-turn must show its question again for retry.",
        )
        crashed_page = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80")[0])
        self.assertEqual(
            crashed_page.get("pendingUserInputRequest"), pending,
            "A paged history read must also show the question again once its recovery has died.",
        )
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")
        for marker in (recovery_pause, recovery_ready, recovery_release):
            marker.unlink(missing_ok=True)
        accepted, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=Green",
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(accepted)["accepted"])
        resumed, _ = self.call_cli("conversation", "history", task_id)
        resumed_history = self.assert_success(resumed)
        self.assertTrue(any(message["text"] == "Recovered answer: Green." for message in resumed_history["messages"]))
        self.assertTrue(any(message["role"] == "user" and "Question: Which color should I use?\nAnswer: Green" in message["text"]
                            for message in resumed_history["messages"]), "The prompt that carried the answer is stored as sent.")
        self.assertNotIn("Answer: Green", self.assert_success(self.call_cli("task", "get", task_id)[0]).get("savedPrompt", ""))
        self.assertIsNone(resumed_history.get("pendingUserInputRequest"))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")
    # case-contract: test_claude_pending_plan_mode_question_recovers_in_plan_mode | A Claude AskUserQuestion asked during a Plan mode turn persists its mode; after its provider process ends, answering resumes the saved Claude session in Plan mode rather than silently downgrading to Code mode, relaunching the recovery turn with --permission-mode plan.
    def test_claude_pending_plan_mode_question_recovers_in_plan_mode(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-restart-plan-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Restart-safe Claude plan question", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--mode", "plan", "--message", "Ask a restart-safe structured question.",
            expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertFalse(failed.get("ok", True), failed)
        restored, _ = self.call_cli("conversation", "history", task_id)
        pending = self.assert_success(restored).get("pendingUserInputRequest")
        self.assertEqual(pending["mode"], "plan")
        accepted, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=Green",
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(accepted)["accepted"])
        recovery_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        recovery_arguments = recovery_history["turns"][-1]["arguments"]
        self.assertIn("--permission-mode", recovery_arguments)
        self.assertEqual(
            recovery_arguments[recovery_arguments.index("--permission-mode") + 1],
            "plan",
            "The recovered turn must continue in Plan mode, not silently downgrade to Code mode.",
        )
        resumed, _ = self.call_cli("conversation", "history", task_id)
        self.assertIsNone(self.assert_success(resumed).get("pendingUserInputRequest"))
    # case-contract: test_claude_background_agent_keeps_turn_open_until_resolved | A Claude background Agent/Task call renders a live subagent activity that stays in progress through its launch confirmation and intermediate progress, resolves only once its real completion notification arrives, and keeps the turn open until then instead of settling early. A status-only completion update is not shown as an agent result; the summary-bearing notification is persisted as one normal assistant message in the parent conversation, appears in the visible transcript as the agent's row (named, finished working, with an arrow) rather than a reply bubble, opens the report in the read-only agent window when clicked, and survives fresh CLI/XPC history reads and app reopening without duplication. A failed background agent remains inspectable as a failed activity, and its error summary is not added as an assistant result. When a background agent's notification wakes the parent after its result, the turn stays open through that resumed work, including when the last agent finishes while the woken parent is still streaming, and ends only with the parent's next result, keeping its final answer and both agent reports. A failed agent whose notification the running turn already consumed ends the send promptly instead of waiting for a wake. The system prompt Playhouse appends for Claude lets it run shell commands and agents in the foreground or background, forbids only processes detached with & or nohup, says it can end its response while background work runs instead of waiting and must report the outcome only after the background results, and no longer tells it to sleep, keep shell commands in the foreground, or keep its turn open for work it started.
    def test_claude_background_agent_keeps_turn_open_until_resolved(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-background-agent"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Claude background agent", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        env = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        command = ("conversation", "send", task_id, "--message", "Launch a background agent for this turn.")
        pause = Path(str(executable) + ".background-summary-pause")
        ready = Path(str(executable) + ".background-summary-ready")
        release = Path(str(executable) + ".background-summary-release")
        pause.write_text("Pause after status-only completion.\n", encoding="utf-8")
        process = self.start_cli(*command, extra_environment=env, binary_output=True)
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should pause after the status-only completion update.")
            self.assertIsNone(
                process.poll(),
                "The CLI send must remain active after Claude returns its parent result but before the background summary notification.",
            )
            interim_history = None
            interim_activity = None
            for _ in range(20):
                interim_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
                interim_history = self.assert_success(interim_response)
                interim_activity = next(a for a in interim_history["activities"] if a["childThreadID"] == "toolu_background_agent")
                if interim_activity["status"] == "inProgress":
                    break
                time.sleep(0.05)
            self.assertEqual(interim_activity["status"], "inProgress", "A status-only update must leave the agent active.")
            self.assertIsNone(interim_activity.get("backgroundTaskSummary"))
            self.assertFalse(
                any(message.get("phase") == "subagent_report" for message in interim_history["messages"]),
                "Progress detail must not appear as a completed assistant result before Claude sends its summary.",
            )
            release.write_text("Release summary notification.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {command}: {stderr!r}")
            output_lines = [line for line in stdout.decode("utf-8").splitlines() if line.strip()]
            self.assertTrue(output_lines, "The CLI should return a final result.")
            response = json.loads(output_lines[-1])
            events = [json.loads(line) for line in output_lines[:-1]]
        finally:
            release.write_text("Release summary after assertion failure.\n", encoding="utf-8")
            if process.poll() is None:
                process.communicate(timeout=30)
        result = self.assert_success(response)
        activity_updates = [
            event["payload"]["activity"] for event in events
            if event.get("type") == "activity" and event["payload"]["activity"].get("childThreadID") == "toolu_background_agent"
        ]
        self.assertGreaterEqual(len(activity_updates), 3, activity_updates)
        # The launch confirmation and the live task_progress update must leave the
        # activity running; only a terminal task_updated/task_notification may
        # resolve it, and once resolved it must not revert to inProgress.
        resolved_index = next(i for i, update in enumerate(activity_updates) if update["status"] != "inProgress")
        self.assertGreater(resolved_index, 0, "The launch confirmation must not resolve the activity: " + str(activity_updates))
        self.assertTrue(
            all(update["status"] == "inProgress" for update in activity_updates[:resolved_index]),
            activity_updates,
        )
        self.assertTrue(
            all(update["status"] == "completed" for update in activity_updates[resolved_index:]),
            activity_updates,
        )
        self.assertEqual(activity_updates[-1]["backgroundTaskID"], "bgtask-fixture-1")
        self.assertEqual(activity_updates[-1]["detail"], "Background check finished.")
        terminal_updates = [update for update in activity_updates if update["status"] == "completed"]
        self.assertTrue(terminal_updates, "The summary-bearing notification should resolve the agent.")
        self.assertEqual(terminal_updates[-1].get("backgroundTaskSummary"), "Background check finished.")
        self.assertTrue(any(message["text"] == "STARTED" for message in result["messages"]))
        history = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        activity = next(a for a in history["activities"] if a["childThreadID"] == "toolu_background_agent")
        self.assertEqual(activity["status"], "completed")
        self.assertEqual(activity["backgroundTaskID"], "bgtask-fixture-1")
        reports = [message for message in history["messages"] if message.get("phase") == "subagent_report"]
        self.assertEqual(len(reports), 1, "The completed background-agent result should be a single parent conversation message.")
        self.assertEqual(reports[0]["role"], "assistant")
        self.assertEqual(reports[0]["provider"], "claude")
        self.assertEqual(reports[0]["text"], "Background check finished.")
        fresh_history = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        fresh_reports = [message for message in fresh_history["messages"] if message.get("phase") == "subagent_report"]
        self.assertEqual(fresh_reports, reports, "Fresh XPC reads should preserve one stable result message without duplication.")
        launch_arguments = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"][0]["arguments"]
        system_prompt = launch_arguments[launch_arguments.index("--append-system-prompt") + 1]
        for guidance in [
            "Never detach a process with & or nohup",
            "in the foreground or with the Bash tool's run_in_background",
            "run Agent/Task calls in the foreground or in the background",
            "you can end your response instead of waiting",
            "Report the task outcome only after you have handled every background result",
        ]:
            self.assertIn(guidance, system_prompt, "Claude should be told how Playhouse handles background agents.")
        for contradiction in ["including long sleeps", "never end your turn while work you started is still running", "Never background a shell command"]:
            self.assertNotIn(contradiction, system_prompt, "Claude must not be told to block on background agents it launched.")

        failed_task_response, _ = self.call_cli(
            "task", "create", "--title", "Claude failed background agent", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        failed_task_id = self.assert_success(failed_task_response)["id"]
        failed_started = time.monotonic()
        failed_send, _ = self.call_cli(
            "conversation", "send", failed_task_id, "--message", "Launch a background agent failure case.",
            extra_environment=env,
        )
        self.assert_success(failed_send)
        self.assertLess(
            time.monotonic() - failed_started, 10,
            "A notification the running turn already consumed must not hold the turn open for a wake that never comes.",
        )
        failed_history = self.assert_success(self.call_cli("conversation", "history", failed_task_id, extra_environment=env)[0])
        failed_activity = next(a for a in failed_history["activities"] if a["childThreadID"] == "toolu_background_agent")
        self.assertEqual(failed_activity["status"], "failed")
        self.assertEqual(failed_activity["backgroundTaskSummary"], "Background check failed.")
        self.assertFalse(
            any(message.get("phase") == "subagent_report" for message in failed_history["messages"]),
            "A failed agent summary must not be presented as a successful assistant result.",
        )

        wake_task_response, _ = self.call_cli(
            "task", "create", "--title", "Claude woken parent", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        wake_task_id = self.assert_success(wake_task_response)["id"]
        wake_command = ("conversation", "send", wake_task_id, "--message", "Launch background agents wake the parent.")
        wake_pause = Path(str(executable) + ".background-wake-pause")
        wake_ready = Path(str(executable) + ".background-wake-ready")
        wake_release = Path(str(executable) + ".background-wake-release")
        wake_pause.write_text("Pause after the last notification arrives mid-work.\n", encoding="utf-8")
        wake_process = self.start_cli(*wake_command, extra_environment=env, binary_output=True)
        try:
            deadline = time.monotonic() + 20
            while not wake_ready.exists() and wake_process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(wake_ready.exists(), "The fixture should pause after the last notification arrives mid-work.")
            # Settling on the stale earlier result would end the send right after
            # this notification; give that regression time to show.
            settle_deadline = time.monotonic() + 2
            while wake_process.poll() is None and time.monotonic() < settle_deadline:
                time.sleep(0.05)
            self.assertIsNone(
                wake_process.poll(),
                "A parent woken by a background notification must keep the turn open until its next result.",
            )
            wake_release.write_text("Release the woken parent's final answer.\n", encoding="utf-8")
            wake_stdout, wake_stderr = wake_process.communicate(timeout=60)
            self.assertEqual(wake_process.returncode, 0, f"CLI exit mismatch for {wake_command}: {wake_stderr!r}")
        finally:
            wake_release.write_text("Release after assertion failure.\n", encoding="utf-8")
            if wake_process.poll() is None:
                wake_process.communicate(timeout=30)
        wake_lines = [line for line in wake_stdout.decode("utf-8").splitlines() if line.strip()]
        wake_result = self.assert_success(json.loads(wake_lines[-1]))
        self.assertTrue(any(message["text"] == "WAKE FINAL" for message in wake_result["messages"]), wake_result["messages"])
        wake_history = self.assert_success(self.call_cli("conversation", "history", wake_task_id, extra_environment=env)[0])
        wake_texts = [message["text"] for message in wake_history["messages"] if message["role"] == "assistant"]
        self.assertIn("WAKE RESUMED", wake_texts)
        self.assertEqual(
            [message for message in wake_history["messages"] if message["role"] == "assistant" and message.get("phase") != "subagent_report"][-1]["text"],
            "WAKE FINAL",
            "The woken parent's final answer should be the turn's last assistant message.",
        )
        wake_reports = sorted(message["text"] for message in wake_history["messages"] if message.get("phase") == "subagent_report")
        self.assertEqual(wake_reports, ["Reviewer A finished.", "Reviewer B finished."])
        self.assertTrue(
            any(activity["id"] == "toolu_wake_read" for activity in wake_history["activities"]),
            "Tool work the woken parent ran should be recorded in the turn.",
        )
    # case-contract: test_claude_background_shell_keeps_turn_open_through_wake | A Claude Bash call launched with run_in_background stays an in-progress activity after its launch confirmation and keeps the turn open after Claude's result while the shell runs, and still after the shell's notification empties the background task list, until the parent turn Claude Code wakes to deliver that notification sends its own result. The woken turn's answer is the final answer, the outcome it reports moves the task to Review without private outcome reminders, and the shell's completion resolves its activity with the command status without becoming an agent report. When the shell finishes before Claude's first result, so the woken turn starts before that result arrives, the turn waits for both results.
    def test_claude_background_shell_keeps_turn_open_through_wake(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-background-shell"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        created, _ = self.call_cli(
            "task", "create", "--title", "Claude background shell", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(created)["id"]
        stage = {name: Path(f"{executable}.background-shell-{name}") for name in [
            "running-pause", "running-ready", "running-release", "wake-pause", "wake-ready", "wake-release",
            "second-result-pause", "second-result-ready", "second-result-release",
        ]}
        stage["running-pause"].write_text("Pause while the shell runs.\n", encoding="utf-8")
        stage["wake-pause"].write_text("Pause between the shell's notification and the woken turn.\n", encoding="utf-8")

        def wait_for(path):
            deadline = time.monotonic() + 20
            while not path.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(path.exists(), f"The fixture should reach {path.name}.")
            # Give a premature settle time to end the send before asserting it is open.
            time.sleep(0.5)

        command = ("conversation", "send", task_id, "--message", "Launch a background shell for this turn.")
        process = self.start_cli(*command, extra_environment=env)
        try:
            wait_for(stage["running-ready"])
            self.assertIsNone(process.poll(), "The send must stay open while a background shell runs after Claude's result.")
            running = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
            shell = next(a for a in running["activities"] if a["id"] == "toolu_background_shell")
            self.assertEqual(shell["status"], "inProgress", "The launch confirmation must not resolve a background shell.")
            stage["running-release"].write_text("Finish the shell.\n", encoding="utf-8")
            wait_for(stage["wake-ready"])
            self.assertIsNone(
                process.poll(),
                "The send must stay open after the shell's notification until Claude's woken turn reports its result.",
            )
            self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress")
            stage["wake-release"].write_text("Start the woken turn.\n", encoding="utf-8")
            response, events = self.finish_cli(process, command, timeout=60)
        finally:
            stage["running-release"].write_text("Release after failure.\n", encoding="utf-8")
            stage["wake-release"].write_text("Release after failure.\n", encoding="utf-8")
            if process.poll() is None:
                process.communicate(timeout=30)
        self.assert_success(response)
        self.assertEqual([e["payload"]["text"] for e in events if e["type"] == "assistant_final"], ["SHELL HANDLED"])
        self.assertEqual(
            self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Review",
            "The outcome Claude reports in its woken turn should be honored.",
        )
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        shell = next(a for a in history["activities"] if a["id"] == "toolu_background_shell")
        self.assertEqual(shell["status"], "completed")
        self.assertEqual(shell["backgroundTaskID"], "bgshell-fixture-1")
        self.assertIn("completed (exit code 0)", shell["detail"])
        self.assertIsNone(shell.get("backgroundTaskSummary"), "A shell's status line is not an agent result.")
        self.assertFalse(any(m.get("phase") == "subagent_report" for m in history["messages"]))
        self.assertEqual(
            [m["text"] for m in history["messages"] if m["role"] == "assistant"][-1], "SHELL HANDLED",
            "The woken turn's answer should be the turn's last assistant message.",
        )

        early_created, _ = self.call_cli(
            "task", "create", "--title", "Claude early background shell", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        early_id = self.assert_success(early_created)["id"]
        for name in ("running-pause", "wake-pause"):
            stage[name].unlink()
        stage["second-result-pause"].write_text("Pause between the first and the woken turn's results.\n", encoding="utf-8")
        early_command = ("conversation", "send", early_id, "--message", "Launch a background shell that finishes early.")
        process = self.start_cli(*early_command, extra_environment=env)
        try:
            wait_for(stage["second-result-ready"])
            self.assertIsNone(
                process.poll(),
                "The first turn's result must not end the send while the woken turn that started before it is unfinished.",
            )
            stage["second-result-release"].write_text("Send the woken turn's result.\n", encoding="utf-8")
            early, early_events = self.finish_cli(process, early_command, timeout=60)
        finally:
            stage["second-result-release"].write_text("Release after failure.\n", encoding="utf-8")
            if process.poll() is None:
                process.communicate(timeout=30)
        self.assert_success(early)
        self.assertEqual(
            [e["payload"]["text"] for e in early_events if e["type"] == "assistant_final"], ["SHELL HANDLED"],
            "When the woken turn starts before Claude's first result, the turn must wait for both results.",
        )
        self.assertEqual(self.assert_success(self.call_cli("task", "get", early_id)[0])["status"], "Review")
        recorded = json.loads(Path(f"{executable}.history").read_text(encoding="utf-8"))["turns"]
        self.assertFalse(
            any("previous request finished without reporting" in (t.get("userText") or "") for t in recorded),
            "An outcome reported in the woken turn must not trigger private outcome reminders.",
        )
    # case-contract: test_claude_stopping_outcome_decides_over_background_work | A Claude turn that reports completed and then leaves a background shell running, a dev server, settles in Review as soon as Claude's result arrives, without waiting for a notification that never comes and without a recovery prompt. A completed outcome reported while a background agent is still running does not settle the turn: the task stays In Progress while the agent runs, and when the woken parent turn then does more work and ends without a new report, the earlier outcome is treated as stale, so the task does not reach Review; Playhouse sends exactly one recovery prompt and the outcome reported in it places the task in Waiting Response. When Claude Code starts the woken turn for a finished background shell and then stays silent, with no outcome reported and no queued follow-up, Playhouse's backstop ends the wait and the same single recovery prompt decides the task's column instead of leaving it In Progress. The UI shows each task in the matching column and the recovery prompt in the transcript.
    def test_claude_stopping_outcome_decides_over_background_work(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-stopping-outcome"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {
            "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable),
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS": "2",
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS": "3",
        }
        nudge_marker = "playhouse internal outcome nudge:"

        def create(title):
            created, _ = self.call_cli(
                "task", "create", "--title", title, "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
            )
            return self.assert_success(created)["id"]

        def status(task_id):
            return self.assert_success(self.call_cli("task", "get", task_id)[0])["status"]

        def nudges():
            turns = json.loads(Path(f"{executable}.history").read_text(encoding="utf-8"))["turns"]
            return [turn for turn in turns if nudge_marker in (turn.get("userText") or "").lower()]

        server_id = create("Claude dev server")
        server_command = ("conversation", "send", server_id, "--message", "Please leave-dev-server-running.")
        server = self.start_cli(*server_command, extra_environment=env)
        try:
            server_response, _ = self.finish_cli(server, server_command, timeout=30)
        finally:
            if server.poll() is None:
                server.communicate(timeout=30)
        self.assert_success(server_response)
        self.assertTrue(Path(f"{executable}.dev-server-result-sent").exists())
        self.assertEqual(status(server_id), "Review", "A reported outcome settles the task even with a shell left running.")
        self.assertEqual(len(nudges()), 0, "A reported stopping outcome needs no recovery prompt.")

        early_id = create("Claude early report")
        pause = Path(f"{executable}.early-report-pause")
        ready = Path(f"{executable}.early-report-ready")
        release = Path(f"{executable}.early-report-release")
        pause.write_text("Pause while the background agent runs.\n", encoding="utf-8")
        early_command = ("conversation", "send", early_id, "--message", "Please report-early-then-continue.")
        early = self.start_cli(*early_command, extra_environment=env)
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and early.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should pause after its early outcome and result.")
            # Give a premature settle time to end the send before asserting it is open.
            time.sleep(0.5)
            self.assertIsNone(early.poll(), "A running background agent keeps the turn open even after an outcome report.")
            self.assertEqual(status(early_id), "In Progress", "The early outcome must not move the task while the agent runs.")
            release.write_text("Finish the background agent.\n", encoding="utf-8")
            early_response, _ = self.finish_cli(early, early_command, timeout=60)
        finally:
            release.write_text("Release after failure.\n", encoding="utf-8")
            if early.poll() is None:
                early.communicate(timeout=30)
        self.assert_success(early_response)
        pause.unlink(missing_ok=True)
        self.assertEqual(
            status(early_id), "Waiting Response",
            "The stale completed report must not reach Review; the recovery prompt's outcome decides.",
        )
        self.assertEqual(len(nudges()), 1, "The woken turn that ended unreported earns exactly one recovery prompt.")
        self.assertIn("This is the only recovery prompt", nudges()[0]["userText"])
        early_history = self.assert_success(self.call_cli("conversation", "history", early_id, extra_environment=env)[0])
        self.assertTrue(any("MORE WORK FOUND" in (m["text"] or "") for m in early_history["messages"] if m["role"] == "assistant"))

        silent_id = create("Claude silent wake")
        woken = Path(f"{executable}.consumed-wake-woken")
        silent_command = ("conversation", "send", silent_id, "--message", "Park a shell and then consumed wake notification.")
        silent = self.start_cli(*silent_command, extra_environment=env)
        try:
            deadline = time.monotonic() + 20
            while not woken.exists() and silent.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(woken.exists(), "The fixture should start the woken turn and then stay silent.")
            self.assertEqual(status(silent_id), "In Progress", "The silent wake is still waited for within its grace.")
            silent_response, _ = self.finish_cli(silent, silent_command, timeout=120)
        finally:
            if silent.poll() is None:
                silent.communicate(timeout=30)
        self.assert_success(silent_response)
        self.assertEqual(
            status(silent_id), "Waiting Response",
            "A lost wake ends in the column the recovery prompt's outcome names, not In Progress forever.",
        )
        self.assertEqual(len(nudges()), 2, "The lost wake earns exactly one recovery prompt of its own.")
    # case-contract: test_claude_steers_turn_parked_on_background_work | A Claude turn whose result is already out while a background shell keeps it open is still steerable: a queued follow-up's Steer reaches the running turn instead of silently staying queued, leaves the queue, appears in the conversation, and the turn waits for Claude's answer to it before the woken parent turn ends the send. The steered follow-up is recorded inside the turn it steered rather than as a turn of its own, so the transcript keeps it in order: while the turn runs and after it ends, the turn's work stays above its bubble, as does the answer given before it while it is shown, and what the turn said after it renders below it. Once Claude's answer to the steer has its own result while the shell still holds the turn open, that answer is already recorded in history exactly once, below the steered follow-up with the answer given before the steer above it, and stays shown rather than living only in the stream; after the turn ends both earlier answers are kept once as commentary and only the woken parent turn's answer is final.
    def test_claude_steers_turn_parked_on_background_work(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-parked-steer"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        created, _ = self.call_cli(
            "task", "create", "--title", "Claude parked steer", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(created)["id"]
        ready = Path(f"{executable}.parked-shell-ready")
        answer_ready = Path(f"{executable}.steered-answer-ready")
        Path(f"{executable}.steered-answer-pause").write_text("Hold after the steered answer's result.\n", encoding="utf-8")
        command = ("conversation", "send", task_id, "--message", "Launch a parked background shell for this turn.")
        process = self.start_cli(*command, extra_environment=env)
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should park the turn after its result while the shell runs.")
            # Let a premature settle end the send before asserting the turn is steerable.
            time.sleep(0.5)
            self.assertIsNone(process.poll(), "The send must stay open while the background shell runs.")
            queued = self.assert_success(self.call_cli(
                "conversation", "queue", task_id, "--message", "Check the other blocked tasks too.",
            )[0])
            steered = self.assert_success(self.call_cli(
                "conversation", "queue-steer", task_id, queued["id"], extra_environment=env,
            )[0])
            self.assertEqual(steered["text"], "Check the other blocked tasks too.")
            self.assertFalse(
                steered["queued"],
                "A turn held open by a background shell is still active, so its follow-up must steer it.",
            )
            self.assertEqual(
                self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0]), [],
                "An accepted steer must leave the queue.",
            )
            deadline = time.monotonic() + 20
            while not answer_ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(answer_ready.exists(), "Claude should answer the steer while the shell still runs.")
            self.assertIsNone(process.poll(), "The shell still holds the turn open after the steered answer.")
            # The answer's own result is out, but nothing settles the turn yet: the answer must
            # already be recorded, in order, rather than held until the turn ends.
            parked = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
            parked_texts = [message["text"] for message in parked["messages"]]
            for text in ("PARKED STARTED", "Check the other blocked tasks too.", "STEERED: Check the other blocked tasks too."):
                self.assertEqual(parked_texts.count(text), 1, f"{text!r} is recorded once while the turn is parked.")
            self.assertLess(parked_texts.index("PARKED STARTED"), parked_texts.index("Check the other blocked tasks too."),
                            "The answer given before the steer stays above it in history.")
            self.assertLess(parked_texts.index("Check the other blocked tasks too."),
                            parked_texts.index("STEERED: Check the other blocked tasks too."),
                            "Claude's answer to the steer follows it in history.")
            Path(f"{executable}.steered-answer-release").write_text("Release after the parked history check.\n", encoding="utf-8")
            response, events = self.finish_cli(process, command, timeout=60)
        finally:
            Path(f"{executable}.steered-answer-release").write_text("Release the fixture.\n", encoding="utf-8")
            if process.poll() is None:
                process.communicate(timeout=30)
        self.assert_success(response)
        self.assertIn(
            "Check the other blocked tasks too.",
            [e["payload"].get("message") for e in events if e["type"] == "steered_message"],
            "The running turn must stream the steered follow-up it accepted.",
        )
        self.assertEqual([e["payload"]["text"] for e in events if e["type"] == "assistant_final"], ["PARKED HANDLED"])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertIn(
            "Check the other blocked tasks too.",
            [message["text"] for message in history["messages"] if message["role"] == "user"],
            "The steered follow-up belongs in the conversation it steered.",
        )
        self.assertIn(
            "STEERED: Check the other blocked tasks too.",
            [message["text"] for message in history["messages"] if message["role"] == "assistant"],
            "Claude's answer to the steered follow-up belongs in the same turn.",
        )
        self.assertEqual(
            [message["text"] for message in history["messages"] if message["role"] == "assistant"][-1],
            "PARKED HANDLED",
            "The woken parent turn's answer still ends the turn.",
        )
        assistant = [(message.get("phase"), message["text"]) for message in history["messages"] if message["role"] == "assistant"]
        self.assertEqual(
            assistant[-3:],
            [("commentary", "PARKED STARTED"), ("commentary", "STEERED: Check the other blocked tasks too."), ("final_answer", "PARKED HANDLED")],
            "Answers recorded while the turn was parked are kept once, and only the turn's last answer is final.",
        )
        question, steer = (
            next(m for m in history["messages"] if m["role"] == "user" and m["text"] == text)
            for text in ("Launch a parked background shell for this turn.", "Check the other blocked tasks too.")
        )
        self.assertIsNotNone(steer.get("turnID"))
        self.assertEqual(
            steer.get("turnID"), question.get("turnID"),
            "The steered follow-up is recorded inside the turn it steered, not as a turn of its own.",
        )
    # case-contract: test_claude_steer_keeps_answer_written_before_it_above | A Claude turn that answers, then publishes a Playhouse progress report, which leaves that answer open, takes a steer at the report's tool boundary: the answer written before the steer is recorded once, above the steered message, as soon as the steer reaches Claude, rather than after Claude's reply to it, and the reply streams below the steer and stays shown while it is still being written instead of being cleared when the earlier answer is closed. After the turn ends the earlier answer stays above the steer as commentary and the reply is the final answer below it, each once. Only Claude Code keeps an answer open across a progress report, so Claude is the representative provider for this Playhouse-owned transcript order.
    def test_claude_steer_keeps_answer_written_before_it_above(self):
        env = self.install_claude_fixture("claude-fixture-reported-steer")
        executable = Path(env["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        created, _ = self.call_cli(
            "task", "create", "--title", "Claude reported steer", "--prompt", "Fixture task description.",
            "--root", self.primary, "--provider", "claude",
        )
        task_id = self.assert_success(created)["id"]
        steer_ready = Path(f"{executable}.reported-steer-ready")
        reply_ready = Path(f"{executable}.steer-reply-ready")
        reply_release = Path(f"{executable}.steer-reply-release")
        Path(f"{executable}.steer-reply-pause").write_text("Hold before the steer reply's result.\n", encoding="utf-8")
        steer_text = "Also cover the docs."
        command = ("conversation", "send", task_id, "--message", "Please answer, report progress, await steering.")
        process = self.start_cli(*command, extra_environment=env)
        try:
            deadline = time.monotonic() + 20
            while not steer_ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(steer_ready.exists(), "The fixture should answer, report progress and wait for a steer.")
            steered = self.assert_success(self.call_cli(
                "conversation", "steer", task_id, "--message", steer_text, extra_environment=env,
            )[0])
            self.assertTrue(steered["accepted"], "The running turn accepts the steer at its report's tool boundary.")
            deadline = time.monotonic() + 20
            while not reply_ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(reply_ready.exists(), "Claude should reply to the steer.")
            # The reply has arrived but its result has not: the answer before the steer is already
            # recorded, once and above the steer.
            texts = [m["text"] for m in self.assert_success(
                self.call_cli("conversation", "history", task_id, extra_environment=env)[0]
            )["messages"]]
            self.assertEqual(texts.count("REPORTED ANSWER"), 1, "The answer before the steer is recorded once.")
            self.assertEqual(texts.count(steer_text), 1, "The steer is recorded once.")
            self.assertLess(texts.index("REPORTED ANSWER"), texts.index(steer_text),
                            "The answer written before the steer is recorded above it.")
            reply_release.write_text("Release after the history check.\n", encoding="utf-8")
            response, events = self.finish_cli(process, command, timeout=60)
        finally:
            reply_release.write_text("Release the fixture.\n", encoding="utf-8")
            if process.poll() is None:
                process.communicate(timeout=30)
        self.assert_success(response)
        reply = f"STEER REPLY: {steer_text}"
        kinds = [(e["type"], e["payload"].get("message") or e["payload"].get("text")) for e in events
                 if e["type"] in ("steered_message", "assistant_progress", "assistant_final")]
        self.assertEqual(
            kinds, [("assistant_progress", "REPORTED ANSWER"), ("steered_message", steer_text), ("assistant_final", reply)],
            "The answer before the steer streams as closed before the steer, and the reply as the final answer after it.",
        )
        messages = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])["messages"]
        turn = [(m["role"], m.get("phase"), m["text"]) for m in messages
                if m["text"] in ("REPORTED ANSWER", steer_text, reply)]
        self.assertEqual(
            turn, [("assistant", "commentary", "REPORTED ANSWER"), ("user", None, steer_text), ("assistant", "final_answer", reply)],
            "After the turn the answer before the steer stays above it and the reply is the final answer below it, each once.",
        )
    # case-contract: test_claude_settles_turn_after_consumed_wake_notification | When Claude Code starts the provider turn that would deliver a finished background task's notification and then says nothing at all, Playhouse settles that turn on its own instead of leaving it open and the task In Progress forever: a follow-up queued while the turn was still parked stays queued through the silent wake, the send finishes and the task reaches Review, and that follow-up is then delivered in its own turn rather than stranded in the queue. A woken turn that is alive and merely slow to speak is not cut off by that backstop: it stays quiet past the grace a consumed notification gets and still ends the turn on its own answer.
    def test_claude_settles_turn_after_consumed_wake_notification(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-consumed-wake"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        # Short graces keep the case fast; which silence settles the turn and
        # which one waits for Claude does not depend on their lengths.
        env = {
            "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable),
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS": "4",
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS": "24",
            "PLAYHOUSE_E2E_CLAUDE_SLOW_WOKEN_SILENCE_SECONDS": "8",
        }
        created, _ = self.call_cli(
            "task", "create", "--title", "Claude consumed wake", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(created)["id"]
        pause = Path(f"{executable}.consumed-wake-pause")
        parked = Path(f"{executable}.consumed-wake-ready")
        release = Path(f"{executable}.consumed-wake-release")
        woken = Path(f"{executable}.consumed-wake-woken")
        pause.write_text("Playhouse test owns this Claude fixture marker.\n", encoding="utf-8")
        command = ("conversation", "send", task_id, "--message", "Park a shell and then consumed wake notification.")
        process = self.start_cli(*command, extra_environment=env)
        try:
            deadline = time.monotonic() + 20
            while not parked.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(parked.exists(), "The fixture should park the turn after its result while the shell runs.")
            # The turn is still the active turn here, so this follow-up queues
            # rather than sending, and only a settled turn can ever deliver it.
            stranded = self.assert_success(self.call_cli(
                "conversation", "queue", task_id, "--message", "Then tell the story of the VM run.",
            )[0])
            self.assertIn(
                stranded["id"],
                [item["id"] for item in self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0])],
                "A follow-up sent while the parked turn is active must wait in the queue.",
            )
            release.write_text("Playhouse test owns this Claude fixture marker.\n", encoding="utf-8")
            deadline = time.monotonic() + 20
            while not woken.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(woken.exists(), "The fixture should start the woken turn and then stay silent.")
            self.assertIsNone(
                process.poll(),
                "The silent wake must not end the send before Playhouse's own grace period settles the turn.",
            )
            response, _ = self.finish_cli(process, command, timeout=120)
        finally:
            if process.poll() is None:
                process.communicate(timeout=30)
        self.assert_success(response)
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertIn(
            "WAKE SHELL STARTED",
            [message["text"] for message in history["messages"] if message["role"] == "assistant"],
            "Settling a stranded turn must keep the answer it already gave.",
        )
        deadline = time.monotonic() + 60
        remaining = None
        while time.monotonic() < deadline:
            remaining = [
                item["id"] for item
                in self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0])
            ]
            if stranded["id"] not in remaining:
                break
            time.sleep(0.2)
        self.assertNotIn(
            stranded["id"], remaining or [],
            "A follow-up queued while the turn was stranded must be delivered once Playhouse settles it.",
        )
        deadline = time.monotonic() + 60
        status = None
        while time.monotonic() < deadline:
            status = self.assert_success(self.call_cli("task", "get", task_id)[0])["status"]
            if status == "Review":
                break
            time.sleep(0.2)
        self.assertEqual(
            status, "Review",
            "A task whose turn was stranded by a silent wake must not stay In Progress once Playhouse settles it.",
        )
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertTrue(
            any(
                "BISCUIT-7" in (message["text"] or "")
                for message in history["messages"] if message["role"] == "assistant"
            ),
            "The delivered follow-up's own answer belongs in the conversation.",
        )

        # A woken turn that is alive and merely slow to speak must not be cut
        # off by that same backstop: it gets its own, far longer grace.
        slow_created, _ = self.call_cli(
            "task", "create", "--title", "Claude slow woken turn", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        slow_id = self.assert_success(slow_created)["id"]
        announced = Path(f"{executable}.slow-woken-announced")
        slow_command = ("conversation", "send", slow_id, "--message", "Park a shell and then a slow woken turn.")
        slow_process = self.start_cli(*slow_command, extra_environment=env)
        try:
            deadline = time.monotonic() + 30
            while not announced.exists() and slow_process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(announced.exists(), "The fixture should announce the woken turn before going quiet.")
            slow_response, _ = self.finish_cli(slow_process, slow_command, timeout=120)
        finally:
            if slow_process.poll() is None:
                slow_process.communicate(timeout=30)
        self.assert_success(slow_response)
        slow_history = self.assert_success(self.call_cli("conversation", "history", slow_id, extra_environment=env)[0])
        self.assertEqual(
            [message["text"] for message in slow_history["messages"] if message["role"] == "assistant"][-1],
            "SLOW WOKEN HANDLED",
            "A woken turn that stays quiet past the consumed-notification grace must still end on its own answer.",
        )
    # case-contract: test_claude_private_recovery_failure_fails_closed | If Claude fails while applying an answer after restart and echoes the answer or recovery instructions, Playhouse returns a generic error, preserves the pending question for retry while the task stays in Waiting Response, stores and shows the prompt that carried the answer as sent, and keeps it out of saved task state and diagnostics.
    def test_claude_private_recovery_failure_fails_closed(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-recovery-failure"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Claude private recovery failure", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )[0])
        task_id = task["id"]
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.",
            expected_status=1, extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        pending = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])["pendingUserInputRequest"]
        Path(str(executable) + ".recovery-error").write_text("Playhouse owns this Claude fixture marker.\n", encoding="utf-8")
        recovery_failure, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, pending["id"], "--answer", "question-1=Green",
            expected_status=1, extra_environment=env,
        )
        self.assert_failure(recovery_failure, "operation_failed")
        self.assertEqual(recovery_failure["error"]["message"], "The private answer could not be applied. Please answer the question again.")
        self.assertNotIn("Answer: Green", recovery_failure["error"]["message"])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertIsNotNone(history.get("pendingUserInputRequest"), "The failed answer must remain available for retry.")
        # The prompt that carried the answer was sent, so it is stored as sent.
        self.assertTrue(any(message["role"] == "user" and "Answer: Green" in message["text"] for message in history["messages"]))
        task_record = self.assert_success(self.call_cli("task", "get", task_id, extra_environment=env)[0])
        self.assertEqual(task_record["status"], "Waiting Response", "An unanswered question stays available for retry after a failed recovery attempt.")
        self.assertNotIn("Answer: Green", task_record.get("savedPrompt", ""))
        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("Answer: Green", diagnostics)
        self.assertNotIn("private recovery prompt", diagnostics.lower())

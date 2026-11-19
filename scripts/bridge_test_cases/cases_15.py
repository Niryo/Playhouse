from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases15:
    # case-contract: test_codex_pending_question_recovers_after_provider_process_restarts | Codex's pending structured question persists after its provider process exits and leaves the task in Waiting Response while unanswered; Playhouse restores it from fresh CLI/XPC history, keeps provider switching blocked, requires the user to re-enter the secret once, and applies the answers in one recovery turn. The live recovery stream and the stored transcript carry the recovery prompt, assistant response, activities, and diffs exactly as sent, including the re-entered secret with its surrounding whitespace, and the visible UI shows them immediately and after app restart; saved task state stays free of the secret. A later Codex turn keeps its own diff and response visible in refreshed CLI/UI history alongside the earlier recovery response. In one task, a no-secret recovery response remains visible after a later secret recovery. The first prompt, delivered before the provider exited although its send reported failure, is in history, never returns to the composer, and is not saved as an unsent draft.
    def test_codex_pending_question_recovers_after_provider_process_restarts(self):
        task_id = self.create_task("Restart-safe Codex question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-restart-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        # The create-time prompt is an unsent draft that a send leaves alone; clear it first.
        self.assert_success(self.call_cli("task", "draft", task_id, "--text", "")[0])
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.", expected_status=1,
            extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        pending, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        request = self.assert_success(pending).get("pendingUserInputRequest")
        self.assertEqual([item["id"] for item in request["questions"]], ["color", "token"])
        self.assertTrue(request["questions"][1]["isSecret"])
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "Ask a restart-safe structured question."
            for message in self.assert_success(pending)["messages"]
        ), "A send that failed after its turn started has still delivered its prompt to the conversation.")
        waiting_record = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(waiting_record["status"], "Waiting Response")
        self.assertFalse(waiting_record["hasUnsentDraft"], "A delivered prompt must not be kept as an unsent draft.")
        blocked_switch, _ = self.call_cli("conversation", "provider", task_id, "set", "claude", expected_status=1, extra_environment=env)
        self.assert_failure(blocked_switch, "invalid_transition")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "provider", task_id)[0])["provider"], "codex")
        answer_final, recovery_events = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"],
            "--answer", "color=Green", "--answer", "token= fixture-secret ", extra_environment=env,
        )
        self.assert_success(answer_final)
        recovery_answer = "Recovered answer: Green; private token fixture-secret was applied."
        self.assertIn(recovery_answer, json.dumps(recovery_events), "The live recovery stream carries the assistant answer as Codex sent it.")
        self.assertTrue(any(
            event.get("type") == "diff" and "fixture-secret" in event["payload"]["diff"] for event in recovery_events
        ), "Live recovery diffs are streamed as is.")
        provider_history = Path(str(executable) + ".history").read_text(encoding="utf-8")
        self.assertIn("fixture-secret", provider_history, "The freshly re-entered secret must reach the resumed provider turn.")
        completed, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        completed_history = self.assert_success(completed)
        self.assertIsNone(completed_history.get("pendingUserInputRequest"))
        self.assertTrue(any(
            message["role"] == "assistant" and message["text"] == recovery_answer
            for message in completed_history["messages"]
        ), "Persisted history stores the recovery response as Codex sent it.")
        recovery_prompts = [
            message["text"] for message in completed_history["messages"]
            if message["role"] == "user" and "Question: What is the private token?" in message["text"]
        ]
        self.assertEqual(len(recovery_prompts), 1, "The recovery prompt is stored once, as sent.")
        self.assertIn("Question: Which color should I use?\nAnswer: Green", recovery_prompts[0])
        self.assertIn("Answer:  fixture-secret", recovery_prompts[0], "The re-entered answer is stored exactly as sent.")
        self.assertTrue(any(
            activity["id"] == "item_private_recovery_command" and activity.get("output") == "fixture-secret"
            for activity in completed_history["activities"]
        ), "Recovery activities are stored as Codex sent them.")
        self.assertNotIn("fixture-secret", self.assert_success(self.call_cli("task", "get", task_id)[0]).get("savedPrompt", ""))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")

        follow_up, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Follow up after private recovery.", extra_environment=env,
        )
        self.assert_success(follow_up)
        follow_up_history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertTrue(any(
            message["role"] == "assistant" and message["text"] == "Follow-up after private recovery complete."
            for message in follow_up_history["messages"]
        ), "A normal Codex follow-up after recovery must remain visible in refreshed history.")
        self.assertIn("follow-up-visible-diff", follow_up_history["diff"]["unifiedDiff"],
            "A later Codex turn must retain its own file-change diff.")
        self.assertTrue(any(
            message["role"] == "assistant" and message["text"] == recovery_answer
            for message in follow_up_history["messages"]
        ), "The earlier recovery response stays in history after a later turn.")
    # case-contract: test_codex_secret_recovery_redaction_fails_closed | When Codex fails while applying recovered answers, Playhouse preserves the pending question while the task stays in Waiting Response, uses a generic visible error, stores and shows the sent recovery prompt as sent, and keeps the secret out of saved task state, diagnostics, and error text; later Codex thread read and resume failures do not affect history, which loads from Playhouse's own transcript store across fresh CLI/XPC reads and app restarts.
    def test_codex_secret_recovery_redaction_fails_closed(self):
        task_id = self.create_task("Fail-closed secret recovery", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-unassociated-restart-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a restart-safe structured question.",
            expected_status=1, extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        pending, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        request = self.assert_success(pending).get("pendingUserInputRequest")
        self.assertIsNotNone(request)
        Path(str(executable) + ".provider-error-async").write_text(
            "Playhouse owns this Codex fixture failure marker.\n", encoding="utf-8"
        )
        recovery_failure, _ = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"],
            "--answer", "color=Green", "--answer", "token=fixture-secret",
            expected_status=1, extra_environment=env,
        )
        self.assert_failure(recovery_failure, "operation_failed")
        self.assertNotIn("fixture-secret", recovery_failure["error"]["message"])
        self.assertNotIn("Answer: Green", recovery_failure["error"]["message"])

        fresh_history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(fresh_history)
        self.assertIsNotNone(history.get("pendingUserInputRequest"), "The failed recovery must leave the question available to retry.")
        recovery_prompt = "Question: What is the private token?\nAnswer: fixture-secret"
        self.assertTrue(any(
            message["role"] == "user" and recovery_prompt in message["text"]
            for message in history["messages"]
        ), "The prompt that carried the answers was sent, so it is stored as sent.")
        record = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(record["status"], "Waiting Response", "An unanswered question stays available for retry after a failed recovery attempt.")
        self.assertNotIn("fixture-secret", record.get("statusMessage", ""))
        self.assertNotIn("fixture-secret", record.get("savedPrompt", ""))
        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("fixture-secret", diagnostics)
        self.assertNotIn("Answer: Green", diagnostics)
        # History comes from Playhouse's own transcript store, so Codex thread read and
        # resume failures cannot break it.
        Path(str(executable) + ".history-error").write_text(
            "Playhouse owns this Codex fixture history failure marker.\n", encoding="utf-8"
        )
        self.restart_provider(executable)
        Path(str(executable) + ".resume-error").write_text(
            "Playhouse owns this Codex fixture resume failure marker.\n", encoding="utf-8"
        )
        reloaded = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertIsNotNone(reloaded.get("pendingUserInputRequest"), "The question stays available to retry after a provider restart.")
        self.assertTrue(any(
            message["role"] == "user" and recovery_prompt in message["text"]
            for message in reloaded["messages"]
        ), "The stored transcript loads without reading the Codex thread.")
        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("fixture-secret", diagnostics)
    # case-contract: test_codex_empty_question_request_is_rejected | A failed turn preserves its blocked reason and appears in the compact Blocked section above Backlog with a user-intervention indication; retrying clears that section, and the successful retry returns to Waiting Response without an explicit completed outcome.
    def test_codex_empty_question_request_is_rejected(self):
        task_id = self.create_task("Empty Codex questions", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-empty"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = os.environ.copy()
        env.update({
            "PLAYHOUSE_DATA_DIRECTORY": str(self.data_directory),
            "PLAYHOUSE_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "PLAYHOUSE_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": arguments.service_name,
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
        })
        completed = subprocess.run(
            [str(arguments.cli), "conversation", "send", task_id, "--message", "Please ask your questions."],
            check=False, capture_output=True, text=True, env=env, timeout=90,
        )
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        lines = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        self.assertTrue(lines and not lines[-1].get("ok"), completed.stdout)
        self.assertIn("question response", lines[-1].get("error", {}).get("message", "").lower())
        task, _ = self.call_cli("task", "get", task_id)
        blocked = self.assert_success(task)
        self.assertEqual(blocked["status"], "Blocked")
        self.assertIn("question response", (blocked.get("statusMessage") or "").lower())
        retry_executable = self.data_directory / "codex-fixture-retry"
        copy_file(fixture, retry_executable)
        retry_executable.chmod(0o755)
        retry, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Retry this task.",
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(retry_executable)},
        )
        self.assertTrue(self.assert_success(retry)["messages"])
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Waiting Response")
    # case-contract: test_codex_nonblocking_question_keeps_task_in_progress | Non-blocking structured questions render inline, remain pending after switching to another conversation, and keep the task In Progress through fresh CLI/XPC history reconciliation after provider exit until answered. Free-text questions expose a selectable Other choice, select it when text is entered, keep it exclusive of listed answers, and deliver the free-text answer through CLI/XPC and visible UI. Answering resumes the provider turn without status nudges while its own pending question is still being resolved; the resumed turn returns to Waiting Response once the pending question clears, and the recovery prompt and response, including the secret answer, are stored and shown as sent.
    def test_codex_nonblocking_question_keeps_task_in_progress(self):
        task_id = self.create_task("Non-blocking question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-nonblocking-restart-question"
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask non-blocking questions.",
            expected_status=1, extra_environment=env,
        )
        self.assertFalse(failed.get("ok", True), failed)
        self.assertEqual(
            self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress",
            "A saved non-blocking question keeps the task In Progress as soon as the provider exits.",
        )
        restored, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(restored)
        request = history.get("pendingUserInputRequest")
        self.assertIsNotNone(request, "The unanswered non-blocking question must survive provider exit.")
        self.assertFalse(request["isBlocking"])
        self.assertTrue(request["questions"][0]["allowsOther"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress")
        accepted, events = self.call_cli(
            "conversation", "answer-user-input", task_id, request["id"],
            "--answer", "color=Custom approach", "--answer", "token=fixture-secret", extra_environment=env,
        )
        self.assertTrue(self.assert_success(accepted)["accepted"])
        completed, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        completed_history = self.assert_success(completed)
        self.assertIsNone(completed_history.get("pendingUserInputRequest"))
        self.assertTrue(any(
            message["role"] == "user" and "Answer: Custom approach" in message["text"] and "Answer: fixture-secret" in message["text"]
            for message in completed_history["messages"]
        ), "The prompt that carried the answers is stored as sent.")
        self.assertTrue(any(
            message["role"] == "assistant" and message["text"] == "Answers received: Custom approach / fixture-secret."
            for message in completed_history["messages"]
        ), "The recovery response is stored as Codex sent it.")
        provider_history = Path(str(executable) + ".history").read_text(encoding="utf-8")
        self.assertIn("Custom approach", provider_history, "The free-text Other answer must reach the recovered Codex turn.")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Waiting Response")
        fixture_turns = json.loads(provider_history)["turns"]
        reminders = [turn for turn in fixture_turns if "Playhouse internal outcome nudge:" in turn.get("userMessage", "")]
        self.assertEqual(len(reminders), 0, "A pending question still being resolved during the recovered turn must suppress private outcome reminders.")
        self.assertFalse(any(event.get("type") == "user_input" for event in events), "Questions from private reminders must not be emitted as user input.")
    # case-contract: test_codex_async_questions_render_and_reply_as_followup | Async agentMessage questions retain choices and a free-text prompt in live updates and fresh CLI/XPC history, retain accepted-turn model attribution during an active history reload, stay separate from later assistant text, and receive validated answers through the shared manager during and after an active turn. The UI shows inline answer cards instead of raw bullet text, blocks incomplete answers, preserves answered cards across reopening, and displays both submitted answers and responses.
    def test_codex_async_questions_render_and_reply_as_followup(self):
        task_id = self.create_task("Async Codex question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-async-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        process = self.start_cli("conversation", "send", task_id, "--message", "Ask an async question.", extra_environment=env)
        ready = Path(str(executable) + ".question-ready")
        deadline = time.monotonic() + 20
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(ready.exists(), "The fixture must hold the first turn open for a real steer.")
        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        live_history = self.assert_success(reloaded)
        question = next(message for message in live_history["messages"] if message["id"] == "item_playhouse_async_question")
        self.assertEqual(question.get("modelID"), "gpt-6-luna", "Fresh history must read the accepted active turn and its model attribution.")
        invalid, _ = self.call_cli("conversation", "answer-async", task_id, question["id"], "--answer", "Yes, update paired tests and run required verification", expected_status=2, extra_environment=env)
        self.assertEqual(invalid["error"]["code"], "invalid_argument")
        reply = "Test and verify: Yes, update paired tests and run required verification\nAdditional detail: Keep the draft intact."
        answer, _ = self.call_cli("conversation", "answer-async", task_id, question["id"], "--answer", "Yes, update paired tests and run required verification", "--answer", "Keep the draft intact.", extra_environment=env)
        self.assertEqual(self.assert_success(answer), {"text": reply, "queued": False})
        first, events = self.finish_cli(process, "conversation send")
        history = self.assert_success(first)
        question = next(message for message in history["messages"] if message["id"] == question["id"])
        self.assertEqual(question["asyncQuestions"], [
            {"title": "Test and verify", "options": [
                "Yes, update paired tests and run required verification",
                "No, leave tests and verification for later",
            ]},
            {"title": "Additional detail"},
        ])
        self.assertEqual(question["phase"], "final_answer")
        followups = [index for index, message in enumerate(history["messages"])
                     if message["role"] == "assistant" and message["text"] == "I can continue while you decide."]
        self.assertEqual(len(followups), 1, "The later assistant text is its own message.")
        self.assertGreater(followups[0], history["messages"].index(question), "The later assistant text follows the question.")
        live_questions = [event.get("payload", {}).get("asyncQuestions") for event in events
                          if event.get("type") == "assistant_progress" and event.get("payload", {}).get("itemID") == question["id"]]
        self.assertEqual(live_questions, [question["asyncQuestions"]], "The live bridge update must retain structured choices.")

        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_history = self.assert_success(reloaded)
        reloaded_question = next(message for message in reloaded_history["messages"] if message["id"] == question["id"])
        self.assertEqual(reloaded_question["asyncQuestions"], question["asyncQuestions"])
        self.assertEqual(reloaded_question["text"], question["text"])
        self.assertEqual(reloaded_history["answeredAsyncQuestionIDs"], [question["id"]])
        self.assertTrue(any(message["role"] == "user" and message["text"] == reply for message in reloaded_history["messages"]))
        self.assertTrue(any("Answers received: " + reply in message["text"] for message in reloaded_history["messages"]))
        saved_fixture = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(saved_fixture["messages"][0]["steeredAnswer"], reply)
        duplicate, _ = self.call_cli("conversation", "answer-async", task_id, question["id"],
                                     "--answer", "No, leave tests and verification for later",
                                     "--answer", "Try to answer again.", expected_status=1, extra_environment=env)
        self.assert_failure(duplicate, "invalid_transition")
        later, _ = self.call_cli("conversation", "answer-async", task_id, "item_playhouse_async_later_question",
                                 "--answer", "Finish after the turn.", extra_environment=env)
        self.assertEqual(self.assert_success(later)["text"], "One more check: Finish after the turn.")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            completed, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
            completed_history = self.assert_success(completed)
            if "item_playhouse_async_later_question" in completed_history["answeredAsyncQuestionIDs"]:
                break
            time.sleep(0.05)
        self.assertEqual(set(completed_history["answeredAsyncQuestionIDs"]),
                         {question["id"], "item_playhouse_async_later_question"})
        self.assertTrue(any("Answers received: One more check: Finish after the turn." in message["text"]
                            for message in completed_history["messages"]))
    # case-contract: test_codex_async_question_queued_answer_retries | An async question answered after its turn ends stays Pending when the first follow-up fails, rejects duplicate answers across fresh CLI/XPC connections, and becomes Answered only after an explicit queued retry succeeds. The paired UI keeps the card and queue action visible across reopening and then displays the delivered response. A fresh `conversation answered-async` read lists no answered questions while the answer is pending and lists the question once it is delivered. The failed answer is not kept in the conversation as a sent message, and the retry sends it exactly once.
    def test_codex_async_question_queued_answer_retries(self):
        task_id = self.create_task("Queued async question", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-async-question-queued"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        first, _ = self.call_cli("conversation", "send", task_id, "--message", "Ask a queued async question.", extra_environment=env)
        question = next(message for message in self.assert_success(first)["messages"] if message["id"] == "item_playhouse_async_question")
        Path(str(executable) + ".fail-next-turn-start").touch()
        answer, _ = self.call_cli("conversation", "answer-async", task_id, question["id"],
                                  "--answer", "Yes, update paired tests and run required verification",
                                  "--answer", "Retry this answer.", extra_environment=env)
        self.assertTrue(self.assert_success(answer)["queued"])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            queued, _ = self.call_cli("conversation", "queue-list", task_id, extra_environment=env)
            queued_item = self.assert_success(queued)[0]
            if queued_item["state"] == "needsAction":
                break
            time.sleep(0.05)
        self.assertEqual(queued_item["state"], "needsAction")
        self.assertEqual(queued_item["asyncQuestionItemID"], question["id"])
        pending, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        self.assertEqual(self.assert_success(pending)["answeredAsyncQuestionIDs"], [])
        expected_reply = ("Test and verify: Yes, update paired tests and run required verification\n"
                          "Additional detail: Retry this answer.")
        # The answer stays in the queue as needs-action, so the conversation doesn't show it as sent.
        self.assertFalse(any(message["role"] == "user" and message["text"] == expected_reply
                             for message in self.assert_success(pending)["messages"]))
        self.assertEqual(self.assert_success(self.call_cli("conversation", "answered-async", task_id)[0])["itemIDs"], [])
        duplicate, _ = self.call_cli("conversation", "answer-async", task_id, question["id"],
                                     "--answer", "No, leave tests and verification for later",
                                     "--answer", "Duplicate.", expected_status=1, extra_environment=env)
        self.assert_failure(duplicate, "invalid_transition")
        retried, _ = self.call_cli("conversation", "queue-retry", task_id, queued_item["id"], extra_environment=env)
        self.assertTrue(self.assert_success(retried)["retried"])
        delivered, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        delivered_history = self.assert_success(delivered)
        self.assertEqual(delivered_history["answeredAsyncQuestionIDs"], [question["id"]])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "answered-async", task_id)[0])["itemIDs"], [question["id"]])
        self.assertTrue(any(message["text"] == "Answers received: " + expected_reply
                            for message in delivered_history["messages"]))
        self.assertEqual(sum(message["role"] == "user" and message["text"] == expected_reply
                             for message in delivered_history["messages"]), 1,
                         "The retried answer is sent once.")
    # case-contract: test_codex_interrupted_turn_blocks_with_reason_and_can_retry | Turn start persists In Progress; a genuine interrupted outcome remains Blocked with its reason, while restart recovery returns stale In Progress work to Waiting Response with its prompt and conversation available. A saved prompt whose turn never started returns to Waiting Response with its draft intact and can be continued; a turn running when the window quits cleanly or is killed keeps running in the bridge daemon, stays In Progress with its prompt visible after relaunch, finishes, and allows a follow-up. Interrupted outcomes and diagnostics persist across connections; a new prompt can finish in Review. The live turn's activity section renders open and folds away when the interrupted turn settles without an answer, on the conversation that stayed open; the interrupted turn adds no final answer and keeps the activity it reported. A queued follow-up remains visible as needing action after interruption, survives reopening, and is dispatched only after an explicit retry; the completed retry becomes the task's latest saved prompt. Recovering a never-started turn into Waiting Response starts Ping once.
    def test_codex_interrupted_turn_blocks_with_reason_and_can_retry(self):
        task_id = self.create_task("Interrupted turn", roots=[self.primary])["id"]
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
        self.assert_success(self.call_cli("task", "draft", task_id, "--text", "")[0])
        self.complete_fixture_turn(task_id, message="Create the conversation thread before interruption.")
        queued_text = "Follow up after the interrupted turn."
        queued = self.assert_success(self.call_cli("conversation", "queue", task_id, "--message", queued_text)[0])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-interrupted"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        interrupted, events = self.call_cli(
            "conversation", "send", task_id, "--message", "Start work that will be interrupted.",
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_failure(interrupted, "operation_failed")
        started = next(event for event in events if event.get("type") == "started")
        self.assertEqual(started.get("payload", {}).get("taskStatus"), "In Progress")
        task, _ = self.call_cli("task", "get", task_id)
        blocked = self.assert_success(task)
        self.assertEqual(blocked["status"], "Blocked")
        self.assertIn("interrupted", blocked["statusMessage"].lower())
        # The window folds its activity section on the settled turn rather than on
        # an answer, and keeps the section rendered because the turn still has the
        # activity it reported. Assert both from the turn's own stream: Codex
        # activities are not persisted by Playhouse, so a history read would reach
        # the real provider rather than this fixture.
        self.assertEqual(
            [event for event in events if event.get("type") == "assistant_final"], [],
            "An interrupted turn should settle without a final answer of its own.",
        )
        reported_activities = [
            event.get("payload", {}).get("activity", {}) for event in events
            if event.get("type") == "activity"
        ]
        self.assertIn(
            "item_fixture_interrupted_command", [activity.get("id") for activity in reported_activities],
            "The interrupted turn should report the activity that keeps the window's section rendered.",
        )
        diagnostic_lines = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        send_failure = next(
            event for event in diagnostic_lines
            if event.get("event") == "conversation.send.failed" and event.get("taskID") == task_id
        )
        self.assertEqual(send_failure["phase"], "codex-turn")
        self.assertEqual(send_failure["storePath"], str(self.data_directory / "Playhouse-v2.store"))
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-retry")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Review")
        retained = self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0])
        self.assertEqual([(item["id"], item["state"]) for item in retained], [(queued["id"], "needsAction")])
        retry_executable = self.data_directory / "codex-fixture-retry-success"
        copy_file(fixture, retry_executable)
        retry_executable.chmod(0o755)
        retried, _ = self.call_cli(
            "conversation", "queue-retry", task_id, queued["id"],
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(retry_executable)},
        )
        self.assertTrue(self.assert_success(retried)["retried"])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0]), [])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["savedPrompt"], queued_text)

        restart_task = self.create_task("Restart recovery", roots=[self.primary])
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
        self.assert_success(self.call_cli("task", "draft", restart_task["id"], "--text", "")[0])
        restart_prompt = "Restore this submitted prompt after an unexpected restart."
        saved_prompt, _ = self.call_cli(
            "task", "prompt", restart_task["id"], "--text", restart_prompt,
            "--status", "In Progress", "--submitted", "true",
        )
        self.assertEqual(self.assert_success(saved_prompt)["pendingSubmittedPrompt"], restart_prompt)
        restarted_history, _ = self.call_cli("conversation", "history", restart_task["id"])
        self.assertEqual(self.assert_success(restarted_history)["messages"], [])
        restarted_task, _ = self.call_cli("task", "get", restart_task["id"])
        restarted_record = self.assert_success(restarted_task)
        self.assertEqual(restarted_record["status"], "Waiting Response")
        self.assertIn("restarted", restarted_record["statusMessage"].lower())
        self.assertEqual([e["sound"] for e in self.diagnostic_events() if e.get("event") == "task.status_sound.played" and e.get("taskID") == restart_task["id"]], ["Ping"])
        self.assertEqual(restarted_record["savedPrompt"], restart_prompt)
        self.assertIsNone(restarted_record.get("pendingSubmittedPrompt"))
        continued_history = self.complete_fixture_turn(
            restart_task["id"], executable_name="codex-fixture-restart-retry",
            message="Continue the saved work after restart.",
        )
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "Continue the saved work after restart."
            for message in continued_history["messages"]
        ))
        restarted_task, _ = self.call_cli("task", "get", restart_task["id"])
        self.assertEqual(self.assert_success(restarted_task)["status"], "Review")

        threaded_restart = self.create_task("Thread restart recovery", roots=[self.primary])
        thread_executable = "codex-fixture-thread-restart"
        first_thread_history = self.complete_fixture_turn(
            threaded_restart["id"], executable_name=thread_executable,
            message="Save this conversation before restarting.",
        )
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "Save this conversation before restarting."
            for message in first_thread_history["messages"]
        ))
        threaded_prompt = "Continue the existing conversation after restart."
        saved_thread_prompt, _ = self.call_cli(
            "task", "prompt", threaded_restart["id"], "--text", threaded_prompt,
            "--status", "In Progress", "--submitted", "true",
        )
        self.assertEqual(self.assert_success(saved_thread_prompt)["pendingSubmittedPrompt"], threaded_prompt)
        recovered_thread_history, _ = self.call_cli(
            "conversation", "history", threaded_restart["id"],
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / thread_executable)},
        )
        recovered_messages = self.assert_success(recovered_thread_history)["messages"]
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == "Save this conversation before restarting."
            for message in recovered_messages
        ), "Restart recovery should preserve earlier messages from the real Codex thread.")
        recovered_thread, _ = self.call_cli("task", "get", threaded_restart["id"])
        recovered_thread_record = self.assert_success(recovered_thread)
        self.assertEqual(recovered_thread_record["status"], "Waiting Response")
        self.assertEqual(recovered_thread_record["statusMessage"],
                         "The agent stopped while Playhouse was restarting. Your conversation is saved; send a follow-up to continue.")
        self.assertIsNone(recovered_thread_record.get("pendingSubmittedPrompt"))
        continued_thread = self.complete_fixture_turn(
            threaded_restart["id"], executable_name=thread_executable,
            message="Continue the existing conversation after restart.",
        )
        self.assertTrue(any(
            message["role"] == "user" and message["text"] == threaded_prompt
            for message in continued_thread["messages"]
        ))
        recovered_thread, _ = self.call_cli("task", "get", threaded_restart["id"])
        self.assertEqual(self.assert_success(recovered_thread)["status"], "Review")
    # case-contract: test_task_workspace_changes_group_staged_and_unstaged_diffs | The task view lists every file changed from the task branch's recorded base in a Changes section below a collapsed Viewed section, including committed branch changes and current staged, unstaged, and untracked edits, and excluding commits unique to the base branch. Marking a file viewed saves its current contents, stages the file in Git, and adds a Viewed entry that keeps showing the reviewed work from the branch base to that snapshot. Work done after that review is listed again under Changes and diffed against the saved snapshot, so one file can appear in both sections at once; a path with no content in the branch base and no current file is zero net change and is hidden entirely, even with a stale viewed snapshot, rather than showing a ghost entry. Selecting text or JSON files opens a calculated side-by-side diff whose header names the baseline used. Viewed snapshots persist across fresh CLI/XPC connections. Files that aren't current Changes entries, including already-viewed and unknown paths, are rejected by the mark-viewed CLI operation, and the UI offers that action only for Changes entries. Uncommitted filenames are green. Opening one diff after another serves each file's own content from the side-by-side editor the app loads once per session, so a later diff reuses that warm editor instead of starting Monaco again. Diagnostics record inventory and file-read outcomes without logging file contents.
    def test_task_workspace_changes_group_staged_and_unstaged_diffs(self):
        self.prepare_workspace_changes()
        task_id = self.create_task(title="Workspace changes", roots=[self.changes])["id"]

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(unviewed), {"deleted.txt", "shared.txt", "staged-deleted.txt", "staged.txt", "syntax.json", "untracked.txt", "working.txt"})
        self.assertEqual(inventory["viewed"], [])
        self.assertEqual(unviewed["deleted.txt"]["status"], "deleted")
        self.assertEqual(unviewed["untracked.txt"]["status"], "untracked")
        self.assertTrue(unviewed["shared.txt"]["isUncommitted"])
        self.assertFalse(unviewed["shared.txt"]["hasViewedSnapshot"], "A never-viewed file has no saved snapshot baseline.")

        shared = self.assert_success(self.changes_diff(task_id, "shared.txt", "unviewed"))
        self.assertEqual(shared["original"], "Shared baseline.\n")
        self.assertEqual(shared["modified"], "Shared working version.\n")
        syntax = self.assert_success(self.changes_diff(task_id, "syntax.json", "unviewed"))
        self.assertEqual(syntax["original"], '{"value":"baseline"}\n')
        self.assertEqual(syntax["modified"], '{"value":"working version"}\n')
        untracked = self.assert_success(self.changes_diff(task_id, "untracked.txt", "unviewed"))
        self.assertEqual(untracked["original"], "")
        self.assertEqual(untracked["modified"], "Untracked file.\n")
        deleted = self.assert_success(self.changes_diff(task_id, "deleted.txt", "unviewed"))
        self.assertEqual(deleted["original"], "Deleted baseline.\n")
        self.assertEqual(deleted["modified"], "")
        reopened = self.assert_success(self.changes_diff(task_id, "shared.txt", "unviewed"))
        self.assertEqual(reopened, shared, "Opening one diff after another keeps serving each file's own content.")

        marked, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "shared.txt")
        self.assertEqual(self.assert_success(marked), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertNotIn("shared.txt", [entry["path"] for entry in inventory["unviewed"]])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertIn("shared.txt", viewed, "A newly viewed file stays visible in Viewed before it changes again.")
        self.assertTrue(viewed["shared.txt"]["hasViewedSnapshot"])
        viewed_diff = self.assert_success(self.changes_diff(task_id, "shared.txt", "viewed"))
        self.assertEqual(viewed_diff["original"], "Shared baseline.\n", "A viewed entry keeps showing the reviewed work from the branch base.")
        self.assertEqual(viewed_diff["modified"], "Shared working version.\n")
        remark, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "shared.txt", expected_status=3)
        self.assert_failure(remark, "not_found")

        (self.changes / "shared.txt").write_text("Edited after viewing.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertIn("shared.txt", viewed, "A later edit leaves the reviewed work listed under Viewed.")
        self.assertEqual(viewed["shared.txt"]["statusCode"], "M ", "A snapshot row badges its own state, not the live index state.")
        self.assertEqual(unviewed["shared.txt"]["statusCode"], "M ")
        self.assertIn("shared.txt", unviewed, "A later edit is also listed as a change still to review.")
        self.assertTrue(unviewed["shared.txt"]["isUncommitted"])
        self.assertTrue(unviewed["shared.txt"]["hasViewedSnapshot"])
        unchanged_viewed_diff = self.assert_success(self.changes_diff(task_id, "shared.txt", "viewed"))
        self.assertEqual(unchanged_viewed_diff["original"], "Shared baseline.\n", "The viewed diff is unaffected by work done after the review.")
        self.assertEqual(unchanged_viewed_diff["modified"], "Shared working version.\n")
        pending_diff = self.assert_success(self.changes_diff(task_id, "shared.txt", "unviewed"))
        self.assertEqual(pending_diff["original"], "Shared working version.\n", "A re-edited file diffs against its saved viewed snapshot, not the branch base.")
        self.assertEqual(pending_diff["modified"], "Edited after viewing.\n")

        marked_untracked, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "untracked.txt")
        self.assertEqual(self.assert_success(marked_untracked), {"viewed": True})
        staged_status = self.run_git(self.changes, "status", "--porcelain", "--", "untracked.txt")
        self.assertEqual(staged_status.strip(), "A  untracked.txt", "Marking a file viewed stages its untracked contents.")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertIn("untracked.txt", viewed)
        self.assertEqual(viewed["untracked.txt"]["status"], "added")
        new_file_viewed_diff = self.assert_success(self.changes_diff(task_id, "untracked.txt", "viewed"))
        self.assertEqual(new_file_viewed_diff["original"], "")
        self.assertEqual(new_file_viewed_diff["modified"], "Untracked file.\n")
        (self.changes / "untracked.txt").write_text("Untracked file, edited after viewing.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertIn("untracked.txt", [entry["path"] for entry in inventory["viewed"]])
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertIn("untracked.txt", unviewed, "Editing a viewed new file lists it as a change still to review.")
        self.assertEqual(unviewed["untracked.txt"]["status"], "modified")
        untracked_diff = self.assert_success(self.changes_diff(task_id, "untracked.txt", "unviewed"))
        self.assertEqual(untracked_diff["original"], "Untracked file.\n")
        self.assertEqual(untracked_diff["modified"], "Untracked file, edited after viewing.\n")

        marked_deleted, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "deleted.txt")
        self.assertEqual(self.assert_success(marked_deleted), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertEqual(viewed["deleted.txt"]["status"], "deleted")
        deleted_viewed_diff = self.assert_success(self.changes_diff(task_id, "deleted.txt", "viewed"))
        self.assertEqual(deleted_viewed_diff["original"], "Deleted baseline.\n")
        self.assertEqual(deleted_viewed_diff["modified"], "")
        (self.changes / "deleted.txt").write_text("Recreated after viewing.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        recreated = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertIn("deleted.txt", recreated, "Recreating a viewed deleted file lists it as a change still to review.")
        self.assertEqual(recreated["deleted.txt"]["status"], "added")
        self.assertEqual(recreated["deleted.txt"]["statusCode"], "A ")
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertEqual(viewed["deleted.txt"]["status"], "deleted", "The reviewed row keeps reporting the deletion it reviewed.")
        self.assertEqual(viewed["deleted.txt"]["statusCode"], "D ")
        recreated_diff = self.assert_success(self.changes_diff(task_id, "deleted.txt", "unviewed"))
        self.assertEqual(recreated_diff["original"], "")
        self.assertEqual(recreated_diff["modified"], "Recreated after viewing.\n")
        self.assert_failure(self.changes_diff(task_id, "stale.txt", "unviewed", expected_status=3), "not_found")
        stale_mark, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "stale.txt", expected_status=3)
        self.assert_failure(stale_mark, "not_found")

        # A file that never existed in the branch base, created then renamed away by two
        # separate file operations (not `git mv`, which Git would recognize as one rename),
        # nets to zero change once both the deletion and the replacement are reviewed.
        (self.changes / "ephemeral.txt").write_text("Ephemeral content.\n", encoding="utf-8")
        marked_ephemeral, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "ephemeral.txt")
        self.assertEqual(self.assert_success(marked_ephemeral), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertEqual(viewed["ephemeral.txt"]["status"], "added")
        (self.changes / "ephemeral.txt").unlink()
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(unviewed["ephemeral.txt"]["status"], "deleted", "Deleting a reviewed new file lists the deletion as a change still to review.")
        marked_ephemeral_deleted, _ = self.call_cli("task", "changes", "mark-viewed", task_id, "--repository", str(self.changes), "--path", "ephemeral.txt")
        self.assertEqual(self.assert_success(marked_ephemeral_deleted), {"viewed": True})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertNotIn("ephemeral.txt", [entry["path"] for entry in inventory["viewed"]], "A reviewed file with no base content and no current file is zero net change, not a ghost entry.")
        self.assertNotIn("ephemeral.txt", [entry["path"] for entry in inventory["unviewed"]])
        (self.changes / "ephemeral.txt").write_text("Reborn content.\n", encoding="utf-8")
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        unviewed = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(unviewed["ephemeral.txt"]["status"], "added", "Recreating the file afterward surfaces it as a fresh change to review.")

        diagnostics = self.diagnostic_events()
        self.assertTrue(any(event.get("event") == "workspace.files.inventory.succeeded" and int(event.get("unviewedCount", "0")) > 0 for event in diagnostics))
        self.assertTrue(any(event.get("event") == "workspace.file.read.succeeded" and event.get("group") == "viewed" for event in diagnostics))
        self.assertTrue(any(event.get("event") == "workspace.file.read.failed" and event.get("path") == "stale.txt" for event in diagnostics))
        self.assertNotIn("Shared working version.", json.dumps(diagnostics))
    # case-contract: test_task_workspace_changes_mark_all_viewed_and_unview | The Changes section header offers Mark all as viewed while it lists files: one action saves a viewed snapshot of every current Changes entry and stages each in Git, so Changes empties and every file is listed under Viewed, and the operation reports how many files it marked, zero when nothing is pending. Each Viewed entry offers Mark as unviewed, which drops that file's snapshot without touching the Git index, so its whole change from the branch base is listed under Changes again; unviewing a file that isn't a current Viewed entry, including one already unviewed and an unknown path, is rejected. These results persist across fresh CLI/XPC connections. The Changes section collapses inside the task sidebar, hiding its Viewed and Changes lists while its header and pending count stay visible and the sidebar stays open for other sections; separately, the whole sidebar hides to a narrow rail that still shows how many files are pending. Each collapsed or expanded state is its own global preference, so opening another task keeps it. Once loaded, refreshing a task with no changes keeps its No changes state on screen instead of flashing the loading placeholder.
    def test_task_workspace_changes_mark_all_viewed_and_unview(self):
        # The sidebar collapse preference and the loading placeholder are window presentation
        # state outside the bridge API; the paired UI case asserts them.
        self.prepare_workspace_changes()
        task_id = self.create_task(title="Mark all viewed", roots=[self.changes])["id"]
        pending_paths = {"deleted.txt", "shared.txt", "staged-deleted.txt", "staged.txt", "syntax.json", "untracked.txt", "working.txt"}
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertEqual({entry["path"] for entry in inventory["unviewed"]}, pending_paths)
        self.assertEqual(inventory["viewed"], [])

        marked, _ = self.call_cli("task", "changes", "mark-all-viewed", task_id)
        self.assertEqual(self.assert_success(marked), {"markedCount": len(pending_paths)})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertEqual(inventory["unviewed"], [], "Marking all viewed leaves nothing pending.")
        viewed = {entry["path"]: entry for entry in inventory["viewed"]}
        self.assertEqual(set(viewed), pending_paths, "Every pending file is listed under Viewed.")
        self.assertEqual(viewed["deleted.txt"]["status"], "deleted")
        self.assertEqual(viewed["untracked.txt"]["status"], "added")
        self.assertEqual(self.run_git(self.changes, "status", "--porcelain", "--", "untracked.txt").strip(), "A  untracked.txt", "Marking all viewed stages each file.")
        self.assertEqual(self.run_git(self.changes, "status", "--porcelain", "--", "shared.txt").strip(), "M  shared.txt")
        self.assertEqual(self.run_git(self.changes, "status", "--porcelain", "--", "deleted.txt").strip(), "D  deleted.txt", "A deleted file is staged as a deletion.")
        self.assertEqual(self.run_git(self.changes, "status", "--porcelain", "--", "staged-deleted.txt").strip(), "D  staged-deleted.txt", "An already staged deletion is accepted and stays staged.")
        again, _ = self.call_cli("task", "changes", "mark-all-viewed", task_id)
        self.assertEqual(self.assert_success(again), {"markedCount": 0}, "With nothing pending, marking all viewed marks nothing.")

        unviewed, _ = self.call_cli("task", "changes", "mark-unviewed", task_id, "--repository", str(self.changes), "--path", "shared.txt")
        self.assertEqual(self.assert_success(unviewed), {"viewed": False})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        pending = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(pending), {"shared.txt"}, "Unviewing lists the file under Changes again.")
        self.assertFalse(pending["shared.txt"]["hasViewedSnapshot"], "An unviewed file no longer has a saved snapshot baseline.")
        self.assertNotIn("shared.txt", [entry["path"] for entry in inventory["viewed"]])
        self.assertEqual(len(inventory["viewed"]), len(pending_paths) - 1, "Other viewed files are unaffected.")
        self.assertEqual(self.run_git(self.changes, "status", "--porcelain", "--", "shared.txt").strip(), "M  shared.txt", "Unviewing leaves the Git index as it was.")
        unviewed_diff = self.assert_success(self.changes_diff(task_id, "shared.txt", "unviewed"))
        self.assertEqual(unviewed_diff["original"], "Shared baseline.\n", "An unviewed file diffs from the branch base again.")
        self.assertEqual(unviewed_diff["modified"], "Shared working version.\n")

        repeat, _ = self.call_cli("task", "changes", "mark-unviewed", task_id, "--repository", str(self.changes), "--path", "shared.txt", expected_status=3)
        self.assert_failure(repeat, "not_found")
        unknown, _ = self.call_cli("task", "changes", "mark-unviewed", task_id, "--repository", str(self.changes), "--path", "missing.txt", expected_status=3)
        self.assert_failure(unknown, "not_found")

        unviewed_deleted, _ = self.call_cli("task", "changes", "mark-unviewed", task_id, "--repository", str(self.changes), "--path", "deleted.txt")
        self.assertEqual(self.assert_success(unviewed_deleted), {"viewed": False})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        pending = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(pending), {"deleted.txt", "shared.txt"})
        self.assertEqual(pending["deleted.txt"]["status"], "deleted")
        final, _ = self.call_cli("task", "changes", "mark-all-viewed", task_id)
        self.assertEqual(self.assert_success(final), {"markedCount": 2})
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task_id)[0])
        self.assertEqual(inventory["unviewed"], [])
        self.assertEqual({entry["path"] for entry in inventory["viewed"]}, pending_paths)
    # case-contract: test_external_git_edits_and_commit_refresh_workspace_changes | A newly created task branch with no branch or worktree changes starts with empty Viewed and Changes sections. External Git commits unique to the task branch and staged, unstaged, or untracked edits update the open task's Changes sidebar automatically; commits unique to the base branch are excluded. Fresh CLI connections report the same per-file inventory. When the base branch's local copy is stale behind its origin remote-tracking branch and the task branch has merged the newer upstream commits, those commits are excluded as well, so the inventory matches the pull request instead of the stale local branch. A local base branch that is ahead of its remote-tracking branch stays the base, so unpushed base commits merged into the task branch are not listed as task changes. While a merge is still open in the task's worktree, its files are held back and the sidebar shows a 'Merge in progress' notice naming the repository instead of the files the merge staged; the CLI reports the repository under mergingRepositories with empty sections, and aborting the merge lists the task's changes again.
    def test_external_git_edits_and_commit_refresh_workspace_changes(self):
        repository = self.data_directory / "external-git"
        repository.mkdir()
        (repository / "tracked.txt").write_text("Baseline.\n", encoding="utf-8")
        self.run_git(repository, "init", "--initial-branch=main")
        self.run_git(repository, "config", "user.name", "Playhouse Bridge Test")
        self.run_git(repository, "config", "user.email", "playhouse-bridge-test@example.invalid")
        self.run_git(repository, "add", "tracked.txt")
        self.run_git(repository, "commit", "-m", "Baseline")
        task_id = self.create_task(title="External Git", roots=[])["id"]
        added, _ = self.call_cli("task", "repository", "add", task_id, "--repo", str(repository))
        task_record = self.assert_success(added)
        record = next(item for item in task_record["repositoryWorktrees"] if item["repositoryPath"] == str(repository))
        self.assertEqual(record["branchFrom"], "main")
        worktree = Path(record["worktreePath"])

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        self.assertEqual(inventory["unviewed"], [])
        self.assertEqual(inventory["viewed"], [])

        (worktree / "tracked.txt").write_text("Branch commit.\n", encoding="utf-8")
        self.run_git(worktree, "add", "tracked.txt")
        self.run_git(worktree, "commit", "-m", "Task branch commit")
        (repository / "base-only.txt").write_text("Base-only commit.\n", encoding="utf-8")
        self.run_git(repository, "add", "base-only.txt")
        self.run_git(repository, "commit", "-m", "Base-only commit")

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        entries = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(entries), {"tracked.txt"})
        self.assertFalse(entries["tracked.txt"]["isUncommitted"])
        self.assertNotIn("base-only.txt", entries)
        branch_diff = self.assert_success(self.changes_diff(task_id, "tracked.txt", "unviewed", repository=worktree))
        self.assertEqual(branch_diff["original"], "Baseline.\n")
        self.assertEqual(branch_diff["modified"], "Branch commit.\n")

        (worktree / "tracked.txt").write_text("Edited externally.\n", encoding="utf-8")
        (worktree / "untracked.txt").write_text("Untracked external file.\n", encoding="utf-8")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        entries = {entry["path"]: entry for entry in inventory["unviewed"]}
        self.assertEqual(set(entries), {"tracked.txt", "untracked.txt"})
        self.assertTrue(entries["tracked.txt"]["isUncommitted"])
        self.assertTrue(entries["untracked.txt"]["isUncommitted"])
        self.run_git(worktree, "add", "tracked.txt", "untracked.txt")
        self.run_git(worktree, "commit", "-m", "Second task branch commit")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        entries = {entry["path"]: entry for entry in self.assert_success(response)["unviewed"]}
        self.assertEqual(set(entries), {"tracked.txt", "untracked.txt"})
        self.assertFalse(entries["tracked.txt"]["isUncommitted"])
        self.assertNotIn("base-only.txt", entries)

        # Upstream moves ahead of a stale local base branch, and the task branch merges it.
        origin = self.data_directory / "external-git-origin.git"
        origin.mkdir()
        self.run_git(origin, "init", "--bare", "--initial-branch=main")
        self.run_git(repository, "remote", "add", "origin", str(origin))
        self.run_git(repository, "push", "origin", "main")
        (repository / "upstream-only.txt").write_text("Upstream commit.\n", encoding="utf-8")
        self.run_git(repository, "add", "upstream-only.txt")
        self.run_git(repository, "commit", "-m", "Upstream commit")
        self.run_git(repository, "push", "origin", "main")
        self.run_git(repository, "reset", "--hard", "HEAD~1")
        self.run_git(worktree, "merge", "--no-edit", "origin/main")
        (worktree / "post-merge.txt").write_text("Written after the merge.\n", encoding="utf-8")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        entries = {entry["path"]: entry for entry in self.assert_success(response)["unviewed"]}
        self.assertEqual(set(entries), {"post-merge.txt", "tracked.txt", "untracked.txt"})
        self.assertNotIn("upstream-only.txt", entries)
        self.assertNotIn("base-only.txt", entries)
        stale_base_diff = self.assert_success(self.changes_diff(task_id, "tracked.txt", "unviewed", repository=worktree))
        self.assertEqual(stale_base_diff["original"], "Baseline.\n")

        # A local base branch that is ahead of origin holds work the task was started from, so it stays the base.
        self.run_git(repository, "merge", "--ff-only", "origin/main")
        (repository / "local-ahead.txt").write_text("Local only.\n", encoding="utf-8")
        self.run_git(repository, "add", "local-ahead.txt")
        self.run_git(repository, "commit", "-m", "Unpushed local base commit")
        self.run_git(worktree, "merge", "--no-edit", "main")
        (worktree / "post-ahead.txt").write_text("Written after the local merge.\n", encoding="utf-8")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        entries = {entry["path"]: entry for entry in self.assert_success(response)["unviewed"]}
        self.assertEqual(set(entries), {"post-ahead.txt", "post-merge.txt", "tracked.txt", "untracked.txt"})
        self.assertNotIn("local-ahead.txt", entries)

        # An open merge stages everything the merged branch brings in, so the repository's files are
        # held back until the merge is concluded rather than listed as task changes.
        task_repository = entries["tracked.txt"]["repository"]
        (repository / "merging-in.txt").write_text("Merged with the merge still open.\n", encoding="utf-8")
        self.run_git(repository, "add", "merging-in.txt")
        self.run_git(repository, "commit", "-m", "Base commit merged without committing")
        self.run_git(worktree, "merge", "--no-commit", "--no-ff", "main")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        merging = self.assert_success(response)
        self.assertEqual(merging["unviewed"], [])
        self.assertEqual(merging["viewed"], [])
        self.assertEqual(merging["mergingRepositories"], [task_repository])
        self.run_git(worktree, "merge", "--abort")
        response, _ = self.call_cli("task", "changes", "list", task_id)
        aborted = self.assert_success(response)
        self.assertEqual(aborted["mergingRepositories"], [])
        self.assertEqual({entry["path"] for entry in aborted["unviewed"]}, {"post-ahead.txt", "post-merge.txt", "tracked.txt", "untracked.txt"})

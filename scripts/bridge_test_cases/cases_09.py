from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases09:
    # case-contract: test_conversation_composer_rejects_blank_and_supports_live_turn_controls | Shift+Enter inserts a newline at the caret without sending and Return submits; multiline drafts persist, expand to the editor limit, remain scrollable and editable across reopening, and submitted prompts persist in history. In the UI the transcript's scroller stays hidden while the pointer is over the composer, shows at a subdued opacity only while the transcript is hovered, and hides again when the pointer leaves. As content is typed in short increments through successive wrapped lines after a line break, the newest insertion remains inside the visible composer viewport while its internal document follows the caret without scrolling backward. Typed straight quotes, apostrophes, and double hyphens stay literal rather than being substituted. Blank drafts cannot be sent or stored. Sending requires a configured repository root, while a task with no selected repository can still be sent as standalone. If a submitted prompt has no Codex thread or active send reservation after restart, the task returns to Waiting Response, clears its pending marker, preserves the draft, and returns it to the composer. Sending to an Untitled auto-branch task derives its branch from the generated title or prompt fallback before preparing the worktree and starting the conversation; if it is concurrently renamed while title generation is pending, the custom title determines the auto branch. A standalone Untitled task starts and persists its provider thread while background title generation is still pending. Stop is enabled as soon as the message is sent, while the turn is still launching and not yet interruptible. Diagnostics correlate title generation with the task and thread while excluding prompt and title text. Queued follow-ups persist with task and thread identity, dispatch after a completed turn, and remain visible for explicit retry after interruption. During an active turn, Return queues a follow-up and queued rows offer Steer. The obsolete footer Queue and Steer buttons are absent.
    def test_conversation_composer_rejects_blank_and_supports_live_turn_controls(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        task_id = self.create_task(title="Blank conversation send", roots=[self.primary])["id"]
        response, _ = self.call_cli(
            "task", "prompt", task_id, "--text", "Invalid submitted prompt", "--submitted", "true", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli(
            "task", "prompt", task_id, "--text", " ", "--status", "In Progress", "--submitted", "true", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("conversation", "send", task_id, "--message", " ", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("conversation", "history", task_id)
        history = self.assert_success(response)
        self.assertEqual(history["activities"], [])
        self.assertEqual(history["messages"], [])
        # Exercise a saved, unsent draft larger than the prompt that exposed the UI stall.
        long_draft = "# Inspect subagents\n" + "Review child activity and preserve the complete result.\n" * 160
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", long_draft)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], long_draft)
        reopened, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], long_draft)
        edited_draft = long_draft + "Edited after reopening."
        edited, _ = self.call_cli("task", "prompt", task_id, "--text", edited_draft)
        self.assertEqual(self.assert_success(edited)["savedPrompt"], edited_draft)
        reopened, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], edited_draft)
        reopened_again, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened_again)["savedPrompt"], edited_draft)
        self.assertEqual(self.assert_success(reopened_again)["status"], "Backlog")
        history, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(history)["messages"], [])
        prompt = "Work on the persisted prompt while I reopen this task."
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], prompt)
        multiline_prompt = "\n".join(f"Draft line {index}" for index in range(1, 16))
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", multiline_prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], multiline_prompt)
        literal_punctuation = 'Use "straight" quotes -- it\'s literal'
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", literal_punctuation)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], literal_punctuation)
        trailing_newline_prompt = "First line\n"
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", trailing_newline_prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], trailing_newline_prompt)
        reopened, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], trailing_newline_prompt)
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(saved)["savedPrompt"], prompt)
        persisted = self.complete_fixture_turn(task_id, executable_name="codex-fixture-success", message=prompt)
        self.assertTrue(any(message["role"] == "user" and message["text"] == prompt for message in persisted["messages"]))
        queued_text = "Send this follow-up once the next turn completes."
        queued, _ = self.call_cli("conversation", "queue", task_id, "--message", queued_text)
        queued_record = self.assert_success(queued)
        self.assertEqual(queued_record["taskID"], task_id)
        self.assertEqual(queued_record["threadID"], self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"])
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual([item["text"] for item in self.assert_success(queue_read)], [queued_text])
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-success", message="Start the turn that releases the saved follow-up.")
        reloaded_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture-success")},
        )
        self.assertEqual([message["text"] for message in self.assert_success(reloaded_history)["messages"] if message["role"] == "user"].count(queued_text), 1)
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual(self.assert_success(queue_read), [], "A completed queued send should be removed and must not dispatch again after reload.")
        interrupted_followup = "Keep this queued after an interrupted turn."
        queued, _ = self.call_cli("conversation", "queue", task_id, "--message", interrupted_followup)
        queued_record = self.assert_success(queued)
        interrupted_fixture = self.data_directory / "codex-fixture-interrupted"
        copy_file(fixture, interrupted_fixture)
        interrupted_fixture.chmod(0o755)
        copy_file(self.data_directory / "codex-fixture-success.history", Path(str(interrupted_fixture) + ".history"))
        interrupted, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Interrupt the active turn.",
            "--answer", "color=Blue", "--answer", "token=fixture-secret", expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(interrupted_fixture)},
        )
        self.assert_failure(interrupted, "operation_failed")
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        retained = self.assert_success(queue_read)
        self.assertEqual(retained[0]["id"], queued_record["id"])
        self.assertEqual(retained[0]["state"], "needsAction", "An interrupted turn must retain its queued text without silently retrying it.")
        retry_fixture = self.data_directory / "codex-fixture-success"
        copy_file(fixture, retry_fixture)
        retry_fixture.chmod(0o755)
        copy_file(Path(str(interrupted_fixture) + ".history"), Path(str(retry_fixture) + ".history"))
        retried, _ = self.call_cli(
            "conversation", "queue-retry", task_id, queued_record["id"],
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(retry_fixture)},
        )
        self.assertTrue(self.assert_success(retried)["retried"])
        queue_read, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual(self.assert_success(queue_read), [], "An explicit retry that completes should remove the queued item.")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["savedPrompt"], interrupted_followup)

        title_task = self.create_repo_task("Untitled task", [self.primary])
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
        self.assert_success(self.call_cli("task", "draft", title_task["id"], "--text", "")[0])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-title-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        title_prompt = "Transcript entry " + ("Readable chat content for scrolling. " * 120).rstrip()
        sent, _ = self.call_cli(
            "conversation", "send", title_task["id"], "--message", title_prompt,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(sent)
        titled, _ = self.call_cli("task", "get", title_task["id"])
        titled_record = self.assert_success(titled)
        self.assertEqual(titled_record["savedPrompt"], title_prompt)
        self.assertEqual(titled_record["title"], "Generated fixture title")
        generated_title_worktree = titled_record["repositoryWorktrees"][0]
        self.assertRegex(generated_title_worktree["branch"], r"^generated-fixture-title(-[a-z0-9]{4})?$")
        self.assertFalse(generated_title_worktree["isPending"])
        self.assertTrue(Path(generated_title_worktree["worktreePath"]).is_dir())
        self.assertTrue(self.branch_exists(self.primary, generated_title_worktree["branch"]))
        title_events = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == title_task["id"]
            and json.loads(line).get("event", "").startswith("task.title_")
        ]
        generation_started = next(event for event in title_events if event["event"] == "task.title_generation.started")
        generation_succeeded = next(event for event in title_events if event["event"] == "task.title_generation.succeeded")
        title_applied = next(event for event in title_events if event["event"] == "task.title_apply.succeeded")
        self.assertEqual(generation_started["threadID"], generation_succeeded["threadID"])
        self.assertTrue(generation_started["threadID"])
        self.assertTrue(generation_succeeded["threadID"])
        self.assertEqual(title_applied["titleSource"], "codex")
        self.assertEqual(title_applied["taskID"], title_task["id"])

        failure_executable = self.data_directory / "codex-fixture-title-failure"
        copy_file(fixture, failure_executable)
        failure_executable.chmod(0o755)
        failure_prompt = "Explain how repository setup works for new contributors"
        failed_title_task = self.create_repo_task("Untitled task", [self.primary])
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
        self.assert_success(self.call_cli("task", "draft", failed_title_task["id"], "--text", "")[0])
        sent, _ = self.call_cli(
            "conversation", "send", failed_title_task["id"], "--message", failure_prompt,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(failure_executable)},
        )
        self.assert_success(sent)
        failed_title, _ = self.call_cli("task", "get", failed_title_task["id"])
        failed_title_record = self.assert_success(failed_title)
        self.assertEqual(failed_title_record["savedPrompt"], failure_prompt)
        self.assertEqual(failed_title_record["title"], failure_prompt)
        fallback_worktree = failed_title_record["repositoryWorktrees"][0]
        fallback_branch = "explain-how-repository-setup-works-for-new-contributors"
        self.assertEqual(fallback_worktree["branch"], fallback_branch)
        self.assertFalse(fallback_worktree["isPending"])
        self.assertTrue(Path(fallback_worktree["worktreePath"]).is_dir())
        self.assertTrue(self.branch_exists(self.primary, fallback_branch))
        self.assertNotEqual(failed_title_record["title"], "Generating title…")
        all_failure_events = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        failure_task_events = [event for event in all_failure_events if event.get("taskID") == failed_title_task["id"]]
        failure_events = [event for event in failure_task_events if event.get("event", "").startswith("task.title_")]
        generation_failed = next(event for event in failure_events if event["event"] == "task.title_generation.failed")
        rpc_failed = next(event for event in all_failure_events if event.get("event") == "codex.rpc.response.failed" and event.get("errorCode") == "-32042")
        fallback_applied = next(event for event in failure_events if event["event"] == "task.title_apply.succeeded")
        self.assertEqual(generation_failed["phase"], "title-turn")
        self.assertTrue(generation_failed["threadID"])
        self.assertTrue(generation_failed.get("errorDescription"))
        self.assertIn("Fixture rejected task-title generation.", generation_failed["errorDescription"])
        self.assertNotIn(failure_prompt, generation_failed["errorDescription"])
        self.assertEqual(rpc_failed["errorDescription"], "Codex returned an RPC error.")
        self.assertNotIn(failure_prompt, json.dumps(rpc_failed))
        self.assertEqual(fallback_applied["titleSource"], "prompt-fallback")
        title_log = json.dumps(title_events + failure_events)
        self.assertNotIn(title_prompt, title_log)
        self.assertNotIn("Generated fixture title", title_log)
        self.assertNotIn(failure_prompt, title_log)

        pending_task = self.create_task("Untitled task", roots=[self.primary])
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
        self.assert_success(self.call_cli("task", "draft", pending_task["id"], "--text", "")[0])
        pending_prompt = "Persist this prompt before title generation finishes."
        pending_executable = self.data_directory / "codex-fixture-title-success-wait"
        copy_file(fixture, pending_executable)
        pending_executable.chmod(0o755)
        pending_send = self.start_cli(
            "conversation", "send", pending_task["id"], "--message", pending_prompt,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(pending_executable)},
        )
        pending_ready = Path(str(pending_executable) + ".resolve-ready")
        pending_release = Path(str(pending_executable) + ".resolve-continue")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not pending_ready.exists() and pending_send.poll() is None:
                time.sleep(0.02)
            self.assertTrue(pending_ready.exists(), "The title generation fixture should reach its pending state.")
            pending_record, _ = self.call_cli("task", "get", pending_task["id"])
            pending_record = self.assert_success(pending_record)
            self.assertEqual(pending_record["title"], "Generating title…")
            self.assertEqual(pending_record["savedPrompt"], pending_prompt)
            self.assertEqual(pending_record["pendingSubmittedPrompt"], pending_prompt)
            self.assertTrue(pending_record.get("codexThreadID"), "The pending conversation thread should remain attached to the task.")
        finally:
            pending_release.write_text("Release title generation.\n", encoding="utf-8")
        self.finish_cli(pending_send, ["conversation", "send", pending_task["id"], "--message", pending_prompt])
        completed_pending, _ = self.call_cli("task", "get", pending_task["id"])
        self.assertIsNone(self.assert_success(completed_pending).get("pendingSubmittedPrompt"))

        renamed_auto_task = self.create_repo_task("Untitled task", [self.secondary])
        renamed_auto_prompt = "Use the concurrently selected task title for this worktree."
        renamed_auto_title = "Concurrent custom branch title"
        renamed_auto_executable = self.data_directory / "codex-fixture-concurrent-title-success-wait"
        copy_file(fixture, renamed_auto_executable)
        renamed_auto_executable.chmod(0o755)
        renamed_auto_send = self.start_cli(
            "conversation", "send", renamed_auto_task["id"], "--message", renamed_auto_prompt,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(renamed_auto_executable)},
        )
        renamed_title_ready = Path(str(renamed_auto_executable) + ".resolve-ready")
        renamed_title_release = Path(str(renamed_auto_executable) + ".resolve-continue")
        try:
            title_ready_deadline = time.monotonic() + 15
            while time.monotonic() < title_ready_deadline and not renamed_title_ready.exists():
                time.sleep(0.02)
            self.assertTrue(renamed_title_ready.exists(), "Title generation should remain pending during the concurrent rename.")
            renamed_response, _ = self.call_cli(
                "task", "rename", renamed_auto_task["id"], "--title", renamed_auto_title
            )
            self.assertEqual(self.assert_success(renamed_response)["title"], renamed_auto_title)
        finally:
            renamed_title_release.write_text("Continue concurrent title generation.\n", encoding="utf-8")
        sent_response, _ = self.finish_cli(
            renamed_auto_send,
            ("conversation", "send", renamed_auto_task["id"], "--message", renamed_auto_prompt),
        )
        self.assert_success(sent_response)
        renamed_auto_record = self.assert_success(self.call_cli("task", "get", renamed_auto_task["id"])[0])
        self.assertEqual(renamed_auto_record["title"], renamed_auto_title)
        self.assertEqual(renamed_auto_record["repositoryWorktrees"][0]["branch"], "concurrent-custom-branch-title")
        self.assertFalse(renamed_auto_record["repositoryWorktrees"][0]["isPending"])

        stale_task = self.create_task("Untitled task", roots=[self.primary])
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
        self.assert_success(self.call_cli("task", "draft", stale_task["id"], "--text", "")[0])
        stale_prompt = "Restore a stale submitted prompt to the composer."
        saved, _ = self.call_cli(
            "task", "prompt", stale_task["id"], "--text", stale_prompt,
            "--status", "In Progress", "--submitted", "true",
        )
        stale_record = self.assert_success(saved)
        self.assertEqual(stale_record["pendingSubmittedPrompt"], stale_prompt)
        stale_history, _ = self.call_cli("conversation", "history", stale_task["id"])
        self.assertEqual(self.assert_success(stale_history)["messages"], [])
        recovered, _ = self.call_cli("task", "get", stale_task["id"])
        recovered_record = self.assert_success(recovered)
        self.assertEqual(recovered_record["status"], "Waiting Response")
        self.assertIn("restarted", recovered_record["statusMessage"].lower())
        self.assertEqual(recovered_record["savedPrompt"], stale_prompt)
        self.assertIsNone(recovered_record.get("pendingSubmittedPrompt"))
    # case-contract: test_conversation_provider_selection_persists_and_validates | New tasks use the default provider from settings, which starts as Codex and rejects unknown providers, and task create can choose a provider explicitly and saves a --prompt description without starting the task, rejecting a blank or missing prompt; the UI shows that task in Backlog with the description unsent in its composer. A task without a conversation switches providers immediately; provider choice persists across fresh CLI/XPC reads and an app relaunch. Each provider's selected model becomes the default for conversations without an override; conversation-specific selections persist across provider switches and fresh CLI/XPC reads without reusing the other provider's model. Unknown providers and Done-task switches are rejected, and history has no provider boundary. A Claude task names Claude in the empty conversation, hides Goal mode, and rejects Goal changes through CLI/XPC. Switching a task's provider also updates the sticky default provider for new tasks and chats.
    def test_conversation_provider_selection_persists_and_validates(self):
        settings = self.assert_success(self.call_cli("settings", "get")[0])
        self.assertEqual(settings["defaultProvider"], "codex", "Existing installs keep Codex as the default provider.")
        codex_task = self.create_task("Provider default task")
        self.assertEqual(codex_task["conversationProvider"], "codex")
        provider = self.assert_success(self.call_cli("conversation", "provider", codex_task["id"])[0])
        self.assertEqual(provider, {"provider": "codex", "supportsGoals": True})
        self.assert_success(self.call_cli("conversation", "model", codex_task["id"], "set", "codex-choice")[0])

        unknown_default, _ = self.call_cli("settings", "set-default-provider", "gemini", expected_status=2)
        self.assert_failure(unknown_default, "invalid_argument")
        self.assertIn("Valid providers: codex, claude", unknown_default["error"]["message"])
        changed = self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assertEqual(changed["defaultProvider"], "claude")
        self.assertEqual(self.assert_success(self.call_cli("settings", "get")[0])["defaultProvider"], "claude")
        claude_task = self.create_task("Provider claude default task")
        self.assertEqual(claude_task["conversationProvider"], "claude")
        explicit, _ = self.call_cli("task", "create", "--title", "Explicit Codex task", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "codex")
        self.assertEqual(self.assert_success(explicit)["conversationProvider"], "codex")
        with_prompt, _ = self.call_cli("task", "create", "--title", "Prompted task", "--root", self.primary, "--prompt", "Full description of the work")
        with_prompt = self.assert_success(with_prompt)
        self.assertEqual(with_prompt["savedPrompt"], "Full description of the work", "task create --prompt saves the description.")
        self.assertEqual(with_prompt["status"], "Backlog", "A prompt on create must not start the task.")
        self.assertNotIn("pendingSubmittedPrompt", with_prompt, "A prompt on create must not be submitted.")
        blank_prompt, _ = self.call_cli("task", "create", "--title", "Blank prompt task", "--root", self.primary, "--prompt", "   ", expected_status=2)
        self.assert_failure(blank_prompt, "invalid_argument")
        missing_prompt, _ = self.call_cli("task", "create", "--title", "Missing prompt task", "--root", self.primary, expected_status=2)
        self.assert_failure(missing_prompt, "invalid_argument")
        unknown_create, _ = self.call_cli("task", "create", "--title", "Unknown provider task", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "gemini", expected_status=2)
        self.assert_failure(unknown_create, "invalid_argument")

        unknown_switch, _ = self.call_cli("conversation", "provider", codex_task["id"], "set", "gemini", expected_status=2)
        self.assert_failure(unknown_switch, "invalid_argument")
        switched = self.assert_success(self.call_cli("conversation", "provider", codex_task["id"], "set", "claude")[0])
        self.assertEqual(switched["conversationProvider"], "claude", "A task without a conversation switches immediately.")
        self.assertEqual(
            self.assert_success(self.call_cli("settings", "get")[0])["defaultProvider"], "claude",
            "Switching a task's provider updates the sticky default for new tasks and chats."
        )
        provider_follows_switch_task = self.create_task("Provider follows switch task")
        self.assertEqual(
            provider_follows_switch_task["conversationProvider"], "claude",
            "A new task defaults to the provider last chosen in any conversation, not Codex."
        )
        self.assertIsNone(self.assert_success(self.call_cli("conversation", "model", codex_task["id"])[0])["modelID"], "Claude must not inherit the Codex model selection.")
        self.assert_success(self.call_cli("conversation", "model", codex_task["id"], "set", "claude-choice")[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "provider", codex_task["id"], "set", "codex")[0])["conversationProvider"], "codex")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", codex_task["id"])[0])["modelID"], "codex-choice")
        self.assert_success(self.call_cli("conversation", "provider", codex_task["id"], "set", "claude")[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", codex_task["id"])[0])["modelID"], "claude-choice")
        self.assertIsNone(switched.get("codexThreadID"))
        self.assertIsNone(switched.get("claudeSessionID"))
        fresh = self.assert_success(self.call_cli("task", "get", codex_task["id"])[0])
        self.assertEqual(fresh["conversationProvider"], "claude", "The provider choice persists across fresh CLI/XPC reads.")
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "provider", codex_task["id"])[0]),
            {"provider": "claude", "supportsGoals": False},
        )
        history = self.assert_success(self.call_cli("conversation", "history", codex_task["id"])[0])
        self.assertEqual(history["messages"], [])
        self.assertEqual(history["providerBoundaries"], [], "Switching before any conversation records no boundary.")
        self.assertIsNone(self.conversation_state(codex_task["id"]), "No transcript is written before the first turn.")
        self.assertEqual(self.conversation_row_counts(codex_task["id"]), {"turns": 0, "messages": 0, "activities": 0},
                         "No transcript rows are written before the first turn.")

        goal_set, _ = self.call_cli("conversation", "goal", claude_task["id"], "set", "--text", "Ship it", expected_status=1)
        self.assert_failure(goal_set, "invalid_transition")
        self.assertIn("Goals are available only in Codex conversations", goal_set["error"]["message"])
        goal_get = self.assert_success(self.call_cli("conversation", "goal", claude_task["id"], "get")[0])
        self.assertIsNone(goal_get, "A Claude task reports no Goal.")

        done_task = self.create_task("Provider done task", roots=[self.secondary])
        self.assert_success(self.call_cli("conversation", "provider", done_task["id"], "set", "codex")[0])
        self.complete_fixture_turn(done_task["id"])
        self.assert_success(self.call_cli("task", "move", done_task["id"], "Done")[0])
        done_switch, _ = self.call_cli("conversation", "provider", done_task["id"], "set", "claude", expected_status=2)
        self.assert_failure(done_switch, "invalid_argument")
        self.assertIn("Done tasks are closed", done_switch["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", done_task["id"])[0])["conversationProvider"], "codex")
    # case-contract: test_claude_answer_stays_final_around_outcome_report | Against the Claude Code protocol fixture, the answer Claude writes before running its Playhouse progress and outcome commands and the closing line it adds afterward form one final answer, not commentary, in the streamed final answer, fresh history, and transcript, and the reported outcome moves the task to Review. Text Claude writes before an ordinary tool stays commentary, and a turn that leaves every status nudge unanswered ends in Blocked. The fixture records the single private recovery prompt for each unreported turn; fresh history shows the nudge prompts and their replies. Switching to Codex hands off the whole Claude answer, excludes answered-turn commentary and private nudge prompts and replies including their redacted placeholders, and hands off only the last commentary from the turn that recorded no answer. A new Claude conversation with no explicit model pick dispatches to Sonnet and shows Sonnet as the picker default.
    def test_claude_answer_stays_final_around_outcome_report(self):
        story = "BISCUIT-7 waited by the gate every evening. One night the boy finally came home."
        story_answer = story + "\n\nThe story is above."
        claude = self.data_directory / "claude-fixture-story"
        codex = self.data_directory / "codex-fixture-handoff-success"
        for source, executable in [("claude-code-fixture.py", claude), ("codex-app-server-fixture.py", codex)]:
            copy_file(Path(__file__).resolve().parent / "fixtures" / source, executable)
            executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        fixtures = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude), "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(codex)}
        created, _ = self.call_cli("task", "create", "--title", "Claude answer", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude")
        task_id = self.assert_success(created)["id"]

        sent, events = self.call_cli("conversation", "send", task_id, "--message", "Tell me a very short dog story.", extra_environment=fixtures)
        self.assert_success(sent)
        self.assertEqual([event["payload"]["text"] for event in events if event["type"] == "assistant_final"], [story_answer])
        progress = [event["payload"]["text"] for event in events if event["type"] == "assistant_progress"]
        self.assertFalse(any("BISCUIT-7" in text for text in progress), f"The story must not stream as commentary: {progress}")
        recorded = json.loads(Path(str(claude) + ".history").read_text(encoding="utf-8"))["turns"][-1]
        self.assertIn("--model", recorded["arguments"], "Claude Code should receive an explicit model even when the user hasn't chosen one.")
        model_argument_index = recorded["arguments"].index("--model")
        self.assertEqual(recorded["arguments"][model_argument_index + 1], "sonnet", "Playhouse should default new Claude turns to Sonnet.")
        self.assertEqual(len(recorded["reportCommands"]), 2, "The fixture should run Playhouse's progress-clear and outcome commands.")
        self.assertTrue(all('"ok":true' in command["output"] for command in recorded["reportCommands"]), recorded["reportCommands"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Review")

        sent, events = self.call_cli("conversation", "send", task_id, "--message", "Please inspect the workspace.", extra_environment=fixtures)
        self.assert_success(sent)
        finals = [event["payload"]["text"] for event in events if event["type"] == "assistant_final"]
        self.assertEqual(finals[0], "Inspection done: the workspace is ready.", "The answer is the first final, ahead of the nudge replies.")
        self.assertEqual(set(finals[1:]), {"OK."}, "Each nudge's reply streams after the answer.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Blocked",
                         "This fixture leaves every nudge unanswered, so the turn settles in Blocked.")

        sent, events = self.call_cli("conversation", "send", task_id, "--message", "Start the checks.", extra_environment=fixtures)
        self.assert_success(sent)
        self.assertEqual({event["payload"]["text"] for event in events if event["type"] == "assistant_final"} - {"OK."}, set(),
                         "This turn records only commentary; the only finals are the replies to its nudges.")

        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=fixtures)[0])
        assistant = [(message["phase"], message["text"]) for message in history["messages"] if message["role"] == "assistant"]
        self.assertEqual(assistant, [
            ("final_answer", story_answer),
            ("commentary", "I'll inspect the workspace first."),
            ("final_answer", "Inspection done: the workspace is ready."),
            *[("final_answer", "OK.")] * OUTCOME_RECOVERY_PROMPTS,
            ("commentary", "Starting the checks."),
            ("commentary", "Checks are running; results will follow."),
            *[("final_answer", "OK.")] * OUTCOME_RECOVERY_PROMPTS,
        ], "A fresh history read keeps the story as one final answer and the pre-tool text as commentary.")
        self.assertTrue(any(message["role"] == "user" and "Playhouse internal outcome nudge:" in message["text"] for message in history["messages"]),
                        "Nudges Playhouse sent are shown in history.")
        self.assertFalse(any("private outcome reminder hidden" in message["text"] for message in history["messages"]))
        self.assertFalse(any("private outcome response hidden" in message["text"] for message in history["messages"]))

        self.assert_success(self.call_cli("conversation", "provider", task_id, "set", "codex")[0])
        sent, _ = self.call_cli("conversation", "send", task_id, "--message", "Continue the story.", extra_environment=fixtures)
        self.assert_success(sent)
        codex_turns = json.loads(Path(str(codex) + ".history").read_text(encoding="utf-8"))["turns"]
        handoff_turn = next(turn for turn in reversed(codex_turns) if turn.get("userMessage", "").endswith("Continue the story."))
        handoff = handoff_turn["userMessage"]
        self.assertIn("<playhouse-handoff-context>", handoff)
        self.assertIn(f"Claude: {story_answer}", handoff, "Codex must receive the whole Claude answer.")
        self.assertIn("Claude: Inspection done: the workspace is ready.", handoff)
        self.assertNotIn("I'll inspect the workspace first.", handoff, "Commentary of an answered turn stays with the provider that produced it.")
        self.assertIn("Claude: Checks are running; results will follow.", handoff, "A turn without an answer hands off its last commentary.")
        self.assertNotIn("Starting the checks.", handoff, "Only the unanswered turn's last commentary is handed off.")
        self.assertNotIn("Playhouse internal outcome nudge:", handoff, "Private outcome reminders must not cross provider boundaries.")
        self.assertNotIn("[Playhouse private outcome reminder hidden]", handoff, "Redacted reminder prompts must not cross provider boundaries.")
        self.assertNotIn("private outcome response hidden", handoff, "Redacted reminder replies must not enter handoff context.")
        self.assertTrue(handoff.endswith("Continue the story."))
    # case-contract: test_claude_resume_recovers_visible_history | A Claude turn that fails after Claude Code created its session leaves that session in place, and the next turn resumes it instead of claiming the same session ID again. After a Claude turn and Playhouse restart, if Claude cannot find its native resumed session, the retried fresh session receives the prior visible conversation from Playhouse's persisted transcript together with the new prompt. Claude completes the turn, and fresh CLI/XPC history and the visible UI retain both turns. A normal Claude resume continues using the native session without receiving duplicate handoff context.
    def test_claude_resume_recovers_visible_history(self):
        claude = self.data_directory / "claude-fixture-resume-recovery"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", claude)
        claude.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        fixtures = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude)}
        task = self.create_task("Claude session recovery", roots=[self.primary])
        self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", "claude")[0])
        fixture_history_path = Path(str(claude) + ".history")

        # A first turn that fails after Claude Code created the session leaves the
        # session behind. The next turn must resume it; claiming the same ID again
        # makes Claude Code exit with "Session ID ... is already in use".
        failed, _ = self.call_cli(
            "conversation", "send", task["id"], "--message", "Please fail-this-claude-turn.",
            expected_status=1, extra_environment=fixtures,
        )
        self.assertFalse(failed.get("ok"), failed)
        session_after_failure = self.assert_success(self.call_cli("task", "get", task["id"])[0])["claudeSessionID"]
        self.assertTrue(session_after_failure, "The failed first turn should still have persisted its Claude session.")

        first, _ = self.call_cli("conversation", "send", task["id"], "--message", "Tell me a very short dog story.", extra_environment=fixtures)
        self.assert_success(first)
        after_failure = next(
            turn for turn in reversed(json.loads(fixture_history_path.read_text(encoding="utf-8"))["turns"])
            if turn.get("userText") == "Tell me a very short dog story."
        )
        self.assertTrue(after_failure["resumed"], "A session left behind by a failed turn must be resumed, not claimed again.")
        self.assertEqual(after_failure["sessionID"], session_after_failure, after_failure)

        second, _ = self.call_cli("conversation", "send", task["id"], "--message", "Please inspect the workspace.", extra_environment=fixtures)
        self.assert_success(second)

        normal_resume = next(
            turn for turn in reversed(json.loads(fixture_history_path.read_text(encoding="utf-8"))["turns"])
            if turn.get("userText") == "Please inspect the workspace."
        )
        self.assertTrue(normal_resume["resumed"], normal_resume)
        self.assertNotIn("<playhouse-handoff-context>", normal_resume["userText"], "A working native resume must not receive duplicate transcript context.")

        send_started = [
            event for event in self.diagnostic_events()
            if event.get("event") == "conversation.send.started" and event.get("taskID") == task["id"]
        ][-1]
        bridge_pid = int(send_started["clientPID"])
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
            self.fail("The isolated bridge service should exit before recovery after restart.")
        restarted_task, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(restarted_task)["conversationProvider"], "claude")

        # The test owns this fixture executable and its sidecar before arming the failure.
        owner = self.data_directory / ".playhouse-claude-fixture-owner"
        self.assertEqual(owner.read_text(encoding="utf-8"), "Playhouse test owns this Claude Code protocol fixture (v1).\n")
        Path(str(claude) + ".missing-resume").write_text("Playhouse test owns this missing-session trigger.\n", encoding="utf-8")
        recovered, events = self.call_cli(
            "conversation", "send", task["id"], "--message", "What happened earlier?", extra_environment=fixtures
        )
        self.assert_success(recovered)
        self.assertIn("OK.", [event["payload"]["text"] for event in events if event["type"] == "assistant_final"])

        recovered_turn = next(
            turn for turn in reversed(json.loads(fixture_history_path.read_text(encoding="utf-8"))["turns"])
            if "playhouse internal outcome nudge:" not in turn.get("userText", "").lower()
        )
        self.assertFalse(recovered_turn["resumed"], "A missing native session should be replaced by a fresh Claude session.")
        prompt = recovered_turn["userText"]
        self.assertIn("<playhouse-handoff-context>", prompt)
        self.assertIn("User: Tell me a very short dog story.", prompt)
        self.assertIn("Claude: BISCUIT-7 waited by the gate every evening.", prompt)
        self.assertIn("User: Please inspect the workspace.", prompt)
        self.assertIn("Claude: Inspection done: the workspace is ready.", prompt)
        self.assertTrue(prompt.endswith("What happened earlier?"))

        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixtures)[0])
        visible = [message["text"] for message in history["messages"]]
        self.assertIn("Tell me a very short dog story.", visible)
        self.assertIn("BISCUIT-7 waited by the gate every evening. One night the boy finally came home.\n\nThe story is above.", visible)
        self.assertIn("What happened earlier?", visible)
        self.assertIn("OK.", visible)
    # case-contract: test_codex_resume_recovers_visible_history | After a Codex turn and a provider restart, a normal Codex send resumes the saved thread without handoff context. If Codex then reports that it no longer has the thread, Playhouse starts a new Codex thread, saves its ID on the task, and sends the prior visible conversation from Playhouse's persisted transcript together with the new prompt; Codex completes the turn, the replacement is recorded in diagnostics, the next send continues on the new thread without handoff context, and fresh CLI/XPC history and the visible UI retain every turn.
    def test_codex_resume_recovers_visible_history(self):
        task = self.create_task("Codex resume recovery", roots=[self.primary])
        codex = self.data_directory / "codex-fixture-resume-recovery"
        turn_starts = Path(str(codex) + ".turn-starts")
        reply = "Answers received: Blue / fixture-secret."

        def last_turn_start(message):
            starts = [json.loads(line) for line in turn_starts.read_text(encoding="utf-8").splitlines() if line.strip()]
            return next(start for start in reversed(starts) if start["text"].endswith(message))

        self.complete_fixture_turn(task["id"], executable_name=codex.name, message="Start with Codex.")
        original_thread = self.assert_success(self.call_cli("task", "get", task["id"])[0])["codexThreadID"]
        self.assertTrue(original_thread)

        # A working resume after a restart keeps the thread and sends no transcript.
        self.restart_provider(codex)
        self.complete_fixture_turn(task["id"], executable_name=codex.name, message="Continue normally.")
        normal = last_turn_start("Continue normally.")
        self.assertEqual(normal["threadId"], original_thread)
        self.assertEqual(normal["text"], "Continue normally.", "A working resume must not receive duplicate transcript context.")

        # The test owns this fixture executable and its sidecar before arming the missing thread.
        owner = self.data_directory / ".playhouse-codex-fixture-owner"
        self.assertEqual(owner.read_text(encoding="utf-8"), "Playhouse test owns this Codex protocol fixture (v1).\n")
        self.restart_provider(codex)
        missing = Path(str(codex) + ".missing-thread")
        missing.write_text("Playhouse test owns this missing-thread trigger.\n", encoding="utf-8")
        self.complete_fixture_turn(task["id"], executable_name=codex.name, message="What happened earlier?")
        self.assertFalse(missing.exists(), "Codex should have been asked to resume the missing thread.")
        replacement = self.assert_success(self.call_cli("task", "get", task["id"])[0])["codexThreadID"]
        self.assertTrue(replacement)
        self.assertNotEqual(replacement, original_thread, "A missing thread is replaced by a new one saved on the task.")
        recovered = last_turn_start("What happened earlier?")
        self.assertEqual(recovered["threadId"], replacement)
        prompt = recovered["text"]
        self.assertIn("<playhouse-handoff-context>", prompt)
        self.assertIn("User: Start with Codex.", prompt)
        self.assertIn("User: Continue normally.", prompt)
        self.assertIn(f"Codex: {reply}", prompt)
        self.assertNotIn("User: What happened earlier?", prompt, "The new prompt is not repeated inside its own context.")
        self.assertTrue(prompt.endswith("What happened earlier?"))
        replaced = [
            event for event in self.diagnostic_events()
            if event.get("event") == "conversation.thread.replaced_missing" and event.get("taskID") == task["id"]
        ]
        self.assertEqual([(event["provider"], event["missingThreadID"], event["threadID"]) for event in replaced],
                         [("codex", original_thread, replacement)])

        self.complete_fixture_turn(task["id"], executable_name=codex.name, message="And after that?")
        following = last_turn_start("And after that?")
        self.assertEqual(following["threadId"], replacement)
        self.assertEqual(following["text"], "And after that?", "The replacement thread already has the conversation.")

        history = self.assert_success(self.call_cli("conversation", "history", task["id"])[0])
        user_texts = [message["text"] for message in history["messages"] if message["role"] == "user"]
        for message in ("Start with Codex.", "Continue normally.", "What happened earlier?", "And after that?"):
            self.assertIn(message, user_texts)
        self.assertFalse(any("<playhouse-handoff-context>" in text for text in user_texts),
                         "The transcript keeps the user's own prompt, not the context sent with it.")
        self.assertEqual(sum(1 for message in history["messages"] if message["role"] == "assistant" and message["text"] == reply), 4)
    # case-contract: test_codex_standalone_chat_resume_recovers_page_history | A Codex standalone chat page keeps its own thread: after a provider restart, a send on the page resumes that thread without page context. If Codex then reports that it no longer has the page's thread, Playhouse starts a new Codex thread, saves it as the page's provider session, and sends only that page's turns from Playhouse's stored chat pages as context together with the new prompt, never an earlier page's turns or the new prompt itself; the replacement is recorded in diagnostics, the next send on the page continues on the new thread without context, and the page keeps every turn in fresh CLI/XPC reads and the visible chat.
    def test_codex_standalone_chat_resume_recovers_page_history(self):
        executable, environment, chat_id = self.start_reattach_chat("codex-fixture-reattach-resume-recovery", provider="codex")

        def active_page():
            return self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]

        def send(message, new_title=None):
            self.send_filed_chat_turn(executable, environment, chat_id, message, new_title=new_title)
            return json.loads(Path(str(executable) + ".reattach-ready").read_text(encoding="utf-8"))

        send("Name a moon of Mars.")
        earlier_page = active_page()
        send("Tell me about volcanoes.", new_title="Volcanoes")
        page = active_page()
        self.assertNotEqual(page["id"], earlier_page["id"])
        seeded = send("What about lava?")
        page_thread = active_page()["providerSessionID"]
        self.assertEqual(seeded["threadId"], page_thread, "The page's first turn starts the page's own thread.")

        # A working resume after a restart keeps the page's thread and sends no page context.
        self.restart_provider(executable)
        normal = send("Continue normally.")
        self.assertEqual(normal["threadId"], page_thread)
        self.assertNotIn("<playhouse-handoff-context>", normal["text"], "A working resume must not receive the page again.")

        self.restart_provider(executable)
        missing = Path(str(executable) + ".missing-thread")
        missing.write_text("Playhouse test owns this missing-thread trigger.\n", encoding="utf-8")
        recovered = send("What happened earlier?")
        self.assertFalse(missing.exists(), "Codex should have been asked to resume the page's missing thread.")
        replacement = active_page()
        self.assertEqual(replacement["id"], page["id"])
        self.assertNotEqual(replacement["providerSessionID"], page_thread, "The page's missing thread is replaced by a new one saved on the page.")
        self.assertEqual(recovered["threadId"], replacement["providerSessionID"])
        prompt = recovered["text"]
        self.assertIn("<playhouse-handoff-context>", prompt)
        for earlier in ("Tell me about volcanoes.", "What about lava?", "Continue normally.", "After restart."):
            self.assertIn(earlier, prompt, "The new thread receives the page's own turns.")
        self.assertNotIn("Name a moon of Mars.", prompt, "An earlier page's turns never reach this page's thread.")
        self.assertNotIn("User: What happened earlier?", prompt, "The new prompt is not repeated inside its own context.")
        self.assertTrue(prompt.endswith("What happened earlier?"))
        replaced = [
            event for event in self.diagnostic_events()
            if event.get("event") == "conversation.thread.replaced_missing" and event.get("taskID") == chat_id
        ]
        self.assertEqual([(event["provider"], event["missingThreadID"], event["threadID"]) for event in replaced],
                         [("codex", page_thread, replacement["providerSessionID"])])

        following = send("And after that?")
        self.assertEqual(following["threadId"], replacement["providerSessionID"])
        self.assertNotIn("<playhouse-handoff-context>", following["text"], "The replacement thread already has the page.")
        self.assertEqual(
            [text for text in self.chat_page_texts(page["id"], environment) if text != "Before restart." and text != "After restart."],
            ["Tell me about volcanoes.", "What about lava?", "Continue normally.", "What happened earlier?", "And after that?"],
            "The page keeps every turn, with the user's own prompts.",
        )
        self.assertEqual(self.chat_page_texts(earlier_page["id"], environment), ["Name a moon of Mars.", "Before restart.", "After restart."])
    # case-contract: test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary | After a completed Codex fixture turn, switching providers is rejected while a follow-up is queued or a turn is active, and the provider menu is disabled during the turn. A settled switch to Claude records a boundary after the last Codex reply that persists across fresh reads and an app relaunch, keeps the Codex thread, and keeps earlier replies labeled Codex; switching back before any Claude turn removes the empty boundary, and the next Codex turn completes in the same thread.
    def test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary(self):
        task = self.create_task("Provider switch task")
        self.complete_fixture_turn(task["id"], message="Start with Codex.")
        fixture_environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture")}
        before = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        codex_thread = self.assert_success(self.call_cli("task", "get", task["id"])[0])["codexThreadID"]
        self.assertTrue(codex_thread)
        self.assertTrue(before["messages"])
        self.assertTrue(all(message.get("provider") == "codex" for message in before["messages"]))

        queued = self.assert_success(self.call_cli("conversation", "queue", task["id"], "--message", "Queued before switching.", extra_environment=fixture_environment)[0])
        blocked_by_queue, _ = self.call_cli("conversation", "provider", task["id"], "set", "claude", expected_status=1, extra_environment=fixture_environment)
        self.assert_failure(blocked_by_queue, "invalid_transition")
        self.assertIn("queued follow-ups", blocked_by_queue["error"]["message"])
        self.assert_success(self.call_cli("conversation", "queue-remove", task["id"], queued["id"], extra_environment=fixture_environment)[0])

        process, executable, active, release = self.start_progress_fixture_turn(task["id"], "codex-fixture-hold-release")
        try:
            blocked_by_turn, _ = self.call_cli("conversation", "provider", task["id"], "set", "claude", expected_status=1, extra_environment=fixture_environment)
            self.assert_failure(blocked_by_turn, "invalid_transition")
            self.assertIn("current turn", blocked_by_turn["error"]["message"])
            self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["conversationProvider"], "codex")
            self.assert_success(self.call_cli("task", "outcome", task["id"], "completed")[0])
        finally:
            release.write_text("Release the active turn.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, f"Held Codex turn failed: {stdout}; {stderr}")

        switched = self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", "claude", extra_environment=fixture_environment)[0])
        self.assertEqual(switched["conversationProvider"], "claude")
        self.assertEqual(switched["codexThreadID"], codex_thread, "Switching keeps the Codex thread for a later return.")
        self.assertIsNone(switched.get("claudeSessionID"), "Claude starts its session on its first turn.")
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        boundaries = history["providerBoundaries"]
        self.assertEqual(len(boundaries), 1, history)
        self.assertEqual(boundaries[0]["provider"], "claude")
        self.assertEqual(boundaries[0]["afterMessageID"], history["messages"][-1]["id"], "The boundary follows the last Codex reply.")
        self.assertEqual(history["messages"][-1]["role"], "assistant")
        self.assertTrue(all(message.get("provider") == "codex" for message in history["messages"]), "Earlier replies stay labeled Codex.")
        orders = [message["timelineOrder"] for message in history["messages"]]
        self.assertEqual(orders, sorted(orders))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["conversationProvider"], "claude")

        returned = self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", "codex", extra_environment=fixture_environment)[0])
        self.assertEqual(returned["conversationProvider"], "codex")
        returned_history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        self.assertEqual(returned_history["providerBoundaries"], [], "Returning before any Claude turn removes the empty boundary.")
        self.complete_fixture_turn(task["id"], message="Continue with Codex.")
        after = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(after["codexThreadID"], codex_thread, "The next Codex turn resumes the same thread.")
        final_history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)[0])
        self.assertEqual(final_history["providerBoundaries"], [])
        self.assertIn("Continue with Codex.", [message["text"] for message in final_history["messages"] if message["role"] == "user"])
        self.assertFalse(
            any("<playhouse-handoff-context>" in message["text"] for message in final_history["messages"]),
            "Handoff context never appears in the visible transcript.",
        )
    # case-contract: test_conversation_transcript_reopens_from_local_store | Playhouse stores every conversation turn in its own transcript store, for Codex and Claude alike. After a Codex turn and, following a provider switch, a Claude turn, a fresh daemon serves the same messages, roles, texts, providers and order without asking Codex for its thread history: Codex replies stay labeled Codex with the model that wrote them, Claude replies stay labeled Claude, and a limited read returns only the latest page with the count of earlier messages and keeps the Codex-to-Claude boundary after the last Codex message.
    def test_conversation_transcript_reopens_from_local_store(self):
        codex = self.data_directory / "codex-fixture-local-store"
        claude = self.install_provider_fixture("claude", "claude-fixture-local-store")
        environment = self.restart_service_environment("codex", codex, PLAYHOUSE_E2E_CLAUDE_EXECUTABLE=str(claude))
        service = {"PLAYHOUSE_BRIDGE_SERVICE_NAME": environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]}
        task = self.create_task("Local transcript store")
        self.complete_fixture_turn(task["id"], executable_name=codex.name, message="Start with Codex.", extra_environment=service)
        self.assert_success(self.call_cli("conversation", "provider", task["id"], "set", "claude", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Tell me a very short dog story.", extra_environment=environment)[0])

        def summary(history):
            return [(message["id"], message["role"], message["text"], message.get("provider")) for message in history["messages"]]
        before = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        messages = before["messages"]
        self.assertIn(("user", "Start with Codex.", "codex"), [(m["role"], m["text"], m.get("provider")) for m in messages])
        self.assertIn(("user", "Tell me a very short dog story.", "claude"), [(m["role"], m["text"], m.get("provider")) for m in messages])
        codex_replies = [m for m in messages if m["role"] == "assistant" and m.get("provider") == "codex"]
        claude_replies = [m for m in messages if m["role"] == "assistant" and m.get("provider") == "claude"]
        self.assertTrue(codex_replies, before)
        self.assertTrue(all(m.get("modelID") for m in codex_replies), "Codex replies keep the model that wrote them.")
        self.assertTrue(any("BISCUIT-7" in m["text"] for m in claude_replies), before)
        self.assertLess(
            max(i for i, m in enumerate(messages) if m.get("provider") == "codex"),
            min(i for i, m in enumerate(messages) if m.get("provider") == "claude"),
            "The transcript keeps the Codex turn before the Claude turn.",
        )

        methods = Path(str(codex) + ".methods")
        self.assertIn("turn/start", methods.read_text(encoding="utf-8").split(), "The method log records this case's Codex requests.")
        methods.write_text("", encoding="utf-8")
        self.kill_daemon(environment)
        after = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        self.assertEqual(summary(after), summary(before), "A fresh daemon serves the stored transcript unchanged.")
        self.assertEqual([m.get("modelID") for m in after["messages"]], [m.get("modelID") for m in messages])
        page = self.assert_success(self.call_cli("conversation", "history", task["id"], "--limit", "2", extra_environment=environment)[0])
        self.assertEqual(summary(page), summary(before)[-2:])
        self.assertEqual(page["earlierMessageCount"], len(messages) - 2)
        last_codex_message = max(i for i, m in enumerate(messages) if m.get("provider") == "codex")
        expected_boundary = [("claude", messages[last_codex_message]["id"])]
        self.assertEqual([(b["provider"], b["afterMessageID"]) for b in after["providerBoundaries"]], expected_boundary)
        self.assertEqual([(b["provider"], b["afterMessageID"]) for b in page["providerBoundaries"]], expected_boundary,
                         "A limited read keeps the Codex-to-Claude boundary after the last Codex message.")
        requested = methods.read_text(encoding="utf-8").split()
        for method in ("thread/read", "thread/turns/list", "thread/items/list"):
            self.assertNotIn(method, requested, "Reading the transcript never asks Codex for its thread history.")
    # case-contract: test_side_chat_forks_claude_conversation_read_only | Selecting text in a Claude task's reply shows a Side chat hint centered above the selection, and no bubble opens until it is clicked; clicking it hides the hint and opens a side chat bubble above the selection that starts compact and grows to wrap its conversation, wider once it has messages and taller with each exchange, until the chat reaches its maximum height and scrolls. The bubble shows the selected text and a compact chat with no subtitle, whose composer has a Comment button, the conversation's model picker and a send button but no Skills button or mode menu. Choosing another model and effort in the bubble applies to the side chat's next messages only: the task keeps its own model. The first side chat message forks the task's Claude session with --resume and --fork-session under a new session ID, read-only (Edit, MultiEdit, Write and NotebookEdit disallowed), with side chat instructions that list the Playhouse CLI and forbid reporting the task's progress or outcome, and the selected text quoted in the prompt; its answer streams and shows the source session's context in the bubble. A follow-up resumes the forked session without forking again, with the model and effort chosen for it. Asking it to create a task lets only the Playhouse CLI's board commands run, checked by a PreToolUse hook Playhouse passes in the launch settings (ahead of the user's own allow rules) and by its permission handler: a Write, an ordinary shell command and the CLI chained with & to another command are denied, while the CLI's task create, whose quoted description contains shell punctuation, really creates the task, and no file is written. The task's own conversation, Claude session, status and history are unchanged by the side chat. A side chat needs a conversation to fork, a selection, a non-empty message and a valid model and effort; an unknown side chat rejects follow-ups, and closing the bubble with Escape ends its live session without adding a comment, while the saved side chat's next follow-up continues the same forked session.
    def test_side_chat_forks_claude_conversation_read_only(self):
        task, executable, environment = self.open_side_chat_task("claude", "claude-fixture-side-chat")
        source_session = task["claudeSessionID"]
        self.assertTrue(source_session)
        history_before, _ = self.history_texts(task["id"], environment)
        fixture_history = Path(str(executable) + ".history")
        source_turns = lambda: [turn for turn in json.loads(fixture_history.read_text(encoding="utf-8"))["turns"]
                                if turn["sessionID"] == source_session]
        source_turn_count = len(source_turns())

        opened, events = self.call_cli(
            "conversation", "side-chat", task["id"], "--selection", "the parser design",
            "--message", "What does this mean?", extra_environment=environment,
        )
        opened = self.assert_success(opened)
        self.assertEqual(opened["provider"], "claude")
        self.assertEqual(opened["taskID"].upper(), task["id"].upper())
        self.assertIn('Side chat about "the parser design", forked from ' + source_session, opened["reply"])
        self.assertIn("which asked: Explain the design of the parser.", opened["reply"])
        self.assertIn(opened["reply"], "".join(event["payload"]["text"] for event in events if event["type"] == "text_delta"))
        fork = json.loads(fixture_history.read_text(encoding="utf-8"))["turns"][-1]
        arguments = fork["arguments"]
        fork_session = fork["sessionID"]
        self.assertNotEqual(fork_session, source_session, "The side chat must run under its own session ID.")
        self.assertEqual(fork["forkedFrom"], source_session)
        self.assertEqual(arguments[arguments.index("--resume") + 1], source_session)
        self.assertEqual(arguments[arguments.index("--session-id") + 1], fork_session)
        self.assertIn("--fork-session", arguments)
        self.assertEqual(arguments[arguments.index("--disallowedTools") + 1], "Edit,MultiEdit,Write,NotebookEdit")
        self.assertEqual(arguments[arguments.index("--permission-mode") + 1], "default")
        instructions = arguments[arguments.index("--append-system-prompt") + 1]
        self.assertIn("You are now in a Playhouse side chat", instructions)
        self.assertIn("never run task progress, task outcome", instructions)
        self.assertIn(" task create --title", instructions)
        self.assertNotIn(f"task outcome {task['id']} <completed", instructions)
        self.assertEqual(fork["userText"], "<selected-text>\nthe parser design\n</selected-text>\n\nWhat does this mean?")

        # Each message may pick its own model and effort; the task keeps its own.
        follow_up = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", opened["sideChatID"],
            "--message", "And the second point?", "--model", "claude-sonnet-4-6", "--effort", "high",
            extra_environment=environment,
        )[0])
        self.assertEqual(follow_up["sideChatID"], opened["sideChatID"])
        self.assertEqual(follow_up["reply"], f"Side chat follow-up 2 on {fork_session}: And the second point?")
        resumed = json.loads(fixture_history.read_text(encoding="utf-8"))["turns"][-1]
        self.assertEqual(resumed["sessionID"], fork_session)
        self.assertEqual(resumed["arguments"][resumed["arguments"].index("--resume") + 1], fork_session)
        self.assertNotIn("--fork-session", resumed["arguments"])
        self.assertNotIn("--session-id", resumed["arguments"])
        self.assertEqual(resumed["userText"], "And the second point?")
        self.assertEqual(resumed["arguments"][resumed["arguments"].index("--model") + 1], "claude-sonnet-4-6")
        self.assertEqual(resumed["effort"], "high")

        created = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", opened["sideChatID"],
            "--message", "Please create a task for this.", extra_environment=environment,
        )[0])
        create_turn = json.loads(fixture_history.read_text(encoding="utf-8"))["turns"][-1]
        create_arguments = create_turn["arguments"]
        # A message that names no model keeps the side chat's previous choice.
        self.assertEqual(create_arguments[create_arguments.index("--model") + 1], "claude-sonnet-4-6")
        self.assertEqual(create_turn["effort"], "high")
        hooks = json.loads(create_arguments[create_arguments.index("--settings") + 1])["hooks"]["PreToolUse"]
        self.assertEqual(len(hooks), 1, "A read-only launch carries exactly one Playhouse PreToolUse hook.")
        self.assertTrue(hooks[0]["hooks"][0]["command"].endswith("'hook' 'side-chat-pre-tool-use'"))
        # The hook runs before the user's own Claude Code allow rules, so it decides alone.
        self.assertEqual(create_turn["hookDecisions"], {
            "side-chat-write": "deny", "side-chat-shell": "deny", "side-chat-chained": "deny", "side-chat-cli": "pass"})
        self.assertEqual(create_turn["permissionDecisions"], {
            "side-chat-write": "deny", "side-chat-shell": "deny", "side-chat-chained": "deny", "side-chat-cli": "allow"})
        self.assertRegex(created["reply"], r"^Created task [0-9A-F-]{36}\.$")
        new_task = self.task_for(created["reply"].removeprefix("Created task ").removesuffix("."), environment)
        self.assertEqual(new_task["title"], "Side chat follow-up")
        self.assertEqual(new_task["savedPrompt"], "Follow up on the side chat about: Please create a task for this. -> keep a; b <path>",
                         "Shell punctuation inside a quoted description must not block the CLI command.")
        worktree = task["repositoryWorktrees"][0]["worktreePath"]
        self.assertFalse(Path(worktree, "side-chat-forbidden.txt").exists(), "A read-only side chat must not write files.")
        self.assertFalse(Path(task["workspaceRoots"][0], "side-chat-forbidden.txt").exists())

        self.assertEqual(len(source_turns()), source_turn_count, "The side chat must never resume the task's own session.")
        self.assert_side_chat_leaves_task_alone(task, task, environment)
        self.assertEqual(self.history_texts(task["id"], environment)[0], history_before,
                         "The side chat's messages must not reach the task's conversation.")
        self.assert_side_chat_validation(task, environment, opened["sideChatID"], fork_session)
    # case-contract: test_side_chat_forks_codex_conversation_read_only | The first side chat message on a Codex task's selected text forks the task's Codex thread with thread/fork into Codex's read-only sandbox (excluding turns from the response, with approvals off and the side chat developer instructions), and every side chat turn names a read-only sandbox policy with network access, so the Playhouse CLI still reaches the bridge daemon. The answer streams, names the forked source thread and quotes the selected text; a follow-up continues the same forked thread with the model and effort chosen for it, reloading the fork in the read-only sandbox when the model changes, and asking it to create a task really creates one through the CLI, run inside the read-only sandbox, where the daemon accepts only board requests from a sandboxed caller, so the same side chat's task delete is refused as forbidden and the task stays. The task's own conversation, Codex thread, status and history are unchanged. In the app the bubble opens on the selection, shows the question and the answer below the selected text, and a follow-up adds a second exchange. Closing a side chat keeps it saved, and its next follow-up continues the same forked thread.
    def test_side_chat_forks_codex_conversation_read_only(self):
        task, executable, environment = self.open_side_chat_task("codex", "codex-fixture-side-chat-success")
        source_thread = task["codexThreadID"]
        self.assertTrue(source_thread)
        history_before, _ = self.history_texts(task["id"], environment)
        fixture_history = Path(str(executable) + ".history")
        read_history = lambda: json.loads(fixture_history.read_text(encoding="utf-8"))

        opened, events = self.call_cli(
            "conversation", "side-chat", task["id"], "--selection", "the parser design",
            "--message", "What does this mean?", extra_environment=environment,
        )
        opened = self.assert_success(opened)
        self.assertEqual(opened["provider"], "codex")
        self.assertEqual(opened["reply"], f'Side chat about "the parser design", forked from {source_thread}: What does this mean?')
        self.assertEqual("".join(event["payload"]["text"] for event in events if event["type"] == "text_delta"), opened["reply"])
        forks = read_history()["threadForks"]
        self.assertEqual(len(forks), 1)
        fork = forks[0]
        self.assertEqual(fork["sourceThreadId"], source_thread)
        self.assertNotEqual(fork["threadId"], source_thread)
        self.assertEqual(fork["sandbox"], "read-only")
        self.assertEqual(fork["approvalPolicy"], "never")
        self.assertTrue(fork["excludeTurns"])
        self.assertIn("You are now in a Playhouse side chat", fork["developerInstructions"])
        self.assertIn("never run task progress, task outcome", fork["developerInstructions"])
        first_turn = read_history()["sideChatTurns"][-1]
        self.assertEqual(first_turn["threadId"], fork["threadId"])
        self.assertEqual(first_turn["sandboxPolicy"], {"type": "readOnly", "networkAccess": True})
        self.assertEqual(first_turn["text"], "<selected-text>\nthe parser design\n</selected-text>\n\nWhat does this mean?")

        follow_up = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", opened["sideChatID"],
            "--message", "And the second point?", "--model", "gpt-6-sol", "--effort", "high",
            extra_environment=environment,
        )[0])
        self.assertEqual(follow_up["reply"], f"Side chat follow-up 2 on {fork['threadId']}: And the second point?")
        second_turn = read_history()["sideChatTurns"][-1]
        self.assertEqual((second_turn["model"], second_turn["effort"]), ("gpt-6-sol", "high"))
        # A new model reloads the forked thread, still in the read-only sandbox.
        self.assertEqual(read_history()["sideChatResumes"], [{"threadId": fork["threadId"], "sandbox": "read-only"}])
        self.assertEqual(len(read_history()["threadForks"]), 1, "A follow-up must continue the fork, not fork again.")
        self.assertEqual(read_history()["sideChatTurns"][-1]["sandboxPolicy"], {"type": "readOnly", "networkAccess": True})

        # An effort the model doesn't support is refused before any turn, and isn't kept.
        turns_before = len(read_history()["sideChatTurns"])
        self.assert_failure(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", opened["sideChatID"],
            "--message", "Think harder?", "--model", "gpt-6-mini", "--effort", "xhigh",
            extra_environment=environment, expected_status=2,
        )[0], "invalid_argument")
        self.assertEqual(len(read_history()["sideChatTurns"]), turns_before)
        created = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", opened["sideChatID"],
            "--message", "Please create a task for this.", extra_environment=environment,
        )[0])
        self.assertRegex(created["reply"], r"^Created task [0-9A-F-]{36}\.$")
        create_turn = read_history()["sideChatTurns"][-1]
        self.assertEqual((create_turn["model"], create_turn["effort"]), ("gpt-6-sol", "high"),
                         "A message that names no model keeps the side chat's previous choice.")
        new_task = self.task_for(created["reply"].removeprefix("Created task ").removesuffix("."), environment)
        self.assertEqual(new_task["title"], "Side chat follow-up")
        # The CLI runs in a read-only sandbox there; the daemon refuses its non-board requests.
        self.assertEqual(read_history()["sideChatForbiddenRequests"], [{"command": "task delete", "ok": False, "error": "forbidden"}])
        self.assertEqual(self.task_for(new_task["id"], environment)["title"], "Side chat follow-up",
                         "A sandboxed side chat must not delete tasks through the daemon.")

        self.assertTrue(all(turn["threadId"] != source_thread for turn in read_history()["sideChatTurns"]))
        self.assert_side_chat_leaves_task_alone(task, task, environment)
        self.assertEqual(self.history_texts(task["id"], environment)[0], history_before,
                         "The side chat's messages must not reach the task's conversation.")
        self.assert_side_chat_validation(task, environment, opened["sideChatID"], fork["threadId"])

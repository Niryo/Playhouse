from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases07:
    # case-contract: test_task_outcome_in_progress_drives_continuations_until_blocked | An in-progress outcome is accepted during an active turn, leaves the task In Progress, and makes Playhouse send a private continuation turn that names the in-progress report; a completed report during that continuation stops the loop at Review. When every turn reports in-progress, Playhouse sends exactly five continuation turns, keeps the task In Progress throughout, and then marks it Blocked with a continuation-limit reason instead of Waiting Response, since the user was never asked anything. Continuation prompts and replies appear in the conversation history as Playhouse-sent messages and their replies. The user taking the work back ends Playhouse's private driving: stopping a continuation keeps the Stop's Waiting Response with no failure reason, and a queued follow-up runs next instead of being buried under further continuations.
    def test_task_outcome_in_progress_drives_continuations_until_blocked(self):
        task_id = self.create_task("Continue in progress", roots=[self.primary])["id"]
        process, executable, active, release = self.start_progress_fixture_turn(
            task_id, "codex-fixture-in-progress-continuation-hold-release"
        )
        try:
            reported = self.assert_success(self.call_cli("task", "outcome", task_id, "in-progress")[0])
            self.assertEqual(reported["outcome"], "in-progress")
            self.assertEqual(reported["taskStatus"], "In Progress", "The outcome is staged until the turn completes.")
            release.write_text("Release the in-progress turn.\n", encoding="utf-8")
            self.wait_for_marker(active, False, "The in-progress turn should finish before its continuation.")
            self.wait_for_marker(active, True, "Playhouse should send a continuation turn after an in-progress report.")
            self.assertEqual(
                self.assert_success(self.call_cli("task", "get", task_id)[0])["status"],
                "In Progress",
                "The task stays In Progress while Playhouse drives the continuation.",
            )
            self.assertEqual(self.assert_success(self.call_cli("task", "outcome", task_id, "completed")[0])["outcome"], "completed")
            release.write_text("Release the continuation turn.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, f"Continuation fixture conversation failed: {stdout}; {stderr}")
            self.assertEqual(
                self.assert_success(self.call_cli("task", "get", task_id)[0])["status"],
                "Review",
                "A completed report during a continuation stops the loop at Review.",
            )
        finally:
            if process.poll() is None:
                release.write_text("Release the continuation turn.\n", encoding="utf-8")
                process.communicate(timeout=30)
        continuations = [
            turn for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
            if "You reported `in-progress`" in (turn.get("userMessage") or "")
        ]
        self.assertEqual(len(continuations), 1, "One in-progress report earns exactly one continuation turn.")
        self.assertIn(f"of {MAX_OUTCOME_CONTINUATIONS}", continuations[0]["userMessage"])

        capped_id = self.create_task("Never settles", roots=[self.primary])["id"]
        capped, capped_executable, capped_active, capped_release = self.start_progress_fixture_turn(
            capped_id, "codex-fixture-in-progress-cap-hold-release"
        )
        try:
            for index in range(MAX_OUTCOME_CONTINUATIONS + 1):
                self.assertEqual(
                    self.assert_success(self.call_cli("task", "get", capped_id)[0])["status"],
                    "In Progress",
                    "Every continuation keeps the task In Progress until the limit is reached.",
                )
                self.assertEqual(self.assert_success(self.call_cli("task", "outcome", capped_id, "in-progress")[0])["outcome"], "in-progress")
                capped_release.write_text(f"Release turn {index + 1}.\n", encoding="utf-8")
                if index < MAX_OUTCOME_CONTINUATIONS:
                    self.wait_for_marker(capped_active, False, "The fixture should finish the current continuation turn.")
                    self.wait_for_marker(capped_active, True, "Playhouse should send the next continuation turn.")
            capped_stdout, capped_stderr = capped.communicate(timeout=60)
            self.assertEqual(capped.returncode, 0, f"Capped continuation conversation failed: {capped_stdout}; {capped_stderr}")
            capped_record = self.assert_success(self.call_cli("task", "get", capped_id)[0])
            self.assertEqual(capped_record["status"], "Blocked", "Running out of continuations is Blocked, not Waiting Response.")
            self.assertIn("continuation turns", capped_record.get("statusMessage") or "")
        finally:
            if capped.poll() is None:
                capped_release.write_text("Release the capped turn.\n", encoding="utf-8")
                capped.communicate(timeout=60)
        capped_turns = json.loads(Path(str(capped_executable) + ".history").read_text(encoding="utf-8"))["turns"]
        self.assertEqual(
            len([turn for turn in capped_turns if "You reported `in-progress`" in (turn.get("userMessage") or "")]),
            MAX_OUTCOME_CONTINUATIONS,
            "Playhouse stops driving the work after the continuation limit.",
        )
        # Stopping a private continuation is the user taking the work back, not a
        # Playhouse failure, so the Stop's own paused state must survive.
        stop_id = self.create_task("Stopped mid continuation", roots=[self.primary])["id"]
        stopped, stop_executable, stop_active, stop_release = self.start_progress_fixture_turn(
            stop_id, "codex-fixture-in-progress-stop-hold-release"
        )
        try:
            self.assertEqual(self.assert_success(self.call_cli("task", "outcome", stop_id, "in-progress")[0])["outcome"], "in-progress")
            stop_release.write_text("Release the in-progress turn.\n", encoding="utf-8")
            self.wait_for_marker(stop_active, False, "The in-progress turn should finish before its continuation.")
            self.wait_for_marker(stop_active, True, "Playhouse should send a continuation turn before the Stop.")
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
            stop_release.write_text("Release the stopped continuation.\n", encoding="utf-8")
            stopper.join(timeout=30)
            self.assertFalse(stopper.is_alive(), "The stop request should settle once the held turn is released.")
            self.assertEqual(len(stop_results), 1)
            self.assert_success(stop_results[0])
            stopped.communicate(timeout=60)
        finally:
            if stopped.poll() is None:
                stop_release.write_text("Release the stopped continuation.\n", encoding="utf-8")
                stopped.communicate(timeout=60)
        stop_record = self.assert_success(self.call_cli("task", "get", stop_id)[0])
        self.assertEqual(stop_record["status"], "Waiting Response", "A Stop during a continuation keeps the user's paused state.")
        self.assertIsNone(stop_record.get("statusMessage"), "A user-requested Stop must not be reported as a Playhouse failure.")
        stop_turns = json.loads(Path(str(stop_executable) + ".history").read_text(encoding="utf-8"))["turns"]
        self.assertEqual(
            len([turn for turn in stop_turns if "You reported `in-progress`" in (turn.get("userMessage") or "")]),
            1,
            "Playhouse must stop driving the work once the user stops it.",
        )

        # A queued follow-up is also the user taking over: the loop steps aside so
        # their message runs next instead of waiting behind private turns.
        queued_id = self.create_task("Queued over continuation", roots=[self.primary])["id"]
        queued_turn, queued_executable, _, queued_release = self.start_progress_fixture_turn(
            queued_id, "codex-fixture-in-progress-queue-hold-release"
        )
        try:
            self.assertEqual(self.assert_success(self.call_cli("task", "outcome", queued_id, "in-progress")[0])["outcome"], "in-progress")
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
        # The follow-up turn settles on its own terms; what matters here is that
        # it ran next instead of queueing behind Playhouse's continuations.
        queued_turns = json.loads(Path(str(queued_executable) + ".history").read_text(encoding="utf-8"))["turns"]
        self.assertEqual(
            len([turn for turn in queued_turns if "You reported `in-progress`" in (turn.get("userMessage") or "")]),
            0,
            "A queued follow-up must take precedence over Playhouse's private continuation.",
        )
        self.assertTrue(
            any("Follow-up from the user." in (turn.get("userMessage") or "") for turn in queued_turns),
            "The queued follow-up should be the next turn the provider receives.",
        )

        capped_history = self.assert_success(self.call_cli(
            "conversation", "history", capped_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(capped_executable)},
        )[0])
        self.assertTrue(
            any(message["role"] == "user" and "You reported `in-progress`" in message.get("text", "") for message in capped_history["messages"]),
            "Continuation prompts Playhouse sent appear in conversation history.",
        )
        self.assertTrue(
            any("Fixture internal reminder reply." in message.get("text", "") for message in capped_history["messages"]),
            "Replies to continuations appear in conversation history.",
        )
        self.assertFalse(
            any(
                hidden in message.get("text", "")
                for message in capped_history["messages"]
                for hidden in ("private outcome reminder hidden", "private outcome response hidden")
            ),
            "No placeholder replaces a continuation or its reply.",
        )
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
    # case-contract: test_task_title_copy_button_copies_persisted_title | The conversation title's copy button places the task's exact persisted title on the pasteboard, including spaces, an ampersand and non-ASCII text, after a rename; the button confirms the copy with a checkmark and its 'Title copied' label, and fresh CLI/XPC reads report the same title the copy produced.
    def test_task_title_copy_button_copies_persisted_title(self):
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
    # case-contract: test_conversation_repository_picker_add_and_replace_buttons | Each repository row in the header's Add repository picker adds the repository alongside the selected ones when the row or its plus button is clicked, and its Replace button removes every selected repository and attaches only that one; the task repository API reaches the same add and replace results, duplicates are rejected, and the saved repository selection follows. The catalog's shared Overlay atom contains both actions and reveals them on hover; the UI keeps them visible over the row and buttons and hides them on exit.
    def test_conversation_repository_picker_add_and_replace_buttons(self):
        # The catalog exercises the same Overlay atom used by the native picker.
        # Pointer tracking itself is presentation state, checked by the paired UI case.
        rendered, _ = self.call_cli("plugin", "render", "--page", "RepositoryChips")
        tree = self.assert_success(rendered)["tree"]
        row_button = self.plugin_node(tree, "conversation-repository-recent-mre")
        scroll = self.plugin_node(tree, "conversation-repository-list")
        row = next(node for node in scroll["children"] if row_button in node["children"])
        self.assertTrue(row["props"]["revealOnHover"])
        for action in ("add", "replace"):
            self.assertIsNotNone(self.plugin_node(row, f"conversation-repository-recent-mre-{action}"))

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
            self.assert_success(self.call_cli("task", "pr", "mode", task_id, "manual")[0])
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
            self.assert_success(self.call_cli("task", "pr", "mode", task_id, "manual")[0])
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
            self.assert_success(self.call_cli("task", "pr", "mode", offline_id, "manual")[0])
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

from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases08:
    # case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | The task context menu offers deletion. Pending repository tasks delete without confirmation and preserve the source repository; confirmed deletion waits for an active conversation turn; clean started worktrees can be deleted; dirty started worktrees require confirmation, and canceling preserves the task and worktree. CLI delete-check derives and reports the confirmation requirement from saved task and worktree state without resuming the Codex thread; confirmed deletion removes the managed worktree. Deleting a task also removes its per-task preferences and any left by already-deleted tasks, while another task's preferences remain.
    def test_task_delete_removes_task_and_later_lookup_is_not_found(self):
        pending = self.create_repo_task("Pending delete", [self.primary])
        pending_id = pending["id"]
        pending_path = pending["repositoryWorktrees"][0]["worktreePath"]
        self.assertTrue(pending["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(pending_path, str(self.primary))
        response, _ = self.call_cli("task", "delete-check", pending_id)
        self.assertTrue(self.assert_success(response)["requiresConfirmation"], "A task with a saved prompt holds user content, so deleting it must confirm.")
        self.assert_success(self.call_cli("task", "prompt", pending_id, "--text", "")[0])
        response, _ = self.call_cli("task", "delete-check", pending_id)
        self.assertFalse(self.assert_success(response)["requiresConfirmation"])
        kept_id = self.create_task("Kept preferences", roots=[self.custom])["id"]
        pending_preference = f"conversationMode.{pending_id.upper()}"
        kept_preference = f"conversationMode.{kept_id.upper()}"
        orphaned_preference = f"playhouse.codex.goal-generation.{str(uuid.uuid4()).upper()}"
        for key in [pending_preference, kept_preference, orphaned_preference]:
            self.write_default(key, "plan")
        lock_barrier = ConversationTurnLockBarrier(self.data_directory, pending_id)
        delete_command = ["task", "delete", pending_id]
        delete_process = None
        continue_delete_process = False
        try:
            delete_process = self.start_cli(*delete_command)
            time.sleep(0.25)
            self.assertIsNone(delete_process.poll(), "Task deletion should wait for the active conversation-turn reservation.")
            retained, _ = self.call_cli("task", "get", pending_id)
            self.assertEqual(self.assert_success(retained)["id"], pending_id)
            continue_delete_process = True
        finally:
            lock_barrier.release()
            if not continue_delete_process and delete_process is not None and delete_process.poll() is None:
                delete_process.terminate()
                try:
                    delete_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    delete_process.kill()
                    delete_process.communicate()
        self.assertIsNotNone(delete_process)
        response, _ = self.finish_cli(delete_process, delete_command)
        self.assertTrue(self.assert_success(response)["deleted"])
        diagnostic_lines = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        delete_event = next(
            event for event in diagnostic_lines
            if event.get("event") == "task.delete.succeeded" and event.get("taskID") == pending_id
        )
        self.assertEqual(delete_event["taskStatus"], "Backlog")
        self.assertIn("processID", delete_event)
        self.assertIn("storePath", delete_event)
        self.assertTrue(Path(pending_path).is_dir(), "Deleting a pending task must preserve the source repository.")
        response, _ = self.call_cli("task", "get", pending_id, expected_status=3)
        self.assert_failure(response, "not_found")
        self.assertFalse(self.default_exists(pending_preference), "Deleting a task must remove its per-task preferences.")
        self.assertFalse(self.default_exists(orphaned_preference), "Deleting a task must remove preferences left by already-deleted tasks.")
        self.assertEqual(self.read_default(kept_preference)[0], "plan", "Another task's preferences must survive a delete.")
        self.assertTrue(self.assert_success(self.call_cli("task", "delete", kept_id)[0])["deleted"])
        self.assertFalse(self.default_exists(kept_preference))

        clean = self.create_repo_task(f"Clean delete {uuid.uuid4().hex[:8]}", [self.primary], materialize=True)
        clean_id = clean["id"]
        self.complete_fixture_turn(clean_id)
        clean, _ = self.call_cli("task", "get", clean_id)
        clean = self.assert_success(clean)
        clean_worktree = Path(clean["repositoryWorktrees"][0]["worktreePath"])
        self.assertEqual(self.run_git(clean_worktree, "status", "--porcelain").strip(), "")
        clean_thread_id = clean["codexThreadID"]
        resume_events_before = sum(
            event.get("event") == "codex.thread.resume_started" and event.get("threadID") == clean_thread_id
            for event in (
                json.loads(line)
                for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            )
        )
        response, _ = self.call_cli("task", "delete-check", clean_id)
        self.assertTrue(self.assert_success(response)["requiresConfirmation"])
        resume_events_after = sum(
            event.get("event") == "codex.thread.resume_started" and event.get("threadID") == clean_thread_id
            for event in (
                json.loads(line)
                for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            )
        )
        self.assertEqual(resume_events_after, resume_events_before, "Delete-check must not resume a conversation thread already owned by the app.")
        response, _ = self.call_cli("task", "delete", clean_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(clean_worktree.exists(), "Deleting a clean managed worktree must remove it.")

        dirty = self.create_repo_task(f"Delete dirty {uuid.uuid4().hex[:8]}", [self.secondary], materialize=True)
        dirty_id = dirty["id"]
        dirty_worktree = Path(dirty["repositoryWorktrees"][0]["worktreePath"])
        (dirty_worktree / "unsaved-work.txt").write_text("work that needs confirmation\n", encoding="utf-8")
        response, _ = self.call_cli("task", "delete-check", dirty_id)
        self.assertTrue(self.assert_success(response)["requiresConfirmation"])
        response, _ = self.call_cli("task", "delete", dirty_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(dirty_worktree.exists(), "Confirmed deletion must remove the dirty managed worktree.")
        response, _ = self.call_cli("task", "get", dirty_id, expected_status=3)
        self.assert_failure(response, "not_found")

        response, _ = self.call_cli("board", "list")
        self.assertEqual(self.assert_success(response)["tasks"], [])
    # case-contract: test_task_delete_reports_real_worktree_failure_and_allows_retry | A real worktree-removal failure records the task title and task, thread, process, phase, and underlying error details, including bounded NSError user-info keys and values, without recording conversation text; the failed task and worktree remain available and deletion succeeds after the repository is restored.
    def test_task_delete_reports_real_worktree_failure_and_allows_retry(self):
        broken_repository = self.data_directory / "delete-failure-repository"
        broken_repository.mkdir()
        self.run_git(broken_repository, "init", "--initial-branch=main")
        self.run_git(broken_repository, "config", "user.name", "Playhouse Test")
        self.run_git(broken_repository, "config", "user.email", "playhouse-test@example.invalid")
        (broken_repository / "README.md").write_text("owned diagnostic fixture\n", encoding="utf-8")
        self.run_git(broken_repository, "add", "README.md")
        self.run_git(broken_repository, "commit", "-m", "Baseline")
        failure_title = f"PRIVATE_DELETE_TITLE_{uuid.uuid4().hex[:8]}"
        failure_prompt = f"PRIVATE_CONVERSATION_TEXT_{uuid.uuid4().hex[:8]}"
        broken = self.create_repo_task(failure_title, [broken_repository])
        broken_id = broken["id"]
        self.complete_fixture_turn(broken_id, message=failure_prompt)
        broken, _ = self.call_cli("task", "get", broken_id)
        broken = self.assert_success(broken)
        broken_worktree = Path(broken["repositoryWorktrees"][0]["worktreePath"])
        moved_repository = self.data_directory / "delete-failure-repository-restored-after-error"
        broken_repository.rename(moved_repository)
        response, _ = self.call_cli("task", "delete", broken_id, expected_status=1)
        self.assert_failure(response, "operation_failed")
        diagnostic_lines = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        failure_event = next(
            event for event in diagnostic_lines
            if event.get("event") == "task.delete.failed" and event.get("taskID") == broken_id
        )
        self.assertEqual(failure_event["phase"], "worktree-removal")
        self.assertTrue(failure_event.get("threadID"))
        self.assertIn("processID", failure_event)
        self.assertIn("error0Domain", failure_event)
        self.assertIn("error0Code", failure_event)
        self.assertIn("error0UserInfoKeys", failure_event)
        self.assertIn("error0UserInfoKeyCount", failure_event)
        self.assertIn("error0UserInfo", failure_event)
        serialized_diagnostics = json.dumps(diagnostic_lines)
        self.assertIn(failure_title, serialized_diagnostics)
        self.assertNotIn(failure_prompt, serialized_diagnostics)
        self.assertTrue(broken_worktree.exists(), "A failed worktree removal must leave its worktree available for recovery.")
        preserved, _ = self.call_cli("task", "get", broken_id)
        self.assertEqual(self.assert_success(preserved)["id"], broken_id)
        moved_repository.rename(broken_repository)
        response, _ = self.call_cli("task", "delete", broken_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        self.assertFalse(broken_worktree.exists())
    # case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; a fresh CLI read and repository discovery use the persisted parent. Dark and Light appearance choices persist, the removed PR conflict preference is absent from CLI/XPC and Settings, and appearance changes update the open Settings picker. Clearing the default parent does not change roots already saved on a task.
    def test_default_parent_settings_read_write_clear_and_validation(self):
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        response, _ = self.call_cli("settings", "get")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
        self.assertEqual(self.assert_success(response)["appearance"], "dark")
        self.assertNotIn("pullRequestConflictAction", self.assert_success(response))
        self.call_cli("settings", "set-pr-conflict-action", "ask", expected_status=2)
        response, _ = self.call_cli("settings", "set-appearance", "light")
        self.assertEqual(self.assert_success(response)["appearance"], "light")
        response, _ = self.call_cli("settings", "set-appearance", "dark")
        self.assertEqual(self.assert_success(response)["appearance"], "dark")
        appearance_writes = [
            event for event in self.diagnostic_events()
            if event.get("event") == "settings.write.succeeded" and event.get("setting") == "appearance"
        ]
        self.assertTrue(any(event.get("value") == "light" for event in appearance_writes))
        self.assertTrue(any(event.get("value") == "dark" for event in appearance_writes))

        response, _ = self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("settings", "get")
        persisted_parent = self.assert_success(response)["defaultParentFolder"]
        self.assertEqual(persisted_parent, str(self.fixture / "suggested-parent"))
        response, _ = self.call_cli("workspace", "suggest", "--parent", persisted_parent)
        self.assertEqual(
            self.assert_success(response)["repositories"],
            sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]),
            "A fresh bridge request should discover repositories under the persisted default parent.",
        )
        alternate_parent = self.alternate.parent
        response, _ = self.call_cli("settings", "set-parent", alternate_parent)
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(alternate_parent))
        response, _ = self.call_cli("settings", "get")
        persisted_parent = self.assert_success(response)["defaultParentFolder"]
        self.assertEqual(persisted_parent, str(alternate_parent))
        response, _ = self.call_cli("workspace", "suggest", "--parent", persisted_parent)
        self.assertEqual(self.assert_success(response)["repositories"], [str(self.alternate)])
        response, _ = self.call_cli("settings", "set-parent", self.fixture / "absent", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["defaultParentFolder"], str(alternate_parent))
        response, _ = self.call_cli("settings", "clear-parent")
        self.assertIsNone(self.assert_success(response)["defaultParentFolder"])
    # case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | The configured-root workspace repos list API returns top-level Git repositories while excluding nested repositories and symlink targets. The conversation picker shows those suggestions, filters by repository name or parent path, and reports no matches for non-repository folders.
    def test_repository_suggestions_skip_nested_repositories_and_symlinks(self):
        root = self.fixture / "suggested-parent"
        _, _ = self.call_cli("settings", "set-parent", root)
        response, _ = self.call_cli("workspace", "repos", "list")
        repository_list = self.assert_success(response)
        self.assertEqual(repository_list["root"], str(root))
        self.assertEqual(repository_list["repositories"], sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]))
        self.assertNotIn(str(self.nested), repository_list["repositories"])
        self.assertNotIn(str(self.external), repository_list["repositories"])

        response, _ = self.call_cli("workspace", "suggest", "--parent", self.fixture / "suggested-parent")
        repositories = self.assert_success(response)["repositories"]
        self.assertEqual(repositories, sorted([str(self.primary), str(self.secondary), str(self.alternate), str(self.changes)]))
        self.assertNotIn(str(self.nested), repositories)
        self.assertNotIn(str(self.external), repositories)
    # case-contract: test_new_task_remembers_last_selected_repositories | The CLI reads and writes ordered last-selected repositories across fresh XPC connections; repository batches prepare managed worktrees in order, use task-title-derived branches and main/main merge settings, and set the active task roots to those worktrees. The selected source repository list remains saved and applies to subsequent tasks. Invalid repository paths are rejected without changing the saved preference. In the UI, a new conversation automatically attaches saved repositories in order while the picker stays closed and the composer remains focused. Opening the picker and choosing another suggestion adds it to the ordered context and saved selection for subsequent conversations. Each saved selection also feeds a newest-first recent repository history of up to twenty repositories that keeps repositories after they are removed from the selection; the task repository recent command lists those that still exist and are not attached to the task, and rejects an unknown task. In the UI, attached repositories appear as large chips carrying a remove badge and the header shows no suggestion chips; removing a repository through its badge makes the add-repository picker list it under Recent before anything is typed, clicking it adds it back to the task and saved selection, and typing a query replaces the recent list with the regular search suggestions.
    def test_new_task_remembers_last_selected_repositories(self):
        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.secondary, "--repo", self.primary)
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.secondary), str(self.primary)])

        created, _ = self.call_cli("task", "create", "--title", "Apply remembered repositories", "--prompt", "Fixture task description.")
        first_task_id = self.assert_success(created)["id"]
        restored, _ = self.call_cli(
            "task", "repository", "add-batch", first_task_id,
            "--repo", self.secondary,
            "--repo", self.primary,
        )
        restored_task = self.assert_success(restored)
        expected_repositories = [str(self.secondary), str(self.primary)]
        first_repositories = restored_task["repositoryWorktrees"]
        self.assertEqual([item["repositoryPath"] for item in first_repositories], expected_repositories)
        self.assertEqual(
            restored_task["workspaceRoots"],
            [item["worktreePath"] for item in first_repositories],
            "The AI-facing repository API should return active managed worktrees as task roots.",
        )
        self.assertEqual([item["branch"] for item in first_repositories], ["apply-remembered-repositories"] * 2)
        self.assertTrue(all(not item["isPending"] for item in first_repositories))
        self.assertEqual([item["branchFrom"] for item in first_repositories], ["main", "main"])
        self.assertEqual([item["mergeTarget"] for item in first_repositories], ["main", "main"])

        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.alternate)
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

        created, _ = self.call_cli("task", "create", "--title", "Apply updated remembered repository", "--prompt", "Fixture task description.")
        second_task_id = self.assert_success(created)["id"]
        restored, _ = self.call_cli(
            "task", "repository", "add-batch", second_task_id,
            "--repo", self.alternate,
        )
        restored_task = self.assert_success(restored)
        second_repositories = restored_task["repositoryWorktrees"]
        self.assertEqual([item["repositoryPath"] for item in second_repositories], [str(self.alternate)])
        self.assertEqual(restored_task["workspaceRoots"], [second_repositories[0]["worktreePath"]])
        self.assertEqual([item["branch"] for item in second_repositories], ["apply-updated-remembered-repository"])
        self.assertEqual([item["branchFrom"] for item in second_repositories], ["main"])
        self.assertEqual([item["mergeTarget"] for item in second_repositories], ["main"])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

        response, _ = self.call_cli("settings", "set-last-repositories", "--repo", self.fixture / "absent", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["lastSelectedRepositories"], [str(self.alternate)])

        # Every saved selection feeds a newest-first recent history that outlives the selection.
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(
            self.assert_success(response)["recentRepositories"],
            [str(self.alternate), str(self.secondary), str(self.primary)],
        )
        recent, _ = self.call_cli("task", "repository", "recent", second_task_id)
        self.assertEqual(
            self.assert_success(recent)["repositories"],
            [str(self.secondary), str(self.primary)],
            "Recent suggestions should exclude repositories already attached to the task.",
        )
        removed, _ = self.call_cli("task", "repository", "remove", second_task_id, "--repo", self.alternate)
        self.assertEqual(self.assert_success(removed)["repositoryWorktrees"], [])
        response, _ = self.call_cli("settings", "get")
        removed_settings = self.assert_success(response)
        self.assertEqual(removed_settings["lastSelectedRepositories"], [])
        self.assertEqual(
            removed_settings["recentRepositories"],
            [str(self.alternate), str(self.secondary), str(self.primary)],
            "Removing a repository must keep it in the recent history.",
        )
        recent, _ = self.call_cli("task", "repository", "recent", second_task_id)
        self.assertEqual(
            self.assert_success(recent)["repositories"],
            [str(self.alternate), str(self.secondary), str(self.primary)],
            "A removed repository should be suggested again for quick re-adding.",
        )
        created, _ = self.call_cli("task", "create", "--title", "Quick add recent repository", "--prompt", "Fixture task description.")
        quick_task_id = self.assert_success(created)["id"]
        quick_added, _ = self.call_cli("task", "repository", "add", quick_task_id, "--repo", self.alternate)
        self.assertEqual(
            [item["repositoryPath"] for item in self.assert_success(quick_added)["repositoryWorktrees"]],
            [str(self.alternate)],
        )
        recent, _ = self.call_cli("task", "repository", "recent", quick_task_id)
        self.assertEqual(self.assert_success(recent)["repositories"], [str(self.secondary), str(self.primary)])

        # The history keeps twenty repositories and skips missing ones when suggesting.
        extras = []
        for index in range(21):
            extra = self.data_directory / f"recent-repository-{index:02d}"
            extra.mkdir()
            subprocess.run(["git", "init", "-q", str(extra)], check=True)
            extras.append(extra)
        command = ["settings", "set-last-repositories"]
        for extra in extras:
            command.extend(["--repo", extra])
        self.assert_success(self.call_cli(*command)[0])
        response, _ = self.call_cli("settings", "get")
        self.assertEqual(self.assert_success(response)["recentRepositories"], [str(extra) for extra in extras[:20]])
        shutil.rmtree(extras[1])
        recent, _ = self.call_cli("task", "repository", "recent", quick_task_id)
        self.assertEqual(
            self.assert_success(recent)["repositories"],
            [str(extras[0])] + [str(extra) for extra in extras[2:20]],
        )
        response, _ = self.call_cli("task", "repository", "recent", str(uuid.uuid4()), expected_status=3)
        self.assert_failure(response, "not_found")
    # case-contract: test_new_task_repository_restore_is_atomic_on_invalid_default | Applying an ordered repository batch with a valid repository followed by an empty Git repository fails without mutation: the CLI reports invalid_argument and fresh reads show no repository attachments or workspace roots; New Task automatically applies saved repositories; an invalid batch shows an error, attaches neither repository, keeps roots empty, preserves the saved order, and leaves the picker closed by default.
    def test_new_task_repository_restore_is_atomic_on_invalid_default(self):
        created, _ = self.call_cli("task", "create", "--title", "Atomic repository restore", "--prompt", "Fixture task description.")
        task_id = self.assert_success(created)["id"]
        initial, _ = self.call_cli("task", "get", task_id)
        initial_task = self.assert_success(initial)
        self.assertEqual(initial_task["workspaceRoots"], [])
        self.assertEqual(initial_task["repositoryWorktrees"], [])
        saved_defaults, _ = self.call_cli(
            "settings", "set-last-repositories",
            "--repo", self.primary,
            "--repo", self.empty_git_repository,
        )
        self.assertEqual(
            self.assert_success(saved_defaults)["lastSelectedRepositories"],
            [str(self.primary), str(self.empty_git_repository)],
        )

        response, _ = self.call_cli(
            "task", "repository", "add-batch", task_id,
            "--repo", self.primary,
            "--repo", self.empty_git_repository,
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

        fresh, _ = self.call_cli("task", "get", task_id)
        fresh_task = self.assert_success(fresh)
        self.assertEqual(fresh_task["workspaceRoots"], [], "A failed batch must not persist any roots.")
        self.assertEqual(fresh_task["repositoryWorktrees"], [], "A failed batch must not persist a partial repository attachment.")
        roots, _ = self.call_cli("task", "roots", "get", task_id)
        self.assertEqual(self.assert_success(roots)["roots"], [])
        settings, _ = self.call_cli("settings", "get")
        self.assertEqual(
            self.assert_success(settings)["lastSelectedRepositories"],
            [str(self.primary), str(self.empty_git_repository)],
            "A failed restore must preserve the ordered repository defaults.",
        )
    # case-contract: test_new_task_has_empty_conversation_history | The CLI creates an Untitled task with no roots, logs task.create.succeeded for its ID, verifies empty history, and deletes it cleanly. New Task logs start and completion events with the same attempt ID and created task ID, then opens one empty conversation with the repository picker closed, the composer focused, and no create sheet. With no selected repositories, the empty conversation prominently says no repository is selected; typing starts immediately and, with a configured repository root, the UI enables standalone Send. Adding folder-only context leaves history empty, and backing out deletes the pending task without confirmation.
    def test_new_task_has_empty_conversation_history(self):
        response, _ = self.call_cli("task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.")
        task_id = self.assert_success(response)["id"]
        task_create = next((event for event in self.diagnostic_events()
                            if event.get("event") == "task.create.succeeded" and event.get("taskID") == task_id), None)
        self.assertIsNotNone(task_create, "Creating a task through CLI/XPC should persist its success diagnostic.")
        response, _ = self.call_cli("task", "get", task_id)
        task = self.assert_success(response)
        self.assertEqual(task["title"], "Untitled task")
        self.assertEqual(task["contextFolders"], [])
        self.assertEqual(task["workspaceRoots"], [])
        self.assertEqual(task["repositoryWorktrees"], [])
        response, _ = self.call_cli("conversation", "history", task_id)
        history = self.assert_success(response)
        self.assertEqual(history["activities"], [])
        self.assertEqual(history["messages"], [])
        self.assertIsNone(history.get("diff"))
        response, _ = self.call_cli("task", "delete", task_id)
        self.assertTrue(self.assert_success(response)["deleted"])
        response, _ = self.call_cli("task", "get", task_id, expected_status=3)
        self.assert_failure(response, "not_found")
    # case-contract: test_new_task_failure_diagnostics | A real directory at the task-store write-lock path makes CLI task creation fail with operation_failed and leaves no task persisted; the paired New Task button shows the save error and writes correlated start and failure diagnostics with the same attempt ID, error domain, and code.
    def test_new_task_failure_diagnostics(self):
        write_lock = self.data_directory / "store-write.lock"
        write_lock.mkdir()
        try:
            response, _ = self.call_cli("task", "create", "--title", "Must not persist", "--prompt", "Fixture task description.", expected_status=1)
            self.assert_failure(response, "operation_failed")
            tasks, _ = self.call_cli("board", "list")
            self.assertEqual(self.assert_success(tasks)["tasks"], [])
            events = self.diagnostic_events()
            self.assertTrue(any(
                event.get("event") == "bridge.request.failed"
                and "Couldn't open the task-store-write lock" in event.get("errorDescription", "")
                for event in events
            ), "The real lock-path failure should be recorded by the bridge.")
        finally:
            write_lock.rmdir()
    # case-contract: test_task_prompt_draft_persists_after_back | Creating a repository task leaves its selected branch pending while the composer automatically saves an unsent prompt as it is typed; clearing the composer clears the stored draft, backing out needs no Save button, and reopening restores the draft without creating a branch or worktree. Blank drafts cannot be stored, and invalid status changes are rejected without mutation. If the title is renamed while delayed title generation is in flight, the late result is skipped, the renamed title persists, and diagnostics record the skip reason without prompt or title text. A prompt saved through the CLI without submitting is an unsent draft, so the composer shows it when the task is reopened. A send that fails before any turn starts, such as one into a folder that no longer exists, returns its prompt to the composer as the draft, clears the pending marker and leaves the task out of In Progress.
    def test_task_prompt_draft_persists_after_back(self):
        suggestions, _ = self.call_cli("workspace", "suggest", "--parent", self.fixture / "suggested-parent")
        self.assertIn(str(self.primary), self.assert_success(suggestions)["repositories"])
        task = self.create_repo_task("Draft persistence", [self.primary], branches={str(self.primary): "draft-persistence"})
        self.assertEqual(task["repositoryWorktrees"][0]["branch"], "draft-persistence")
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        task_id = task["id"]
        prompt = "Please update the README and explain the change."
        response, _ = self.call_cli("task", "prompt", task_id, "--text", prompt, "--status", "Backlog")
        saved = self.assert_success(response)
        self.assertEqual(saved["savedPrompt"], prompt)
        self.assertTrue(saved["hasUnsentDraft"], "A prompt saved without submitting is an unsent draft.")
        self.assertEqual(saved["status"], "Backlog")
        invalid, _ = self.call_cli("task", "prompt", task_id, "--text", "Changed", "--status", "Not a status", expected_status=2)
        self.assert_failure(invalid, "invalid_argument")
        invalid_transition, _ = self.call_cli("task", "prompt", task_id, "--text", "Changed", "--status", "Done", expected_status=2)
        self.assert_failure(invalid_transition, "invalid_argument")
        renamed, _ = self.call_cli("task", "rename", task_id, "--title", "Stable draft title")
        self.assertEqual(self.assert_success(renamed)["title"], "Stable draft title")
        reopened, _ = self.call_cli("task", "get", task_id)
        reopened_task = self.assert_success(reopened)
        self.assertEqual(reopened_task["savedPrompt"], prompt)
        self.assertEqual(reopened_task["status"], "Backlog")
        cleared, _ = self.call_cli("task", "prompt", task_id, "--text", "")
        self.assertIsNone(self.assert_success(cleared).get("savedPrompt"))
        self.assertFalse(self.assert_success(cleared)["hasUnsentDraft"])
        restored, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(restored)["savedPrompt"], prompt)
        self.assertEqual(reopened_task["title"], "Stable draft title")

        delayed_task = self.create_task(title="Untitled task", roots=[self.primary])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-title-success-wait"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        fixture_owner = self.data_directory / ".playhouse-codex-fixture-owner"
        fixture_owner.write_text("Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8")
        ready = Path(str(executable) + ".resolve-ready")
        resume = Path(str(executable) + ".resolve-continue")
        environment = os.environ.copy()
        environment.update({
            "PLAYHOUSE_DATA_DIRECTORY": str(self.data_directory),
            "PLAYHOUSE_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "PLAYHOUSE_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": arguments.service_name,
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
        })
        process = subprocess.Popen(
            [
                str(self.cli), "conversation", "send", delayed_task["id"],
                "--message", "Explain the delayed title result.",
                "--answer", "color=Blue", "--answer", "token=fixture-secret",
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not ready.exists():
            time.sleep(0.02)
        if not ready.exists():
            resume.write_text("Release the title-generation fixture.\n", encoding="utf-8")
            output, error_output = process.communicate(timeout=30)
            self.fail(f"Title generation did not reach its delayed response: {output}\n{error_output}")
        renamed_title = "Stable title chosen while generation is pending"
        renamed, _ = self.call_cli("task", "rename", delayed_task["id"], "--title", renamed_title)
        self.assertEqual(self.assert_success(renamed)["title"], renamed_title)
        resume.write_text("Release the title-generation fixture.\n", encoding="utf-8")
        output, error_output = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, f"CLI send failed: {output}\n{error_output}")
        delayed_result = json.loads([line for line in output.splitlines() if line.strip()][-1])
        self.assertTrue(delayed_result.get("ok"), delayed_result.get("error"))
        final_task = self.assert_success(self.call_cli("task", "get", delayed_task["id"])[0])
        self.assertEqual(final_task["title"], renamed_title)
        title_events = [
            json.loads(line)
            for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == delayed_task["id"]
            and json.loads(line).get("event", "").startswith("task.title_")
        ]
        skipped = next(event for event in title_events if event["event"] == "task.title_apply.skipped")
        self.assertEqual(skipped["reason"], "title_changed")
        self.assertEqual(skipped["currentTitleState"], "custom")
        self.assertEqual(skipped["titleSource"], "codex")
        serialized_title_events = json.dumps(title_events)
        self.assertNotIn("Explain the delayed title result.", serialized_title_events)
        self.assertNotIn("Generated fixture title", serialized_title_events)

        # A send that fails before any turn starts has not delivered its prompt, so the prompt
        # returns to the composer as the unsent draft instead of staying as the last sent prompt.
        gone_root = self.fixture / "failed-send-root"
        gone_root.mkdir()
        failed_task_id = self.create_task("Failed send draft", roots=[gone_root])["id"]
        self.assert_success(self.call_cli("task", "draft", failed_task_id, "--text", "")[0])
        shutil.rmtree(gone_root)
        failed_prompt = "Send this to a folder that is gone."
        failed_send, _ = self.call_cli(
            "conversation", "send", failed_task_id, "--message", failed_prompt, expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assertFalse(failed_send.get("ok", True), failed_send)
        returned = self.assert_success(self.call_cli("task", "get", failed_task_id)[0])
        self.assertTrue(returned["hasUnsentDraft"], f"A send that never started a turn returns its prompt as the draft. error={failed_send.get('error')} record={ {k: returned.get(k) for k in ('status', 'savedPrompt', 'pendingSubmittedPrompt', 'hasUnsentDraft')} }")
        self.assertEqual(returned["savedPrompt"], failed_prompt)
        self.assertIsNone(returned.get("pendingSubmittedPrompt"))
        self.assertNotEqual(returned["status"], "In Progress")
    # case-contract: test_composer_draft_autosaves_during_active_turn | Composer text typed while the agent responds is autosaved as an unsent draft together with its attached image, without ending the turn's submitted prompt or changing its status, and malformed draft images fail validation without changing the draft. A follow-up queued from elsewhere and dispatched after the turn does not replace the draft, which stays saved after the turn ends and is restored to the composer with its image after navigating away and after an app restart. Text steered or queued from the composer leaves the saved draft and does not reappear after the turn, and sending the draft clears it, its images leaving once the turn starts. A submitted prompt whose turn never started returns to the composer with its images, together with the draft typed after it.
    def test_composer_draft_autosaves_during_active_turn(self):
        task_id = self.create_task(title="Draft beside an active turn")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-draft-serial-success-wait"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        image = self.data_directory / "draft-tiny.png"
        image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        invalid_image = self.data_directory / "draft-invalid.png"
        invalid_image.write_bytes(b"not an image")
        first_prompt = "Start the turn the draft is typed beside."
        typed_draft = "Typed while the agent responds; keep me after the turn."
        queued_text = "A follow-up queued from elsewhere during the turn."
        # The prompt's image stays in the draft until its turn starts.
        self.assert_success(self.call_cli("task", "prompt", task_id, "--text", first_prompt, "--image", image)[0])
        send_command = ["conversation", "send", task_id, "--message", first_prompt, "--image", image]
        process = self.start_cli(*send_command, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)})
        ready = Path(str(executable) + ".resolve-ready")
        release = Path(str(executable) + ".resolve-continue")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should hold the turn active while the draft is typed.")
            running = self.assert_success(self.call_cli("task", "get", task_id)[0])
            self.assertEqual(running["status"], "In Progress")
            self.assertEqual(running["pendingSubmittedPrompt"], first_prompt)
            self.assertFalse(running["hasUnsentDraft"], "The sent prompt is not an unsent draft.")
            self.assertEqual(running["draftImageDataURLs"], [], "A sent image should leave the draft once its turn starts.")

            saved = self.assert_success(self.call_cli("task", "draft", task_id, "--text", typed_draft, "--image", image)[0])
            self.assertEqual(saved["savedPrompt"], typed_draft)
            self.assertTrue(saved["hasUnsentDraft"])
            self.assertEqual(len(saved["draftImageDataURLs"]), 1)
            self.assertTrue(saved["draftImageDataURLs"][0].startswith("data:image/png;base64,"))
            self.assertEqual(saved["status"], "In Progress", "Saving a draft must not change the running task's status.")
            self.assertEqual(saved["pendingSubmittedPrompt"], first_prompt, "Saving a draft must not end the turn's submitted prompt.")
            invalid, _ = self.call_cli("task", "draft", task_id, "--text", "Replace with a bad image", "--image", invalid_image, expected_status=2)
            self.assert_failure(invalid, "invalid_argument")
            excess, _ = self.call_cli(
                "task", "draft", task_id, "--text", "Replace with too many images",
                *[argument for _ in range(9) for argument in ("--image", image)],
                expected_status=2,
            )
            self.assert_failure(excess, "invalid_argument")
            unchanged = self.assert_success(self.call_cli("task", "get", task_id)[0])
            self.assertEqual(unchanged["savedPrompt"], typed_draft)
            self.assertEqual(unchanged["draftImageDataURLs"], saved["draftImageDataURLs"])
            self.assert_success(self.call_cli("conversation", "queue", task_id, "--message", queued_text)[0])
        finally:
            release.write_text("Release the active turn.\n", encoding="utf-8")
        self.finish_cli(process, send_command)

        history = self.assert_success(self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )[0])
        user_texts = [message["text"] for message in history["messages"] if message["role"] == "user"]
        self.assertEqual(user_texts.count(queued_text), 1, "The queued follow-up should dispatch after the turn.")
        self.assertNotIn(typed_draft, user_texts, "An unsent draft must never be sent.")
        settled = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertIsNone(settled.get("pendingSubmittedPrompt"))
        self.assertNotEqual(settled["status"], "In Progress")
        self.assertEqual(settled["savedPrompt"], typed_draft, "A dispatched follow-up must not replace the unsent draft.")
        self.assertTrue(settled["hasUnsentDraft"])
        self.assertEqual(settled["draftImageDataURLs"], saved["draftImageDataURLs"])

        # The composer hands a steered or queued draft off by saving the emptied composer.
        cleared = self.assert_success(self.call_cli("task", "draft", task_id, "--text", "")[0])
        self.assertIsNone(cleared.get("savedPrompt"))
        self.assertEqual(cleared["draftImageDataURLs"], [])
        self.assertFalse(cleared["hasUnsentDraft"])
        # A CLI prompt write does not consume draft images, so the image stays the unsent draft.
        self.assert_success(self.call_cli("task", "draft", task_id, "--text", "", "--image", image)[0])
        unmarked = self.assert_success(self.call_cli("task", "prompt", task_id, "--text", "")[0])
        self.assertTrue(unmarked["hasUnsentDraft"], "Draft images stay an unsent draft through an unsubmitted CLI prompt write.")
        self.assertEqual(len(unmarked["draftImageDataURLs"]), 1, "An image waiting for its turn stays in the draft.")
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--image", image,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )[0])
        image_only_sent = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(image_only_sent["draftImageDataURLs"], [], "An image-only send must not return its image to the composer.")
        self.assertFalse(image_only_sent["hasUnsentDraft"])
        # A send of the draft itself clears the mark even when the draft text matches.
        self.assert_success(self.call_cli("task", "draft", task_id, "--text", typed_draft)[0])
        sent = self.assert_success(self.call_cli(
            "task", "prompt", task_id, "--text", typed_draft, "--status", "In Progress", "--submitted", "true"
        )[0])
        self.assertFalse(sent["hasUnsentDraft"])
        self.assertEqual(sent["pendingSubmittedPrompt"], typed_draft)

        never_started = self.create_task(title="Draft beside a turn that never started")["id"]
        submitted = "Submitted before Playhouse restarted."
        later_draft = "Typed after sending, before the restart."
        self.assert_success(self.call_cli(
            "task", "prompt", never_started, "--text", submitted, "--status", "In Progress", "--submitted", "true"
        )[0])
        self.assert_success(self.call_cli("task", "draft", never_started, "--text", later_draft)[0])
        recovered = self.assert_success(self.call_cli("task", "reconcile", never_started)[0])
        self.assertEqual(recovered["status"], "Waiting Response")
        self.assertIsNone(recovered.get("pendingSubmittedPrompt"))
        self.assertEqual(recovered["savedPrompt"], submitted + "\n\n" + later_draft)
        self.assertTrue(recovered["hasUnsentDraft"])
        never_started_image = self.create_task(title="Image prompt whose turn never started")["id"]
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
        self.assert_success(self.call_cli("task", "draft", never_started_image, "--text", "")[0])
        self.assert_success(self.call_cli(
            "task", "prompt", never_started_image, "--text", submitted, "--image", image,
            "--status", "In Progress", "--submitted", "true",
        )[0])
        recovered_image = self.assert_success(self.call_cli("task", "reconcile", never_started_image)[0])
        self.assertEqual(recovered_image["savedPrompt"], submitted)
        self.assertEqual(len(recovered_image["draftImageDataURLs"]), 1, "A never-started prompt should return with its image.")
        self.assertTrue(recovered_image["hasUnsentDraft"])

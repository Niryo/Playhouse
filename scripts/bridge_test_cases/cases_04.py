from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases04:
    # case-contract: test_legacy_store_import_failure_preserves_original | An invalid legacy database fails import without changing the source or publishing a destination or partial snapshot; the normal isolated board remains usable.
    def test_legacy_store_import_failure_preserves_original(self):
        self.assert_success(self.call_cli("task", "create", "--title", "Healthy board", "--prompt", "Fixture task description.", "--root", self.primary)[0])
        failure = self.data_directory / "invalid-legacy"
        failure.mkdir()
        source = failure / "Playhouse.store"
        contents = b"Not a SQLite database"
        source.write_bytes(contents)
        response, _ = self.call_cli("task", "list", expected_status=1, extra_environment={"PLAYHOUSE_DATA_DIRECTORY": str(failure)})
        self.assertFalse(response["ok"])
        self.assertEqual(source.read_bytes(), contents)
        self.assertFalse((failure / "Playhouse-v2.store").exists())
        self.assertFalse(list(failure.glob(".store-import-*")))
        self.assertEqual(self.assert_success(self.call_cli("task", "list")[0])["tasks"][0]["title"], "Healthy board")
    # case-contract: test_task_store_repairs_missing_pending_prompt_column | A real legacy SwiftData task store with in-progress timing columns and no submitted-prompt column waits for the store-write lock while CLI/XPC reads concurrently; migration backs up before adding the missing VARCHAR prompt column as nullable with no default and preserves elapsed time at zero. The CLI preserves the task and its saved prompt, which a store from before drafts were flagged does not restore as a draft, and the visible app opens the migrated store with an empty composer that keeps the saved prompt through a subsequent restart with duration still zero; metadata advances and later opens create no additional backup. The store is imported once into the protected filename and the legacy database remains unchanged. Committed WAL-only saved prompt data survives import, and a subsequent edited draft survives restart without reimport.
    def test_task_store_repairs_missing_pending_prompt_column(self):
        seeded = subprocess.run(
            [str(arguments.legacy_store_seeder), str(self.data_directory)],
            check=True, capture_output=True, text=True,
        )
        task_id = seeded.stdout.strip()
        draft = "Keep this draft through the store repair."
        store = self.data_directory / "Playhouse-v2.store"
        legacy_store = self.data_directory / "Playhouse.store"
        with sqlite3.connect(legacy_store) as database:
            columns = {row[1] for row in database.execute("PRAGMA table_info(ZBOARDTASK)")}
            self.assertNotIn("ZPENDINGSUBMITTEDPROMPT", columns)
            self.assertTrue({"ZINPROGRESSSTARTEDAT", "ZTOTALINPROGRESSSECONDS"} <= columns)
            self.assertEqual(database.execute("SELECT count(*) FROM ZBOARDTASK").fetchone()[0], 1)
            legacy_metadata = plistlib.loads(database.execute("SELECT Z_PLIST FROM Z_METADATA").fetchone()[0])
            legacy_hash = legacy_metadata["NSStoreModelVersionHashes"]["BoardTask"]
            self.assertEqual(len(legacy_hash), 32)

        wal = sqlite3.connect(legacy_store)
        self.addCleanup(wal.close)
        wal.execute("PRAGMA journal_mode=WAL")
        wal.execute("PRAGMA wal_autocheckpoint=0")
        draft = "Committed WAL draft must survive import."
        wal.execute("UPDATE ZBOARDTASK SET ZSAVEDPROMPT = ?", (draft,))
        wal.commit()
        self.assertGreater(Path(str(legacy_store) + "-wal").stat().st_size, 0)
        legacy_bytes = legacy_store.read_bytes()
        barrier = TaskStoreWriteLockBarrier(self.data_directory)
        try:
            waiting = self.start_cli("task", "get", task_id)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not any(
                event.get("event") == "persistence.store.schema_migration.waiting_for_write_lock"
                for event in self.diagnostic_events()
            ):
                time.sleep(0.05)
            self.assertTrue(any(
                event.get("event") == "persistence.store.schema_migration.waiting_for_write_lock"
                for event in self.diagnostic_events()
            ), "The legacy-store open should wait for the real store-write lock.")
            self.assertIsNone(waiting.poll(), "The XPC read must not bypass the held migration lock.")
            self.assertFalse(list(self.data_directory.glob("Playhouse.store.before-pending-prompt-*.backup")))
        finally:
            barrier.release()
        reopened, _ = self.finish_cli(waiting, ("task", "get", task_id))
        self.assertEqual(self.assert_success(reopened)["savedPrompt"], draft)
        self.assertFalse(self.assert_success(reopened)["hasUnsentDraft"], "A pre-flag saved prompt is not restored as a draft.")
        self.assertEqual(self.assert_success(reopened)["title"], "Legacy pending prompt store")
        self.assertTrue(any(
            event.get("event") == "persistence.store.schema_migration.write_lock_acquired"
            and int(event.get("waitMilliseconds", "0")) > 0
            for event in self.diagnostic_events()
        ))
        backups = list(self.data_directory.glob("Playhouse.store.before-pending-prompt-*.backup"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        with sqlite3.connect(backups[0]) as backup:
            self.assertEqual(backup.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertEqual(backup.execute("SELECT count(*) FROM ZBOARDTASK").fetchone()[0], 1)
            backup_columns = {row[1] for row in backup.execute("PRAGMA table_info(ZBOARDTASK)")}
            self.assertNotIn("ZPENDINGSUBMITTEDPROMPT", backup_columns)
            self.assertTrue({"ZINPROGRESSSTARTEDAT", "ZTOTALINPROGRESSSECONDS"} <= backup_columns)
        listed, _ = self.call_cli("board", "list")
        self.assertEqual([item["id"] for item in self.assert_success(listed)["tasks"]], [task_id])
        self.assertEqual(len(list(self.data_directory.glob("Playhouse.store.before-pending-prompt-*.backup"))), 1)
        self.assertEqual(legacy_store.read_bytes(), legacy_bytes)
        with sqlite3.connect(store) as database:
            migrated_columns = {row[1] for row in database.execute("PRAGMA table_info(ZBOARDTASK)")}
            self.assertTrue({"ZPENDINGSUBMITTEDPROMPT", "ZINPROGRESSSTARTEDAT", "ZTOTALINPROGRESSSECONDS"} <= migrated_columns)
            prompt_column = next(row for row in database.execute("PRAGMA table_info(ZBOARDTASK)") if row[1] == "ZPENDINGSUBMITTEDPROMPT")
            self.assertEqual((prompt_column[2], prompt_column[3], prompt_column[4]), ("VARCHAR", 0, None))
            duration_column = next(row for row in database.execute("PRAGMA table_info(ZBOARDTASK)") if row[1] == "ZTOTALINPROGRESSSECONDS")
            self.assertEqual((duration_column[2], duration_column[3], duration_column[4]), ("FLOAT", 0, None))
            self.assertEqual(database.execute("SELECT ZTOTALINPROGRESSSECONDS FROM ZBOARDTASK").fetchone()[0], 0)
            migrated_metadata = plistlib.loads(database.execute("SELECT Z_PLIST FROM Z_METADATA").fetchone()[0])
            self.assertNotEqual(migrated_metadata["NSStoreModelVersionHashes"]["BoardTask"], legacy_hash)
        self.assertEqual(
            len([event for event in self.diagnostic_events() if event.get("event") == "persistence.store.schema_repaired"]),
            1,
        )

        self.assert_success(self.call_cli("task", "prompt", task_id, "--text", "Edited after import", "--status", "Backlog")[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["savedPrompt"], "Edited after import")
        self.assertEqual(len([e for e in self.diagnostic_events() if e.get("event") == "persistence.store.legacy_imported"]), 1)
    # case-contract: test_test_bundle_rejects_unisolated_data_directory | A test-built Playhouse service rejects a data directory outside the temporary test area and a linked store inside it before creating or opening either store; the visible app remains on its isolated board and can still read its tasks.
    def test_test_bundle_rejects_unisolated_data_directory(self):
        unsafe = Path.home() / "Library" / "Caches" / f"Playhouse-bridge-guard-{uuid.uuid4()}"
        self.assertFalse(unsafe.exists())
        unsafe.mkdir(parents=True)
        marker = unsafe / ".playhouse-test-owner"
        marker.write_text("Playhouse bridge guard test (v1).\n", encoding="utf-8")
        try:
            response, _ = self.call_cli(
                "board", "list", expected_status=1,
                extra_environment={"PLAYHOUSE_DATA_DIRECTORY": str(unsafe)},
            )
            self.assert_failure(response, "operation_failed")
            self.assertIn("isolated temporary data directory", response["error"]["message"])
            self.assertFalse((unsafe / "Playhouse-v2.store").exists())
            linked = self.data_directory / "linked-store"
            linked.mkdir()
            (linked / "Playhouse-v2.store").symlink_to(unsafe / "Playhouse-v2.store")
            response, _ = self.call_cli(
                "board", "list", expected_status=1,
                extra_environment={"PLAYHOUSE_DATA_DIRECTORY": str(linked)},
            )
            self.assert_failure(response, "operation_failed")
            self.assertIn("linked task store", response["error"]["message"])
            self.assertFalse((unsafe / "Playhouse-v2.store").exists())
            good, _ = self.call_cli("board", "list")
            self.assertEqual(self.assert_success(good)["tasks"], [])
        finally:
            self.assertEqual(marker.read_text(encoding="utf-8"), "Playhouse bridge guard test (v1).\n")
            shutil.rmtree(unsafe)
    # case-contract: test_task_worktree_preparation_serializes_auto_branch_claims | Tasks with the same automatic branch choice remain pending without creating a worktree before conversation start. When one task has claimed the generated branch, a send from the other (through the CLI) succeeds with its own suffixed branch and a separate worktree, leaving both tasks started; the opt-in live provider integration sends both turns concurrently and confirms each task gets a distinct branch and worktree.
    def test_task_worktree_preparation_serializes_auto_branch_claims(self):
        title = f"Concurrent auto branch {uuid.uuid4().hex[:8]}"
        existing_worktree_count = self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree ")
        tasks = [
            self.create_repo_task(title, [self.primary]),
            self.create_repo_task(title, [self.primary]),
        ]
        self.assertEqual(self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree "), existing_worktree_count)
        records = [self.assert_success(self.call_cli("task", "get", task["id"])[0]) for task in tasks]
        self.assertTrue(all(record["repositoryWorktrees"][0]["isPending"] for record in records))
        self.assertTrue(all(record["repositoryWorktrees"][0]["branch"] == "auto" for record in records))
        self.assertTrue(all(record["repositoryWorktrees"][0]["worktreePath"] == str(self.primary) for record in records))
        self.assertTrue(all(record["status"] == "Backlog" for record in records))
        winner, loser = tasks
        self.complete_fixture_turn(winner["id"])
        claimed = self.assert_success(self.call_cli("task", "get", winner["id"])[0])["repositoryWorktrees"][0]
        self.assertFalse(claimed["isPending"])
        claimed_count = self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree ")
        self.assertEqual(claimed_count, existing_worktree_count + 1)
        self.complete_fixture_turn(loser["id"], message="Claim the same generated title.")
        started = self.assert_success(self.call_cli("task", "get", loser["id"])[0])
        loser_record = started["repositoryWorktrees"][0]
        self.assertFalse(loser_record["isPending"])
        self.assertNotEqual(loser_record["branch"], claimed["branch"])
        self.assertNotEqual(loser_record["worktreePath"], claimed["worktreePath"])
        self.assertEqual(self.run_git(self.primary, "worktree", "list", "--porcelain").count("worktree "), claimed_count + 1)
    # case-contract: test_auto_branch_gets_suffix_when_name_is_taken | Two tasks with the same title and an automatic branch on one repository both start: the first gets the title slug, the second a fresh branch named like the slug plus a hyphen and four lowercase letters or digits, in a different worktree. An existing local branch named like the slug, with no task using it, is never checked out: a new automatic task gets a suffixed fresh branch started from its branch-from. The visible task conversation shows the resolved suffixed branch.
    def test_auto_branch_gets_suffix_when_name_is_taken(self):
        title = f"Suffix branch {uuid.uuid4().hex[:8]}"
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        suffixed = re.compile(rf"^{re.escape(slug)}-[a-z0-9]{{4}}$")
        first = self.create_repo_task(title, [self.primary], materialize=True)
        second = self.create_repo_task(title, [self.primary], materialize=True)
        first_record = first["repositoryWorktrees"][0]
        second_record = second["repositoryWorktrees"][0]
        self.assertEqual(first_record["branch"], slug)
        self.assertRegex(second_record["branch"], suffixed)
        self.assertNotEqual(first_record["worktreePath"], second_record["worktreePath"])
        self.assertTrue(Path(second_record["worktreePath"]).is_dir())
        self.assertEqual(self.run_git(second_record["worktreePath"], "rev-parse", "--abbrev-ref", "HEAD").strip(), second_record["branch"])

        stale_title = f"Stale branch {uuid.uuid4().hex[:8]}"
        stale_slug = re.sub(r"[^a-z0-9]+", "-", stale_title.lower()).strip("-")
        self.run_git(self.primary, "branch", stale_slug, "HEAD")
        stale_commit = self.run_git(self.primary, "rev-parse", stale_slug).strip()
        self.run_git(self.primary, "branch", "branch-source-for-suffix", "HEAD")
        third = self.create_repo_task(
            stale_title, [self.primary], branch_from={str(self.primary): "branch-source-for-suffix"}, materialize=True,
        )
        third_record = third["repositoryWorktrees"][0]
        self.assertRegex(third_record["branch"], re.compile(rf"^{re.escape(stale_slug)}-[a-z0-9]{{4}}$"))
        self.assertEqual(third_record["branchFrom"], "branch-source-for-suffix")
        self.assertEqual(self.run_git(self.primary, "rev-parse", stale_slug).strip(), stale_commit)
        self.assertNotIn(f"branch refs/heads/{stale_slug}\n", self.run_git(self.primary, "worktree", "list", "--porcelain") + "\n")
    # case-contract: test_task_done_removes_worktree_and_preserves_branch | Sending the first message derives an auto branch from the generated task title, with a prompt fallback when title generation fails. Every linked PR must be merged before the task can move to Done. App focus checks each linked PR no more than once per 20 seconds; rapid focus changes are coalesced into one refresh after the cooldown. An unmerged PR keeps its link and suppresses the completion button. PR links and the green completion button have hit targets of at least 30×30 points. After all PRs merge, a later focus check replaces their links with a green completion button; clicking it waits for the task lock and then trusts that already-confirmed merge state, moving the task to Done immediately without re-querying GitHub even if merge status changed while the lock was held. The CLI's task move command has no such cached state, so it always verifies merge status directly with GitHub before completing, including rechecking after waiting for a contended task lock, and reports unmerged pull requests instead of completing when a PR is not actually merged. Completion removes managed worktrees while preserving their branches, does not merge into the local target, retains conversation history, and exposes the task in the searchable archive, whose conversation keeps its composer for follow-up questions; the CLI searches matching local Codex JSONL session files, including current input_text and output_text message content, without loading conversation histories, while the visible archive searches both user input_text and assistant output_text, loads the newest 40 first, and reveals older tasks as the user scrolls. While only some linked PRs are merged, each merged PR's number shows in merged purple and the task offers no completion checkmark until all are merged. The archive slides in from the board header's archive button as a 340-point SidePanel atom (done-archive-panel) along the window's trailing edge, and its close button slides it away until the button opens it again.
    def test_task_done_removes_worktree_and_preserves_branch(self):
        task = self.create_repo_task("Untitled task", [self.primary, self.secondary])
        draft = "Please update the README and add concise setup steps for first time contributors tomorrow."
        self.assertEqual(self.assert_success(self.call_cli("task", "prompt", task["id"], "--text", draft)[0])["savedPrompt"], draft)
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["branch"], "auto")
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        executable = self.data_directory / "codex-fixture"
        self.complete_fixture_turn(task["id"], message=draft)
        started = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        record = started["repositoryWorktrees"][0]
        self.assertFalse(record["isPending"])
        # An earlier case may already have left a branch with the generated name; auto branches then get a suffix.
        self.assertRegex(record["branch"], r"^generated-fixture-title(-[a-z0-9]{4})?$")
        worktree = Path(record["worktreePath"])
        codex_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(codex_history["threadStartCwd"], str(worktree), "The Codex thread must start in the managed task worktree.")
        self.assertEqual(codex_history["turns"][0]["cwd"], str(worktree), "The user turn must run from the managed task worktree.")
        self.assertEqual(codex_history["turns"][0]["runtimeWorkspaceRoots"], [item["worktreePath"] for item in started["repositoryWorktrees"]])
        target_head = self.run_git(self.primary, "rev-parse", "main")
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD"), target_head)
        current, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(current)["status"], "Review")
        pr_url = self.seed_done_task_pull_request(task["id"])
        second_pr_url = self.seed_done_task_pull_request(task["id"], number=456, repository_index=1)
        gh_directory = self.data_directory / "gh-fixture"
        gh_directory.mkdir()
        gh_state = gh_directory / "state"
        gh_calls = gh_directory / "calls"
        gh_state.write_text("123=merged\n456=unmerged\n", encoding="utf-8")
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_environment = {
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "PLAYHOUSE_E2E_GH_STATE_PATH": str(gh_state),
            "PLAYHOUSE_E2E_GH_CALL_LOG": str(gh_calls),
        }
        linked = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(linked["repositoryWorktrees"][0]["pullRequestURL"], pr_url)
        self.assertEqual(linked["repositoryWorktrees"][1]["pullRequestURL"], second_pr_url)
        partial = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual({item["number"]: item["health"] for item in partial}, {123: "merged", 456: "green"}, "Only the merged PR reads as merged while its sibling is open.")
        (self.primary / "target-only.txt").write_text("Master advanced after this task branch was created.\n", encoding="utf-8")
        self.run_git(self.primary, "add", "target-only.txt")
        self.run_git(self.primary, "commit", "-m", "Advance merge target while task is under review")
        target_head = self.run_git(self.primary, "rev-parse", "main")
        move_lock = TaskOperationLockBarrier(self.data_directory, task["id"])
        move_command = ["task", "move", task["id"], "Done"]
        move_process = self.start_cli(*move_command, extra_environment=gh_environment)
        try:
            time.sleep(0.25)
            self.assertIsNone(move_process.poll(), "Moving a task to Done must wait for an active per-task operation.")
            current, _ = self.call_cli("task", "get", task["id"])
            self.assertEqual(self.assert_success(current)["status"], "Review")
        finally:
            move_lock.release()
        response, _ = self.finish_cli(move_process, move_command, expected_status=1)
        self.assert_failure(response, "invalid_transition")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review")
        gh_state.write_text("123=merged\n456=merged\n", encoding="utf-8")
        response, _ = self.call_cli(*move_command, extra_environment=gh_environment)
        self.assertEqual(self.assert_success(response)["status"], "Done")
        calls = gh_calls.read_text(encoding="utf-8").splitlines()
        self.assertEqual(sorted(calls), ["123", "123", "123", "456", "456", "456"], "The status probe and the Done verification each check both PRs once, plus the earlier move attempt.")
        self.assertFalse(worktree.exists(), "Moving a task to Done must remove its managed worktree.")
        self.assertTrue(self.branch_exists(self.primary, record["branch"]))
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main"), target_head, "Moving a task to Done must not merge into the local target.")
        self.assertEqual((self.primary / "target-only.txt").read_text(encoding="utf-8"), "Master advanced after this task branch was created.\n")
        self.assertFalse((self.primary / "task-result.txt").exists())
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]["mergeTarget"], "main")
        completed, _ = self.call_cli("task", "get", task["id"])
        self.assertEqual(self.assert_success(completed)["savedPrompt"], draft)
        board, _ = self.call_cli("board", "list")
        archived = next(item for item in self.assert_success(board)["tasks"] if item["id"] == task["id"])
        self.assertEqual(archived["status"], "Done")
        history, _ = self.call_cli(
            "conversation", "history", task["id"],
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture")},
        )
        messages = self.assert_success(history)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and "Answers received: Blue / fixture-secret." in message["text"] for message in messages))
        thread_id = started["codexThreadID"]
        sessions = self.data_directory / "codex-home" / "sessions" / "2026" / "10" / "22"
        sessions.mkdir(parents=True)
        session_file = sessions / f"rollout-2026-10-22T00-00-00-{thread_id}.jsonl"
        session_file.write_text(
            json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "LOCAL-SESSION-ONLY-user-token"}]}})
            + "\n"
            + json.dumps({"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "LOCAL-SESSION-ONLY-assistant-token"}]}})
            + "\n",
            encoding="utf-8",
        )
        search_env = {"CODEX_HOME": str(self.data_directory / "codex-home")}
        for query in ("local-session-only-user-TOKEN", "local-session-only-assistant-TOKEN"):
            search, _ = self.call_cli("archive", "search", query, extra_environment=search_env)
            search_results = self.assert_success(search)
            self.assertEqual([result["id"] for result in search_results], [task["id"]], "Archive search should find current Codex input_text/output_text content in the task's local session file.")
        invalid_search, _ = self.call_cli("archive", "search", "   ", expected_status=2, extra_environment=search_env)
        self.assert_failure(invalid_search, "invalid_argument")
        filler_ids = []
        for index in range(1, 41):
            filler = self.assert_success(self.call_cli("task", "create", "--title", f"Archive page filler {index}", "--prompt", "Fixture task description.", "--root", str(self.custom))[0])
            filler_ids.append(filler["id"])
            self.complete_fixture_turn(filler["id"])
            moved = self.assert_success(self.call_cli("task", "move", filler["id"], "Done")[0])
            self.assertEqual(moved["status"], "Done")
        board, _ = self.call_cli("board", "list")
        archived_tasks = [item for item in self.assert_success(board)["tasks"] if item["status"] == "Done"]
        archived_ids = {item["id"] for item in archived_tasks}
        self.assertGreaterEqual(len(archived_tasks), 41, "The CLI board read should retain completed tasks beyond the first visible archive page.")
        self.assertTrue(set(filler_ids).issubset(archived_ids), "All persisted archive records should remain available across pages.")
    # case-contract: test_task_done_preserves_dirty_worktree | Moving a reviewed task to Done removes its managed worktree and keeps its branch and target commit without committing or merging. When the worktree holds uncommitted changes the move is refused until the user confirms discarding them: declining keeps the task in Review with its files intact, and confirming removes them. A reviewed task stays in Review until it is moved; in the UI the Done drawer rests as a thin sliver beside, not over, the board columns (once a board wider than its window is scrolled to its trailing end) and just left of the board scroller, which keeps the window edge, opens only while a reviewed card is dragged, and returns to rest both after a card is dropped on Done and when a card is dropped back in place without moving the task.
    def test_task_done_preserves_dirty_worktree(self):
        task = self.create_repo_task("Dirty cleanup", [self.primary], materialize=True)
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.complete_fixture_turn(task["id"])
        tracked = worktree / "playhouse-primary.txt"
        tracked.write_text("Edited after review\n", encoding="utf-8")
        untracked = worktree / "unsaved.txt"
        untracked.write_text("keep me\n", encoding="utf-8")
        target_before = self.run_git(self.primary, "rev-parse", "main")
        branch = task["repositoryWorktrees"][0]["branch"]
        branch_head = self.run_git(worktree, "rev-parse", "HEAD")
        persisted_review = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(persisted_review["status"], "Review", "A reviewed task should stay in Review until it is moved.")
        rejected, _ = self.call_cli("task", "move", task["id"], "Done", expected_status=1)
        self.assertEqual(rejected["error"]["code"], "invalid_transition")
        self.assertIn("discards the uncommitted changes", rejected["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review",
                         "An unconfirmed move must leave the task in Review.")
        self.assertTrue(worktree.exists(), "An unconfirmed move must keep the worktree.")
        self.assertEqual(tracked.read_text(encoding="utf-8"), "Edited after review\n")
        self.assertEqual(untracked.read_text(encoding="utf-8"), "keep me\n")
        response, _ = self.call_cli("task", "move", task["id"], "Done", "--discard-changes")
        self.assertEqual(self.assert_success(response)["status"], "Done")
        self.assertFalse(worktree.exists(), "A confirmed move must remove the worktree with its uncommitted changes.")
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main"), target_before)
        self.assertEqual(self.run_git(self.primary, "rev-parse", branch), branch_head, "The branch must keep its commits without merging.")
        self.assertTrue(self.branch_exists(self.primary, branch))
    # case-contract: test_done_task_accepts_follow_up_conversation | A Done task keeps its conversation open: the UI shows the composer with an archived hint saying a follow-up reopens the task in a fresh worktree from the merge target, instead of a read-only notice; its changes read reports no changes rather than a Git error for the removed worktree, and switching its provider is rejected. A follow-up sent from a Done task moves it back to In Progress before the turn starts, so it shows in the board's In Progress column while the agent works, with a fresh worktree renewed for the removed one. The real provider turn runs in that fresh worktree and is told it as an active task worktree rather than that the task is archived; its completed outcome moves the task to Review, the removed worktree stays removed, and the follow-up and its reply persist in the history across fresh reads. A Done task with no worktree to renew (one with only a context root) reopens to In Progress for its follow-up the same way, keeps that root, and its completed outcome moves it to Review.
    def test_done_task_accepts_follow_up_conversation(self):
        task = self.create_repo_task("Archived follow-up", [self.primary], materialize=True)
        record = task["repositoryWorktrees"][0]
        worktree = Path(record["worktreePath"])
        done = self.assert_success(self.call_cli("task", "move", task["id"], "Done")[0])
        self.assertEqual(done["status"], "Done")
        self.assertFalse(worktree.exists(), "Moving to Done removes the managed worktree before the follow-up.")
        changes = self.assert_success(self.call_cli("task", "changes", "list", task["id"])[0])
        self.assertEqual((changes["unviewed"], changes["viewed"]), ([], []), "A Done task reads no Git changes for its removed worktree instead of failing.")
        done_switch, _ = self.call_cli("conversation", "provider", task["id"], "set", "claude", expected_status=2)
        self.assert_failure(done_switch, "invalid_argument")
        self.assertIn("Done tasks are closed", done_switch["error"]["message"])
        executable = self.data_directory / "codex-fixture"
        question = "Which files did this archived task change?"
        running = {}

        def inspect_running_follow_up():
            # While the agent works on the follow-up, the task sits in the board's In Progress column.
            current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
            self.assertEqual(current["status"], "In Progress", "A follow-up moves the Done task back to In Progress.")
            board = self.assert_success(self.call_cli("board", "list")[0])["tasks"]
            self.assertEqual(next(item for item in board if item["id"] == task["id"])["status"], "In Progress")
            running["record"] = current["repositoryWorktrees"][0]

        self.complete_fixture_turn(task["id"], message=question, while_turn_held=inspect_running_follow_up)
        fresh = running["record"]
        fresh_worktree = Path(fresh["worktreePath"])
        self.assertNotEqual(fresh["worktreePath"], record["worktreePath"], "The reopened task works in a fresh worktree.")
        self.assertFalse(fresh["isPending"])
        self.assertEqual(fresh["repositoryPath"], record["repositoryPath"])
        self.assertTrue(fresh_worktree.exists(), "Reopening renews the removed worktree.")
        self.assertFalse(worktree.exists(), "The removed worktree stays removed.")
        turn_data = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        follow_up = turn_data["turns"][-1]
        self.assertIn(question, follow_up["userMessage"])
        self.assertEqual(follow_up["cwd"], fresh["worktreePath"], "The follow-up runs in the fresh worktree.")
        self.assertEqual(follow_up["runtimeWorkspaceRoots"], [fresh["worktreePath"]])
        instructions = turn_data["threadResumeDeveloperInstructions"][-1]
        self.assertNotIn("This task is Done (archived)", instructions, "The follow-up runs as an active task.")
        self.assertIn(f"Active task worktrees for edits: {record['repositoryPath']} -> {fresh['worktreePath']}", instructions)
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(current["status"], "Review", "The follow-up's completed outcome moves the reopened task to Review.")
        self.assertEqual(current["repositoryWorktrees"][0]["worktreePath"], fresh["worktreePath"])
        history = self.assert_success(self.call_cli(
            "conversation", "history", task["id"],
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )[0])["messages"]
        self.assertTrue(any(message["role"] == "user" and question in message["text"] for message in history), "The follow-up persists in the reopened task's history.")
        self.assertGreaterEqual(sum(1 for message in history if message["role"] == "assistant"), 2, "The follow-up's reply joins the earlier conversation.")

        # A task with only a context root has no worktree to renew; its follow-up still reopens it.
        rooted = self.assert_success(self.call_cli("task", "create", "--title", "Archived rooted follow-up", "--prompt", "Fixture task description.", "--root", self.primary)[0])
        self.complete_fixture_turn(rooted["id"])
        self.assertEqual(self.assert_success(self.call_cli("task", "move", rooted["id"], "Done")[0])["status"], "Done")
        rooted_running = {}

        def inspect_rooted_follow_up():
            rooted_running["record"] = self.assert_success(self.call_cli("task", "get", rooted["id"])[0])

        self.complete_fixture_turn(rooted["id"], message="One more question.", while_turn_held=inspect_rooted_follow_up)
        self.assertEqual(rooted_running["record"]["status"], "In Progress", "A follow-up reopens a Done task that has no worktree to renew.")
        self.assertEqual(rooted_running["record"]["repositoryWorktrees"], [])
        self.assertEqual(rooted_running["record"]["workspaceRoots"], [str(self.primary)])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", rooted["id"])[0])["status"], "Review")
    # case-contract: test_done_task_follow_up_reopen_failure_keeps_task_done | A follow-up to a Done task whose merge target no longer exists cannot renew its removed worktree: the send fails with the missing merge target error, the task stays Done with no new worktree and no provider turn, and the follow-up is not left pending as a submitted prompt, so the UI composer keeps its text.
    def test_done_task_follow_up_reopen_failure_keeps_task_done(self):
        target = "reopen-failure-target"
        self.run_git(self.primary, "branch", target, "main")

        def remove_target():
            if self.branch_exists(self.primary, target):
                self.run_git(self.primary, "branch", "-D", target)

        self.addCleanup(remove_target)
        task = self.create_repo_task("Reopen failure", [self.primary], merge_targets={self.primary: target}, materialize=True)
        record = task["repositoryWorktrees"][0]
        self.assertEqual(self.assert_success(self.call_cli("task", "move", task["id"], "Done")[0])["status"], "Done")
        self.assertFalse(Path(record["worktreePath"]).exists())
        self.run_git(self.primary, "branch", "-D", target)
        executable = self.data_directory / "codex-fixture"
        history_path = Path(str(executable) + ".history")
        turns_before = len(json.loads(history_path.read_text(encoding="utf-8"))["turns"])
        failed, _ = self.call_cli(
            "conversation", "send", task["id"], "--message", "Can you follow up on this?",
            expected_status=1, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_failure(failed, "operation_failed")
        self.assertIn(f"The merge target '{target}' doesn't exist", failed["error"]["message"])
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(current["status"], "Done", "A follow-up that cannot reopen the task leaves it Done.")
        self.assertEqual(current["repositoryWorktrees"][0]["worktreePath"], record["worktreePath"], "A failed reopen creates no worktree.")
        self.assertIsNone(current.get("pendingSubmittedPrompt"), "The failed follow-up is not left pending.")
        self.assertEqual(len(json.loads(history_path.read_text(encoding="utf-8"))["turns"]), turns_before, "No provider turn runs.")
    # case-contract: test_done_task_follow_up_setup_failure_restores_draft | A Done task with only a context folder reopens without creating a worktree, but if that folder disappears and no default parent is configured, a bridge follow-up send fails before a provider turn starts; the task moves to Waiting Response, and the submitted prompt returns to its draft. The test then restores the folder so the UI can reopen the task and display the returned draft.
    def test_done_task_follow_up_setup_failure_restores_draft(self):
        context_root = self.data_directory / "removed-follow-up-context"
        context_root.mkdir()
        self.assert_success(self.call_cli("settings", "set-parent", self.fixture)[0])
        task = self.assert_success(self.call_cli(
            "task", "create", "--title", "Missing follow-up root", "--prompt", "Fixture task description.", "--root", context_root,
        )[0])
        self.complete_fixture_turn(task["id"])
        self.assertEqual(self.assert_success(self.call_cli("task", "move", task["id"], "Done")[0])["status"], "Done")
        shutil.rmtree(context_root)
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "codex-fixture"
        history_path = Path(str(executable) + ".history")
        turns_before = len(json.loads(history_path.read_text(encoding="utf-8"))["turns"])
        failed, _ = self.call_cli(
            "conversation", "send", task["id"], "--message", "Follow up after the context folder vanished.",
            expected_status=1, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_failure(failed, "settings_required")
        self.assertIn("repository root folder", failed["error"]["message"].lower())
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(current["status"], "Waiting Response")
        self.assertEqual(current["repositoryWorktrees"], [])
        self.assertIsNone(current.get("pendingSubmittedPrompt"))
        self.assertTrue(current["hasUnsentDraft"])
        self.assertEqual(
            current["savedPrompt"],
            "Follow up after the context folder vanished.\n\nFixture task description.",
            "The submitted follow-up returns to draft without losing the prior unsent draft.",
        )
        board = self.assert_success(self.call_cli("board", "list")[0])["tasks"]
        self.assertEqual(next(item for item in board if item["id"] == task["id"])["status"], "Waiting Response")
        self.assertEqual(len(json.loads(history_path.read_text(encoding="utf-8"))["turns"]), turns_before, "No provider turn runs.")
        context_root.mkdir()
    # case-contract: test_merged_task_renew_opens_fresh_worktree_and_new_pr | `task repository renew` starts follow-up Git work after a pull request merged. It is rejected while the repository has no linked pull request, while the linked pull request is unmerged, and while the merged worktree has uncommitted changes, leaving the task unchanged. A merged PR status read persists that it merged, and the next turn is told the merged branch is finished and to renew before Git changes. Renewing from inside the agent's turn retires the record with its merged PR to the task's past repositories, keeps the merged branch, removes the old worktree once that turn ends, and creates a fresh worktree on a new suffixed branch based on the merge target as just fetched from the remote, so it holds the merged commits even when the local target is stale. A new pull request then opens from the fresh worktree, and the card shows the merged PR in purple beside the new one; once the task is Done, the archive row lists both, and a pull request status read of the Done task, whose worktree was removed, lists only its recorded pull requests, the retired one marked past, without probing instead of failing. A Done task renews too: a follow-up to it returns it to In Progress before its turn starts, and `task repository renew` on a Done task does the same, each with a fresh worktree for every repository whose worktree was removed (a past link only for records that had a pull request); that turn's completed outcome moves it to Review, keeping both merged PRs on fresh reads.
    def test_merged_task_renew_opens_fresh_worktree_and_new_pr(self):
        remote_root = self.data_directory / "renew-remotes"
        self.assertFalse(remote_root.exists(), "Each case must start with an isolated remote fixture directory.")
        remote_root.mkdir()
        (remote_root / ".playhouse-test-owner").write_text("Playhouse bridge test owns these renew remotes.\n", encoding="utf-8")
        remote = remote_root / "primary.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
        self.assertNotIn("origin", self.run_git(self.primary, "remote").split())

        def remove_fixture_origin():
            current = subprocess.run(["git", "-C", str(self.primary), "remote", "get-url", "origin"], check=False, capture_output=True, text=True)
            if current.returncode == 0 and current.stdout.strip() == str(remote):
                self.run_git(self.primary, "remote", "remove", "origin")

        self.addCleanup(remove_fixture_origin)
        self.run_git(self.primary, "remote", "add", "origin", str(remote))
        self.run_git(self.primary, "push", "origin", "main")

        task = self.create_repo_task("Renew merged work", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        old = task["repositoryWorktrees"][0]
        old_worktree = Path(old["worktreePath"])
        no_pr, _ = self.call_cli("task", "repository", "renew", task["id"], "--repo", str(self.primary), expected_status=1)
        self.assert_failure(no_pr, "invalid_transition")
        self.assertIn("no merged pull request", no_pr["error"]["message"])

        gh_directory = self.data_directory / "renew-gh-fixture"
        gh_directory.mkdir()
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_state = gh_directory / "state"
        create_log = gh_directory / "create-calls"
        gh_environment = {
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "PLAYHOUSE_E2E_GH_STATE_PATH": str(gh_state),
            "PLAYHOUSE_E2E_GH_CALL_LOG": str(gh_directory / "calls"),
            "PLAYHOUSE_E2E_GH_CREATE_LOG": str(create_log),
            "PLAYHOUSE_E2E_GH_CREATE_FIRST_NUMBER": "501",
        }
        self.seed_done_task_pull_request(task["id"], number=123)
        gh_state.write_text("123=unmerged\n", encoding="utf-8")
        unmerged, _ = self.call_cli("task", "repository", "renew", task["id"], "--repo", str(self.primary), expected_status=1, extra_environment=gh_environment)
        self.assert_failure(unmerged, "invalid_transition")
        self.assertIn("#123 isn't merged yet", unmerged["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]["worktreePath"], old["worktreePath"])

        # GitHub merges the PR: the remote target gains the merged commit while the local target stays stale.
        merger = remote_root / "merger"
        subprocess.run(["git", "clone", "--quiet", "--branch", "main", str(remote), str(merger)], check=True, capture_output=True, text=True)
        (merger / "merged-on-github.txt").write_text("Merged pull request #123.\n", encoding="utf-8")
        self.run_git(merger, "add", "merged-on-github.txt")
        self.run_git(merger, "-c", "user.name=Playhouse Test", "-c", "user.email=test@playhouse.invalid", "commit", "-m", "Merge pull request #123")
        self.run_git(merger, "push", "origin", "HEAD:main")
        merged_head = self.run_git(merger, "rev-parse", "HEAD").strip()
        self.assertNotEqual(self.run_git(self.primary, "rev-parse", "main").strip(), merged_head, "The local merge target must be stale.")
        gh_state.write_text("123=merged\n", encoding="utf-8")
        status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual([item["health"] for item in status], ["merged"])
        flagged = self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]
        self.assertTrue(flagged["isPullRequestMerged"], "Reading a merged PR's status persists that it merged.")

        executable = self.data_directory / "codex-fixture"
        renew_command = ("task", "repository", "renew", task["id"], "--repo", str(self.primary))
        renewal = {}

        def renew_during_turn():
            # The agent renews from inside its own turn, as the instructions tell it to.
            (old_worktree / "left-behind.txt").write_text("uncommitted\n", encoding="utf-8")
            dirty, _ = self.call_cli(*renew_command, expected_status=1, extra_environment=gh_environment)
            self.assert_failure(dirty, "operation_failed")
            self.assertIn("uncommitted changes", dirty["error"]["message"])
            (old_worktree / "left-behind.txt").unlink()
            renewal["record"] = self.assert_success(self.call_cli(*renew_command, extra_environment=gh_environment)[0])
            time.sleep(0.5)
            self.assertTrue(old_worktree.exists(), "The merged worktree stays while the turn that renewed it still runs.")

        self.complete_fixture_turn(task["id"], message="Can you follow up on the merged change?", extra_environment=gh_environment, while_turn_held=renew_during_turn)
        turn_data = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        # Later resumes carry the renewed mapping; the turn itself started with the merged guidance.
        instructions = next((item for item in turn_data["threadResumeDeveloperInstructions"] if item and "Merged pull requests:" in item), "")
        self.assertIn(f"Merged pull requests: #123 for {old['repositoryPath']} (branch {old['branch']})", instructions)
        self.assertIn("do not commit or push to it", instructions)
        self.assertIn(f"task repository renew {task['id']} --repo <path>", instructions)

        renewed = renewal["record"]
        self.assertEqual(renewed["status"], "In Progress", "Renewing a reviewed task mid-turn leaves the running turn's status alone.")
        fresh = renewed["repositoryWorktrees"][0]
        self.assertFalse(fresh["isPending"])
        self.assertTrue(fresh["createdByPlayhouse"])
        self.assertNotEqual(fresh["branch"], old["branch"])
        self.assertRegex(fresh["branch"], r"^renew-merged-work-[a-z0-9]{4}$", "The fresh branch is named like the task with a suffix because the merged branch keeps the slug.")
        self.assertNotEqual(fresh["worktreePath"], old["worktreePath"])
        self.assertEqual(fresh["branchFrom"], "origin/main")
        self.assertEqual(fresh["mergeTarget"], "main")
        self.assertIsNone(fresh.get("pullRequestNumber"))
        self.assertFalse(fresh["isPullRequestMerged"])
        fresh_worktree = Path(fresh["worktreePath"])
        self.assertEqual(self.run_git(fresh_worktree, "rev-parse", "HEAD").strip(), merged_head, "The fresh worktree starts from the merge target as just fetched.")
        self.assertTrue((fresh_worktree / "merged-on-github.txt").exists())
        self.assertEqual(renewed["workspaceRoots"], [fresh["worktreePath"]])
        past = renewed["pastRepositoryWorktrees"]
        self.assertEqual([(item["pullRequestNumber"], item["branch"], item["isPullRequestMerged"]) for item in past], [(123, old["branch"], True)])
        self.assertTrue(self.branch_exists(self.primary, old["branch"]), "Renewing keeps the merged branch.")
        deadline = time.monotonic() + 20
        while old_worktree.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(old_worktree.exists(), "The merged worktree is removed once the turn that renewed it ends.")

        (fresh_worktree / "follow-up.txt").write_text("Follow-up after the merge.\n", encoding="utf-8")
        created = self.assert_success(self.call_cli(
            "task", "pr", "create", task["id"],
            extra_environment={**gh_environment, "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )[0])
        self.assertEqual(created["repositoryWorktrees"][0]["pullRequestNumber"], 501)
        self.assertEqual([item["pullRequestNumber"] for item in created["pastRepositoryWorktrees"]], [123])
        create_targets = [line.split("\t", 2)[1] for line in create_log.read_text(encoding="utf-8").splitlines() if line.startswith("create\t")]
        self.assertEqual(create_targets, [str(fresh_worktree.resolve())], "The new pull request opens from the fresh worktree.")

        gh_state.write_text("123=merged\n501=merged\n", encoding="utf-8")
        self.assertEqual(self.assert_success(self.call_cli("task", "move", task["id"], "Done", extra_environment=gh_environment)[0])["status"], "Done")
        self.assertFalse(fresh_worktree.exists())
        for arguments in ([], ["--shared"]):
            listed = self.assert_success(self.call_cli("task", "pr", "status", task["id"], *arguments, extra_environment=gh_environment)[0])
            self.assertEqual([(item["number"], item["merged"], item.get("past")) for item in listed], [(501, True, None), (123, True, True)],
                             "A Done task whose worktree was removed lists only its recorded pull requests, the retired one marked past, without probing.")
        archived = next(item for item in self.assert_success(self.call_cli("board", "list")[0])["tasks"] if item["id"] == task["id"])
        self.assertEqual([item["pullRequestNumber"] for item in archived["pastRepositoryWorktrees"]], [123], "The Done archive keeps the PR merged before the renew.")
        self.assertEqual(archived["repositoryWorktrees"][0]["pullRequestNumber"], 501)
        self.assertTrue(archived["repositoryWorktrees"][0]["isPullRequestMerged"])

        def reopen_during_turn():
            # The follow-up itself renewed the removed worktree before its turn started.
            reopened = self.assert_success(self.call_cli("task", "get", task["id"])[0])
            self.assertEqual(reopened["status"], "In Progress", "A follow-up moves the Done task back to In Progress.")
            renewal["reopened"] = reopened

        self.complete_fixture_turn(task["id"], message="Please make one more change.", expected_status="Review", extra_environment=gh_environment, while_turn_held=reopen_during_turn)
        reopened = renewal["reopened"]
        self.assertEqual([item["pullRequestNumber"] for item in reopened["pastRepositoryWorktrees"]], [123, 501])
        self.assertTrue(all(item["isPullRequestMerged"] for item in reopened["pastRepositoryWorktrees"]))
        third = Path(reopened["repositoryWorktrees"][0]["worktreePath"])
        self.assertTrue(third.exists())
        self.assertEqual(self.run_git(third, "rev-parse", "HEAD").strip(), merged_head)
        persisted = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(persisted["status"], "Review", "The reopening turn's completed outcome moves the task to Review, not back to Done.")
        self.assertEqual([item["pullRequestNumber"] for item in persisted["pastRepositoryWorktrees"]], [123, 501])
        self.assertEqual(persisted["repositoryWorktrees"][0]["worktreePath"], str(third))

        # Reopening a multi-repository Done task renews every repository whose worktree was removed.
        multi = self.create_repo_task("Renew both repositories", [self.primary, self.secondary], materialize=True)
        self.assertEqual(self.assert_success(self.call_cli("task", "move", multi["id"], "Done")[0])["status"], "Done")
        self.assertFalse(any(Path(item["worktreePath"]).exists() for item in multi["repositoryWorktrees"]))
        both = self.assert_success(self.call_cli("task", "repository", "renew", multi["id"], "--repo", str(self.primary), extra_environment=gh_environment)[0])
        self.assertEqual(both["status"], "In Progress")
        self.assertEqual(len(both["repositoryWorktrees"]), 2)
        for before, after in zip(multi["repositoryWorktrees"], both["repositoryWorktrees"]):
            self.assertEqual(after["repositoryPath"], before["repositoryPath"])
            self.assertFalse(after["isPending"])
            self.assertNotEqual(after["worktreePath"], before["worktreePath"])
            self.assertTrue(Path(after["worktreePath"]).exists(), "Each repository of the reopened task gets a fresh worktree.")
        self.assertEqual(both["pastRepositoryWorktrees"], [], "Records without a pull request leave no past link.")
        self.complete_fixture_turn(multi["id"], message="Change both repositories.")
    # case-contract: test_task_pr_create_reports_real_gh_failure | The CLI confirms a new repository-backed task persists in Backlog; the UI shows no PR control there, then shows the active-card PR action after the conversation completes with a minimum 30-point hit target, on its own last row below the card title and time row and on the right, with that row absent while the task sits in Backlog. The active-card PR control visibly presents its native help on hover and keeps showing the pointing-hand cursor while its tooltip is up, with the arrow over the window's title bar, while hovering the card itself shows no tooltip and the card remains an openable control; the Done archive PR action remains available with its completed-task label and visibly presents its native help on hover with the pointing-hand cursor, then waits for the task lock before a real GitHub CLI or branch publication failure without saving a PR link or changing Done status. The card's PR button shows its full PR label with its hover capsule around it, not a truncated ellipsis; the button is the built-in pull requests plugin's, which `plugin list` reports as an enabled inline task card plugin.
    def test_task_pr_create_reports_real_gh_failure(self):
        task = self.create_repo_task(
            "PR failure", [self.primary], merge_targets={self.primary: "main"}
        )
        self.assertEqual(task["status"], "Backlog")
        persisted_backlog = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(persisted_backlog["status"], "Backlog")
        self.complete_fixture_turn(task["id"])
        task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(task["repositoryWorktrees"][0]["mergeTarget"], "main")
        conflicts, _ = self.call_cli("task", "pr", "conflicts", task["id"])
        self.assertEqual(self.assert_success(conflicts)["repositories"], [])
        completed, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(completed)["status"], "Done")

        command = ["task", "pr", "create", task["id"]]
        operation_lock = TaskOperationLockBarrier(self.data_directory, task["id"])
        process = self.start_cli(*command)
        try:
            time.sleep(0.25)
            self.assertIsNone(process.poll(), "PR creation should wait on the active per-task operation lock before calling gh.")
            current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
            self.assertEqual(current["status"], "Done")
            self.assertIsNone(current["repositoryWorktrees"][0].get("pullRequestNumber"))
            self.assertIsNone(current["repositoryWorktrees"][0].get("pullRequestURL"))
        except BaseException:
            if process.poll() is None:
                process.terminate()
                process.communicate()
            raise
        finally:
            operation_lock.release()
        response, _ = self.finish_cli(process, command, expected_status=1)
        self.assert_failure(response, "operation_failed")
        self.assertTrue(
            "gh auth login" in response["error"]["message"]
            or "couldn't publish the task branch" in response["error"]["message"],
            response["error"]["message"],
        )
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        record = current["repositoryWorktrees"][0]
        self.assertEqual(record["mergeTarget"], "main")
        self.assertIsNone(record.get("pullRequestNumber"))
        self.assertIsNone(record.get("pullRequestURL"))
        self.assertEqual(current["status"], "Done")

        # The card's PR button is the built-in pull requests plugin's, an inline task card plugin.
        listed = self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]
        pull_requests = next(plugin for plugin in listed if plugin["id"] == "pull-requests")
        self.assertEqual({key: pull_requests.get(key) for key in ["placement", "presentation", "builtIn", "enabled"]},
                         {"placement": "taskItem", "presentation": "inline", "builtIn": True, "enabled": True})

from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases06:
    # case-contract: test_review_sync_resolves_conflicts_with_provider_or_blocks | When the remote pull request branch conflicts with local task commits, the review sync merges the remote branch and instructs the task's provider to resolve every conflict; if conflicts remain after the provider turn, the sync fails, the task moves to Blocked with the sync failure message, the merge stays in progress for manual resolution, and the remote branch is unchanged. A rerun with the conflicts staged commits the resolution, pushes the merged branch, and returns the task to Review. The board triggers the same sync automatically when a mergeable pull request's remote head diverges from the local head.
    def test_review_sync_resolves_conflicts_with_provider_or_blocks(self):
        task = self.create_repo_task("Review sync conflicts", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        record = task["repositoryWorktrees"][0]
        worktree = Path(record["worktreePath"])
        branch = record["branch"]
        self.seed_done_task_pull_request(task["id"], number=123)
        remote = self.data_directory / "review-sync-conflict-origin.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
        self.run_git(self.primary, "remote", "add", "origin", str(remote))
        conflict_path = "review-sync-conflict.txt"
        (worktree / conflict_path).write_text("base version\n", encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        self.run_git(worktree, "commit", "-m", "Base for sync conflict")
        self.run_git(worktree, "push", "--set-upstream", "origin", branch)

        clone = self.data_directory / "review-sync-conflict-clone"
        subprocess.run(["git", "clone", "--branch", branch, str(remote), str(clone)], check=True, capture_output=True, text=True)
        (clone / conflict_path).write_text("remote version\n", encoding="utf-8")
        self.run_git(clone, "add", conflict_path)
        self.run_git(clone, "commit", "-m", "Remote conflicting commit")
        self.run_git(clone, "push", "origin", branch)
        remote_head = self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip()
        (worktree / conflict_path).write_text("local version\n", encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        self.run_git(worktree, "commit", "-m", "Local conflicting commit")
        local_head = self.run_git(worktree, "rev-parse", "HEAD").strip()

        # The provider fixture turn runs but resolves nothing, so the sync fails closed.
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-review-conflicts"
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli("task", "pr", "sync", task["id"], extra_environment=environment, expected_status=1)
        self.assert_failure(failed, "operation_failed")
        self.assertIn("couldn't resolve every merge conflict", failed["error"]["message"])
        blocked = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(blocked["status"], "Blocked")
        self.assertIn("couldn't sync this task's changes with its pull request", blocked.get("statusMessage") or "")
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), local_head)
        merge_in_progress = subprocess.run(
            ["git", "-C", str(worktree), "rev-parse", "--verify", "MERGE_HEAD"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(merge_in_progress.returncode, 0, "The failed sync should leave its merge in progress for manual resolution.")
        self.assertEqual(self.run_git(worktree, "diff", "--name-only", "--diff-filter=U").strip(), conflict_path)
        self.assertEqual(self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip(), remote_head, "A failed sync must leave the remote branch unchanged.")

        # Staging the resolution lets a rerun commit the merge, push, and restore Review.
        resolved_content = "resolved local and remote versions\n"
        (worktree / conflict_path).write_text(resolved_content, encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        healed, _ = self.call_cli("task", "pr", "sync", task["id"], extra_environment=environment)
        healed_result = self.assert_success(healed)
        self.assertEqual([item["action"] for item in healed_result["records"]], ["pushed"])
        self.assertEqual(healed_result["status"], "Review")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain", "--untracked-files=all").strip(), "")
        finished_merge = subprocess.run(
            ["git", "-C", str(worktree), "rev-parse", "--verify", "MERGE_HEAD"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(finished_merge.returncode, 128, "The rerun should finish the merge it resumed.")
        healed_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertEqual(self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip(), healed_head)
        pushed_content = subprocess.run(
            ["git", "--git-dir", str(remote), "show", f"refs/heads/{branch}:{conflict_path}"],
            check=True, capture_output=True, text=True,
        ).stdout
        self.assertEqual(pushed_content, resolved_content)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review")
        self.run_git(self.primary, "remote", "remove", "origin")
    # case-contract: test_done_archive_displays_existing_pull_request_link | CLI/XPC creates PRs for two repositories, verifies the first PR persists when the second creation fails, retries only the missing repository, confirms each gh create call targets the corresponding repository worktree, and confirms both saved numbers on fresh reads. The UI labels active-card and Done-archive multi-repository creation actions PRs, clicks the active action, verifies the partial-success retry action, confirms the gh create calls target both repository worktrees and retry only the failed one, then shows exact PR numbers on the active task and Done archive, including four-digit values without grouping separators, each with a hit target at least 30 points wide and tall. Hovering the outer padded edge of each PR link triggers its feedback.
    def test_done_archive_displays_existing_pull_request_link(self):
        task = self.create_repo_task("Archived linked PR", [self.primary, self.secondary], materialize=True)
        completed, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(completed)["status"], "Done")
        url = self.seed_done_task_pull_request(task["id"], number=1234)
        second_url = self.seed_done_task_pull_request(task["id"], number=1235, repository_index=1)

        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(current["status"], "Done")
        record = current["repositoryWorktrees"][0]
        self.assertEqual(record["pullRequestNumber"], 1234)
        self.assertEqual(record["pullRequestURL"], url)
        self.assertEqual(current["repositoryWorktrees"][1]["pullRequestNumber"], 1235)
        self.assertEqual(current["repositoryWorktrees"][1]["pullRequestURL"], second_url)
        archived = next(item for item in self.assert_success(self.call_cli("board", "list")[0])["tasks"] if item["id"] == task["id"])
        self.assertEqual(archived["repositoryWorktrees"][0]["pullRequestNumber"], 1234)
        self.assertEqual(archived["repositoryWorktrees"][1]["pullRequestNumber"], 1235)

        creating = self.create_repo_task("Create PRs for every repository", [self.primary, self.secondary], materialize=True)
        self.clear_task_provider_session(creating["id"])
        remote_root = self.data_directory / "pull-request-remotes"
        self.assertFalse(remote_root.exists(), "Each case must start with an isolated remote fixture directory.")
        remote_root.mkdir()
        (remote_root / ".playhouse-test-owner").write_text("Playhouse bridge test owns these PR remotes.\n", encoding="utf-8")
        for index, record in enumerate(creating["repositoryWorktrees"]):
            remote = remote_root / f"repository-{index}.git"
            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
            source_repository = Path(record["repositoryPath"])
            self.assertNotIn("origin", self.run_git(source_repository, "remote").split())

            def remove_fixture_origin(repository, expected_url):
                current = subprocess.run(
                    ["git", "-C", str(repository), "remote", "get-url", "origin"],
                    check=False, capture_output=True, text=True,
                )
                if current.returncode == 0 and current.stdout.strip() == str(expected_url):
                    self.run_git(repository, "remote", "remove", "origin")

            self.addCleanup(remove_fixture_origin, source_repository, remote)
            self.run_git(Path(record["worktreePath"]), "remote", "add", "origin", str(remote))
            self.run_git(Path(record["worktreePath"]), "push", "origin", "main")
            (Path(record["worktreePath"]) / "task-change.txt").write_text(f"Repository {index} task change.\n", encoding="utf-8")

        gh_directory = self.data_directory / "creation-gh-fixture"
        gh_directory.mkdir()
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_state = gh_directory / "state"
        gh_state.write_text("", encoding="utf-8")
        create_log = gh_directory / "create-calls"
        failure_path = gh_directory / "fail-create-attempt"
        failure_path.write_text("2\n", encoding="utf-8")
        gh_environment = {
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "PLAYHOUSE_E2E_GH_STATE_PATH": str(gh_state),
            "PLAYHOUSE_E2E_GH_CALL_LOG": str(gh_directory / "view-calls"),
            "PLAYHOUSE_E2E_GH_CREATE_LOG": str(create_log),
            "PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH": str(failure_path),
            "PLAYHOUSE_E2E_GH_CREATE_FIRST_NUMBER": "501",
        }
        failed_create, _ = self.call_cli("task", "pr", "create", creating["id"], expected_status=1, extra_environment=gh_environment)
        self.assert_failure(failed_create, "operation_failed")
        partially_created = self.assert_success(self.call_cli("task", "get", creating["id"])[0])
        self.assertEqual(partially_created["repositoryWorktrees"][0]["pullRequestNumber"], 501)
        self.assertIsNone(partially_created["repositoryWorktrees"][1].get("pullRequestNumber"))
        failure_path.write_text("", encoding="utf-8")
        retried = self.assert_success(self.call_cli("task", "pr", "create", creating["id"], extra_environment=gh_environment)[0])
        self.assertEqual([record["pullRequestNumber"] for record in retried["repositoryWorktrees"]], [501, 502])
        self.assertEqual(
            [record["pullRequestURL"] for record in retried["repositoryWorktrees"]],
            ["https://github.com/playhouse-test/fixture/pull/501", "https://github.com/playhouse-test/fixture/pull/502"],
        )
        create_events = create_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(sum(line.startswith("created\t") for line in create_events), 2)
        self.assertEqual(sum(line.startswith("failed\t") for line in create_events), 1)
        create_targets = [line.split("\t", 2)[1] for line in create_events if line.startswith(("create\t", "failed\t"))]
        self.assertEqual(
            create_targets,
            [str(Path(creating["repositoryWorktrees"][0]["worktreePath"]).resolve()),
             str(Path(creating["repositoryWorktrees"][1]["worktreePath"]).resolve()),
             str(Path(creating["repositoryWorktrees"][1]["worktreePath"]).resolve())],
            "Creation must target each repository, and retry only the repository whose create failed.",
        )
        fresh = self.assert_success(self.call_cli("task", "get", creating["id"])[0])
        self.assertEqual([record["pullRequestNumber"] for record in fresh["repositoryWorktrees"]], [501, 502])
    # case-contract: test_task_pr_create_skips_unchanged_repositories | PR creation opens a pull request only for repositories whose task branch has commits its merge target lacks: in a two-repository task where only the primary worktree changed, gh create runs once, against the primary worktree, the primary saves its PR number on a fresh read, and the unchanged secondary keeps no PR link instead of failing the whole operation with GitHub's no-commits error and is remembered as skipped at its branch head, so the card offers no further create action; a review sync with no change keeps the skip, and once the primary's pull request merges and the task moves to Done, the Done archive shows the primary's PR link and no create action either. A two-repository task whose every repository is unchanged is rejected with a message saying no repository has changes to open a pull request for, with no gh create call and no PR link saved, and both repositories are remembered as skipped. After the task changes one of them, the review sync clears only that repository's skip, the card's create action counts it alone as a single PR, and creating it opens exactly one more pull request, for that repository. A later change to the still-skipped repository beside that linked PR brings back a single create action for the repository without a linked pull request, and creating it links that repository too. The UI shows the primary's PR link after clicking the PRs action and reports the all-unchanged message in the failure alert.
    def test_task_pr_create_skips_unchanged_repositories(self):
        def remove_fixture_origin(repository, expected_url):
            current = subprocess.run(
                ["git", "-C", str(repository), "remote", "get-url", "origin"],
                check=False, capture_output=True, text=True,
            )
            if current.returncode == 0 and current.stdout.strip() == str(expected_url):
                self.run_git(repository, "remote", "remove", "origin")

        task = self.create_repo_task(
            "Skip unchanged repositories", [self.primary, self.secondary],
            merge_targets={self.primary: "main", self.secondary: "main"}, materialize=True,
        )
        self.clear_task_provider_session(task["id"])
        remote_root = self.data_directory / "skip-unchanged-remotes"
        self.assertFalse(remote_root.exists(), "Each case must start with an isolated remote fixture directory.")
        remote_root.mkdir()
        (remote_root / ".playhouse-test-owner").write_text("Playhouse bridge test owns these PR remotes.\n", encoding="utf-8")
        for index, record in enumerate(task["repositoryWorktrees"]):
            remote = remote_root / f"repository-{index}.git"
            subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
            self.addCleanup(remove_fixture_origin, Path(record["repositoryPath"]), remote)
            self.run_git(Path(record["worktreePath"]), "remote", "add", "origin", str(remote))
            self.run_git(Path(record["worktreePath"]), "push", "origin", "main")
        primary_worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        (primary_worktree / "task-change.txt").write_text("Only the primary repository changed.\n", encoding="utf-8")

        gh_directory = self.data_directory / "skip-unchanged-gh-fixture"
        gh_directory.mkdir()
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_state = gh_directory / "state"
        gh_state.write_text("", encoding="utf-8")
        create_log = gh_directory / "create-calls"
        gh_environment = {
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "PLAYHOUSE_E2E_GH_STATE_PATH": str(gh_state),
            "PLAYHOUSE_E2E_GH_CALL_LOG": str(gh_directory / "view-calls"),
            "PLAYHOUSE_E2E_GH_CREATE_LOG": str(create_log),
            "PLAYHOUSE_E2E_GH_CREATE_FIRST_NUMBER": "501",
        }
        created = self.assert_success(self.call_cli("task", "pr", "create", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(created["repositoryWorktrees"][0]["pullRequestNumber"], 501)
        self.assertIsNone(created["repositoryWorktrees"][1].get("pullRequestNumber"), "An unchanged repository must not get a pull request.")
        create_targets = [line.split("\t", 2)[1] for line in create_log.read_text(encoding="utf-8").splitlines() if line.startswith("create\t")]
        self.assertEqual(create_targets, [str(primary_worktree.resolve())], "gh create must run only for the changed repository.")
        fresh = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(fresh["repositoryWorktrees"][0]["pullRequestNumber"], 501)
        self.assertIsNone(fresh["repositoryWorktrees"][1].get("pullRequestNumber"))
        secondary_worktree = Path(task["repositoryWorktrees"][1]["worktreePath"])
        secondary_head = self.run_git(secondary_worktree, "rev-parse", "HEAD").strip()
        self.assertEqual(
            fresh["repositoryWorktrees"][1].get("pullRequestSkippedHead"), secondary_head,
            "The unchanged repository must be remembered as skipped so the card stops offering it a pull request.",
        )
        self.assertIsNone(fresh["repositoryWorktrees"][0].get("pullRequestSkippedHead"))

        # The review gate keeps the skip while the repository stays unchanged, and so does Done.
        self.assert_success(self.call_cli("task", "pr", "sync", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(
            self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][1].get("pullRequestSkippedHead"),
            secondary_head,
        )
        gh_state.write_text("501=merged\n", encoding="utf-8")
        self.assert_success(self.call_cli("task", "move", task["id"], "Done", extra_environment=gh_environment)[0])
        archived = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(archived["status"], "Done")
        self.assertEqual(archived["repositoryWorktrees"][0]["pullRequestNumber"], 501)
        self.assertEqual(
            archived["repositoryWorktrees"][1].get("pullRequestSkippedHead"), secondary_head,
            "The Done archive reads the same skip, so it offers no create action either.",
        )

        # The source repositories keep the origins the first task's worktrees added.
        unchanged = self.create_repo_task(
            "Nothing to propose", [self.primary, self.secondary],
            merge_targets={self.primary: "main", self.secondary: "main"}, materialize=True,
        )
        self.clear_task_provider_session(unchanged["id"])
        rejected, _ = self.call_cli("task", "pr", "create", unchanged["id"], expected_status=1, extra_environment=gh_environment)
        self.assert_failure(rejected, "invalid_transition")
        self.assertIn("No repository in this task has changes", rejected["error"]["message"])
        self.assertEqual(
            sum(line.startswith("create\t") for line in create_log.read_text(encoding="utf-8").splitlines()), 1,
            "An all-unchanged task must not call gh create.",
        )
        skipped = self.assert_success(self.call_cli("task", "get", unchanged["id"])[0])["repositoryWorktrees"]
        self.assertTrue(all(record.get("pullRequestNumber") is None for record in skipped))
        self.assertTrue(all(record.get("pullRequestSkippedHead") for record in skipped), "Both unchanged repositories must be remembered as skipped.")

        # Once the task changes one repository, the review sync offers that one a pull request again.
        later_worktree = Path(skipped[1]["worktreePath"])
        (later_worktree / "later-change.txt").write_text("The secondary repository changed later.\n", encoding="utf-8")
        self.assert_success(self.call_cli("task", "pr", "sync", unchanged["id"], extra_environment=gh_environment)[0])
        reopened = self.assert_success(self.call_cli("task", "get", unchanged["id"])[0])["repositoryWorktrees"]
        self.assertEqual(reopened[0].get("pullRequestSkippedHead"), skipped[0]["pullRequestSkippedHead"], "The still-unchanged repository stays skipped.")
        self.assertIsNone(reopened[1].get("pullRequestSkippedHead"), "A changed repository must await a pull request again.")
        created_later = self.assert_success(self.call_cli("task", "pr", "create", unchanged["id"], extra_environment=gh_environment)[0])
        self.assertIsNone(created_later["repositoryWorktrees"][0].get("pullRequestNumber"))
        self.assertEqual(created_later["repositoryWorktrees"][1]["pullRequestNumber"], 502)
        create_targets = [line.split("\t", 2)[1] for line in create_log.read_text(encoding="utf-8").splitlines() if line.startswith("create\t")]
        self.assertEqual(
            create_targets, [str(primary_worktree.resolve()), str(later_worktree.resolve())],
            "The later change must open exactly one more pull request, for the changed repository.",
        )

        # Beside a linked PR, a later change to the still-skipped repository offers it a pull request too.
        later_primary_worktree = Path(skipped[0]["worktreePath"])
        (later_primary_worktree / "later-change.txt").write_text("The primary repository changed later.\n", encoding="utf-8")
        self.assert_success(self.call_cli("task", "pr", "sync", unchanged["id"], extra_environment=gh_environment)[0])
        self.assertIsNone(self.assert_success(self.call_cli("task", "get", unchanged["id"])[0])["repositoryWorktrees"][0].get("pullRequestSkippedHead"))
        both = self.assert_success(self.call_cli("task", "pr", "create", unchanged["id"], extra_environment=gh_environment)[0])
        self.assertEqual([record.get("pullRequestNumber") for record in both["repositoryWorktrees"]], [503, 502])
        create_targets = [line.split("\t", 2)[1] for line in create_log.read_text(encoding="utf-8").splitlines() if line.startswith("create\t")]
        self.assertEqual(create_targets[-1], str(later_primary_worktree.resolve()))
        self.assertEqual(len(create_targets), 3)
    # case-contract: test_task_lifecycle_rollout_clears_records_and_clean_worktrees | The one-time lifecycle rollout clears task records and clean managed worktrees, preserves branches, and retains dirty managed worktrees with a notice.
    def test_task_lifecycle_rollout_clears_records_and_clean_worktrees(self):
        clean = self.create_repo_task("Rollout clean", [self.primary], materialize=True)
        dirty = self.create_repo_task(
            "Rollout dirty", [self.secondary], branch_from={str(self.secondary): "main"}, materialize=True
        )
        clean_record = clean["repositoryWorktrees"][0]
        dirty_record = dirty["repositoryWorktrees"][0]
        clean_path = Path(clean_record["worktreePath"])
        dirty_path = Path(dirty_record["worktreePath"])
        retained_file = dirty_path / "playhouse-secondary.txt"
        retained_file.write_text("Secondary baseline.\nKeep this worktree.\n", encoding="utf-8")
        (self.data_directory / "task-lifecycle-v2-reset").unlink()

        listed, _ = self.call_cli("task", "list")
        self.assertEqual(self.assert_success(listed)["tasks"], [])
        self.assertFalse(clean_path.exists())
        self.assertEqual(retained_file.read_text(encoding="utf-8"), "Secondary baseline.\nKeep this worktree.\n")
        self.assertEqual(self.run_git(self.primary, "show-ref", "--verify", "--quiet", f"refs/heads/{clean_record['branch']}"), "")
        self.assertEqual(self.run_git(self.secondary, "show-ref", "--verify", "--quiet", f"refs/heads/{dirty_record['branch']}"), "")
        notice = json.loads((self.data_directory / "task-lifecycle-v2-notice.json").read_text(encoding="utf-8"))
        self.assertEqual(notice, [str(dirty_path)])
    # case-contract: test_task_status_transitions_and_rejects_unknown_status | With both pairs populated, the board keeps Blocked above Backlog and Waiting Response above In Progress, washes only the Waiting Response column in its purple tint (its pixels read purple where the other columns read neutral), allows vertical scrolling to reach lower backlog tasks, leaves Review as its own column, hides empty status sections, removes Done from the columns, and rejects manual changes to Codex-owned task status; ⌘F reveals and focuses a prominent board search that filters task cards by title as text changes, while close restores all cards. Answering a question without an explicit completed outcome leaves the task in Waiting Response. Task card titles use slightly expanded letter spacing and line spacing. The board's columns stay clickable where they draw after a sideways scroll followed by a new card, without needing a window resize. The board's scroller stays hidden until the pointer is over the board, then shows at a subdued opacity while the pointer rests there, and hides again once the pointer leaves; holding its knob makes it clearly more opaque than the same knob hovered, and releasing returns it to the subdued opacity. Each board column is built from plugin atoms: the empty In Progress and Review columns show their empty state while the populated Backlog does not, and the Backlog's Add button opens a new task conversation.
    def test_task_status_transitions_and_rejects_unknown_status(self):
        task_id = self.create_task()["id"]
        response, _ = self.call_cli("task", "move", task_id, "Unknown", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        for status in ["In Progress", "Blocked", "Waiting Response", "Backlog"]:
            response, _ = self.call_cli("task", "move", task_id, status, expected_status=2)
            self.assert_failure(response, "invalid_argument")
            self.assertIn("controlled by Codex", response["error"]["message"])
        response, _ = self.call_cli("task", "move", task_id, "Review", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        self.assertIn("Only a task in Waiting Response", response["error"]["message"])
        response, _ = self.call_cli("task", "move", task_id, "Done", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        self.assertIn("Only a task in Review", response["error"]["message"])
        response, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(response)["status"], "Backlog")

        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        blocked_id = self.create_task("Blocked layout", roots=[self.secondary])["id"]
        empty_fixture = self.data_directory / "codex-fixture-status-empty"
        copy_file(fixture, empty_fixture)
        empty_fixture.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        blocked_response, _ = self.call_cli(
            "conversation", "send", blocked_id, "--message", "Please ask your questions.",
            expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(empty_fixture)},
        )
        self.assert_failure(blocked_response, "operation_failed")
        blocked = self.assert_success(self.call_cli("task", "get", blocked_id)[0])
        self.assertEqual(blocked["status"], "Blocked")
        self.assertIn("question response", blocked["statusMessage"].lower())

        waiting_id = self.create_task("Waiting layout", roots=[self.primary])["id"]
        question_fixture = self.data_directory / "codex-fixture-status-question-flow"
        copy_file(fixture, question_fixture)
        question_fixture.chmod(0o755)
        question_response, question_events = self.call_cli(
            "conversation", "send", waiting_id, "--message", "Please ask your questions.",
            "--mode", "plan", "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(question_fixture)},
        )
        self.assert_success(question_response)
        self.assertTrue(any(
            event.get("type") == "started" and event.get("payload", {}).get("taskStatus") == "In Progress"
            for event in question_events
        ), "Starting the question turn should move the task into In Progress.")
        input_event = next(event for event in question_events if event.get("type") == "user_input")
        self.assertEqual(input_event["payload"].get("taskStatus"), "Waiting Response")
        self.assertTrue(any(event.get("type") == "task_status"
                            and event.get("payload", {}).get("taskStatus") == "In Progress"
                            for event in question_events),
                        "Submitting the answer should resume the active task.")
        waiting = self.assert_success(self.call_cli("task", "get", waiting_id)[0])
        self.assertEqual(waiting["status"], "Waiting Response")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", blocked_id)[0])["status"], "Blocked")
    # case-contract: test_waiting_response_task_moves_to_review_manually | A task in Waiting Response moves to Review through the CLI and on the board, both from its card's Move to Review context-menu item, which Waiting Response and Blocked cards offer, and by dragging the card onto the Review column. The move runs the same review gate as a completed outcome: local changes on a PR-linked worktree are committed before the task reaches Review. It clears the waiting status, persists across a fresh CLI/XPC read, keeps the linked pull request, returns a task already in Review unchanged, and the moved task can still complete to Done. A Backlog task is rejected and keeps its status; a task whose turn is still running while it shows Waiting Response is rejected and keeps both its status and its uncommitted changes; and when the pull request sync fails, the move reports the error, shown on the board as an alert, and leaves the task in Waiting Response; once GitHub reports the pull request merged, a retry commits local work, skips syncing the merged branch even though its remote is unreachable, and moves the task to Review. Each transition into Waiting Response plays Ping and each transition into Review plays Glass; rejected and repeated moves play no sound.
    def test_waiting_response_task_moves_to_review_manually(self):
        def remove_fixture_origin(repository, expected_url):
            current = subprocess.run(
                ["git", "-C", str(repository), "remote", "get-url", "origin"],
                check=False, capture_output=True, text=True,
            )
            if current.returncode == 0 and current.stdout.strip() == str(expected_url):
                self.run_git(repository, "remote", "remove", "origin")

        backlog_id = self.create_task("Manual review backlog")["id"]
        rejected, _ = self.call_cli("task", "move", backlog_id, "Review", expected_status=2)
        self.assert_failure(rejected, "invalid_argument")
        self.assertIn("Only a task in Waiting Response", rejected["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", backlog_id)[0])["status"], "Backlog")

        task = self.create_repo_task("Manual review", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.seed_done_task_pull_request(task["id"], number=321)
        initial_sound_count = len([e for e in self.diagnostic_events() if e.get("event") == "task.status_sound.played" and e.get("taskID") == task["id"]])
        # Work the turn left uncommitted; the Review gate must commit it.
        (worktree / "manual-review.txt").write_text("Waiting turn output.\n", encoding="utf-8")

        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-manual-review-question-flow"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        command = ["conversation", "send", task["id"], "--message", "Please ask your questions.", "--mode", "plan"]
        process = self.start_cli(*command, extra_environment=environment)
        try:
            deadline = time.monotonic() + 60
            pending = None
            while process.poll() is None and time.monotonic() < deadline and pending is None:
                history, _ = self.call_cli("conversation", "history", task["id"], extra_environment=environment)
                pending = self.assert_success(history).get("pendingUserInputRequest")
                if pending is None:
                    time.sleep(0.1)
            self.assertIsNotNone(pending, "The blocking question should hold the turn open.")
            self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Waiting Response")
            # The pending question's turn still owns the worktree and the final status.
            sounds_before_rejection = [e for e in self.diagnostic_events() if e.get("event") == "task.status_sound.played" and e.get("taskID") == task["id"]]
            running, _ = self.call_cli("task", "move", task["id"], "Review", expected_status=2)
            self.assert_failure(running, "invalid_argument")
            self.assertIn("still running", running["error"]["message"])
            self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Waiting Response")
            self.assertIn("manual-review.txt", self.run_git(worktree, "status", "--porcelain", "--untracked-files=all"))
            self.assertEqual([e for e in self.diagnostic_events() if e.get("event") == "task.status_sound.played" and e.get("taskID") == task["id"]], sounds_before_rejection)
            answered, _ = self.call_cli(
                "conversation", "answer-user-input", task["id"], pending["id"],
                "--answer", "color=Blue", "--answer", "token=fixture-secret", extra_environment=environment,
            )
            self.assert_success(answered)
            response, _ = self.finish_cli(process, command)
            self.assert_success(response)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=20)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Waiting Response",
                         "The answered turn settles in Waiting Response.")

        # A sync that cannot reach the PR remote fails the move and leaves the task waiting.
        missing_remote = self.data_directory / "manual-review-missing-origin.git"
        self.addCleanup(remove_fixture_origin, self.primary, missing_remote)
        self.run_git(worktree, "remote", "add", "origin", str(missing_remote))
        failed, _ = self.call_cli("task", "move", task["id"], "Review", expected_status=1)
        self.assert_failure(failed, "operation_failed")
        self.assertIn("origin", failed["error"]["message"], "The failure should carry the git error for the unreachable PR remote.")
        self.assertNotIn("still running", failed["error"]["message"])
        waiting = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(waiting["status"], "Waiting Response", "A failed review sync must not move or block the task.")

        # Once GitHub reports the PR merged, its gone branch is not synced and the retry reaches Review.
        (worktree / "merged-retry.txt").write_text("Work after the failed move.\n", encoding="utf-8")
        gh_directory = self.data_directory / "manual-review-gh-fixture"
        gh_directory.mkdir()
        (gh_directory / "state").write_text("321=merged\n", encoding="utf-8")
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_environment = {
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "PLAYHOUSE_E2E_GH_STATE_PATH": str(gh_directory / "state"),
            "PLAYHOUSE_E2E_GH_CALL_LOG": str(gh_directory / "calls"),
        }
        moved = self.assert_success(self.call_cli("task", "move", task["id"], "Review", extra_environment=gh_environment)[0])
        self.run_git(self.primary, "remote", "remove", "origin")
        self.assertEqual(moved["status"], "Review")
        self.assertIsNone(moved.get("statusMessage"))
        self.assertEqual(self.run_git(worktree, "status", "--porcelain", "--untracked-files=all").strip(), "",
                         "Moving to Review should commit the PR-linked worktree's local changes like a completed turn.")
        self.assertIn("merged-retry.txt", self.run_git(worktree, "show", "--name-only", "--format=%s", "HEAD"),
                      "The merged retry should commit the work left after the failed move.")
        self.assertIn("manual-review.txt", self.run_git(worktree, "log", "--name-only", "--format=%s", "-2"))
        reread = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(reread["status"], "Review")
        self.assertEqual(reread["repositoryWorktrees"][0]["pullRequestNumber"], 321)
        again = self.assert_success(self.call_cli("task", "move", task["id"], "Review")[0])
        self.assertEqual(again["status"], "Review", "A task already in Review is returned unchanged.")
        sounds = [event for event in self.diagnostic_events()
                  if event.get("event") == "task.status_sound.played" and event.get("taskID") == task["id"]]
        self.assertEqual([event["sound"] for event in sounds[initial_sound_count:]], ["Ping", "Ping", "Glass"])
        done = self.assert_success(self.call_cli("task", "move", task["id"], "Done", "--allow-unmerged")[0])
        self.assertEqual(done["status"], "Done")
    # case-contract: test_waiting_and_blocked_tasks_move_directly_to_review_and_done | A task in Waiting Response moves straight to Done, and a Blocked task moves to Review or straight to Done, through the CLI and on the board: Waiting Response and Blocked cards offer Move to Done in their context menu, Blocked cards also offer Move to Review, a Blocked card dragged onto the Review column lands in Review, and a Blocked card dragged onto the Done drawer lands in Done; a Backlog card offers neither and a Backlog task is still rejected for both moves and keeps its status. Moving a Waiting Response task to Done while its blocking question's turn still runs is rejected as still running, shown on the board in a Couldn't move task to Done alert, and keeps the task in Waiting Response with its worktree in place; once the turn finishes, Move to Done reaches Done and removes the task's clean Playhouse worktree as a move from Review does. Moving a Blocked task to Review clears its blocked reason and plays Glass; moving one to Done clears it too. Each move persists across a fresh CLI/XPC read, and a task already in Done is returned unchanged.
    def test_waiting_and_blocked_tasks_move_directly_to_review_and_done(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        question_executable = self.data_directory / "codex-fixture-direct-move-question-flow"
        copy_file(fixture, question_executable)
        question_executable.chmod(0o755)
        empty_executable = self.data_directory / "codex-fixture-direct-move-empty"
        copy_file(fixture, empty_executable)
        empty_executable.chmod(0o755)
        question_environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(question_executable)}

        def blocked_task(title, root):
            task_id = self.create_task(title, roots=[root])["id"]
            response, _ = self.call_cli(
                "conversation", "send", task_id, "--message", "Please ask your questions.", expected_status=1,
                extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(empty_executable)},
            )
            self.assert_failure(response, "operation_failed")
            blocked = self.assert_success(self.call_cli("task", "get", task_id)[0])
            self.assertEqual(blocked["status"], "Blocked")
            self.assertTrue(blocked.get("statusMessage"), "A blocked task carries the reason it is blocked.")
            return task_id

        def sounds(task_id):
            return [event["sound"] for event in self.diagnostic_events()
                    if event.get("event") == "task.status_sound.played" and event.get("taskID") == task_id]

        # Backlog still can't skip ahead to Done or Review.
        backlog_id = self.create_task("Direct move backlog")["id"]
        rejected, _ = self.call_cli("task", "move", backlog_id, "Done", expected_status=2)
        self.assert_failure(rejected, "invalid_argument")
        self.assertIn("Only a task in Review, Waiting Response or Blocked", rejected["error"]["message"])
        rejected, _ = self.call_cli("task", "move", backlog_id, "Review", expected_status=2)
        self.assert_failure(rejected, "invalid_argument")
        self.assertIn("Only a task in Waiting Response or Blocked", rejected["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", backlog_id)[0])["status"], "Backlog")

        # Waiting Response -> Done, refused while the question's turn still runs.
        waiting = self.create_repo_task("Direct waiting done", [self.primary], materialize=True)
        worktree = Path(waiting["repositoryWorktrees"][0]["worktreePath"])
        command = ["conversation", "send", waiting["id"], "--message", "Please ask your questions.", "--mode", "plan"]
        process = self.start_cli(*command, extra_environment=question_environment)
        try:
            deadline = time.monotonic() + 60
            pending = None
            while process.poll() is None and time.monotonic() < deadline and pending is None:
                history, _ = self.call_cli("conversation", "history", waiting["id"], extra_environment=question_environment)
                pending = self.assert_success(history).get("pendingUserInputRequest")
                if pending is None:
                    time.sleep(0.1)
            self.assertIsNotNone(pending, "The blocking question should hold the turn open.")
            self.assertEqual(self.assert_success(self.call_cli("task", "get", waiting["id"])[0])["status"], "Waiting Response")
            running, _ = self.call_cli("task", "move", waiting["id"], "Done", expected_status=2)
            self.assert_failure(running, "invalid_argument")
            self.assertIn("still running", running["error"]["message"])
            self.assertEqual(self.assert_success(self.call_cli("task", "get", waiting["id"])[0])["status"], "Waiting Response")
            self.assertTrue(worktree.exists(), "A refused move must leave the running turn's worktree in place.")
            answered, _ = self.call_cli(
                "conversation", "answer-user-input", waiting["id"], pending["id"],
                "--answer", "color=Blue", "--answer", "token=fixture-secret", extra_environment=question_environment,
            )
            self.assert_success(answered)
            self.assert_success(self.finish_cli(process, command)[0])
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=20)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", waiting["id"])[0])["status"], "Waiting Response")
        done = self.assert_success(self.call_cli("task", "move", waiting["id"], "Done")[0])
        self.assertEqual(done["status"], "Done")
        self.assertIsNone(done.get("statusMessage"))
        self.assertFalse(worktree.exists(), "Done removes the task's clean Playhouse worktree as it does from Review.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", waiting["id"])[0])["status"], "Done")

        # Blocked -> Review clears the blocked reason and plays the Review sound.
        review_id = blocked_task("Direct blocked review", self.secondary)
        blocked_sounds = sounds(review_id)
        reviewed = self.assert_success(self.call_cli("task", "move", review_id, "Review")[0])
        self.assertEqual(reviewed["status"], "Review")
        self.assertIsNone(reviewed.get("statusMessage"))
        reread = self.assert_success(self.call_cli("task", "get", review_id)[0])
        self.assertEqual(reread["status"], "Review")
        self.assertIsNone(reread.get("statusMessage"))
        self.assertEqual(sounds(review_id)[len(blocked_sounds):], ["Glass"])
        drag_review_id = blocked_task("Direct blocked review drag", self.secondary)
        dragged = self.assert_success(self.call_cli("task", "move", drag_review_id, "Review")[0])
        self.assertEqual(dragged["status"], "Review")
        self.assertIsNone(self.assert_success(self.call_cli("task", "get", drag_review_id)[0]).get("statusMessage"))

        # Blocked -> Done.
        done_id = blocked_task("Direct blocked done", self.secondary)
        done = self.assert_success(self.call_cli("task", "move", done_id, "Done")[0])
        self.assertEqual(done["status"], "Done")
        self.assertIsNone(done.get("statusMessage"))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", done_id)[0])["status"], "Done")
        repeated = self.assert_success(self.call_cli("task", "move", done_id, "Done")[0])
        self.assertEqual(repeated["status"], "Done", "A task already in Done is returned unchanged.")
    # case-contract: test_task_progress_reports_publish_persist_and_clear | The CLI publishes standard and custom progress only during an active task turn, persists each report across fresh CLI/XPC connections, rejects invalid reports, and clears explicitly. During an active turn the CLI accepts completed and waiting-response outcomes, rejects invalid or inactive outcomes, and persists the selected status; provider processes started from the CLI/XPC service or the app's composer inherit that app's bridge service name and store directory, and an outcome reported with exactly that inherited environment reaches the task. A successful turn without an outcome and with nothing left running receives exactly one private recovery prompt that offers only the stopping outcomes; a completed report during it moves the task to Review, a waiting-response report during it leaves the task in Waiting Response, and no report by its end marks the task Blocked with the missing-outcome reason rather than Waiting Response, since the user was never asked anything. The board shows progress details and places completed tasks in Review and waiting outcomes in Waiting Response. New threads receive hidden progress and outcome instructions at thread start, and existing threads receive them on resume; turn requests do not repeat the instructions. Those instructions require updates at phase changes, around substantial tools, and at least every 30 seconds during long work; they offer no outcome for unfinished work and tell the agent to keep awaiting a required command within the turn. They place the outcome call, still the final CLI action, before the user-visible final reply, which ends the turn so it never ends on a tool call, and they tell the agent not to repeat an answer after a no-visible-output notice. Only an explicit completed outcome reaches Review. When a final answer ends with the outcome command written as text instead of run, the final answer, fresh history, and transcript hide that command, and it counts as the turn's outcome only when it names this task. A recovery prompt Playhouse sent shows its prompt and the agent's reply in Codex history and the visible transcript, including after later ordinary turns. Fresh Codex history after those prompts also retains the latest ordinary-turn diff while showing their replies. Completed and waiting-response outcomes start Glass and Ping respectively when their turns settle.
    def test_task_progress_reports_publish_persist_and_clear(self):
        task_id = self.create_task("Progress reports", roots=[self.primary])["id"]
        response, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "building", expected_status=1)
        self.assert_failure(response, "invalid_transition")
        inactive_outcome, _ = self.call_cli("task", "outcome", task_id, "completed", expected_status=1)
        self.assert_failure(inactive_outcome, "invalid_transition")

        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-unique-turns-hold-release"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = os.environ.copy()
        environment.update({
            "PLAYHOUSE_DATA_DIRECTORY": str(self.data_directory),
            "PLAYHOUSE_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
            "PLAYHOUSE_E2E_DEFAULTS_SUITE": self.defaults_suite,
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": arguments.service_name,
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
        })
        turn = DrainedPopen(
            [str(self.cli), "conversation", "send", task_id, "--message", "Work on this task."],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
        )
        active_marker = Path(str(executable) + ".turn-active")
        release_marker = Path(str(executable) + ".turn-release")
        try:
            deadline = time.monotonic() + 20
            while not active_marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(active_marker.exists(), "The fixture turn did not become active.")
            current, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(current)["status"], "In Progress")

            published, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "building", "--detail", "Compiling the app")
            record = self.assert_success(published)
            self.assertEqual(record["progressType"], "building")
            self.assertEqual(record["progressLabel"], "Building")
            self.assertEqual(record["progressDetail"], "Compiling the app")
            fresh, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(fresh)["progressDetail"], "Compiling the app")

            invalid_type, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "unknown", expected_status=2)
            self.assert_failure(invalid_type, "invalid_argument")
            custom, _ = self.call_cli("task", "progress", "custom", task_id, "--label", "Checking migration", "--detail", "Reading the stored task data")
            custom_record = self.assert_success(custom)
            self.assertIsNone(custom_record.get("progressType"))
            self.assertEqual(custom_record["progressLabel"], "Checking migration")
            self.assertEqual(custom_record["progressDetail"], "Reading the stored task data")
            blank_custom, _ = self.call_cli("task", "progress", "custom", task_id, "--label", " ", expected_status=2)
            self.assert_failure(blank_custom, "invalid_argument")

            invalid_outcome, _ = self.call_cli("task", "outcome", task_id, "unknown", expected_status=2)
            self.assert_failure(invalid_outcome, "invalid_argument")

            cleared, _ = self.call_cli("task", "progress", "clear", task_id)
            self.assertIsNone(self.assert_success(cleared).get("progressLabel"))
            final_report, _ = self.call_cli("task", "progress", "publish", task_id, "--type", "testing")
            self.assertEqual(self.assert_success(final_report)["progressLabel"], "Testing")
            # The provider process must inherit this service's name and store, so
            # its in-turn outcome call reaches this task rather than the defaults.
            bridge_environment = json.loads(Path(str(executable) + ".bridge-environment").read_text(encoding="utf-8"))
            self.assertEqual(bridge_environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"], arguments.service_name)
            self.assertEqual(Path(bridge_environment["PLAYHOUSE_DATA_DIRECTORY"]).resolve(), self.data_directory.resolve())
            completed, _ = self.call_cli("task", "outcome", task_id, "completed", extra_environment=bridge_environment)
            completed_record = self.assert_success(completed)
            self.assertEqual(completed_record["outcome"], "completed")
            self.assertEqual(completed_record["taskStatus"], "In Progress", "The outcome is staged until the Codex turn completes successfully.")
            release_marker.write_text("Release the active turn.\n", encoding="utf-8")
            stdout, stderr = turn.communicate(timeout=20)
            self.assertEqual(turn.returncode, 0, f"Fixture conversation failed: {stdout}; {stderr}")
            final_response = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
            self.assertTrue(final_response["ok"], final_response.get("error"))
            finished, _ = self.call_cli("task", "get", task_id)
            finished_record = self.assert_success(finished)
            self.assertEqual(finished_record["status"], "Review")
            self.assertIsNone(finished_record.get("progressLabel"))
            follow_up = DrainedPopen(
                [str(self.cli), "conversation", "send", task_id, "--message", "Continue on this task."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The resumed fixture turn did not become active.")
                waiting_outcome, _ = self.call_cli("task", "outcome", task_id, "waiting-response")
                waiting_record = self.assert_success(waiting_outcome)
                self.assertEqual(waiting_record["outcome"], "waiting-response")
                self.assertEqual(waiting_record["taskStatus"], "In Progress")
                release_marker.write_text("Release the resumed turn.\n", encoding="utf-8")
                follow_stdout, follow_stderr = follow_up.communicate(timeout=20)
                self.assertEqual(follow_up.returncode, 0, f"Resumed fixture conversation failed: {follow_stdout}; {follow_stderr}")
                follow_response = json.loads([line for line in follow_stdout.splitlines() if line.strip()][-1])
                self.assertTrue(follow_response["ok"], follow_response.get("error"))
            finally:
                if follow_up.poll() is None:
                    release_marker.write_text("Release the resumed turn.\n", encoding="utf-8")
                    follow_up.communicate(timeout=20)
            sounds = [e["sound"] for e in self.diagnostic_events() if e.get("event") == "task.status_sound.played" and e.get("taskID") == task_id]
            self.assertEqual(sounds, ["Glass", "Ping"])
            omitted_follow_up = DrainedPopen(
                [str(self.cli), "conversation", "send", task_id, "--message", "A turn without an outcome."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The no-outcome fixture turn should become active.")
                for nudge_index in range(OUTCOME_RECOVERY_PROMPTS + 1):
                    self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "In Progress", "The fallback status should be deferred until the recovery prompt finishes.")
                    release_marker.write_text(f"Release turn {nudge_index + 1}.\n", encoding="utf-8")
                    if nudge_index < OUTCOME_RECOVERY_PROMPTS:
                        deadline = time.monotonic() + 10
                        while active_marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertFalse(active_marker.exists(), "The fixture should finish the current unreported turn.")
                        deadline = time.monotonic() + 10
                        while not active_marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.02)
                        self.assertTrue(active_marker.exists(), "Playhouse should send its one private recovery prompt.")
                omitted_stdout, omitted_stderr = omitted_follow_up.communicate(timeout=30)
                self.assertEqual(omitted_follow_up.returncode, 0, f"No-outcome fixture conversation failed: {omitted_stdout}; {omitted_stderr}")
                omitted_record = self.assert_success(self.call_cli("task", "get", task_id)[0])
                self.assertEqual(omitted_record["status"], "Blocked", "An unanswered recovery prompt never asked the user anything, so the task is Blocked rather than Waiting Response.")
                self.assertIn("one recovery prompt went unanswered", omitted_record.get("statusMessage") or "")
                visible_history, _ = self.call_cli(
                    "conversation", "history", task_id,
                    extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
                )
                visible_history_record = self.assert_success(visible_history)
                visible_messages = visible_history_record["messages"]
                self.assertTrue(any(item["role"] == "user" and "ended without reporting a task outcome" in item.get("text", "") for item in visible_messages), "The nudge Playhouse sent appears in conversation history.")
                self.assertTrue(any("Fixture internal reminder reply." in item.get("text", "") for item in visible_messages), "The agent's reply to the nudge appears in conversation history.")
                self.assertIn("ordinary-turn-diff-after-reminders", visible_history_record["diff"]["unifiedDiff"], "Private reminders must not replace the latest ordinary-turn diff.")
            finally:
                if omitted_follow_up.poll() is None:
                    release_marker.write_text("Release the no-outcome turn.\n", encoding="utf-8")
                    omitted_follow_up.communicate(timeout=20)
            recovered_follow_up = DrainedPopen(
                [str(self.cli), "conversation", "send", task_id, "--message", "Report the outcome after a reminder."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The reminder recovery fixture turn should become active.")
                release_marker.write_text("Release the initial unreported turn.\n", encoding="utf-8")
                deadline = time.monotonic() + 10
                while active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(active_marker.exists(), "The initial unreported turn should finish before the reminder.")
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "Playhouse should send a private reminder after the omitted outcome.")
                completed_reminder, _ = self.call_cli("task", "outcome", task_id, "completed", extra_environment=bridge_environment)
                self.assertEqual(self.assert_success(completed_reminder)["outcome"], "completed")
                release_marker.write_text("Release the reminder after its outcome is reported.\n", encoding="utf-8")
                recovered_stdout, recovered_stderr = recovered_follow_up.communicate(timeout=20)
                self.assertEqual(recovered_follow_up.returncode, 0, f"Reminder recovery fixture conversation failed: {recovered_stdout}; {recovered_stderr}")
                recovered_record, _ = self.call_cli("task", "get", task_id)
                self.assertEqual(self.assert_success(recovered_record)["status"], "Review", "A completed CLI outcome reported during a private reminder should be honored.")
            finally:
                if recovered_follow_up.poll() is None:
                    release_marker.write_text("Release the reminder recovery turn.\n", encoding="utf-8")
                    recovered_follow_up.communicate(timeout=20)
            waiting_follow_up = DrainedPopen(
                [str(self.cli), "conversation", "send", task_id, "--message", "Report waiting after a reminder."],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
            )
            try:
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "The waiting outcome fixture turn should become active.")
                release_marker.write_text("Release the initial unreported turn.\n", encoding="utf-8")
                deadline = time.monotonic() + 10
                while active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(active_marker.exists(), "The initial turn should finish before asking for its outcome.")
                deadline = time.monotonic() + 10
                while not active_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(active_marker.exists(), "Playhouse should send a reminder before reporting a waiting outcome.")
                waiting_reminder, _ = self.call_cli("task", "outcome", task_id, "waiting-response", extra_environment=bridge_environment)
                self.assertEqual(self.assert_success(waiting_reminder)["outcome"], "waiting-response")
                release_marker.write_text("Release the reminder after its outcome is reported.\n", encoding="utf-8")
                waiting_stdout, waiting_stderr = waiting_follow_up.communicate(timeout=20)
                self.assertEqual(waiting_follow_up.returncode, 0, f"Waiting reminder fixture conversation failed: {waiting_stdout}; {waiting_stderr}")
                waiting_record, _ = self.call_cli("task", "get", task_id)
                self.assertEqual(self.assert_success(waiting_record)["status"], "Waiting Response", "A waiting-response outcome reported during a private reminder should be honored.")
            finally:
                if waiting_follow_up.poll() is None:
                    release_marker.write_text("Release the waiting reminder turn.\n", encoding="utf-8")
                    waiting_follow_up.communicate(timeout=20)
            # A model can write its outcome command as answer text instead of running
            # it. The echo is hidden, and it counts only when it names this task.
            for echoed_task_id, expected_status in [(str(uuid.uuid4()).upper(), "Blocked"), (task_id, "Review")]:
                echoed_turn = DrainedPopen(
                    [str(self.cli), "conversation", "send", task_id, "--message", f"Echo the outcome command for {echoed_task_id}."],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
                )
                try:
                    deadline = time.monotonic() + 10
                    while not active_marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue(active_marker.exists(), "The echoed-outcome fixture turn should become active.")
                    held_turns = OUTCOME_RECOVERY_PROMPTS + 1 if expected_status == "Blocked" else 1
                    for held_turn_index in range(held_turns):
                        release_marker.write_text(f"Release echoed turn {held_turn_index + 1}.\n", encoding="utf-8")
                        if held_turn_index < held_turns - 1:
                            deadline = time.monotonic() + 10
                            while active_marker.exists() and time.monotonic() < deadline:
                                time.sleep(0.02)
                            self.assertFalse(active_marker.exists(), "The current echoed turn should finish before a private reminder.")
                            deadline = time.monotonic() + 10
                            while not active_marker.exists() and time.monotonic() < deadline:
                                time.sleep(0.02)
                            self.assertTrue(active_marker.exists(), "Playhouse should send a private reminder for an unreported echoed outcome.")
                    echoed_stdout, echoed_stderr = echoed_turn.communicate(timeout=20)
                    self.assertEqual(echoed_turn.returncode, 0, f"Echoed-outcome fixture conversation failed: {echoed_stdout}; {echoed_stderr}")
                    echoed_events = [json.loads(line) for line in echoed_stdout.splitlines() if line.strip()]
                    finals = [event["payload"]["text"] for event in echoed_events if event.get("type") == "assistant_final"]
                    self.assertEqual(finals, ["Fixture answer with an echoed outcome."], "The streamed final answer must hide the echoed outcome command.")
                    echoed_record, _ = self.call_cli("task", "get", task_id)
                    self.assertEqual(self.assert_success(echoed_record)["status"], expected_status)
                    echoed_history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)})[0])
                    self.assertTrue(any(item["text"] == "Fixture answer with an echoed outcome." for item in echoed_history["messages"]))
                    self.assertFalse(any("task outcome" in message["text"] for message in echoed_history["messages"] if message["role"] == "assistant"), "A fresh history read must hide the echoed outcome command.")
                    self.assertFalse(any(item.get("text") == "[Playhouse private outcome reminder hidden]" for item in echoed_history["messages"]), "A later Codex history refresh must omit earlier private reminders.")
                    self.assertFalse(any(item.get("text") == "[Playhouse private outcome response hidden]" for item in echoed_history["messages"]), "A later Codex history refresh must omit earlier private reminder replies.")
                    self.assertTrue(any(item["role"] == "user" and "ended without reporting a task outcome" in item.get("text", "") for item in echoed_history["messages"]), "Later history refreshes keep the nudges Playhouse sent.")
                    self.assertTrue(any("Fixture internal reminder reply." in item.get("text", "") for item in echoed_history["messages"]), "Later history refreshes keep the replies to those nudges.")
                finally:
                    if echoed_turn.poll() is None:
                        release_marker.write_text("Release the echoed-outcome turn.\n", encoding="utf-8")
                        echoed_turn.communicate(timeout=20)
            turn_data = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            self.assertEqual(turn_data["threadStartCount"], 1)
            self.assertGreaterEqual(turn_data["threadResumeCount"], 1)
            self.assertEqual(len(turn_data["turns"]), 11)
            nudge_turns = [turn for turn in turn_data["turns"] if "ended without reporting a task outcome" in turn.get("userMessage", "")]
            self.assertEqual(len(nudge_turns), 2 * OUTCOME_RECOVERY_PROMPTS + 2, "Each missing-outcome send should receive exactly one private recovery prompt.")
            self.assertTrue(all("task outcome" in turn["userMessage"] and "This is the only recovery prompt" in turn["userMessage"] for turn in nudge_turns), "Each hidden request should explicitly direct the agent to report an outcome.")
            self.assertTrue(all("in-progress" not in turn["userMessage"] and "blocked --reason" in turn["userMessage"] for turn in nudge_turns), "The recovery prompt offers only stopping outcomes.")
            self.assertTrue(all(turn["developerInstructions"] is None for turn in turn_data["turns"]), "Thread-scoped task instructions should not be repeated in turn requests.")
            instructions = turn_data["threadStartDeveloperInstructions"]
            self.assertIn(str(self.cli), instructions)
            self.assertIn("task progress publish", instructions)
            self.assertIn("hidden from the conversation", instructions)
            self.assertIn("at least every 30 seconds", instructions)
            self.assertIn("active suite/case and position", instructions)
            self.assertIn("CLI/XPC 3/8", instructions)
            self.assertIn("under 80 characters", instructions)
            self.assertIn("task outcome", instructions)
            self.assertIn("<completed|waiting-response|blocked>", instructions)
            self.assertIn("There is no outcome for unfinished work", instructions)
            self.assertIn("keep awaiting or polling that same command session in this turn", instructions)
            self.assertNotIn("in-progress", instructions)
            self.assertIn("sends one private recovery prompt", instructions)
            self.assertIn("before you write your final reply, make exactly one stopping outcome call", instructions)
            self.assertIn("Write your user-visible final reply after the outcome call returns", instructions)
            self.assertIn("never end a turn on a tool call", instructions)
            self.assertIn("The outcome call must be your final CLI action for the turn, made only after every command you still need has finished.", instructions)
            self.assertIn("previous response had no visible output but you already answered in this turn, do not repeat the answer", instructions)
            self.assertIn("waiting-response", instructions)
            self.assertIn("final CLI action", instructions)
            self.assertIn("Active task worktrees for edits", instructions)
            self.assertIn("Never silently edit a source repository path.", instructions)
            self.assertIn("workspace repos list", instructions)
            self.assertIn("read-only inspection of returned source paths", instructions)
            self.assertIn("Add a repository to this task only when you intend to create or commit changes in it", instructions)
            self.assertIn("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated.", instructions)
            resume_instructions = turn_data["threadResumeDeveloperInstructions"]
            self.assertTrue(resume_instructions, "Resumed task threads should receive updated task instructions.")
            self.assertTrue(all("task outcome" in instructions for instructions in resume_instructions))
        finally:
            if turn.poll() is None:
                release_marker.write_text("Release the active turn.\n", encoding="utf-8")
                turn.communicate(timeout=20)
            active_marker.unlink(missing_ok=True)
            release_marker.unlink(missing_ok=True)

from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases05:
    # case-contract: test_task_auto_pr_toggle_creates_pull_request_on_review | A working-state task card (In Progress, Blocked, or Waiting Response) with no linked pull request shows the pull-request-mode plugin's compact mode pill in place of the manual PR button, closed on its current mode and defaulting to Manual; clicking it slides out Manual, PR, Green, and Merge, and choosing one selects it and folds the pill back onto it. The pill stays beside linked pull requests so autopilot and merge remain switchable. The mode is the plugin's own state keyed by task id, not a property of the task: a new task has no saved mode and is in Manual mode, choosing Manual clears the saved mode, every other choice (PR included) is saved and reflected across a fresh read, and a saved value no mode knows reads as Manual. When a turn completes in PR mode, the plugin creates the task's pull request on the way to Review with no user click, exactly once. Choosing Merge for that task in Review is a change the plugin acts on at once: it merges the green pull request with no other command, and the task stays in Review. In Manual mode, a new task's default, the task reaches Review with no pull request, and the existing manual PR button still creates it afterward unchanged. Every new task starts in Manual mode, whatever mode another task was left in. Creating a pull request with --if-needed for an unknown task is rejected. A task saved before the mode was the plugin's keeps its old Manual, Green, or Merge choice: the bridge imports it once into the plugin's state at its next request (a mode already chosen in the plugin wins, and PR imports nothing), and its card's pill shows it. In the same request, once, each task saved while PR was the default that still has no mode of its own gets PR saved as its own, so existing tasks keep opening their pull request on Review and their pill shows PR; a task created afterward still starts in Manual.
    def test_task_auto_pr_toggle_creates_pull_request_on_review(self):
        missing, _ = self.call_cli("task", "pr", "create", str(uuid.uuid4()), "--if-needed", expected_status=3)
        self.assert_failure(missing, "not_found")

        def remove_fixture_origin(repository, expected_url):
            # A worktree shares its source repository's git config, so adding
            # "origin" there leaks into every other task worktree of that
            # repository; remove it only if it still matches what this case set.
            current = subprocess.run(
                ["git", "-C", str(repository), "remote", "get-url", "origin"],
                check=False, capture_output=True, text=True,
            )
            if current.returncode == 0 and current.stdout.strip() == str(expected_url):
                self.run_git(repository, "remote", "remove", "origin")

        task = self.create_repo_task("Auto PR toggle", [self.primary], merge_targets={self.primary: "main"})
        self.assertNotIn("pullRequestMode", task, "The mode is the plugin's state, not a property of the task.")
        self.assertIsNone(self.pull_request_mode(task["id"]), "A new task has no saved mode, so it is in Manual mode.")

        # Tasks saved before the mode was the plugin's kept it in their own columns. Seed those real
        # SwiftData rows and forget that the import ran; the bridge imports them once, at the start of
        # its next request. That request goes to the daemon that already holds this case's preferences:
        # a second process on a path-named defaults suite (the tests' isolated preferences, not the app's)
        # reads its own writes stale, which a real launch on the app's suite never does.
        legacy_columns = {
            "Legacy PR autopilot": ("ZPULLREQUESTAUTOPILOT = 1, ZPULLREQUESTAUTOMERGE = 0", "autopilot"),
            "Legacy PR merge": ("ZPULLREQUESTAUTOPILOT = 1, ZPULLREQUESTAUTOMERGE = 1", "merge"),
            "Legacy PR manual": ("ZAUTOCREATEPULLREQUESTONREVIEW = 0, ZPULLREQUESTAUTOPILOT = 0", "manual"),
            "Legacy PR default": ("ZAUTOCREATEPULLREQUESTONREVIEW = 1, ZPULLREQUESTAUTOPILOT = 0", None),
            "Legacy PR already chosen": ("ZPULLREQUESTAUTOPILOT = 1, ZPULLREQUESTAUTOMERGE = 1", "manual"),
        }
        legacy_ids = {title: self.create_task(title=title)["id"] for title in legacy_columns}
        self.set_pull_request_mode(legacy_ids["Legacy PR already chosen"], "manual")
        with sqlite3.connect(self.data_directory / "Playhouse-v2.store") as database:
            for title, (columns, _) in legacy_columns.items():
                seeded = database.execute(f"UPDATE ZBOARDTASK SET {columns} WHERE ZTITLE = ?", (title,))
                self.assertEqual(seeded.rowcount, 1, f"Seed the legacy mode columns of {title}.")
        # Forget, too, that the tasks saved while PR was the default had it saved as their own: a
        # first launch since Manual became the default runs both, the import first.
        for flag in ("legacyPullRequestModesImported", "existingTaskPullRequestModesPinned"):
            subprocess.run(["/usr/bin/defaults", "delete", self.defaults_suite, flag], check=False, capture_output=True)
            self.assertFalse(self.default_exists(flag))
        imported_state = self.assert_success(self.call_cli("plugin", "state", "--id", "pull-request-mode")[0])["state"]
        for title, (_, mode) in legacy_columns.items():
            self.assertEqual(imported_state.get(legacy_ids[title]), mode or "pr",
                             f"{title} imports as the plugin's state; a mode already chosen in the plugin wins, and a legacy PR task keeps PR.")
        self.assertEqual(imported_state.get(task["id"]), "pr", "A task saved while PR was the default keeps PR as its own mode.")
        self.assertNotIn("pullRequestMode", self.assert_success(self.call_cli("task", "get", legacy_ids["Legacy PR merge"])[0]))
        self.assertTrue(self.default_exists("legacyPullRequestModesImported"), "The import is recorded so it runs once.")
        self.assertTrue(self.default_exists("existingTaskPullRequestModesPinned"), "Keeping PR for existing tasks is recorded so it runs once.")
        imports = [event for event in self.diagnostic_events() if event.get("event") == "plugin.pull_request_mode.imported" and event.get("count") == "3"]
        self.assertEqual(len(imports), 1, "Three legacy modes were imported, in one pass; PR imports nothing.")
        pinned = [event for event in self.diagnostic_events() if event.get("event") == "plugin.pull_request_mode.pinned" and event.get("count") == "2"]
        self.assertEqual(len(pinned), 1, "The two tasks with no mode of their own (the legacy PR task and this case's task) kept PR, in one pass.")
        # A later choice in the plugin is not overwritten by the old columns, or by PR, on later requests.
        self.set_pull_request_mode(legacy_ids["Legacy PR merge"], None)
        self.assertIsNone(self.pull_request_mode(legacy_ids["Legacy PR merge"]))
        self.assertEqual(len([event for event in self.diagnostic_events() if event.get("event") == "plugin.pull_request_mode.imported" and event.get("count") != "0"]), 1,
                         "The import runs once.")
        self.assertEqual(len([event for event in self.diagnostic_events() if event.get("event") == "plugin.pull_request_mode.pinned" and event.get("count") != "0"]), 1,
                         "Keeping PR for existing tasks runs once.")
        self.assertIsNone(self.pull_request_mode(self.create_task(title="Fresh after legacy import")["id"]), "A new task starts in Manual mode.")

        for mode in ("autopilot", "merge", "manual"):
            self.set_pull_request_mode(task["id"], mode)
            self.assertEqual(self.pull_request_mode(task["id"]), mode, "The plugin keeps the chosen mode across a fresh CLI connection.")
        # PR is no longer the default, so choosing it is saved; this task gets its pull request on Review.
        self.set_pull_request_mode(task["id"], "pr")
        self.assertEqual(self.pull_request_mode(task["id"]), "pr", "The plugin keeps PR across a fresh CLI connection.")

        remote_root = self.data_directory / "auto-pr-remotes"
        remote_root.mkdir()
        (remote_root / ".playhouse-test-owner").write_text("Playhouse bridge test owns these PR remotes.\n", encoding="utf-8")
        remote = remote_root / "auto-pr.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)

        gh_directory = self.data_directory / "auto-pr-gh-fixture"
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
            "PLAYHOUSE_E2E_GH_CREATE_FIRST_NUMBER": "701",
        }

        # Mirrors complete_fixture_turn's own driving loop (a 90s deadline accommodates
        # real repository worktree preparation), but adds the remote the first time the
        # turn holds so the real `gh`/`git` publish path can succeed when the outcome
        # reports completed with Auto PR on.
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-auto-pr"
        hold_marker = Path(str(executable) + ".hold-release")
        hold_marker.touch()
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        turn_environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable), **gh_environment}
        command = ["conversation", "send", task["id"], "--message", "Complete this task.", "--answer", "color=Blue", "--answer", "token=fixture-secret"]
        active = Path(str(executable) + ".turn-active")
        release = Path(str(executable) + ".turn-release")
        active.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        process = self.start_cli(*command, extra_environment=turn_environment)
        try:
            deadline = time.monotonic() + 90
            remote_added = False
            outcome_count = 0
            while process.poll() is None and time.monotonic() < deadline:
                if active.exists() and not release.exists():
                    if outcome_count == 0:
                        # The first hold is the real task turn: make the worktree
                        # publishable, then report its outcome so Auto PR's
                        # subsequent pull-request-summary turn (a separate,
                        # task-outcome-less fixture activation on the same
                        # executable) has something real to describe.
                        materialized = self.assert_success(self.call_cli("task", "get", task["id"])[0])
                        record = materialized["repositoryWorktrees"][0]
                        self.assertFalse(record["isPending"], "The worktree must be ready by the time the turn is active.")
                        self.addCleanup(remove_fixture_origin, self.primary, remote)
                        self.run_git(Path(record["worktreePath"]), "remote", "add", "origin", str(remote))
                        self.run_git(Path(record["worktreePath"]), "push", "origin", "main")
                        # GitHub rejects a pull request whose branch has no commits.
                        (Path(record["worktreePath"]) / "task-change.txt").write_text("Auto PR task change.\n", encoding="utf-8")
                        remote_added = True
                        response, _ = self.call_cli("task", "outcome", task["id"], "completed", extra_environment=gh_environment)
                        self.assertEqual(self.assert_success(response)["outcome"], "completed")
                        outcome_count += 1
                        # Auto PR's own pull-request-summary turn reuses this same
                        # executable next; without the hold marker it takes the
                        # fixture's normal default-answer path instead of pausing
                        # again for an outcome nothing will ever report.
                        hold_marker.unlink(missing_ok=True)
                    release.write_text("Release the fixture turn.\n", encoding="utf-8")
                time.sleep(0.02)
            self.assertGreater(outcome_count, 0, "The fixture should hold the turn until its explicit outcome is reported.")
            self.assertTrue(remote_added, "The remote must be added before the outcome is reported.")
            response, _ = self.finish_cli(process, command)
            self.assert_success(response)
        finally:
            if process.poll() is None:
                release.write_text("Release the fixture turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            hold_marker.unlink(missing_ok=True)

        reviewed = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(reviewed["status"], "Review")
        self.assertEqual(reviewed["repositoryWorktrees"][0]["pullRequestNumber"], 701)
        self.assertEqual(reviewed["repositoryWorktrees"][0]["pullRequestURL"], "https://github.com/playhouse-test/fixture/pull/701")
        create_events = create_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            sum(line.startswith("created\t") for line in create_events), 1,
            "Auto PR should create the pull request exactly once without the user clicking anything.",
        )

        # Choosing Merge for a task in Review is a change the plugin acts on at once:
        # it follows the green pull request and merges it, with no CLI command.
        gh_state.write_text("701=unmerged\n701.checks=success\n701.threads=0\n", encoding="utf-8")
        self.set_pull_request_mode(task["id"], "merge", extra_environment=gh_environment)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and not any(line.startswith("merged\t701") for line in create_log.read_text(encoding="utf-8").splitlines()):
            time.sleep(0.2)
        self.assertIn("merged\t701\t--squash", create_log.read_text(encoding="utf-8").splitlines(), "Choosing Merge in Review merges the green pull request.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review", "Merging leaves the task in Review.")

        default_task = self.create_task("Default PR mode")
        self.assertIsNone(self.pull_request_mode(default_task["id"]), "A new task should start in Manual mode.")
        self.set_pull_request_mode(default_task["id"], "pr")
        after_on = self.create_task("Default PR mode after switching on")
        self.assertIsNone(self.pull_request_mode(after_on["id"]), "A new task should still start in Manual mode after another task was switched to PR.")
        self.assertEqual(self.pull_request_mode(default_task["id"]), "pr")

        def review_modes(task_id):
            return [event.get("mode") for event in self.diagnostic_events()
                    if event.get("event") == "plugin.pull_request_mode.review" and event.get("taskID") == task_id]

        # A new task, with no mode chosen, is in Manual mode.
        manual_task = self.create_repo_task("Manual PR toggle", [self.secondary], merge_targets={self.secondary: "main"})
        self.assertIsNone(self.pull_request_mode(manual_task["id"]))
        self.complete_fixture_turn(manual_task["id"], executable_name="codex-fixture-manual-pr")
        manual_reviewed = self.assert_success(self.call_cli("task", "get", manual_task["id"])[0])
        self.assertEqual(manual_reviewed["status"], "Review")
        self.wait_for(lambda: review_modes(manual_task["id"]) == ["manual"], "A new task reaches Review in Manual mode.")
        self.assertIsNone(
            manual_reviewed["repositoryWorktrees"][0].get("pullRequestNumber"),
            "In Manual mode, the default, reaching Review must not create a pull request by itself.",
        )
        # A saved value no mode knows reads as the default, Manual.
        self.set_pull_request_mode(after_on["id"], "sometimes")
        self.complete_fixture_turn(after_on["id"], executable_name="codex-fixture-unknown-pr-mode")
        self.wait_for(lambda: review_modes(after_on["id"]) == ["manual"], "An unknown saved mode reaches Review as Manual.")

        manual_remote_root = self.data_directory / "manual-pr-remotes"
        manual_remote_root.mkdir()
        (manual_remote_root / ".playhouse-test-owner").write_text("Playhouse bridge test owns these PR remotes.\n", encoding="utf-8")
        manual_remote = manual_remote_root / "manual-pr.git"
        subprocess.run(["git", "init", "--bare", str(manual_remote)], check=True, capture_output=True, text=True)
        manual_worktree_path = Path(manual_reviewed["repositoryWorktrees"][0]["worktreePath"])
        self.addCleanup(remove_fixture_origin, self.secondary, manual_remote)
        self.run_git(manual_worktree_path, "remote", "add", "origin", str(manual_remote))
        self.run_git(manual_worktree_path, "push", "origin", "main")
        (manual_worktree_path / "task-change.txt").write_text("Manual PR task change.\n", encoding="utf-8")
        manual_create_environment = {
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture-manual-pr"),
            **gh_environment,
        }
        manual_created = self.assert_success(self.call_cli("task", "pr", "create", manual_task["id"], extra_environment=manual_create_environment)[0])
        self.assertEqual(
            manual_created["repositoryWorktrees"][0]["pullRequestNumber"], 702,
            "The manual create flow must still work unchanged when Auto PR stays off.",
        )
    # case-contract: test_task_pr_autopilot_fixes_red_pull_request_until_green | `task pr status` reports each linked PR's check state, failing check names, and a green, red, or pending health, and reads unresolved review threads only when asked (`--review-threads`, as every autopilot pass does), so a PR-mode card's probe never reads them; the board colours each linked PR number green, red, or blue by that health and keeps the mode pill beside linked PRs. `task pr autopilot` is one pass of the pull-request-mode plugin's Green mode, which the plugin runs for its Green tasks when they reach Review, when Green is chosen for a task in Review, and on focus; a pass leaves a task inactive unless it sits in Review with a linked pull request. With checks still running it sends no turn, and the plugin re-probes only those Green PRs on a slow poll until they settle. When checks fail or review threads are unresolved it sends one visible Playhouse autopilot fix turn through the task's provider that names the failing checks and unresolved threads, asks the model to judge every comment critically and to reply to and resolve each thread whether or not it changes code, and allows waiting-response for blockers it cannot fix (such as a GitHub outage or a Jira ticket the user must add); the task is In Progress during that turn and returns to Review when it reports completed. Once the PR is green autopilot sends nothing, never merges it, and resets its loop guard, so the same red state returning later (picked up by the focus probe) is fixed again. A fix turn that reports waiting-response stops the loop until the user sends the task back to Review, after which autopilot may try the red PR once more; a red state unchanged since the last fix moves the task to Waiting Response with a reason instead of being sent again, and the CLI case also drives the five-attempt cap to its Waiting Response stop after a fresh set of attempts (`--reset-attempts`, as choosing the mode again passes). A check rerun counts only by its latest run, as on GitHub: a failure followed by a newer success reads green with no failing checks, a success followed by a newer failure reads red naming the check, and same-named checks from different workflows stay separate (one failing workflow still reads red, failing names listed once), as do commit status contexts by context and untimed entries by rollup order. The pull-request-mode plugin's service runs these passes itself and records each follow: when Green is chosen for a task in Review, when a Green task reaches Review, on the slow poll while checks run, and on focus through its throttle (the CLI case counts three focus events within the cooldown as one follow at once and one when it ends); each pass records its result, and a pass skipped because the turn that moved the task to Review still holds it is looked at again on the poll. A pass the plugin started (`--confirm-with pull-request-mode`) asks it again right before merging or sending a fix turn, so a Green task's `--merge` pass merges nothing and reports inactive, and `--confirm-with` with no plugin id is invalid_argument. A shared status probe (`task pr status --shared`, as the card's plugins probe) shares a probe already running, so two at once ask GitHub once, and reuses its answer for a few seconds, while an explicit read always asks GitHub and leaves the shared answer alone; creating a task's pull requests or running a pass forgets the shared answer, and a failed probe is not kept.
    def test_task_pr_autopilot_fixes_red_pull_request_until_green(self):
        missing, _ = self.call_cli("task", "pr", "autopilot", str(uuid.uuid4()), expected_status=3)
        self.assert_failure(missing, "not_found")
        task = self.create_repo_task("PR autopilot", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        self.assertEqual(task["status"], "Review")
        self.seed_done_task_pull_request(task["id"], number=801)

        gh_directory = self.data_directory / "autopilot-gh-fixture"
        gh_directory.mkdir()
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_state = gh_directory / "state"
        gh_calls = gh_directory / "calls"
        gh_environment = {"PATH": f"{gh_directory}:{os.environ.get('PATH', '')}"}

        def set_pull_request(checks, threads=0):
            gh_state.write_text(f"801=unmerged\n801.checks={checks}\n801.threads={threads}\n", encoding="utf-8")

        def history_texts(role):
            history = self.assert_success(self.call_cli(
                "conversation", "history", task["id"],
                extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture")},
            )[0])
            return [item["text"] for item in history["messages"] if item["role"] == role]

        set_pull_request("failure", threads=1)
        manual_status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(manual_status[0]["checks"], "failure")
        self.assertEqual(manual_status[0]["failingChecks"], ["fixture-ci"])
        self.assertEqual(manual_status[0]["health"], "red")
        self.assertIsNone(manual_status[0].get("unresolvedReviewThreads"), "A plain status read leaves review threads alone.")
        self.assertNotIn("threads 801", gh_calls.read_text(encoding="utf-8").splitlines())
        with_threads = self.assert_success(self.call_cli("task", "pr", "status", task["id"], "--review-threads", extra_environment=gh_environment)[0])
        self.assertEqual(with_threads[0]["unresolvedReviewThreads"], 1)
        self.assertIn("threads 801", gh_calls.read_text(encoding="utf-8").splitlines())
        gh_calls.write_text("", encoding="utf-8")

        # A shared probe (as the card's plugins make on focus and on moves) shares a
        # running probe and reuses its answer for a while; an explicit read always asks.
        cache_environment = {**gh_environment, "PLAYHOUSE_E2E_PR_STATUS_CACHE_SECONDS": "60"}

        def probes():
            return gh_calls.read_text(encoding="utf-8").splitlines().count("801")

        def shared_status():
            return self.assert_success(self.call_cli("task", "pr", "status", task["id"], "--shared", extra_environment=cache_environment)[0])

        set_pull_request("failure")
        together = []
        readers = [threading.Thread(target=lambda: together.append(shared_status())) for _ in range(2)]
        for reader in readers:
            reader.start()
        for reader in readers:
            reader.join()
        self.assertEqual([states[0]["health"] for states in together], ["red", "red"])
        self.assertEqual(probes(), 1, "Two shared probes at once ask GitHub once.")
        set_pull_request("success")
        self.assertEqual(shared_status()[0]["health"], "red", "A shared probe within the cache's life reuses the answer.")
        self.assertEqual(probes(), 1)
        self.assertEqual(self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=cache_environment)[0])[0]["health"], "green",
                         "An explicit read always asks GitHub.")
        self.assertEqual(probes(), 2)
        self.assertEqual(shared_status()[0]["health"], "red", "An explicit read leaves the shared answer alone.")
        self.assert_success(self.call_cli("task", "pr", "create", task["id"], "--if-needed", extra_environment=cache_environment)[0])
        self.assertEqual(shared_status()[0]["health"], "green", "Creating a task's pull requests forgets its shared answer.")
        self.assertEqual(probes(), 3)
        set_pull_request("pending")
        self.assertEqual(self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], extra_environment=cache_environment)[0])["action"], "pending")
        gh_state.unlink()
        self.assert_failure(self.call_cli("task", "pr", "status", task["id"], "--shared", expected_status=1, extra_environment=cache_environment)[0], "operation_failed")
        set_pull_request("pending")
        self.assertEqual(shared_status()[0]["health"], "pending", "A pass forgets the shared answer, and a failed probe isn't kept.")
        self.assertTrue(any(event.get("event") == "task.pr.status.shared" and event.get("taskID") == task["id"] for event in self.diagnostic_events()),
                        "The reused answers are recorded.")
        gh_calls.write_text("", encoding="utf-8")

        # A rerun counts only by its latest run, as on GitHub.
        for checks, state, failing in (("rerun-success", "success", []), ("rerun-failure", "failure", ["fixture-ci"]), ("workflows", "failure", ["build"]), ("workflows-failing", "failure", ["build"]), ("statuses", "success", []), ("untimed", "success", [])):
            set_pull_request(checks)
            rerun_status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
            self.assertEqual(rerun_status[0]["checks"], state, checks)
            self.assertEqual(rerun_status[0]["failingChecks"], failing, checks)

        set_pull_request("pending")
        user_messages_before = len(history_texts("user"))
        pending = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(pending["action"], "pending")
        self.assertEqual(pending["states"][0]["health"], "pending")
        self.assertEqual(pending["states"][0]["unresolvedReviewThreads"], 0)
        self.assertIn("threads 801", gh_calls.read_text(encoding="utf-8").splitlines(), "Autopilot reads the PR's review threads.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review")
        self.assertEqual(len(history_texts("user")), user_messages_before, "Pending checks must not start a fix turn.")

        set_pull_request("failure", threads=2)
        observed = {}

        def while_fixing(environment):
            observed["status"] = self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"]
            # The fix is pushed: the threads are answered and resolved, and CI reruns.
            set_pull_request("pending")

        fixed = self.drive_held_fixture_command(
            task["id"], ["task", "pr", "autopilot", task["id"]], "completed",
            on_hold=while_fixing, extra_environment=gh_environment,
        )
        self.assertEqual(fixed["action"], "fixed")
        self.assertEqual(fixed["states"][0]["health"], "red")
        self.assertEqual(fixed["states"][0]["unresolvedReviewThreads"], 2)
        self.assertEqual(observed["status"], "In Progress", "A fix turn brings the task back to In Progress.")
        self.assertEqual(fixed["taskStatus"], "Review", "Reporting completed returns the fixed task to Review.")
        prompt = history_texts("user")[-1]
        self.assertTrue(prompt.startswith("Playhouse autopilot:"), prompt)
        for expected in ("#801", "failing checks: fixture-ci", "2 unresolved review threads", "critically", "reply", "resolve", "waiting-response", "Jira"):
            self.assertIn(expected, prompt)
        rerun = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(rerun["action"], "pending", "Rerunning checks after a fix are followed, not fixed again.")

        set_pull_request("success")
        user_messages_before = len(history_texts("user"))
        green = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(green["action"], "green")
        self.assertEqual(green["states"][0]["health"], "green")
        self.assertEqual(len(history_texts("user")), user_messages_before, "A green PR needs no fix turn.")
        self.assertNotIn("merged\t", (gh_directory / "create-calls").read_text(encoding="utf-8") if (gh_directory / "create-calls").exists() else "", "Autopilot alone never merges.")

        # The same red state as the first fix comes back after green. Green reset the
        # loop guard, so autopilot fixes it again, and the model may stop the loop.
        set_pull_request("failure", threads=2)
        waiting = self.drive_held_fixture_command(
            task["id"], ["task", "pr", "autopilot", task["id"]], "waiting-response", extra_environment=gh_environment,
        )
        self.assertEqual(waiting["action"], "fixed", "Green must reset the loop guard so a repeated red state is fixed again.")
        self.assertEqual(waiting["taskStatus"], "Waiting Response")
        idle = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(idle["action"], "inactive", "Waiting Response stops the autopilot loop.")

        # The user sends the task back to Review: autopilot tries the still-red PR once
        # more, and when that fix changes nothing it stops with a reason.
        self.complete_fixture_turn(task["id"])
        retried = self.drive_held_fixture_command(
            task["id"], ["task", "pr", "autopilot", task["id"]], "completed", extra_environment=gh_environment,
        )
        self.assertEqual(retried["action"], "fixed", "A user's message lets autopilot send the same red state again.")
        user_messages_before = len(history_texts("user"))
        stalled = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(stalled["action"], "stalled")
        current = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(current["status"], "Waiting Response")
        self.assertIn("nothing changed", current["statusMessage"])
        self.assertEqual(len(history_texts("user")), user_messages_before, "An unchanged red state must not be sent again.")

        # Choosing the mode again restarts the streak (--reset-attempts, as the plugin
        # passes); five fixes that never reach green exhaust it even though each one
        # changed something.
        self.complete_fixture_turn(task["id"])
        for attempt in range(1, 6):
            set_pull_request("failure", threads=attempt)
            result = self.drive_held_fixture_command(
                task["id"], ["task", "pr", "autopilot", task["id"], *(["--reset-attempts"] if attempt == 1 else [])], "completed", extra_environment=gh_environment,
            )
            self.assertEqual(result["action"], "fixed", f"Fix attempt {attempt} should run.")
        set_pull_request("failure", threads=6)
        capped = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(capped["action"], "stalled")
        capped_task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(capped_task["status"], "Waiting Response")
        self.assertIn("5 fix turns", capped_task["statusMessage"])

        # The pull-request-mode plugin's service follows a Green task itself: when Green is
        # chosen in Review, when it reaches Review, on a slow poll while checks run, and on
        # focus through its throttle.
        followed = self.create_repo_task("PR autopilot service", [self.secondary], merge_targets={self.secondary: "main"}, materialize=True)
        self.seed_done_task_pull_request(followed["id"], number=802)
        gh_state.write_text("802=unmerged\n802.checks=pending\n", encoding="utf-8")
        service_environment = {**gh_environment, "PLAYHOUSE_E2E_PR_AUTOPILOT_POLL_SECONDS": "2", "PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS": "3"}

        def follows(trigger):
            return [event for event in self.diagnostic_events() if event.get("event") == "plugin.pull_request_mode.follow"
                    and event.get("taskID") == followed["id"] and event.get("trigger") == trigger]

        def wait_for_follows(trigger, count, timeout=20):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline and len(follows(trigger)) < count:
                time.sleep(0.25)
            self.assertGreaterEqual(len(follows(trigger)), count, f"The plugin follows the task on {trigger}.")

        self.set_pull_request_mode(followed["id"], "autopilot", extra_environment=service_environment)
        wait_for_follows("mode", 1)
        self.assertEqual(follows("mode")[0]["mode"], "autopilot")
        wait_for_follows("poll", 1)
        # A turn that waits for the user leaves the task where the user moves it to Review.
        self.complete_fixture_turn(followed["id"], executable_name="codex-fixture-follow", outcome="waiting-response",
                                   expected_status="Waiting Response", extra_environment=service_environment)
        self.assert_success(self.call_cli("task", "move", followed["id"], "Review", extra_environment=service_environment)[0])
        wait_for_follows("review", 1)
        for _ in range(3):
            self.assert_success(self.call_cli("plugin", "event", "app.focus", extra_environment=service_environment)[0])
        wait_for_follows("focus", 2)
        time.sleep(4)
        self.assertEqual(len(follows("focus")), 2, "Three focuses within the cooldown follow once at once and once when it ends.")

        # Green ends the slow poll. A turn that completes moves the task to Review while it
        # still holds the task, so that pass is skipped; the plugin looks again on the poll.
        gh_state.write_text("802=unmerged\n802.checks=success\n", encoding="utf-8")
        wait_for_follows("poll", len(follows("poll")) + 1)
        time.sleep(3)
        polls_when_green = len(follows("poll"))
        time.sleep(3)
        self.assertEqual(len(follows("poll")), polls_when_green, "A green PR isn't polled.")
        self.complete_fixture_turn(followed["id"], executable_name="codex-fixture-follow-review", extra_environment=service_environment)
        wait_for_follows("review", 2)

        def review_outcomes():
            return [event.get("action") for event in self.diagnostic_events() if event.get("event") == "plugin.pull_request_mode.followed"
                    and event.get("taskID") == followed["id"] and event.get("trigger") == "review"]

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and len(review_outcomes()) < 2:
            time.sleep(0.25)
        self.assertEqual(len(review_outcomes()), 2, "The review pass reports its outcome.")
        if review_outcomes()[1] == "inactive":
            # Generous: the review pass and the next 2s poll can lag when the host is busy.
            wait_for_follows("poll", polls_when_green + 1, timeout=30)
        else:
            # On a busy host the turn can let go of the task before the pass reads it; the
            # pass then finds the green PR itself, and a green PR needs no poll.
            self.assertEqual(review_outcomes()[1], "green", "A review pass that isn't skipped finds the green PR.")

        # A pass the plugin started asks it again before it merges: with the mode no longer
        # Merge, it merges nothing.
        gh_state.write_text("802=unmerged\n802.checks=success\n", encoding="utf-8")
        # The plugin's own poll pass may still be running (its follow event is logged as it
        # starts), which turns this pass away before it asks; ask again once that pass ends.
        def merge_pass():
            outcome = self.assert_success(self.call_cli(
                "task", "pr", "autopilot", followed["id"], "--merge", "--confirm-with", "pull-request-mode", extra_environment=gh_environment,
            )[0])
            return None if outcome.get("reason") == "Autopilot is already handling this task." else outcome
        declined = self.wait_for(merge_pass, "A merge pass should run once the plugin's pass ends.")
        self.assertEqual(declined["action"], "inactive")
        self.assertNotIn("merged\t802", (gh_directory / "create-calls").read_text(encoding="utf-8") if (gh_directory / "create-calls").exists() else "")
        # Diagnostics are written by a background flush, so the event can land after the call returns.
        self.wait_for(lambda: any(event.get("event") == "plugin.pull_request_mode.declined" and event.get("taskID") == followed["id"] and event.get("action") == "merge"
                                  for event in self.diagnostic_events()), "The plugin declined the merge.")
        self.assert_failure(self.call_cli("task", "pr", "autopilot", followed["id"], "--confirm-with", expected_status=2)[0], "invalid_argument")
        self.set_pull_request_mode(followed["id"], None)
    # case-contract: test_task_pr_merge_mode_merges_green_pull_request | Merge mode (a `task pr autopilot --merge` pass, which the pull-request-mode plugin runs for its Merge tasks) does everything autopilot does (it reads review threads, and red pull requests take the same autopilot fix path covered by the autopilot case) and also merges each linked pull request once it is green: with checks still running, or no checks reported yet on a freshly pushed head, it merges nothing and the task stays in Review; once checks pass (or the head has had no checks past the registration grace, as in a repository without CI) with no unresolved threads and GitHub reporting it mergeable, it merges the PR through GitHub CLI, pinned to the head commit it saw green, with the first merge method the repository allows (squash when allowed, otherwise a merge commit), exactly once; the PR reads as merged, the task stays in Review for the user to complete, and the card shows the merged completion action. A head that still has no checks after the registration grace is merged all the same. A merge GitHub refuses (for example a required review) moves the task to Waiting Response with GitHub's reason instead of retrying.
    def test_task_pr_merge_mode_merges_green_pull_request(self):
        task = self.create_repo_task("PR merge mode", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        refused = self.create_repo_task("PR merge refused", [self.secondary], merge_targets={self.secondary: "main"}, materialize=True)
        self.seed_done_task_pull_request(task["id"], number=811)
        self.seed_done_task_pull_request(refused["id"], number=812)

        gh_directory = self.data_directory / "merge-gh-fixture"
        gh_directory.mkdir()
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_state = gh_directory / "state"
        gh_calls = gh_directory / "calls"
        merge_log = gh_directory / "create-calls"
        gh_environment = {"PATH": f"{gh_directory}:{os.environ.get('PATH', '')}"}
        gh_state.write_text("811=unmerged\n811.checks=pending\n812=unmerged\n812.checks=none\n812.merge=Pull request is not mergeable: a review is required\n", encoding="utf-8")

        def commit_head(worktree, committed_at=None):
            # The no-checks grace runs from the head's commit time; pin it either way.
            environment = dict(os.environ)
            if committed_at:
                environment.update({"GIT_AUTHOR_DATE": committed_at, "GIT_COMMITTER_DATE": committed_at})
            subprocess.run(["git", "-C", str(worktree), "commit", "--allow-empty", "-m", "Fixture head"], check=True, capture_output=True, text=True, env=environment)

        def merges():
            return [line for line in merge_log.read_text(encoding="utf-8").splitlines() if line.startswith("merge")] if merge_log.exists() else []

        pending = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], "--merge", extra_environment=gh_environment)[0])
        self.assertEqual(pending["action"], "pending")
        self.assertEqual(pending["states"][0]["unresolvedReviewThreads"], 0)
        self.assertIn("threads 811", gh_calls.read_text(encoding="utf-8").splitlines(), "Merge mode reads review threads like autopilot.")
        self.assertEqual(merges(), [], "Running checks must not be merged.")
        commit_head(task["repositoryWorktrees"][0]["worktreePath"])
        gh_state.write_text(gh_state.read_text(encoding="utf-8").replace("811.checks=pending", "811.checks=none"), encoding="utf-8")
        no_checks = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], "--merge", extra_environment=gh_environment)[0])
        self.assertEqual(no_checks["action"], "pending", "A freshly pushed head may not have registered its checks yet.")
        self.assertEqual(no_checks["taskStatus"], "Review")
        self.assertEqual(merges(), [], "A head with no checks reported yet must not be merged.")
        gh_state.write_text(gh_state.read_text(encoding="utf-8").replace("811.checks=none", "811.checks=pending"), encoding="utf-8")

        gh_state.write_text(gh_state.read_text(encoding="utf-8").replace("811.checks=pending", "811.checks=success"), encoding="utf-8")
        merged = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], "--merge", extra_environment=gh_environment)[0])
        self.assertEqual(merged["action"], "merged")
        self.assertEqual(merged["mergedPullRequests"], [811])
        self.assertTrue(merged["states"][0]["merged"])
        self.assertEqual(merged["states"][0]["health"], "merged", "A merged PR reports the merged (purple) health.")
        self.assertEqual(merges(), ["merged\t811\t--squash"], "A green PR is merged once with the first allowed method.")
        merge_call = [line for line in merge_log.read_text(encoding="utf-8").splitlines() if line.startswith("merged\t811")]
        self.assertEqual(len(merge_call), 1)
        self.assertEqual(merged["taskStatus"], "Review", "Merging leaves the task in Review for the user to complete.")
        again = self.assert_success(self.call_cli("task", "pr", "autopilot", task["id"], "--merge", extra_environment=gh_environment)[0])
        self.assertEqual(again["action"], "merged")
        self.assertIsNone(again.get("mergedPullRequests"), "An already-merged PR is reported, not merged again.")
        self.assertEqual(len(merges()), 1, "An already-merged PR is not merged again.")
        status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertTrue(status[0]["merged"])

        # Long past the grace with still no checks (a repository without CI): merge mode
        # still attempts the merge. GitHub refuses it here (a required review), so the
        # task stops in Waiting Response with GitHub's reason.
        commit_head(refused["repositoryWorktrees"][0]["worktreePath"], committed_at="2020-01-01T00:00:00Z")
        no_ci = self.assert_success(self.call_cli("task", "pr", "autopilot", refused["id"], "--merge", extra_environment=gh_environment)[0])
        self.assertEqual(no_ci["action"], "stalled")
        no_ci_task = self.assert_success(self.call_cli("task", "get", refused["id"])[0])
        self.assertEqual(no_ci_task["status"], "Waiting Response")
        self.assertIn("couldn't merge pull request #812", no_ci_task["statusMessage"])
        self.assertNotIn("no checks", no_ci_task["statusMessage"])
        self.assertEqual(merges(), ["merged\t811\t--squash", "merge-failed\t812\t--squash"], "No checks past the grace is still merged, with the first allowed method.")

        # The user sends it back to Review; GitHub still refuses the merge. The
        # `repo.methods` line, written after #811 merged, disallows squash from here on.
        self.complete_fixture_turn(refused["id"])
        gh_state.write_text(gh_state.read_text(encoding="utf-8") + "repo.methods=merge,rebase\n", encoding="utf-8")
        stalled = self.assert_success(self.call_cli("task", "pr", "autopilot", refused["id"], "--merge", extra_environment=gh_environment)[0])
        self.assertEqual(stalled["action"], "stalled")
        current = self.assert_success(self.call_cli("task", "get", refused["id"])[0])
        self.assertEqual(current["status"], "Waiting Response")
        self.assertIn("couldn't merge pull request #812", current["statusMessage"])
        self.assertIn("a review is required", current["statusMessage"])
        self.assertEqual(merges()[-1], "merge-failed\t812\t--merge")
        idle = self.assert_success(self.call_cli("task", "pr", "autopilot", refused["id"], "--merge", extra_environment=gh_environment)[0])
        self.assertEqual(idle["action"], "inactive", "A refused merge does not retry.")
    # case-contract: test_review_probe_failure_alerts_only_while_in_review | A Review task whose linked pull request probe fails reports it: `task pr status` fails as operation_failed with the GitHub CLI's error, and the board raises its Pull request operation failed alert naming that error. Once the task moves to Done with --allow-unmerged, which removes its worktree, it is Done with no worktree left, a board probe that was already running when it moved raises no alert, and `task pr status` of the Done task lists only its recorded pull request, without probing, instead of the GitHub CLI's error.
    def test_review_probe_failure_alerts_only_while_in_review(self):
        task = self.create_repo_task("Review probe failure", [self.primary], materialize=True)
        self.assertEqual(task["status"], "Review")
        self.seed_done_task_pull_request(task["id"], number=123)
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        directory = self.data_directory / "review-probe-failure-gh"
        directory.mkdir()
        executable = directory / "gh"
        executable.write_text("#!/bin/sh\necho 'fixture probe failure' >&2\nexit 1\n", encoding="utf-8")
        executable.chmod(0o755)
        environment = {"PATH": f"{directory}:{os.environ.get('PATH', '')}"}
        status, _ = self.call_cli("task", "pr", "status", task["id"], expected_status=1, extra_environment=environment)
        self.assert_failure(status, "operation_failed")
        self.assertIn("fixture probe failure", status["error"]["message"], "The probe reports the GitHub CLI's own error.")
        moved, _ = self.call_cli("task", "move", task["id"], "Done", "--allow-unmerged", extra_environment=environment)
        self.assertEqual(self.assert_success(moved)["status"], "Done")
        self.assertFalse(worktree.exists(), "Moving to Done removes the worktree a later probe would read.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Done")
        listed = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=environment)[0])
        self.assertEqual([(item["number"], item.get("past")) for item in listed], [(123, None)],
                         "A Done task whose worktree was removed lists only its recorded pull request, without probing GitHub.")
    # case-contract: test_review_pr_conflicts_probe_and_verify | Separate Review task cards probe their linked pull requests concurrently on app focus, with refreshes limited to one per 20 seconds, with focus events during cooldown coalesced into one trailing refresh. A conflicting PR or a mergeable PR whose remote head is not pushed locally retains the imported conflict action with its indicator artwork beside its PR link; the UI renders the artwork inside the action, keeps it beside the PR link, and gives both controls hit targets of at least 30×30 points. Clicking the conflict action sends the corrected request in the task conversation. CLI and UI use the same GitHub mergeability and head checks, retry once when resolution remains unconfirmed, and clear the action only after GitHub confirms the pushed head.
    def test_review_pr_conflicts_probe_and_verify(self):
        task = self.create_repo_task("Review PR conflict probe", [self.primary, self.secondary], materialize=True)
        self.assertEqual(task["status"], "Review")
        self.assertEqual(self.assert_success(self.call_cli("task", "pr", "status", task["id"])[0]), [])
        self.seed_done_task_pull_request(task["id"], number=123)
        self.seed_done_task_pull_request(task["id"], number=456, repository_index=1)

        directory = self.data_directory / "review-pr-gh-fixture"
        directory.mkdir()
        state = directory / "state"
        state.write_text("123=CONFLICTING\n456=MERGEABLE\n", encoding="utf-8")
        started = directory / "started"
        started.mkdir()
        executable = directory / "gh"
        executable.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" != pr ] || [ \"$2\" != view ] || { [ \"$3\" != 123 ] && [ \"$3\" != 456 ]; } || [ \"$4\" != --json ] || [ \"$5\" != mergedAt,mergeable,headRefOid,statusCheckRollup,state ]; then\n"
            "  echo 'Unexpected gh fixture command' >&2\n"
            "  exit 2\n"
            "fi\n"
            f"touch {shlex.quote(str(started))}/\"$3\"\n"
            f"for attempt in $(seq 1 100); do [ -f {shlex.quote(str(started / '123'))} ] && [ -f {shlex.quote(str(started / '456'))} ] && break; sleep 0.02; done\n"
            f"if [ ! -f {shlex.quote(str(started / '123'))} ] || [ ! -f {shlex.quote(str(started / '456'))} ]; then echo 'PR probes did not run in parallel' >&2; exit 3; fi\n"
            f"mergeable=$(awk -F= -v number=\"$3\" '$1 == number {{ print $2 }}' {shlex.quote(str(state))})\n"
            "head=$(git rev-parse HEAD)\n"
            "if [ \"$mergeable\" = HEAD_MISMATCH ]; then head=remote-head-not-pushed; mergeable=MERGEABLE; fi\n"
            "if [ \"$mergeable\" = CONFLICTING ]; then printf '{\"mergedAt\":null,\"mergeable\":\"CONFLICTING\",\"headRefOid\":\"%s\",\"statusCheckRollup\":[]}\\n' \"$head\"; else printf '{\"mergedAt\":null,\"mergeable\":\"MERGEABLE\",\"headRefOid\":\"%s\",\"statusCheckRollup\":[]}\\n' \"$head\"; fi\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        environment = {"PATH": f"{directory}:{os.environ.get('PATH', '')}"}
        status, _ = self.call_cli("task", "pr", "status", task["id"], extra_environment=environment)
        states = self.assert_success(status)
        self.assertEqual({item["number"] for item in states}, {123, 456})
        self.assertEqual({item["number"] for item in states if item["hasConflicts"]}, {123})
        self.assertTrue(all(item["headRefOid"] == item["localHeadOid"] for item in states))
        self.assertTrue((started / "123").is_file() and (started / "456").is_file(), "Both linked PR probes should overlap.")

        (started / "123").unlink()
        (started / "456").unlink()
        still_conflicted, _ = self.call_cli("task", "pr", "verify", task["id"], extra_environment=environment)
        self.assertEqual(self.assert_success(still_conflicted)["status"], "stillConflicted")
        self.assertTrue((started / "123").is_file() and (started / "456").is_file())

        state.write_text("123=MERGEABLE\n456=HEAD_MISMATCH\n", encoding="utf-8")
        for number in (123, 456):
            (started / str(number)).unlink()
        mismatch, _ = self.call_cli("task", "pr", "verify", task["id"], extra_environment=environment)
        self.assertEqual(self.assert_success(mismatch)["status"], "stillConflicted", "A mergeable PR with a remote head that is not pushed locally must retain the conflict indicator.")
        mismatch_status, _ = self.call_cli("task", "pr", "status", task["id"], extra_environment=environment)
        mismatch_state = next(item for item in self.assert_success(mismatch_status) if item["number"] == 456)
        self.assertNotEqual(mismatch_state["headRefOid"], mismatch_state["localHeadOid"])

        state.write_text("123=MERGEABLE\n456=MERGEABLE\n", encoding="utf-8")
        for number in (123, 456):
            (started / str(number)).unlink()
        verification, _ = self.call_cli("task", "pr", "verify", task["id"], extra_environment=environment)
        self.assertEqual(self.assert_success(verification)["status"], "resolved")
    # case-contract: test_task_pr_conflicts_detect_without_mutation | The real Git CLI detects merge conflicts without mutation, and PR creation still publishes the task branch and reaches the normal GitHub CLI path; conflicts do not block PR creation. CLI/XPC resolves staged conflicts locally without pushing and commits and pushes a staged resolution without changing the target. The paired UI confirms PR creation proceeds for a conflicted branch and the existing Fix Conflicts action still appears once the PR is linked.
    def test_task_pr_conflicts_detect_without_mutation(self):
        task = self.create_repo_task("PR conflict detection", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        record = task["repositoryWorktrees"][0]
        worktree = Path(record["worktreePath"])
        conflict_path = "playhouse-pr-conflict-fixture.txt"
        remote = self.data_directory / "pr-conflict-origin.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
        self.run_git(self.primary, "remote", "add", "origin", str(remote))
        self.run_git(self.primary, "push", "--set-upstream", "origin", "main")
        target_file = self.primary / conflict_path
        target_file.write_text("target branch version\n", encoding="utf-8")
        self.run_git(self.primary, "add", conflict_path)
        self.run_git(self.primary, "commit", "-m", "Update PR target fixture")
        self.run_git(self.primary, "push", "origin", "main")
        branch_file = worktree / conflict_path
        branch_file.write_text("task branch version\n", encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        self.run_git(worktree, "commit", "-m", "Update task branch fixture")
        branch_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        target_head = self.run_git(self.primary, "rev-parse", "main").strip()

        checked, _ = self.call_cli("task", "pr", "conflicts", task["id"])
        self.assertEqual(self.assert_success(checked)["repositories"], [str(self.primary)])
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), branch_head)
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main").strip(), target_head)
        self.assertEqual((worktree / conflict_path).read_text(encoding="utf-8"), "task branch version\n")
        self.assertEqual(target_file.read_text(encoding="utf-8"), "target branch version\n")
        # The fixture gh fails the first create, so the attempt reaches the normal GitHub CLI
        # failure without depending on the installed gh or its sign-in.
        gh_directory = self.data_directory / "gh-fixture"
        gh_directory.mkdir()
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        (gh_directory / "state").write_text("", encoding="utf-8")
        gh_create_log = gh_directory / "create-calls"
        gh_create_failure = gh_directory / "fail-create-attempt"
        gh_create_failure.write_text("1", encoding="utf-8")
        gh_environment = {
            # PR creation asks the task's provider for the PR text first; use the fixture that ran its turn.
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(self.data_directory / "codex-fixture"),
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "PLAYHOUSE_E2E_GH_STATE_PATH": str(gh_directory / "state"),
            "PLAYHOUSE_E2E_GH_CALL_LOG": str(gh_directory / "calls"),
            "PLAYHOUSE_E2E_GH_CREATE_LOG": str(gh_create_log),
            "PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH": str(gh_create_failure),
        }
        pr_attempt, _ = self.call_cli("task", "pr", "create", task["id"], expected_status=1, extra_environment=gh_environment)
        self.assert_failure(pr_attempt, "operation_failed")
        self.assertNotIn("conflicts_require_confirmation", json.dumps(pr_attempt))
        self.assertNotIn("Pull request conflicts were found", pr_attempt["error"]["message"])
        self.assertIn("GitHub CLI couldn't complete the request. fixture GitHub create failure", pr_attempt["error"]["message"])
        failed_creates = [line.split("\t")[1] for line in gh_create_log.read_text(encoding="utf-8").splitlines() if line.startswith("failed\t")]
        self.assertEqual(
            [os.path.realpath(path) for path in failed_creates], [os.path.realpath(worktree)],
            "gh pr create should have run once in the task worktree.",
        )
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), branch_head)
        task_branch_ref = f"refs/heads/{record['branch']}"
        published_branch_head = self.run_git(remote, "rev-parse", task_branch_ref).strip()
        self.assertEqual(published_branch_head, branch_head, "A conflict must not block publishing the task branch for PR creation.")
        subprocess.run(["git", "--git-dir", str(remote), "update-ref", "-d", task_branch_ref], check=True, capture_output=True, text=True)
        self.run_git(worktree, "fetch", "origin", "main")
        merge = subprocess.run(
            ["git", "-C", str(worktree), "merge", "--no-commit", "--no-ff", "FETCH_HEAD"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(merge.returncode, 1, f"Expected the real Git fixture merge to conflict: {merge.stderr}")
        resolved_content = "resolved task and target versions\n"
        branch_file.write_text(resolved_content, encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        resolved_only, _ = self.call_cli("task", "pr", "resolve", task["id"], "resolve-only")
        self.assertEqual(self.assert_success(resolved_only)["id"], task["id"])
        resolved_only_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertNotEqual(resolved_only_head, branch_head, "Resolve-only should commit a fully staged conflict resolution locally.")
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main").strip(), target_head, "Conflict resolution must leave the target branch unchanged.")
        self.assertEqual(branch_file.read_text(encoding="utf-8"), resolved_content)
        unresolved_remote_branch = subprocess.run(
            ["git", "--git-dir", str(remote), "show-ref", "--verify", "--quiet", task_branch_ref],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(unresolved_remote_branch.returncode, 1, "Resolve-only must commit locally without publishing the task branch.")

        target_file.write_text("target branch version two\n", encoding="utf-8")
        self.run_git(self.primary, "add", conflict_path)
        self.run_git(self.primary, "commit", "-m", "Advance PR target fixture again")
        self.run_git(self.primary, "push", "origin", "main")
        target_head_second = self.run_git(self.primary, "rev-parse", "main").strip()
        branch_file.write_text("task branch version two\n", encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        self.run_git(worktree, "commit", "-m", "Advance task branch fixture again")
        branch_head_second = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.run_git(worktree, "fetch", "origin", "main")
        second_merge = subprocess.run(
            ["git", "-C", str(worktree), "merge", "--no-commit", "--no-ff", "FETCH_HEAD"],
            check=False, capture_output=True, text=True,
        )
        self.assertEqual(second_merge.returncode, 1, f"Expected the second real Git fixture merge to conflict: {second_merge.stderr}")
        pushed_content = "resolved task and target versions two\n"
        branch_file.write_text(pushed_content, encoding="utf-8")
        self.run_git(worktree, "add", conflict_path)
        resolved, _ = self.call_cli("task", "pr", "resolve", task["id"], "resolve-and-push")
        self.assertEqual(self.assert_success(resolved)["id"], task["id"])
        resolved_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertNotEqual(resolved_head, branch_head_second, "A fully staged resolution should be committed when resuming the second merge.")
        self.assertEqual(self.run_git(self.primary, "rev-parse", "main").strip(), target_head_second, "Conflict resolution must leave the target branch unchanged.")
        self.assertEqual(branch_file.read_text(encoding="utf-8"), pushed_content)
        remote_branch_head = self.run_git(remote, "rev-parse", task_branch_ref).strip()
        self.assertEqual(remote_branch_head, resolved_head, "Resolve-and-push must publish the resolved task branch.")
        remote_content = subprocess.run(
            ["git", "--git-dir", str(remote), "show", f"{task_branch_ref}:{conflict_path}"],
            check=True, capture_output=True, text=True,
        ).stdout
        self.assertEqual(remote_content, pushed_content)
        self.assertIsNone(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0].get("pullRequestNumber"))
        invalid, _ = self.call_cli("task", "pr", "resolve", task["id"], "unknown", expected_status=2)
        self.assert_failure(invalid, "invalid_argument")
        self.run_git(self.primary, "remote", "remove", "origin")
    # case-contract: test_review_sync_pushes_unpushed_changes_on_completion | A completed turn outcome on a task with a PR-linked repository and a configured remote commits local work, merges new remote pull request commits, and pushes the branch before the task reaches Review, so the reviewed worktree holds no local-only changes. A linked repository without a publishing remote is left untouched and still reaches Review. When the sync cannot complete, the task moves to Blocked with the sync failure message instead of resting in Review, and a later successful sync pushes the stranded commits and returns the task to Review. While a provider turn holds the task's worktree, the sync command skips it untouched and reports turn-active. A worktree switched off its task branch fails the sync with a message naming both branches and blocks the task, leaving that other branch and the remote untouched; once switched back, a remote commit whose changes the branch already holds is concluded as a merge commit and pushed, the task returns to Review, and the next sync is up-to-date instead of failing on an unfinished merge. A merge Git refuses outright, such as one with unrelated history, blocks the task with Git's own error after the generic merge failure message, and restoring the remote branch heals it back to Review. A clean merge an earlier sync left unfinished on the task branch is concluded as a merge commit and pushed. A task branch deleted on a reachable remote is reported as no-remote-branch and leaves the task in Review.
    def test_review_sync_pushes_unpushed_changes_on_completion(self):
        task = self.create_repo_task("Review sync push", [self.primary], merge_targets={self.primary: "main"}, materialize=True)
        record = task["repositoryWorktrees"][0]
        worktree = Path(record["worktreePath"])
        branch = record["branch"]
        self.seed_done_task_pull_request(task["id"], number=123)

        # Without a publishing remote, the sync has nothing to act on and Review is untouched.
        no_remote, _ = self.call_cli("task", "pr", "sync", task["id"])
        no_remote_result = self.assert_success(no_remote)
        self.assertEqual([item["action"] for item in no_remote_result["records"]], ["no-remote"])
        self.assertEqual(no_remote_result["status"], "Review")

        # While a provider turn owns the worktree, the sync skips instead of mutating it.
        process, _, active, release = self.start_progress_fixture_turn(task["id"], "codex-fixture-review-sync-hold-release")
        try:
            skipped, _ = self.call_cli("task", "pr", "sync", task["id"])
            skipped_result = self.assert_success(skipped)
            self.assertEqual(skipped_result.get("skipped"), "turn-active")
            self.assertEqual(skipped_result["records"], [])
            outcome, _ = self.call_cli("task", "outcome", task["id"], "completed")
            self.assertEqual(self.assert_success(outcome)["outcome"], "completed")
            release.write_text("Release the active turn.\n", encoding="utf-8")
            process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                release.write_text("Release the active turn.\n", encoding="utf-8")
                process.communicate(timeout=20)
            active.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review")

        remote = self.data_directory / "review-sync-origin.git"
        subprocess.run(["git", "init", "--bare", str(remote)], check=True, capture_output=True, text=True)
        self.run_git(self.primary, "remote", "add", "origin", str(remote))
        self.run_git(worktree, "push", "--set-upstream", "origin", branch)

        # A reviewer commit on the remote PR branch the local branch has not seen.
        clone = self.data_directory / "review-sync-clone"
        subprocess.run(["git", "clone", "--branch", branch, str(remote), str(clone)], check=True, capture_output=True, text=True)
        (clone / "remote-side.txt").write_text("Remote reviewer commit.\n", encoding="utf-8")
        self.run_git(clone, "add", "remote-side.txt")
        self.run_git(clone, "commit", "-m", "Remote PR commit")
        self.run_git(clone, "push", "origin", branch)
        reviewer_head = self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip()

        # Local uncommitted work the completed turn leaves behind.
        (worktree / "local-side.txt").write_text("Local turn output.\n", encoding="utf-8")
        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-review-sync")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain", "--untracked-files=all").strip(), "")
        local_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertEqual(self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip(), local_head)
        self.assertNotEqual(local_head, reviewer_head, "The sync should push a merge of the reviewer commit and the local work.")
        self.assertEqual((worktree / "remote-side.txt").read_text(encoding="utf-8"), "Remote reviewer commit.\n")
        pushed_local_side = subprocess.run(
            ["git", "--git-dir", str(remote), "show", f"refs/heads/{branch}:local-side.txt"],
            check=True, capture_output=True, text=True,
        ).stdout
        self.assertEqual(pushed_local_side, "Local turn output.\n")

        # A sync the daemon cannot complete blocks the task instead of resting in Review.
        self.run_git(self.primary, "remote", "set-url", "origin", str(self.data_directory / "missing-remote.git"))
        (worktree / "local-side.txt").write_text("Unpushable local change.\n", encoding="utf-8")
        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-review-sync", expected_status="Blocked")
        blocked = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertIn("couldn't sync this task's changes with its pull request", blocked.get("statusMessage") or "")

        # A later successful sync pushes the stranded commit and returns the task to Review.
        self.run_git(self.primary, "remote", "set-url", "origin", str(remote))
        healed, _ = self.call_cli("task", "pr", "sync", task["id"])
        healed_result = self.assert_success(healed)
        self.assertEqual([item["action"] for item in healed_result["records"]], ["pushed"])
        self.assertEqual(healed_result["status"], "Review")
        healed_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertEqual(self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip(), healed_head)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["status"], "Review")

        # A remote commit whose changes the local branch already holds, as after a squash merge.
        self.run_git(clone, "pull", "--ff-only", "origin", branch)
        for repository in (clone, worktree):
            (repository / "duplicate-side.txt").write_text("Same change on both sides.\n", encoding="utf-8")
            self.run_git(repository, "add", "duplicate-side.txt")
            self.run_git(repository, "commit", "-m", f"Duplicate change in {repository.name}")
        self.run_git(clone, "push", "origin", branch)
        duplicate_remote_head = self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip()

        # A worktree switched off its task branch is never merged into, committed to, or pushed.
        self.run_git(worktree, "checkout", "-b", "agent-side-branch")
        side_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        switched, _ = self.call_cli("task", "pr", "sync", task["id"], expected_status=1)
        self.assert_failure(switched, "operation_failed")
        self.assertIn("is on branch 'agent-side-branch', not its pull request branch", switched["error"]["message"])
        self.assertIn(f"'{branch}'", switched["error"]["message"])
        switched_task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(switched_task["status"], "Blocked")
        self.assertIn("agent-side-branch", switched_task.get("statusMessage") or "")
        self.assertEqual(self.run_git(worktree, "rev-parse", "HEAD").strip(), side_head)
        self.assertNotEqual(
            subprocess.run(["git", "-C", str(worktree), "rev-parse", "--verify", "MERGE_HEAD"], check=False, capture_output=True).returncode,
            0, "A sync on a switched branch must not start a merge.",
        )
        self.assertEqual(self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip(), duplicate_remote_head)

        # Back on the task branch, the clean merge is committed and pushed rather than left in progress.
        self.run_git(worktree, "checkout", branch)
        self.run_git(worktree, "branch", "-D", "agent-side-branch")
        merged, _ = self.call_cli("task", "pr", "sync", task["id"])
        merged_result = self.assert_success(merged)
        self.assertEqual([item["action"] for item in merged_result["records"]], ["merged-and-pushed"])
        self.assertEqual(merged_result["status"], "Review")
        self.assertNotIn("agent-side-branch", self.assert_success(self.call_cli("task", "get", task["id"])[0]).get("statusMessage") or "")
        self.assertNotEqual(
            subprocess.run(["git", "-C", str(worktree), "rev-parse", "--verify", "MERGE_HEAD"], check=False, capture_output=True).returncode,
            0, "A merge whose result matches HEAD must still be concluded.",
        )
        merged_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertEqual(len(self.run_git(worktree, "rev-list", "--parents", "-n", "1", merged_head).split()), 3)
        self.assertEqual(self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip(), merged_head)
        again, _ = self.call_cli("task", "pr", "sync", task["id"])
        self.assertEqual([item["action"] for item in self.assert_success(again)["records"]], ["up-to-date"])

        # A fatal merge failure reports Git's own error instead of only a generic message.
        unrelated = self.run_git(clone, "commit-tree", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "-m", "Unrelated history").strip()
        self.run_git(clone, "push", "--force", "origin", f"{unrelated}:refs/heads/{branch}")
        fatal, _ = self.call_cli("task", "pr", "sync", task["id"], expected_status=1)
        self.assert_failure(fatal, "operation_failed")
        self.assertIn("Git couldn't merge the remote task branch.", fatal["error"]["message"])
        self.assertIn("unrelated histories", fatal["error"]["message"])
        fatal_task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(fatal_task["status"], "Blocked")
        self.assertIn("unrelated histories", fatal_task.get("statusMessage") or "")
        self.run_git(worktree, "push", "--force", "origin", f"{merged_head}:refs/heads/{branch}")
        restored, _ = self.call_cli("task", "pr", "sync", task["id"])
        restored_result = self.assert_success(restored)
        self.assertEqual([item["action"] for item in restored_result["records"]], ["up-to-date"])
        self.assertEqual(restored_result["status"], "Review")

        # A clean merge an earlier sync left unfinished on the task branch is concluded and pushed.
        self.run_git(clone, "pull", "--ff-only", "origin", branch)
        for repository in (clone, worktree):
            (repository / "leftover-side.txt").write_text("Already merged change.\n", encoding="utf-8")
            self.run_git(repository, "add", "leftover-side.txt")
            self.run_git(repository, "commit", "-m", f"Leftover change in {repository.name}")
        self.run_git(clone, "push", "origin", branch)
        self.run_git(worktree, "fetch", "--quiet", "origin", branch)
        self.run_git(worktree, "merge", "--no-commit", "--no-ff", "FETCH_HEAD")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain", "--untracked-files=all").strip(), "")
        leftover, _ = self.call_cli("task", "pr", "sync", task["id"])
        leftover_result = self.assert_success(leftover)
        self.assertEqual([item["action"] for item in leftover_result["records"]], ["pushed"])
        self.assertEqual(leftover_result["status"], "Review")
        self.assertNotEqual(
            subprocess.run(["git", "-C", str(worktree), "rev-parse", "--verify", "MERGE_HEAD"], check=False, capture_output=True).returncode,
            0, "The sync should conclude a merge an earlier sync left unfinished.",
        )
        leftover_head = self.run_git(worktree, "rev-parse", "HEAD").strip()
        self.assertEqual(len(self.run_git(worktree, "rev-list", "--parents", "-n", "1", leftover_head).split()), 3)
        self.assertEqual(self.run_git(remote, "rev-parse", f"refs/heads/{branch}").strip(), leftover_head)

        # A branch deleted on a reachable remote is reported as missing, not as a fetch failure.
        self.run_git(remote, "update-ref", "-d", f"refs/heads/{branch}")
        deleted, _ = self.call_cli("task", "pr", "sync", task["id"])
        deleted_result = self.assert_success(deleted)
        self.assertEqual([item["action"] for item in deleted_result["records"]], ["no-remote-branch"])
        self.assertEqual(deleted_result["status"], "Review")
        self.run_git(self.primary, "remote", "remove", "origin")

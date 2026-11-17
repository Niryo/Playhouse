from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases26:
    def install_detect_gh_fixture(self, name):
        gh_directory = self.data_directory / name
        gh_directory.mkdir()
        gh = gh_directory / "gh"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "gh-fixture.sh", gh)
        gh.chmod(0o755)
        gh_state = gh_directory / "state"
        gh_state.write_text("", encoding="utf-8")
        environment = {
            "PATH": f"{gh_directory}:{os.environ.get('PATH', '')}",
            "PLAYHOUSE_E2E_GH_STATE_PATH": str(gh_state),
            "PLAYHOUSE_E2E_GH_CALL_LOG": str(gh_directory / "calls"),
            "PLAYHOUSE_E2E_GH_CREATE_LOG": str(gh_directory / "create-calls"),
            "PLAYHOUSE_E2E_GH_DETECT_LOG": str(gh_directory / "detect-calls"),
        }
        return gh_state, gh_directory / "detect-calls", environment

    # case-contract: test_task_repository_add_worktree_keeps_several_worktrees_per_repository | `task repository add-worktree` gives a task another worktree of a repository it already has, created at once on its own new branch (the given name, or a fresh one from the task title), and adding an already attached repository again does the same, so one repository can hold several worktrees, each listed with its own path and branch and persisted across fresh reads. A second worktree on a branch the task already uses is rejected and leaves the task unchanged. While a repository has several worktrees, `--repo` alone no longer picks one: remove, renew, edit and pr link fail with an error naming each worktree path and asking for `--worktree`, and `--worktree <path>`, like that worktree's chip remove badge, removes just that worktree and its folder. Each worktree's chip opens that worktree's settings. The next agent turn lists every worktree mapping and is told to open pull requests with task pr create or register them with task pr link, never to switch a worktree's branch, and to use add-worktree for another branch. `task create` can list a repository more than once: each entry is its own pending worktree with its own chip, the further automatic ones waiting as auto 2, auto 3 and so on, so each can be edited or removed on its own (with `--worktree-branch` naming it on the CLI), and starting the task gives each its own branch; giving two of them the same branch is rejected as invalid_argument and creates no task.
    def test_task_repository_add_worktree_keeps_several_worktrees_per_repository(self):
        task = self.create_repo_task("Several worktrees", [str(self.primary)], materialize=True)
        first = task["repositoryWorktrees"][0]
        self.assertFalse(first["isPending"])

        added = self.assert_success(self.call_cli(
            "task", "repository", "add-worktree", task["id"], "--repo", str(self.primary), "--branch", "second-line"
        )[0])
        records = added["repositoryWorktrees"]
        self.assertEqual(len(records), 2)
        self.assertEqual({record["repositoryPath"] for record in records}, {first["repositoryPath"]})
        second = records[1]
        self.assertEqual(second["branch"], "second-line")
        self.assertFalse(second["isPending"], "An added worktree is created at once.")
        self.assertNotEqual(second["worktreePath"], first["worktreePath"])
        self.assertEqual(self.run_git(Path(second["worktreePath"]), "branch", "--show-current").strip(), "second-line")
        self.assertEqual(self.run_git(Path(first["worktreePath"]), "branch", "--show-current").strip(), first["branch"], "The first worktree keeps its branch.")

        duplicate, _ = self.call_cli("task", "repository", "add-worktree", task["id"], "--repo", str(self.primary), "--branch", "second-line", expected_status=2)
        self.assert_failure(duplicate, "invalid_argument")
        self.assertIn("already has a worktree on branch 'second-line'", duplicate["error"]["message"])

        # Adding the attached repository again is one more worktree, on a fresh branch.
        third_task = self.assert_success(self.call_cli("task", "repository", "add", task["id"], "--repo", str(self.primary))[0])
        self.assertEqual(len(third_task["repositoryWorktrees"]), 3)
        third = third_task["repositoryWorktrees"][2]
        self.assertFalse(third["isPending"])
        self.assertNotIn(third["branch"], {first["branch"], "second-line"})
        self.assertTrue(third["branch"].startswith("several-worktrees"), third["branch"])

        fresh = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual([record["worktreePath"] for record in fresh["repositoryWorktrees"]],
                         [first["worktreePath"], second["worktreePath"], third["worktreePath"]], "Every worktree persists.")

        for command in (
            ("task", "repository", "remove", task["id"], "--repo", str(self.primary)),
            ("task", "repository", "renew", task["id"], "--repo", str(self.primary)),
            ("task", "repository", "edit", task["id"], "--repo", str(self.primary), "--branch", "x", "--branch-from", "main"),
            ("task", "pr", "link", task["id"], "--repo", str(self.primary), "--url", "https://github.com/playhouse-test/fixture/pull/1"),
        ):
            ambiguous, _ = self.call_cli(*command, expected_status=2)
            self.assert_failure(ambiguous, "invalid_argument")
            message = ambiguous["error"]["message"]
            self.assertIn("has 3 worktrees on this task", message, command)
            self.assertIn("--worktree", message)
            for record in fresh["repositoryWorktrees"]:
                self.assertIn(record["worktreePath"], message)
        self.assertEqual(len(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"]), 3, "Ambiguous commands change nothing.")

        removed = self.assert_success(self.call_cli("task", "repository", "remove", task["id"], "--worktree", third["worktreePath"])[0])
        self.assertEqual([record["worktreePath"] for record in removed["repositoryWorktrees"]], [first["worktreePath"], second["worktreePath"]])
        deadline = time.monotonic() + 20
        while Path(third["worktreePath"]).exists() and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(Path(third["worktreePath"]).exists(), "Removing a worktree removes its folder.")
        self.assertTrue(Path(second["worktreePath"]).exists())

        self.complete_fixture_turn(task["id"], message="Keep going on both lines.")
        history = json.loads((self.data_directory / "codex-fixture.history").read_text(encoding="utf-8"))
        instructions = "\n".join(item for item in [history.get("threadStartDeveloperInstructions"), *history.get("threadResumeDeveloperInstructions", [])] if item)
        self.assertIn(f"{first['repositoryPath']} -> {first['worktreePath']}", instructions)
        self.assertIn(f"{first['repositoryPath']} -> {second['worktreePath']}", instructions)
        self.assertIn(f"task repository add-worktree {task['id']} --repo <path>", instructions)
        self.assertIn(f"task pr link {task['id']} --worktree <path> --url <pr-url>", instructions)
        self.assertIn("Never switch the branch checked out in a task worktree", instructions)

        # A new task can list one repository twice: each gets its own worktree on its own branch.
        # Each further automatic entry waits as "auto 2", "auto 3"..., so each can be edited or removed on its own.
        repeated = self.create_repo_task("Repeated repository", [str(self.primary)] * 3)
        self.assertEqual([(record["repositoryPath"], record["isPending"], record["branch"]) for record in repeated["repositoryWorktrees"]],
                         [(first["repositoryPath"], True, "auto"), (first["repositoryPath"], True, "auto 2"), (first["repositoryPath"], True, "auto 3")])
        unchosen, _ = self.call_cli("task", "repository", "remove", repeated["id"], "--repo", str(self.primary), expected_status=2)
        self.assert_failure(unchosen, "invalid_argument")
        self.assertIn("--worktree-branch", unchosen["error"]["message"])
        edited = self.assert_success(self.call_cli(
            "task", "repository", "edit", repeated["id"], "--worktree", str(self.primary), "--worktree-branch", "auto 2",
            "--branch", "repeated-second", "--branch-from", "main"
        )[0])
        self.assertEqual([record["branch"] for record in edited["repositoryWorktrees"]], ["auto", "repeated-second", "auto 3"])
        trimmed = self.assert_success(self.call_cli(
            "task", "repository", "remove", repeated["id"], "--worktree", str(self.primary), "--worktree-branch", "auto 3"
        )[0])
        self.assertEqual([(record["branch"], record["isPending"]) for record in trimmed["repositoryWorktrees"]],
                         [("auto", True), ("repeated-second", True)])
        self.assertEqual([record["branch"] for record in self.assert_success(self.call_cli("task", "get", repeated["id"])[0])["repositoryWorktrees"]],
                         ["auto", "repeated-second"], "The edit and removal persist.")
        started = self.create_repo_task("Repeated started", [str(self.primary), str(self.primary)], materialize=True)["repositoryWorktrees"]
        self.assertEqual(len(started), 2)
        self.assertNotEqual(started[0]["branch"], started[1]["branch"], "Each worktree starts on its own branch.")
        self.assertNotEqual(started[0]["worktreePath"], started[1]["worktreePath"])
        for record in started:
            self.assertEqual(self.run_git(Path(record["worktreePath"]), "branch", "--show-current").strip(), record["branch"])
        tasks_before = len(self.assert_success(self.call_cli("board", "list")[0])["tasks"])
        same_branch, _ = self.call_cli("task", "create", "--title", "Same branch twice", "--prompt", "Fixture task description.",
                                       "--repo", str(self.primary), "--repo", str(self.primary), "--branch", f"{self.primary}=twice", expected_status=2)
        self.assert_failure(same_branch, "invalid_argument")
        self.assertIn("needs its own branch", same_branch["error"]["message"])
        self.assertEqual(len(self.assert_success(self.call_cli("board", "list")[0])["tasks"]), tasks_before, "A rejected create adds no task.")

    # case-contract: test_task_pr_status_detects_branch_pull_requests_and_switched_branches | A pull request status read looks up the pull request GitHub has for each started worktree's checked-out branch, so one opened outside Playhouse (for example with gh pr create) is recorded with its number and URL and listed by `task get` and `task pr status` with the worktree it belongs to. Two worktrees of one repository each get their own. When a worktree's branch was switched by hand, the read records the branch actually checked out, keeps the earlier pull request listed with the task's past pull requests, and finds the new branch's pull request; a closed pull request is recorded as closed, and `task pr status` lists it with closed health beside the open one and the earlier one marked past; a later one for that branch replaces it. After one worktree's pull request merges, `task repository renew --worktree <path>` gives just that worktree a fresh branch, lists the merged pull request once with the past ones, and leaves the other worktree and its pull request as they were. A read that finds nothing leaves the task unchanged, and a Done task is never probed: its status read lists only its recorded pull requests.
    def test_task_pr_status_detects_branch_pull_requests_and_switched_branches(self):
        gh_state, detect_log, gh_environment = self.install_detect_gh_fixture("detect-gh-fixture")
        task = self.create_repo_task("Detect pull requests", [str(self.primary)], materialize=True)
        first = task["repositoryWorktrees"][0]
        second = self.assert_success(self.call_cli(
            "task", "repository", "add-worktree", task["id"], "--repo", str(self.primary), "--branch", "detect-second"
        )[0])["repositoryWorktrees"][1]

        nothing = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(nothing, [], "No pull request exists yet.")
        self.assertIn(f"--head {first['branch']} --state all", detect_log.read_text(encoding="utf-8"))
        self.assertIn("--head detect-second --state all", detect_log.read_text(encoding="utf-8"))
        unchanged = self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"]
        self.assertEqual([record.get("pullRequestNumber") for record in unchanged], [None, None])

        # Both PRs were opened with gh pr create, outside Playhouse.
        gh_state.write_text(f"head.{first['branch']}=611\nhead.detect-second=612\n", encoding="utf-8")
        status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(sorted((item["worktreePath"], item["number"], item["branch"]) for item in status),
                         sorted([(first["worktreePath"], 611, first["branch"]), (second["worktreePath"], 612, "detect-second")]))
        self.assertEqual({item["url"] for item in status},
                         {"https://github.com/playhouse-test/fixture/pull/611", "https://github.com/playhouse-test/fixture/pull/612"})
        recorded = self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"]
        self.assertEqual([record["pullRequestNumber"] for record in recorded], [611, 612])
        self.assertEqual(recorded[1]["pullRequestURL"], "https://github.com/playhouse-test/fixture/pull/612")

        # Someone switches the second worktree to another branch by hand and opens a PR there.
        self.run_git(Path(second["worktreePath"]), "checkout", "-q", "-b", "detect-switched")
        gh_state.write_text(f"head.{first['branch']}=611\nhead.detect-second=612\nhead.detect-switched=613\n613.closed=true\n", encoding="utf-8")
        switched_status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(sorted((item["number"], item.get("closed", False), item.get("past") or False) for item in switched_status),
                         [(611, False, False), (612, False, True), (613, True, False)],
                         "The status read lists the open PR, the closed one and the earlier branch's PR, marked past.")
        self.assertEqual(next(item for item in switched_status if item["number"] == 613)["health"], "closed")
        switched_task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        switched = switched_task["repositoryWorktrees"][1]
        self.assertEqual(switched["branch"], "detect-switched", "The checked-out branch replaces the recorded one.")
        self.assertEqual(switched["pullRequestNumber"], 613)
        self.assertTrue(switched["isPullRequestClosed"])
        self.assertFalse(switched["isPullRequestMerged"])
        self.assertEqual([record.get("pullRequestNumber") for record in switched_task["pastRepositoryWorktrees"]], [612], "The earlier branch's PR stays listed.")
        self.assertEqual(switched_task["pastRepositoryWorktrees"][0]["branch"], "detect-second")
        self.assertEqual(switched_task["repositoryWorktrees"][0]["pullRequestNumber"], 611, "The other worktree keeps its PR.")

        # The closed PR is replaced by a fresh one for the same branch.
        gh_state.write_text(f"head.{first['branch']}=611\nhead.detect-switched=614\n", encoding="utf-8")
        self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        reopened_task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        reopened = reopened_task["repositoryWorktrees"][1]
        self.assertEqual(reopened["pullRequestNumber"], 614)
        self.assertFalse(reopened["isPullRequestClosed"])
        self.assertEqual([record.get("pullRequestNumber") for record in reopened_task["pastRepositoryWorktrees"]], [612, 613])

        # The first worktree's PR merges; renewing just that worktree gives it a fresh branch.
        gh_state.write_text(f"611=merged\nhead.{first['branch']}=611\nhead.detect-switched=614\n", encoding="utf-8")
        self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertTrue(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]["isPullRequestMerged"])
        renewed_task = self.assert_success(self.call_cli("task", "repository", "renew", task["id"], "--worktree", first["worktreePath"])[0])
        renewed, sibling = renewed_task["repositoryWorktrees"]
        self.assertNotEqual(renewed["branch"], first["branch"], "The renewed worktree is on a fresh branch.")
        self.assertIsNone(renewed.get("pullRequestNumber"))
        self.assertEqual((sibling["worktreePath"], sibling["branch"], sibling["pullRequestNumber"]),
                         (second["worktreePath"], "detect-switched", 614), "The other worktree and its PR are unchanged.")
        past_numbers = [record.get("pullRequestNumber") for record in renewed_task["pastRepositoryWorktrees"]]
        self.assertEqual(sorted(past_numbers), [611, 612, 613], "The merged PR is listed once with the past ones.")

        gh_state.write_text(f"611=merged\n614=merged\nhead.detect-switched=614\n", encoding="utf-8")
        done = self.assert_success(self.call_cli("task", "move", task["id"], "Done", extra_environment=gh_environment)[0])
        self.assertEqual(done["status"], "Done")
        probes = detect_log.read_text(encoding="utf-8")
        done_status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual(sorted((item["number"], item.get("past") or False) for item in done_status), [(611, True), (612, True), (613, True), (614, False)],
                         "A Done task lists its recorded pull requests without probing.")
        self.assertEqual(detect_log.read_text(encoding="utf-8"), probes, "A Done task is never probed.")
        archived = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        listed = sorted(record["pullRequestNumber"] for record in archived["repositoryWorktrees"] + archived["pastRepositoryWorktrees"] if record.get("pullRequestNumber"))
        self.assertEqual(listed, [611, 612, 613, 614], "Every pull request stays listed on the Done task.")

    # case-contract: test_task_pr_link_registers_pull_request_for_worktree_branch | `task pr link <task-id> --worktree <path> --url <pr-url>` reads the pull request from GitHub and records it on that worktree when its head branch is the worktree's checked-out branch, so `task get` and `task pr status` list it. A pull request for another branch is rejected with an error naming both branches, an invalid URL and a pull request GitHub can't find are rejected, and each failure leaves the task unchanged. With one worktree of the repository `--repo` selects it; a pull request GitHub later closes is recorded as closed on the next read, and the worktree's chip settings in the task header show it as #N · closed, linking to it; linking again replaces the link and keeps the earlier pull request listed with the task's past pull requests. A worktree switched by hand to a branch that can't be a task branch (the repository's default branch) keeps its recorded branch and pull request on a read, and linking that branch's pull request is rejected. Linking is rejected on a Done task.
    def test_task_pr_link_registers_pull_request_for_worktree_branch(self):
        gh_state, detect_log, gh_environment = self.install_detect_gh_fixture("link-gh-fixture")
        task = self.create_repo_task("Link pull requests", [str(self.primary)], materialize=True)
        record = task["repositoryWorktrees"][0]
        # Only the other branch's PR exists yet, so nothing is there to detect.
        gh_state.write_text("head.someone-else=622\n", encoding="utf-8")
        link = ("task", "pr", "link", task["id"], "--worktree", record["worktreePath"], "--url")

        invalid, _ = self.call_cli(*link, "not a url", expected_status=2, extra_environment=gh_environment)
        self.assert_failure(invalid, "invalid_argument")
        mismatch, _ = self.call_cli(*link, "https://github.com/playhouse-test/fixture/pull/622", expected_status=2, extra_environment=gh_environment)
        self.assert_failure(mismatch, "invalid_argument")
        self.assertIn("is for branch 'someone-else'", mismatch["error"]["message"])
        self.assertIn(f"is on branch '{record['branch']}'", mismatch["error"]["message"])
        missing, _ = self.call_cli(*link, "https://github.com/playhouse-test/fixture/pull/699", expected_status=1, extra_environment=gh_environment)
        self.assertFalse(missing["ok"])
        self.assertIsNone(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0].get("pullRequestNumber"), "Failed links change nothing.")

        gh_state.write_text(f"head.{record['branch']}=621\nhead.someone-else=622\nhead.{record['branch']}-later=623\n", encoding="utf-8")
        linked = self.assert_success(self.call_cli(*link, "https://github.com/playhouse-test/fixture/pull/621", extra_environment=gh_environment)[0])
        self.assertEqual(linked["repositoryWorktrees"][0]["pullRequestNumber"], 621)
        self.assertEqual(linked["repositoryWorktrees"][0]["pullRequestURL"], "https://github.com/playhouse-test/fixture/pull/621")
        status = self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        self.assertEqual([(item["number"], item["worktreePath"]) for item in status], [(621, record["worktreePath"])])

        # GitHub closes the linked PR: the next read records it as closed.
        gh_state.write_text(f"head.{record['branch']}=621\n621.closed=true\nhead.someone-else=622\nhead.{record['branch']}-later=623\n", encoding="utf-8")
        self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        closed = self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]
        self.assertEqual(closed["pullRequestNumber"], 621)
        self.assertTrue(closed["isPullRequestClosed"], "A PR closed on GitHub is recorded as closed.")
        self.assertFalse(closed["isPullRequestMerged"])
        self.assertEqual(closed["pullRequestURL"], "https://github.com/playhouse-test/fixture/pull/621", "The worktree's settings link the closed PR.")

        # With a single worktree of the repository, --repo selects it.
        self.run_git(Path(record["worktreePath"]), "checkout", "-q", "-b", f"{record['branch']}-later")
        relinked = self.assert_success(self.call_cli(
            "task", "pr", "link", task["id"], "--repo", str(self.primary), "--url", "https://github.com/playhouse-test/fixture/pull/623",
            extra_environment=gh_environment
        )[0])
        self.assertEqual(relinked["repositoryWorktrees"][0]["pullRequestNumber"], 623)
        self.assertEqual(relinked["repositoryWorktrees"][0]["branch"], f"{record['branch']}-later", "Linking records the branch the PR is for.")
        self.assertEqual([past.get("pullRequestNumber") for past in relinked["pastRepositoryWorktrees"]], [621])

        # A worktree switched to a branch that can't be a task branch (the default branch) keeps its record.
        default_branch = self.run_git(self.primary, "branch", "--show-current").strip()
        self.run_git(Path(record["worktreePath"]), "checkout", "-q", "--ignore-other-worktrees", default_branch)
        gh_state.write_text(f"head.{record['branch']}-later=623\nhead.{default_branch}=624\n", encoding="utf-8")
        self.assert_success(self.call_cli("task", "pr", "status", task["id"], extra_environment=gh_environment)[0])
        guarded = self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]
        self.assertEqual((guarded["branch"], guarded["pullRequestNumber"]), (f"{record['branch']}-later", 623),
                         "A read doesn't adopt the default branch or its PR.")
        refused, _ = self.call_cli(*link, "https://github.com/playhouse-test/fixture/pull/624", expected_status=2, extra_environment=gh_environment)
        self.assert_failure(refused, "invalid_argument")
        self.assertIn(f"is on branch '{default_branch}', which can't be a task branch", refused["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]["pullRequestNumber"], 623)
        self.run_git(Path(record["worktreePath"]), "checkout", "-q", f"{record['branch']}-later")

        gh_state.write_text("623=merged\n", encoding="utf-8")
        self.assertEqual(self.assert_success(self.call_cli("task", "move", task["id"], "Done", extra_environment=gh_environment)[0])["status"], "Done")
        done, _ = self.call_cli(*link, "https://github.com/playhouse-test/fixture/pull/621", expected_status=1, extra_environment=gh_environment)
        self.assert_failure(done, "invalid_transition")

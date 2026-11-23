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
        # The rules name the commands; their usage is in the task agent's help, with this task's ID given.
        self.assertIn("create one with task repository add-worktree and work in its returned worktreePath", instructions)
        self.assertIn("register it right away with task pr link from that worktree's branch", instructions)
        self.assertIn(f"This task's ID is {task['id']}.", instructions)
        self.assertIn(f"'{self.cli}' help --for task", instructions)
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
    # case-contract: test_standalone_chat_reply_shows_turn_token_usage | A standalone chat shows what each turn cost under the turn's last reply. Providers report usage once per turn, so a history read marks only the last assistant reply of each turn with that turn's recorded usage (input, output, cache read and cache write exactly as the turn's Token Stats row), leaving the user's message and earlier commentary unmarked, and an empty chat has nothing marked. A second turn that replies twice (Claude Code's no-visible-output notice between its answer and a later reply) marks only its last reply, with its own row, while the first reply keeps the first turn's. A history page that ends inside a turn marks none of that turn's messages, because its last reply is on a later page, while an earlier turn whose reply is in the page stays marked, including a reply that ends the page when the next page starts another turn. In the chat, the marked reply shows a small token counter (1.6K tokens) directly beneath it, whose tooltip names the turn's total and its four buckets, while prompts and a turn's earlier replies show none, and clicking it opens the window's usual Token Stats modal for that turn alone, which Done closes. A turn's Token Stats read only the session the turn ran in, its page's own session rather than the page the chat is on now, and only the requests sent from the turn's first message until the next turn's: after a third turn (Saturn again) on a new page, the chat's own map reads the new page's session (3 requests) and its own summary still covers every turn (4,800 tokens), while with --turn the first turn's map reads its 2 requests and each Saturn turn's its 3, each holding the prompt that turn sent and listing, by what it says, the injected reminder that turn was sent and no other turn's, every listed item's preview is the start of the text Show reads for it, the second turn's summary lists only its row (1,600 tokens) with its 3 model calls, Raw Input numbers its requests from 1 to 3 and exports its first request with its prompt, a request past its last is not_found, and an unknown turn is not_found. In the window, after that third turn the second turn's counter opens Token Stats with its total (1,600), only its own turn row and 3 model calls, and the first turn's counter opens Token Stats with its 2 model calls, whose Raw Input single-request scope shows Request 2 of 2 and where Show reads that turn's injected reminder and not the other turn's, and its prompt row the Jupiter prompt and not the Saturn one (on the CLI, the first turn's summary has 2 model calls and its latest request's third and fourth items are that reminder and that Jupiter prompt). Usage is attributed to Playhouse's local turn on the shared recording path for both Claude and Codex, so one representative provider (Claude) covers the case.
    def test_standalone_chat_reply_shows_turn_token_usage(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        environment = self.install_claude_fixture("claude-fixture-chat-token-usage")
        # Where the fixture writes each page's session file, which a turn's Token Stats read.
        environment["CLAUDE_CONFIG_DIR"] = str(self.data_directory / "claude-config")
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        # Matches TURN_USAGE in scripts/fixtures/claude-code-fixture.py.
        turn_usage = {"inputTokens": 1000, "outputTokens": 200, "cacheReadTokens": 300, "cacheCreationTokens": 100}

        def history(*options):
            return self.assert_success(self.call_cli("conversation", "history", chat_id, *options, extra_environment=environment)[0])

        def marked(messages):
            return [message for message in messages if message.get("turnTokenUsage")]

        self.assertEqual(marked(history()["messages"]), [], "An empty chat has no reply to mark.")
        # The fixture's close-turn-first chat turn answers once; its Saturn turn answers, gets Claude
        # Code's no-visible-output notice, and replies again, so that turn has two replies.
        prompts = ["Name the largest moon of Jupiter.", "Name the largest moon of Saturn."]
        for prompt in prompts:
            self.assert_success(self.call_cli("conversation", "send", chat_id, "--message", prompt, extra_environment=environment)[0])

        messages = history()["messages"]
        rows = {turn["id"]: turn["usage"] for turn in self.assert_success(self.call_cli("task", "token-usage", chat_id)[0])["turns"]}
        turn_ids = [next(message["turnID"] for message in messages if message["role"] == "user" and message["text"] == prompt) for prompt in prompts]
        self.assertEqual(len(set(turn_ids)), 2, "Each prompt starts its own turn.")
        for turn_id in turn_ids:
            self.assertEqual(rows.get(turn_id), turn_usage, "Token Stats records each chat turn under the turn the messages carry.")
            turn = [message for message in messages if message.get("turnID") == turn_id]
            replies = [message for message in turn if message["role"] == "assistant" and message.get("phase") != "subagent_report"]
            self.assertTrue(replies, "The fixture turn should reply.")
            self.assertEqual([message["id"] for message in marked(turn)], [replies[-1]["id"]],
                             "Only the turn's last reply carries the turn's tokens.")
            self.assertEqual(replies[-1]["turnTokenUsage"], rows[turn_id], "The reply shows exactly its turn's Token Stats row.")
        self.assertEqual(len(marked(messages)), 2, "No other message is marked.")
        second_replies = [message for message in messages if message.get("turnID") == turn_ids[1] and message["role"] == "assistant"]
        self.assertEqual([message["text"] for message in second_replies], ["Titan is the largest moon of Saturn.", "I already answered above."])
        self.assertIsNone(second_replies[0].get("turnTokenUsage"), "A turn's earlier reply is not marked; its last reply is.")

        # A page that ends on the second turn's prompt holds none of that turn's replies, so its
        # prompt stays unmarked, while the first turn's reply in the page keeps its tokens.
        second_prompt_id = next(message["id"] for message in messages if message.get("turnID") == turn_ids[1] and message["role"] == "user")
        after_prompt = messages[messages.index(next(m for m in messages if m["id"] == second_prompt_id)) + 1]["id"]
        # A page that ends exactly on the first turn's last reply keeps it marked: the message
        # after the page starts another turn.
        seam = history("--before", second_prompt_id, "--limit", "2")
        self.assertGreater(seam["laterMessageCount"], 0)
        self.assertEqual(seam["messages"][-1]["turnID"], turn_ids[0])
        self.assertEqual([message.get("turnID") for message in marked(seam["messages"])], [turn_ids[0]],
                         "A reply that ends a page stays marked when the next page starts a new turn.")
        page = history("--before", after_prompt, "--limit", "3")
        self.assertGreater(page["laterMessageCount"], 0)
        self.assertEqual(page["messages"][-1]["id"], second_prompt_id)
        self.assertEqual([message.get("turnID") for message in marked(page["messages"])], [turn_ids[0]],
                         "A turn that runs past the page marks nothing; the earlier turn's reply stays marked.")

        # A turn's Token Stats read only that turn. The fixture logs each chat turn's requests in
        # its page's session: the Jupiter turn sends 2, the Saturn turn 3. A third turn (Saturn
        # again) on a new page runs in a session of its own, which becomes the chat's current one.
        self.assert_success(self.call_cli("chat", "page", "new", "--title", "Another topic", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", chat_id, "--message", prompts[1], extra_environment=environment)[0])
        later = history()["messages"]
        third_turn = [message["turnID"] for message in later if message["role"] == "user" and message["text"] == prompts[1]][-1]
        self.assertNotIn(third_turn, turn_ids)
        page_list = self.assert_success(self.call_cli("chat", "page", "list", extra_environment=environment)[0])
        sessions = {page["providerSessionID"] for page in page_list["pages"] if page.get("providerSessionID")}
        self.assertEqual(len(sessions), 2, f"The new page's turn runs in its own session: {page_list}")

        def waste(*options):
            return self.assert_success(self.call_cli("task", "token-waste", chat_id, *options, extra_environment=environment)[0])

        def flattened(text):
            return " ".join(part for part in re.split(r"[\n\r\v\f\x85\u2028\u2029]", text[:400]) if part)

        self.assertEqual([agent["requests"] for agent in waste()["agents"]], [3],
                         "Unscoped, the chat's map reads the session of the page it is on now.")
        for turn_id, requests in [(turn_ids[0], 2), (turn_ids[1], 3), (third_turn, 3)]:
            report = waste("--turn", turn_id)
            self.assertEqual([agent["requests"] for agent in report["agents"]], [requests],
                             f"Turn {turn_id} reads only its page's session and only its own requests.")
            self.assertTrue(report["wasters"], "The turn's items are listed.")
            for item in report["wasters"]:
                shown = self.assert_success(self.call_cli(
                    "task", "raw-input-text", chat_id, "--turn", turn_id, "--agent", item["agent"], "--item", str(item["item"]),
                    "--length", "100000", extra_environment=environment,
                )[0])
                preview, text = item["preview"], flattened(shown["text"])
                if preview.endswith("…"):
                    self.assertTrue(text.startswith(preview[:-1]), f"The preview is the start of the text Show reads: {preview!r}")
                else:
                    self.assertEqual(text, preview, "The preview is the text Show reads.")
            reminders = [item for item in report["wasters"] if item["kind"] == "systemReminder"]
            expected_reminder = "Chat fixture reminder sent with the " + ("close_first" if turn_id == turn_ids[0] else "notice") + " turn."
            self.assertEqual([item["label"] for item in reminders], [expected_reminder],
                             "The turn lists the injected text it sent, by what it says, and no other turn's.")
            self.assertIn(expected_reminder, reminders[0]["preview"], "The injected item's preview is its sent text.")
            prompts_sent = [item for item in report["wasters"] if item["kind"] == "userText"]
            expected_prompt = prompts[0] if turn_id == turn_ids[0] else prompts[1]
            self.assertEqual(len(prompts_sent), 1, "Each turn sent one prompt.")
            prompt_text = self.assert_success(self.call_cli(
                "task", "raw-input-text", chat_id, "--turn", turn_id, "--agent", prompts_sent[0]["agent"],
                "--item", str(prompts_sent[0]["item"]), "--length", "100000", extra_environment=environment,
            )[0])["text"]
            self.assertTrue(prompt_text.rstrip().endswith(expected_prompt), "The turn's map holds the prompt the turn sent.")

        second = self.assert_success(self.call_cli("task", "token-usage", chat_id, "--turn", turn_ids[1], extra_environment=environment)[0])
        self.assertEqual([turn["id"] for turn in second["turns"]], [turn_ids[1]], "A turn's summary lists only that turn.")
        self.assertEqual(second["totalTokens"], 1600)
        self.assertEqual(second["callUsage"]["totalCalls"], 3, "The turn's model calls are its own requests.")
        first = self.assert_success(self.call_cli("task", "token-usage", chat_id, "--turn", turn_ids[0], extra_environment=environment)[0])
        self.assertEqual(first["callUsage"]["totalCalls"], 2, "The first turn shares its page's session but counts only its own requests.")
        # Raw Input and Show for the first turn read that turn: its latest request is its second, and
        # after the system prompt and the Bash tool it sent the turn's reminder, then the Jupiter prompt.
        latest = self.assert_success(self.call_cli(
            "task", "raw-input", chat_id, "--turn", turn_ids[0], "--scope", "request", extra_environment=environment,
        )[0])
        self.assertEqual((latest["request"]["number"], latest["request"]["count"]), (2, 2))
        reminder_row = next(row for row in latest["rows"] if row["position"] == 2)
        self.assertEqual((reminder_row["kind"], reminder_row["label"]), ("systemReminder", "Chat fixture reminder sent with the close_first turn."))
        prompt_row = next(row for row in latest["rows"] if row["position"] == 3)
        self.assertEqual(prompt_row["kind"], "userText")
        shown = self.assert_success(self.call_cli(
            "task", "raw-input-text", chat_id, "--turn", turn_ids[0], "--agent", latest["agent"], "--item", str(prompt_row["id"]),
            "--length", "100000", extra_environment=environment,
        )[0])["text"]
        self.assertIn(prompts[0], shown)
        self.assertNotIn(prompts[1], shown, "Show reads no other turn's prompt.")
        whole = self.assert_success(self.call_cli("task", "token-usage", chat_id)[0])
        self.assertEqual(whole["totalTokens"], 4800, "The chat's own summary still covers every turn.")

        request = self.assert_success(self.call_cli(
            "task", "raw-input", chat_id, "--turn", turn_ids[1], "--scope", "request", "--request", "3", extra_environment=environment,
        )[0])["request"]
        self.assertEqual((request["number"], request["count"]), (3, 3), "Raw Input numbers the turn's requests from 1.")
        exported = self.assert_success(self.call_cli(
            "task", "raw-input-export", chat_id, "--turn", turn_ids[1], "--request", "1", extra_environment=environment,
        )[0])
        self.assertIn(prompts[1], exported["text"], "Exporting the turn's first request shows the prompt it sent.")
        past, _ = self.call_cli("task", "raw-input", chat_id, "--turn", turn_ids[1], "--scope", "request", "--request", "4",
                                expected_status=3, extra_environment=environment)
        self.assert_failure(past, "not_found")
        self.assertIn("made 3 requests", past["error"]["message"])
        unknown, _ = self.call_cli("task", "token-waste", chat_id, "--turn", "no-such-turn", expected_status=3, extra_environment=environment)
        self.assert_failure(unknown, "not_found")
        self.assertIn("That turn is not in this conversation.", unknown["error"]["message"])
    # case-contract: test_transcript_rows_stay_with_older_messages | A provider divider and a goal achievement stay right after the message they were recorded after. A long Claude history whose switch from Codex sits on its older page, with a switch to Claude and back that sent nothing stored on the same message, has one Codex-to-Claude divider after the last Codex message in complete and paged CLI/XPC history, the empty switch pair dropped, and the newest page leaves that message out; another turn leaves the divider where it was. Opened on its newest page, the visible transcript draws neither that divider nor a goal achievement recorded after the last Codex message, at the bottom or anywhere after a newer message, and they stay hidden after a new message is sent from the composer; a goal achievement recorded after the latest turn's folded commentary follows that turn's question, above its answer, not the newest message. Scrolling up loads the older page and shows the one divider, then that goal achievement, right after the last Codex message and before the next question, with no Switched to Codex divider. The placement is Playhouse-owned and the same for both providers, so one switch from Codex to Claude covers the case.
    def test_transcript_rows_stay_with_older_messages(self):
        claude = self.install_provider_fixture("claude", "claude-fixture-row-anchors")
        fixtures = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude)}
        task_id = self.create_task("Rows with older messages", roots=[self.primary])["id"]
        self.complete_fixture_turn(task_id, executable_name="codex-fixture-row-anchors", message="Start with Codex.")
        self.assert_success(self.call_cli("conversation", "provider", task_id, "set", "claude", extra_environment=fixtures)[0])
        self.seed_long_history(task_id, switch_after_turn=10, latest_commentary=True)
        anchor = "item_long_history_assistant_10"

        def boundaries(history):
            return [(boundary["provider"], boundary["afterMessageID"]) for boundary in history["providerBoundaries"]]

        full = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        ids = [message["id"] for message in full["messages"]]
        self.assertEqual(boundaries(full), [("claude", anchor)], "The undone switch pair leaves no dividers of its own.")
        self.assertEqual(full["messages"][ids.index(anchor)]["provider"], "codex")
        self.assertEqual(full["messages"][ids.index(anchor) + 1]["text"], "Long history user 11.")
        self.assertEqual(full["messages"][ids.index(anchor) + 1]["provider"], "claude")
        commentary = full["messages"][ids.index("item_long_history_commentary_60")]
        self.assertEqual((commentary["role"], commentary["phase"]), ("assistant", "commentary"))

        newest = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80")[0])
        self.assertEqual(newest["earlierMessageCount"], len(ids) - 80)
        self.assertNotIn(anchor, [message["id"] for message in newest["messages"]], "The divider's message sits on the older page.")
        self.assertEqual(boundaries(newest), [("claude", anchor)], "The newest page names the divider's message, not its own last one.")

        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Tell me a very short dog story.", extra_environment=fixtures)[0])
        after = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        self.assertTrue(ordinary_messages(after["messages"])[-1]["text"].startswith("BISCUIT-7"), after["messages"][-1])
        self.assertEqual(boundaries(after), [("claude", anchor)], "A new turn leaves the divider after the message it follows.")
        newest_after = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80")[0])
        self.assertNotIn(anchor, [message["id"] for message in newest_after["messages"]])
        self.assertEqual(boundaries(newest_after), [("claude", anchor)])
        older = self.assert_success(self.call_cli(
            "conversation", "history", task_id, "--limit", "80", "--before", newest_after["messages"][0]["id"]
        )[0])
        older_ids = [message["id"] for message in older["messages"]]
        self.assertIn(anchor, older_ids, "Loading the older page brings the divider's message.")
        self.assertEqual(older["messages"][older_ids.index(anchor) + 1]["text"], "Long history user 11.")
        self.assertEqual(boundaries(older), [("claude", anchor)])

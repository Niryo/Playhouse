from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases16:
    # case-contract: test_task_workspace_changes_over_limit_show_notice | A task whose worktree holds more than 1000 changed files still reports every one of them through fresh CLI connections, while the open task's Changes sidebar shows a 'Too many changes to list' notice naming the count instead of rendering the file list, so the window stays responsive. Bringing the count back under the limit lists the files again.
    def test_task_workspace_changes_over_limit_show_notice(self):
        repository = self.data_directory / "many-changes"
        repository.mkdir()
        (repository / "tracked.txt").write_text("Baseline.\n", encoding="utf-8")
        self.run_git(repository, "init", "--initial-branch=main")
        self.run_git(repository, "config", "user.name", "Playhouse Bridge Test")
        self.run_git(repository, "config", "user.email", "playhouse-bridge-test@example.invalid")
        self.run_git(repository, "add", "tracked.txt")
        self.run_git(repository, "commit", "-m", "Baseline")
        task_id = self.create_task(title="Many changes", roots=[])["id"]
        added, _ = self.call_cli("task", "repository", "add", task_id, "--repo", str(repository))
        record = next(item for item in self.assert_success(added)["repositoryWorktrees"] if item["repositoryPath"] == str(repository))
        generated = Path(record["worktreePath"]) / "generated"
        generated.mkdir()
        for index in range(1001):
            (generated / f"file-{index:04d}.txt").write_text(f"Generated {index}.\n", encoding="utf-8")

        response, _ = self.call_cli("task", "changes", "list", task_id)
        inventory = self.assert_success(response)
        self.assertEqual(len(inventory["unviewed"]), 1001, "The limit only affects the sidebar; the CLI still reports every file.")
        self.assertEqual(inventory["viewed"], [])

        (generated / "file-1000.txt").unlink()
        response, _ = self.call_cli("task", "changes", "list", task_id)
        self.assertEqual(len(self.assert_success(response)["unviewed"]), 1000)
    # case-contract: test_claude_nudged_turn_work_stays_in_conversation | A Claude turn answers while a background review runs, the review's notification arrives right after that answer, and the woken turn adds nothing and reports no outcome; the review's report and the answer both stay in history. Playhouse's private status nudge then starts a turn that keeps working, and a message the user steers into it is kept too: its commentary, its shell call, the background suite it launches, that suite's report delivered in a notification-driven woken turn, the screenshot it presents, and its final answer are streamed and recorded in order, and the completed outcome it reports moves the task to Review. Fresh history, a paged history read, and a later ordinary turn all keep that work, with the final report as the latest message before the later turn, while the nudge prompt Playhouse sent is shown once as its own message and no placeholder replaces it.
    def test_claude_nudged_turn_work_stays_in_conversation(self):
        env = self.install_claude_fixture("claude-fixture-nudged-work")
        executable = Path(env["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"])
        created, _ = self.call_cli(
            "task", "create", "--title", "Claude nudged work", "--prompt", "Fixture task description.",
            "--root", self.primary, "--provider", "claude",
        )
        task_id = self.assert_success(created)["id"]
        steer_pause = Path(f"{executable}.nudged-steer-pause")
        steer_ready = Path(f"{executable}.nudged-steer-ready")
        steer_pause.write_text("Hold the nudged turn for a steer.\n", encoding="utf-8")
        send_command = ("conversation", "send", task_id, "--message", "Wait for the pending UI review.")
        process = self.start_cli(*send_command, extra_environment=env)
        try:
            deadline = time.monotonic() + 60
            while not steer_ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(steer_ready.exists(), "The private nudge turn should start and wait for a steer.")
            steered = self.assert_success(self.call_cli(
                "conversation", "steer", task_id, "--message", "Also double check the docs.", extra_environment=env,
            )[0])
            self.assertTrue(steered["accepted"], "A user can steer the running nudge turn.")
            response, events = self.finish_cli(process, send_command, timeout=60)
        finally:
            if process.poll() is None:
                process.communicate(timeout=30)
        self.assert_success(response)
        self.assertIn("Also double check the docs.", [e["payload"].get("message") for e in events if e["type"] == "steered_message"],
                      "The steered message should stream even though it joined a private nudge turn.")
        stale_answer = "The task review is approved. Only the UI review is still pending."
        final_report = "All checks passed and the screenshot is attached. The work is complete."
        finals = [event["payload"]["text"] for event in events if event["type"] == "assistant_final"]
        self.assertEqual(finals, [stale_answer, final_report],
                         "Both the unreported turn's answer and the nudged turn's final report should stream.")
        streamed_activities = [event["payload"]["activity"]["id"] for event in events if event["type"] == "activity"]
        self.assertIn("toolu_nudged_check", streamed_activities, "The nudged turn's work should stream live.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Review",
                         "The completed outcome reported inside the nudged turn moves the task to Review.")
        turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
        nudges = [turn for turn in turns if "playhouse internal outcome nudge:" in turn.get("userText", "").lower()]
        self.assertEqual(len(nudges), 1, "The turn that reported no outcome gets one private status nudge, which settles it.")
        self.assertTrue(any(" conversation present-image " in command["command"] and '"ok":true' in command["output"]
                            for command in nudges[0]["reportCommands"]),
                        f"The nudged turn should present its screenshot: {nudges[0]['reportCommands']}")

        race_report = ("subagent_report", "UI review approved.")
        expected_tail = [
            ("final_answer", stale_answer),
            ("commentary", "Every review is approved. Running the final check."),
            ("commentary", "STEERED NUDGE: Also double check the docs."),
            ("commentary", "Starting the final suite in the background."),
            ("subagent_report", "Final suite passed: all cases green."),
            ("agent_image", "Nudged turn screenshot"),
            ("final_answer", final_report),
        ]

        def assert_nudged_work(messages, label):
            assistant = [(m.get("phase"), m["text"]) for m in messages if m["role"] == "assistant"]
            self.assertIn(race_report, assistant, f"{label}: the report that arrived right after the answer should be kept.")
            tail = [entry for entry in assistant if entry != race_report][-len(expected_tail):]
            self.assertEqual(tail, expected_tail, f"{label}: the nudged turn's work should be in order.")
            serialized = json.dumps(messages)
            self.assertEqual(sum(1 for m in messages if m["role"] == "user" and "Playhouse internal outcome nudge:" in m["text"]), 1,
                             f"{label}: the nudge Playhouse sent is shown once, as its own message.")
            for hidden in ("private outcome reminder hidden", "private outcome response hidden"):
                self.assertNotIn(hidden, serialized, f"{label}: no placeholder replaces the nudge.")
            self.assertIn("Also double check the docs.", [m["text"] for m in messages if m["role"] == "user"],
                          f"{label}: the steered message that joined the nudge turn should stay in the conversation.")
            image = next(m for m in messages if m.get("phase") == "agent_image")
            final = next(m for m in reversed(messages) if m["text"] == final_report)
            self.assertEqual(image["turnID"], final["turnID"], f"{label}: the screenshot belongs to the nudged turn.")

        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        assert_nudged_work(history["messages"], "fresh history")
        self.assertEqual(history["messages"][-1]["text"], final_report, "The nudged turn's final report is the latest message.")
        timeline = [activity for activity in history.get("timelineActivities", []) if activity["id"] == "toolu_nudged_check"]
        self.assertEqual(len(timeline), 1, "The nudged turn's shell call should be a timeline tool row.")
        self.assertEqual(timeline[0]["input"], "echo NUDGED CHECK PASSED")
        self.assertIn("NUDGED CHECK PASSED", timeline[0].get("output") or "")
        suite = next(activity for activity in history["activities"] if activity["id"] == "toolu_nudged_suite")
        self.assertEqual(suite["status"], "completed")
        self.assertEqual(suite["backgroundTaskSummary"], "Final suite passed: all cases green.")

        page = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "3", extra_environment=env)[0])
        self.assertEqual([(m.get("phase"), m["text"]) for m in page["messages"]], expected_tail[-3:],
                         "A paged read should end on the nudged turn's work.")
        image_page = next(m for m in page["messages"] if m.get("phase") == "agent_image")
        self.assertTrue(image_page["imageDataURLs"] and image_page["imageDataURLs"][0].startswith("data:image/png;base64,"))

        response, _ = self.call_cli("conversation", "send", task_id, "--message", "Thanks, that's all.", extra_environment=env)
        self.assert_success(response)
        later = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        later_start = next(index for index, m in enumerate(later["messages"]) if m["role"] == "user" and m["text"] == "Thanks, that's all.")
        later_turn = later["messages"][later_start:]
        self.assertEqual(later_turn[1]["text"], "OK.", "The later turn follows the nudged work.")
        self.assertTrue(all(m["text"] == "OK." for m in later_turn[1:] if m["role"] == "assistant"))
        self.assertTrue(any("Playhouse internal outcome nudge:" in m["text"] for m in later_turn[1:] if m["role"] == "user"),
                        "The later turn reported no outcome, so it got its own shown nudge.")
        assert_nudged_work(later["messages"][:later_start], "after a later turn")
    # case-contract: test_codex_nudged_turn_work_stays_in_conversation | A Codex turn that reports no outcome receives Playhouse's private status nudge, and the nudged turn keeps working, with a message the user steers into it kept too: its commentary, its shell command, and its final answer are streamed and appear in fresh history after the earlier answer, with the shell command as a timeline tool row, and the completed outcome it reports moves the task to Review. Fresh history shows the nudge prompt Playhouse sent exactly once as its own message, with no placeholder replacing it; after a later ordinary turn the earlier nudge stays shown, the later turn's own nudge appears after its message, and no placeholder replaces either. The steered message is recorded inside the nudge turn it joined rather than as a turn of its own, and the transcript shows the turn's work above it and the final answer below it. The work the turn streams after the steer follows it, and while the turn still runs it renders below the steered message.
    def test_codex_nudged_turn_work_stays_in_conversation(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-nudged-work-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        task_id = self.create_task("Codex nudged work", roots=[self.primary])["id"]
        steer_pause = Path(f"{executable}.nudged-steer-pause")
        steer_ready = Path(f"{executable}.nudged-steer-ready")
        steer_pause.write_text("Hold the nudged turn for a steer.\n", encoding="utf-8")
        Path(f"{executable}.nudged-final-pause").write_text("Hold the nudged turn's final answer.\n", encoding="utf-8")
        send_command = ("conversation", "send", task_id, "--message", "Start the work.")
        process = self.start_cli(*send_command, extra_environment=env)
        try:
            deadline = time.monotonic() + 60
            while not steer_ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(steer_ready.exists(), "The private nudge turn should start and wait for a steer.")
            steered = self.assert_success(self.call_cli(
                "conversation", "steer", task_id, "--message", "Also double check the docs.", extra_environment=env,
            )[0])
            self.assertTrue(steered["accepted"], "A user can steer the running nudge turn.")
            final_ready = Path(f"{executable}.nudged-final-ready")
            deadline = time.monotonic() + 60
            while not final_ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(final_ready.exists(), "The steered nudge turn keeps working before its final answer.")
            Path(f"{executable}.nudged-final-release").write_text("Finish the nudged turn.\n", encoding="utf-8")
            response, events = self.finish_cli(process, send_command, timeout=60)
        finally:
            if process.poll() is None:
                process.communicate(timeout=30)
        self.assert_success(response)
        self.assertIn("Also double check the docs.", [e["payload"].get("message") for e in events if e["type"] == "steered_message"],
                      "The steered message should stream even though it joined a private nudge turn.")
        commentary = "Codex is finishing the remaining check after the nudge."
        final_report = "Codex finished the remaining check after the nudge. Everything is done."
        finals = [event["payload"]["text"] for event in events if event["type"] == "assistant_final"]
        self.assertEqual(finals[-1:], [final_report], "The nudged turn's final answer should stream.")
        streamed = [(event["type"], event["payload"].get("message") or event["payload"].get("text")) for event in events]
        steer_at = streamed.index(("steered_message", "Also double check the docs."))
        self.assertLess(steer_at, streamed.index(("assistant_progress", commentary)),
                        "The work the turn streams after the steer follows the steered message.")
        self.assertLess(steer_at, len(streamed) - 1 - streamed[::-1].index(("assistant_final", final_report)),
                        "The final answer streamed after the steer follows the steered message.")
        self.assertIn("item_nudged_check_1", [event["payload"]["activity"]["id"] for event in events if event["type"] == "activity"],
                      "The nudged turn's shell command should stream live.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Review",
                         "The completed outcome reported inside the nudged turn moves the task to Review.")
        saved = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        nudges = [turn for turn in saved["turns"] if "playhouse internal outcome nudge:" in (turn.get("userMessage") or "").lower()]
        self.assertEqual(len(nudges), 1, "The completed outcome in the first nudge ends the private loop.")

        def assert_nudged_work(history, label):
            assistant = [(m.get("phase"), m["text"]) for m in history["messages"] if m["role"] == "assistant"]
            self.assertIn("Also double check the docs.", [m["text"] for m in history["messages"] if m["role"] == "user"],
                          f"{label}: the steered message that joined the nudge turn should stay in the conversation.")
            steer = next(m for m in history["messages"] if m["role"] == "user" and m["text"] == "Also double check the docs.")
            nudge = next(m for m in history["messages"] if m["role"] == "user" and "Playhouse internal outcome nudge:" in m["text"])
            self.assertIsNotNone(steer.get("turnID"))
            self.assertEqual(steer.get("turnID"), nudge.get("turnID"),
                             f"{label}: the steered message is recorded inside the nudge turn it joined, not as a turn of its own.")
            self.assertGreater(len(assistant), 2, f"{label}: the earlier answer should stay ahead of the nudged work.")
            self.assertNotIn(assistant[0], [("commentary", commentary), ("final_answer", final_report)])
            self.assertEqual(assistant[1:3], [("commentary", commentary), ("final_answer", final_report)],
                             f"{label}: the nudged work should follow the earlier answer in order.")
            serialized = json.dumps(history["messages"])
            nudges_shown = sum(1 for m in history["messages"] if m["role"] == "user" and "Playhouse internal outcome nudge:" in m["text"])
            self.assertTrue(nudges_shown == 1 if label == "fresh history" else nudges_shown >= 1,
                            f"{label}: the nudge Playhouse sent is shown as its own message.")
            for hidden in ("private outcome reminder hidden", "private outcome response hidden"):
                self.assertNotIn(hidden, serialized, f"{label}: no placeholder replaces the nudge.")
            timeline = [activity for activity in history.get("timelineActivities", []) if activity["id"] == "item_nudged_check_1"]
            self.assertEqual(len(timeline), 1, f"{label}: the nudged shell command should be a timeline tool row.")
            self.assertEqual(timeline[0]["input"], "echo NUDGED CHECK PASSED")

        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        assert_nudged_work(history, "fresh history")
        self.assertEqual(history["messages"][-1]["text"], final_report, "The nudged turn's final answer is the latest message.")
        response, _ = self.call_cli("conversation", "send", task_id, "--message", "Thanks, that's all.", extra_environment=env)
        self.assert_success(response)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Review",
                         "The later turn's own nudge keeps working and reports completed instead of blocking the task.")
        later = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        assert_nudged_work(later, "later turn")
        later_start = max(i for i, m in enumerate(later["messages"]) if m["role"] == "user" and m["text"] == "Thanks, that's all.")
        self.assertTrue(any("Playhouse internal outcome nudge:" in m["text"] for m in later["messages"][later_start + 1:] if m["role"] == "user"),
                        "The later turn's own nudge is shown after its message.")
    # case-contract: test_agents_info_usage_recovers_when_account_reads_fail | When either provider account metadata read fails, a usage refresh still reads that provider usage and retains its last known account. Codex and Claude usage changes reach the CLI and open Agents info section, and after both account reads recover another refresh updates both usage values and retains the correct accounts.
    def test_agents_info_usage_recovers_when_account_reads_fail(self):
        source = Path(__file__).resolve().parent / "fixtures"
        codex = self.data_directory / "codex-fixture-usage-failure"
        claude = self.data_directory / "claude-fixture-usage-failure"
        for src, target, owner in [("codex-app-server-fixture.py", codex, "codex"), ("claude-code-fixture.py", claude, "claude")]:
            copy_file(source / src, target)
            target.chmod(0o755)
            (self.data_directory / f".playhouse-{owner}-fixture-owner").write_text(
                f"Playhouse test owns this {'Codex protocol' if owner == 'codex' else 'Claude Code protocol'} fixture (v1).\n", encoding="utf-8")
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(codex), "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude)}
        def refresh():
            result = self.assert_success(self.call_cli("usage", "get", "--refresh", extra_environment=env)[0])
            return {p["provider"]: p for p in result["providers"]}
        def percent(state, key):
            return next(w["usedPercent"] for w in state["snapshot"]["windows"] if w["id"] == key)
        initial = refresh()
        self.assertEqual(initial["codex"]["account"], "codex-fixture@example.com")
        self.assertEqual(initial["claude"]["account"], "claude-fixture@example.com")
        errors = [Path(str(codex) + ".account-read-error"), Path(str(claude) + ".auth-status-error")]
        for error in errors: error.touch()
        def values(codex_used, claude_used):
            Path(str(codex) + ".account").write_text(json.dumps({"loggedIn": True, "email": "codex-fixture@example.com", "used": [codex_used, 62]}), encoding="utf-8")
            Path(str(claude) + ".usage").write_text(json.dumps({"rate_limits_available": True, "rate_limits": {"five_hour": {"utilization": claude_used, "resets_at": "2099-01-01T00:00:00Z"}}}), encoding="utf-8")
        values(47, 24)
        failed = refresh()
        self.assertEqual((percent(failed["codex"], "primary"), percent(failed["claude"], "five_hour")), (47, 24))
        self.assertEqual((failed["codex"]["account"], failed["claude"]["account"]), ("codex-fixture@example.com", "claude-fixture@example.com"))
        for error in errors: error.unlink()
        values(54, 31)
        Path(str(codex) + ".account").write_text(json.dumps({"loggedIn": True, "email": "codex-recovered@example.com", "used": [54, 62]}), encoding="utf-8")
        Path(str(claude) + ".auth-state").write_text(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "email": "claude-recovered@example.com", "subscriptionType": "max"}), encoding="utf-8")
        recovered = refresh()
        self.assertEqual((percent(recovered["codex"], "primary"), percent(recovered["claude"], "five_hour")), (54, 31))
        self.assertEqual((recovered["codex"]["account"], recovered["claude"]["account"]), ("codex-recovered@example.com", "claude-recovered@example.com"))
    # case-contract: test_agents_info_shows_provider_usage_and_accounts | The Agents info section reads Claude and Codex plan usage and accounts through the bridge. A refresh reads both providers: Codex's account, plan, both rolling windows (5h and weekly) with percent used and reset times, and its credits balance come from the app-server, while Claude's usage is read with Claude Code's get_usage control request, which has none for this account yet, so Claude starts with a signed-in account and no usage. While a usage watch remains open, it periodically refreshes both providers; Codex and Claude usage changed without a push reaches the watch and appears in the open window, and the Codex snapshot persists. A Claude turn's rate_limit_event then fills Claude's 5h and weekly windows and its warning status from the stream, a usage watch already open receives that change as a pushed update without asking again, a fresh read returns the same values, and the last-known snapshot is persisted to disk. A later event whose window reset time has already passed reads back as reset (empty, no reset time) and lifts the limit status without any provider call. Because Claude Code streams rate_limit_event only when a limit's status changes, and a usage-based plan's event has no utilization, every finished Claude turn reads the plan's usage again through get_usage (skipping the local transcript scan) without a refresh: the read replaces the windows with the plan's current ones, keeps get_usage percents as percents, shows a usage-based plan's monthly extra usage as a Spend limit row with the reset time from the stream's overage event, and is persisted; a refresh reads it too, a reply without plan usage keeps the last known rows, a reached spend limit reads as the limit reached, and a usage request that is never answered times out, keeping the last known rows, so later reads work again. Switching the Codex account signs out, clears the cached usage, starts a new login that returns its sign-in URL, and shows the new account's account and usage after the login completes; switching the Claude account does the same through the CLI and drops the old account's usage. A signed-out provider reports loggedIn false with no account or usage, a login restores it, and an unknown provider is rejected as invalid_argument. In the visible UI the Agents info section sits at the bottom of the left sidebar, below the Scheduled Tasks button and inside it, titled Agents info, with a separate compact Claude block and Codex block, each showing its account and plan together on the row beneath the provider name, its window rows with percentages and reset times, and a switch-account button; Codex's credits show in its block and Claude's warning status shows as Near limit. After a Claude turn whose usage read reports the plan's spend, the open window shows Claude's Spend limit row with its percent and reset time and the updated 5h row without a relaunch. A signed-out provider shows a Log in button instead of usage, which starts the login and brings usage back, and switching the account signs out and in without asking when no task for that provider is running. The section is open by default and its title is a button that minimizes it: the agent blocks go away and the title moves down to rest at the bottom of the sidebar, and expanding brings them back; the choice is remembered, so a section minimized before a relaunch is still minimized afterwards. Every read reports whether each CLI is installed from the same executable lookup Playhouse launches it with; an agent whose CLI is not installed has no block, and with neither installed the section is not shown. While a task for a provider is running, its switch-account button first asks for confirmation naming how many of its tasks are running, and cancelling keeps the account.
    def test_agents_info_shows_provider_usage_and_accounts(self):
        source = Path(__file__).resolve().parent / "fixtures"
        codex = self.data_directory / "codex-fixture-agents-info"
        claude = self.data_directory / "claude-fixture-agents-info"
        copy_file(source / "codex-app-server-fixture.py", codex)
        copy_file(source / "claude-code-fixture.py", claude)
        codex.chmod(0o755)
        claude.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(codex),
            "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude),
        }

        def usage(*extra):
            result = self.assert_success(self.call_cli("usage", "get", *extra, extra_environment=environment)[0])
            return {entry["provider"]: entry for entry in result["providers"]}

        def wait_for(provider, predicate, message, refresh=False):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                state = usage(*(["--refresh"] if refresh else []))[provider]
                if predicate(state):
                    return state
                time.sleep(0.2)
            self.fail(message)

        def windows(state):
            return {window["id"]: window for window in (state.get("snapshot") or {}).get("windows", [])}

        # Without a fixture a provider is not installed: it reports no account or usage,
        # and nothing is launched for it, not even the machine's own CLI.
        bare = {entry["provider"]: entry for entry in self.assert_success(self.call_cli("usage", "get", "--refresh")[0])["providers"]}
        for provider in ("codex", "claude"):
            self.assertIs(bare[provider]["installed"], False)
            self.assertIsNone(bare[provider].get("account"))
            self.assertIsNone(bare[provider].get("snapshot"))

        # Validation: the provider must be one Playhouse knows.
        unknown, _ = self.call_cli("usage", "login", "gemini", extra_environment=environment, expected_status=2)
        self.assert_failure(unknown, "invalid_argument")

        # A refresh reads both providers. Codex reports usage from its app-server;
        # Claude only reports while a task runs, so it has an account and no usage yet.
        providers = usage("--refresh")
        codex_state, claude_state = providers["codex"], providers["claude"]
        self.assertTrue(codex_state["installed"] and codex_state["loggedIn"])
        self.assertEqual((codex_state["account"], codex_state["plan"]), ("codex-fixture@example.com", "Plus"))
        codex_windows = windows(codex_state)
        self.assertEqual([codex_windows[key]["label"] for key in ("primary", "secondary")], ["5h", "Weekly"])
        self.assertEqual([codex_windows[key]["usedPercent"] for key in ("primary", "secondary")], [30, 62])
        self.assertGreater(codex_windows["primary"]["resetsAt"], time.time())
        self.assertEqual(codex_state["snapshot"]["credits"], {"hasCredits": True, "unlimited": False, "balance": "12.50"})
        self.assertTrue(claude_state["installed"] and claude_state["loggedIn"])
        self.assertEqual((claude_state["account"], claude_state["plan"]), ("claude-fixture@example.com", "Max"))
        self.assertIsNone(claude_state.get("snapshot"), "Claude has no usage before a task reports it.")

        # A Claude turn's rate_limit_event fills its windows from the stream.
        task_id = self.create_task("Claude usage", provider="claude")["id"]
        event_path = Path(str(claude) + ".rate-limit-event")

        def claude_turn(info):
            event_path.write_text(json.dumps({"type": "rate_limit_event", "rate_limit_info": info}), encoding="utf-8")
            self.assert_success(self.call_cli(
                "conversation", "send", task_id, "--message", "Say hello.", extra_environment=environment
            )[0])

        # A window follows the usage store's changes as providers push them.
        watcher = self.start_cli("usage", "get", "--watch", extra_environment=environment, binary_output=True)
        self.addCleanup(watcher.kill)
        self.read_watcher_snapshot(watcher, lambda report: True, event_type="usage_state")
        # Usage changed by another client has no push on this connection. The open
        # watch must refresh it and persist it without another explicit read.
        Path(str(codex) + ".account").write_text(json.dumps({
            "loggedIn": True, "email": "codex-fixture@example.com", "used": [47, 68],
        }), encoding="utf-8")
        periodic_claude_usage = Path(str(claude) + ".usage")
        periodic_claude_usage.write_text(json.dumps({"rate_limits_available": True, "rate_limits": {
            "five_hour": {"utilization": 24, "resets_at": "2099-01-01T00:00:00Z"},
        }}), encoding="utf-8")
        refreshed = self.read_watcher_snapshot(
            watcher,
            lambda report: windows(next(entry for entry in report["providers"] if entry["provider"] == "codex")).get("primary", {}).get("usedPercent") == 47,
            timeout=45, event_type="usage_state",
        )
        self.assertEqual(windows(next(entry for entry in refreshed["providers"] if entry["provider"] == "codex"))["secondary"]["usedPercent"], 68)
        self.read_watcher_snapshot(
            watcher,
            lambda report: windows(next(entry for entry in report["providers"] if entry["provider"] == "claude")).get("five_hour", {}).get("usedPercent") == 24,
            timeout=45, event_type="usage_state",
        )
        periodic_claude_usage.unlink()
        saved = json.loads(next(self.data_directory.rglob("agent-usage.json")).read_text(encoding="utf-8"))
        self.assertEqual(saved["codex"]["snapshot"]["windows"][0]["usedPercent"], 47)
        now = int(time.time())
        claude_turn({
            "status": "allowed_warning", "rateLimitType": "five_hour", "utilization": 0.83, "resetsAt": now + 3600,
            "unifiedWindows": {
                "five_hour": {"utilization": 0.83, "resetsAt": now + 3600},
                "seven_day": {"utilization": 0.41, "resetsAt": now + 3 * 86400},
            },
        })
        pushed = self.read_watcher_snapshot(
            watcher,
            lambda report: windows(next(entry for entry in report["providers"] if entry["provider"] == "claude")).get("five_hour", {}).get("usedPercent") == 83,
            event_type="usage_state",
        )
        self.assertEqual(windows(next(entry for entry in pushed["providers"] if entry["provider"] == "claude"))["seven_day"]["usedPercent"], 41)
        watcher.terminate()
        watcher.wait(timeout=10)
        claude_state = usage()["claude"]
        claude_windows = windows(claude_state)
        self.assertEqual([claude_windows[key]["label"] for key in ("five_hour", "seven_day")], ["5h", "Weekly"])
        self.assertEqual([claude_windows[key]["usedPercent"] for key in ("five_hour", "seven_day")], [83, 41])
        self.assertEqual(claude_state["snapshot"]["status"], "warning")
        persisted = list(self.data_directory.rglob("agent-usage.json"))
        self.assertTrue(persisted, "The last-known usage should be saved so it survives a restart.")
        saved = json.loads(persisted[0].read_text(encoding="utf-8"))
        self.assertEqual(saved["claude"]["snapshot"]["windows"][0]["usedPercent"], 83)

        # A window whose reset time has passed reads as reset, with no provider call.
        claude_turn({"status": "rejected", "rateLimitType": "five_hour", "utilization": 1.0, "resetsAt": now - 10})
        claude_state = usage()["claude"]
        expired = windows(claude_state)["five_hour"]
        self.assertTrue(expired["isReset"])
        self.assertEqual(expired["usedPercent"], 0)
        self.assertIsNone(expired.get("resetsAt"))
        self.assertEqual(claude_state["snapshot"]["status"], "allowed", "The limit lifts with the window that held it.")
        self.assertEqual(windows(claude_state)["seven_day"]["usedPercent"], 41)

        # Claude Code pushes rate_limit_event only when a limit's status changes, and a
        # usage-based plan's event names its spend limit with no utilization. So after
        # every turn Playhouse reads the plan's usage with Claude Code's get_usage
        # control request, without a model call and without a refresh.
        usage_path = Path(str(claude) + ".usage")
        usage_reads = Path(str(claude) + ".usage-reads")

        def read_count():
            return len(usage_reads.read_text(encoding="utf-8").splitlines()) if usage_reads.exists() else 0

        def iso(seconds):
            return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seconds))

        usage_path.write_text(json.dumps({"rate_limits_available": True, "rate_limits": {
            "five_hour": {"utilization": 12.0, "resets_at": iso(now + 7200)},
            "seven_day": {"utilization": 0.5, "resets_at": iso(now + 5 * 86400)},
            "seven_day_opus": None,
            "extra_usage": {"is_enabled": True, "monthly_limit": 65000, "used_credits": 33602,
                            "utilization": 51.7, "spend_limit_reached": False},
        }}), encoding="utf-8")
        reads_before_turn = read_count()
        claude_turn({"status": "allowed", "rateLimitType": "overage", "resetsAt": now + 20 * 86400, "isUsingOverage": False})
        claude_state = wait_for(
            "claude", lambda state: windows(state).get("five_hour", {}).get("usedPercent") == 12,
            "A finished Claude turn should read the plan's usage again.",
        )
        self.assertGreater(read_count(), reads_before_turn, "The turn's end reads usage through get_usage.")
        self.assertIs(json.loads(usage_reads.read_text(encoding="utf-8").splitlines()[-1])["skipBehaviors"], True,
                      "The read skips the local transcript scan.")
        read_windows = windows(claude_state)
        self.assertEqual(list(read_windows), ["five_hour", "seven_day", "overage"], "The read lists the plan's windows; null ones are left out.")
        self.assertFalse(read_windows["five_hour"]["isReset"], "The read replaces the expired window with the current one.")
        self.assertEqual(read_windows["five_hour"]["resetsAt"], now + 7200)
        self.assertEqual(read_windows["seven_day"]["usedPercent"], 0.5, "get_usage reports percents, so 0.5 stays 0.5%.")
        self.assertEqual((read_windows["overage"]["label"], read_windows["overage"]["usedPercent"]), ("Spend limit", 51.7))
        self.assertEqual(read_windows["overage"]["resetsAt"], now + 20 * 86400, "The spend's reset time comes from the stream's overage event.")
        self.assertEqual(claude_state["snapshot"]["status"], "allowed")
        saved = json.loads(persisted[0].read_text(encoding="utf-8"))
        self.assertEqual([window["usedPercent"] for window in saved["claude"]["snapshot"]["windows"]], [12, 0.5, 51.7])

        # A refresh reads it too; a reply without plan usage keeps the last known rows.
        usage_path.write_text(json.dumps({"rate_limits_available": False, "rate_limits": None}), encoding="utf-8")
        reads_before_refresh = read_count()
        claude_state = usage("--refresh")["claude"]
        self.assertGreater(read_count(), reads_before_refresh, "A refresh reads Claude's usage.")
        self.assertEqual([window["usedPercent"] for window in windows(claude_state).values()], [12, 0.5, 51.7],
                         "An unavailable reply must not clear the rows.")
        usage_path.write_text(json.dumps({"rate_limits_available": True, "rate_limits": {
            "extra_usage": {"is_enabled": True, "utilization": 100.0, "spend_limit_reached": True},
        }}), encoding="utf-8")
        claude_state = usage("--refresh")["claude"]
        self.assertEqual(list(windows(claude_state)), ["overage"], "A read replaces the windows a plan no longer has.")
        self.assertEqual(claude_state["snapshot"]["status"], "rejected", "A reached spend limit is a reached limit.")

        # A get_usage request that is never answered times out instead of holding
        # every later read, and the next read works again.
        hang_path = Path(str(claude) + ".usage-hang")
        hang_path.write_text("hang\n", encoding="utf-8")
        started = time.monotonic()
        claude_state = usage("--refresh")["claude"]
        self.assertLess(time.monotonic() - started, 45, "An unanswered usage read must time out.")
        self.assertEqual(list(windows(claude_state)), ["overage"], "A read that timed out keeps the last known rows.")
        hang_path.unlink()
        usage_path.write_text(json.dumps({"rate_limits_available": True, "rate_limits": {
            "extra_usage": {"is_enabled": True, "utilization": 40.0, "spend_limit_reached": False},
        }}), encoding="utf-8")
        self.assertEqual(windows(usage("--refresh")["claude"])["overage"]["usedPercent"], 40, "Reads work again after a timeout.")
        usage_path.unlink()

        # Switching the Codex account signs out, clears usage, and signs in again;
        # the new account's usage arrives with the login's own notifications.
        switched = self.assert_success(self.call_cli("usage", "switch-account", "codex", extra_environment=environment)[0])
        self.assertEqual(switched["loginURL"], "https://example.invalid/codex-login")
        codex_state = wait_for(
            "codex", lambda state: state.get("account") == "codex-second@example.com" and windows(state).get("primary", {}).get("usedPercent") == 7,
            "Codex never showed the switched account's usage.",
        )
        self.assertEqual(windows(codex_state)["secondary"]["usedPercent"], 20)

        # Switching the Claude account runs the CLI's logout and login and drops the old usage.
        switched = self.assert_success(self.call_cli("usage", "switch-account", "claude", extra_environment=environment)[0])
        self.assertIsNone(switched["loginURL"])
        claude_state = wait_for(
            "claude", lambda state: state.get("account") == "claude-second@example.com" and not state["loginInProgress"],
            "Claude never showed the switched account.",
        )
        self.assertEqual(claude_state["plan"], "Pro")
        self.assertIsNone(claude_state.get("snapshot"), "The old account's usage must not carry over.")

        # A signed-out provider has no account or usage; logging in restores it.
        Path(str(codex) + ".account").write_text(json.dumps({"loggedIn": False, "email": None, "used": [0, 0]}), encoding="utf-8")
        Path(str(claude) + ".auth-state").write_text(json.dumps({"loggedIn": False}), encoding="utf-8")
        providers = usage("--refresh")
        for provider in ("codex", "claude"):
            self.assertIs(providers[provider]["loggedIn"], False)
            self.assertIsNone(providers[provider].get("account"))
            self.assertIsNone(providers[provider].get("snapshot"))
        self.assert_success(self.call_cli("usage", "login", "claude", extra_environment=environment)[0])
        wait_for("claude", lambda state: state["loggedIn"] is True and state.get("account") == "claude-second@example.com",
                 "A Claude login should restore the account.")
        login = self.assert_success(self.call_cli("usage", "login", "codex", extra_environment=environment)[0])
        self.assertEqual(login["loginURL"], "https://example.invalid/codex-login")
        wait_for("codex", lambda state: state["loggedIn"] is True and state.get("account") == "codex-second@example.com",
                 "A Codex login should restore the account.")
    # case-contract: test_codex_context_compaction_threshold_and_model_switch | With a configured 100,000-token threshold and 150,000-token minimum, a Codex task reporting 120,000 context tokens calls thread/compact/start before its next prompt, records one successful automatic threshold event with a labelled activity, and adds no empty assistant turn. After a same-model turn records 220,000 context tokens, switching models compacts through the RPC first, records the old model and model-switch trigger, and waits for the matching successful terminal notification before turn/start. A failure after the initial acknowledgment is recorded as unsuccessful while the prompt still runs. If the app-server rejects compaction, Playhouse records a failed activity and event but continues the prompt. Codex uses reported context and model changes; its path does not depend on Claude's prompt-cache TTL or warm-idle scheduler.
    def test_codex_context_compaction_threshold_and_model_switch(self):
        environment = self.install_codex_fixture("codex-fixture-auto-threshold")
        environment["PLAYHOUSE_E2E_CODEX_CONTEXT_TOKENS"] = "120000"
        context_tokens_file = Path(environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".context-tokens")
        context_tokens_file.write_text("120000", encoding="utf-8")
        self.assert_success(self.call_cli(
            "settings", "set-auto-compaction", "--threshold", "100000", "--minimum", "150000"
        )[0])
        task_id = self.create_task("Codex threshold compaction", provider="codex")["id"]
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "First Codex turn.", "--model", "gpt-6-sol",
            extra_environment=environment,
        )[0])
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Continue after the context threshold.", "--model", "gpt-6-sol",
            extra_environment=environment,
        )[0])
        usage = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])
        threshold_events = usage["contextCompactions"]
        self.assertEqual(len(threshold_events), 1)
        self.assertEqual(threshold_events[0]["provider"], "codex")
        self.assertEqual(threshold_events[0]["trigger"], "threshold")
        self.assertEqual(threshold_events[0]["preTokens"], 120000)
        self.assertTrue(threshold_events[0]["succeeded"])
        history_path = Path(environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".history")
        history = json.loads(history_path.read_text(encoding="utf-8"))
        methods = [event["method"] for event in history["rpcOrder"]]
        self.assertEqual(methods, ["turn/start", "thread/compact/start", "compaction/completed", "turn/start"])
        conversation = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        rows = [item for item in conversation["activities"] if item.get("isContextCompaction")]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["title"], "Context compacted automatically")
        self.assertFalse(any(message.get("role") == "assistant" and not message.get("text", "").strip()
                             for message in conversation["messages"]))

        context_tokens_file.write_text("220000", encoding="utf-8")
        self.assert_success(self.call_cli(
            "settings", "set-auto-compaction", "--threshold", "300000", "--minimum", "150000"
        )[0])
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Grow context before switching models.", "--model", "gpt-6-sol",
            extra_environment=environment,
        )[0])
        methods = [event["method"] for event in json.loads(history_path.read_text(encoding="utf-8"))["rpcOrder"]]
        self.assertEqual(methods[-1], "turn/start", "The same-model turn records the 220k usage for the upcoming switch.")
        previous_order_count = len(methods)
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Switch to Luna.", "--model", "gpt-6-luna",
            extra_environment=environment,
        )[0])
        events = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])["contextCompactions"]
        self.assertEqual(events[-1]["trigger"], "model-switch")
        self.assertEqual(events[-1]["model"], "gpt-6-sol")
        self.assertEqual(events[-1]["preTokens"], 220000)
        self.assertTrue(events[-1]["succeeded"])
        switch_history = json.loads(history_path.read_text(encoding="utf-8"))
        methods = [event["method"] for event in switch_history["rpcOrder"]]
        self.assertEqual(methods[previous_order_count:], ["thread/compact/start", "compaction/completed", "turn/start"])

        failure_marker = Path(environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".compact-fail")
        failure_marker.touch()
        previous_order_count = len(methods)
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Continue after failed compaction.", "--model", "gpt-6-sol",
            extra_environment=environment,
        )[0])
        failure_events = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])["contextCompactions"]
        self.assertFalse(failure_events[-1]["succeeded"])
        failure_history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        failure_rows = [item for item in failure_history["activities"] if item.get("isContextCompaction")]
        self.assertTrue(any(item["title"] == "Automatic context compaction failed" and item["status"] == "failed" for item in failure_rows))
        self.assertIn("Continue after failed compaction.", [message["text"] for message in failure_history["messages"]])
        failure_order = json.loads(history_path.read_text(encoding="utf-8"))["rpcOrder"]
        self.assertEqual([event["method"] for event in failure_order][previous_order_count:],
                         ["thread/compact/start", "turn/start"])
        failure_marker.unlink()
        terminal_failure = Path(environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".compact-terminal-fail")
        terminal_failure.touch()
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Continue after asynchronous failure.", "--model", "gpt-6-luna",
            extra_environment=environment,
        )[0])
        terminal_failure.unlink()
        terminal_events = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])["contextCompactions"]
        self.assertEqual(len(terminal_events), len(failure_events) + 1)
        self.assertFalse(terminal_events[-1]["succeeded"])
        final_history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        self.assertIn("Continue after asynchronous failure.", [message["text"] for message in final_history["messages"]])
    # case-contract: test_task_terminal_opens_shell_in_task_worktree | Each task's sidebar ends in a command row whose buttons sit at its right edge; it holds a terminal button. The terminal only ever opens in the task's created repository worktree, never in its source repository or a context folder, and never creates a worktree itself: while the task's worktree is still pending, or the task has no repository, the button is disabled and the CLI reports terminal_unavailable without creating the worktree, and the button enables in the open conversation once the worktree is created. The CLI reports how the terminal starts: the account's executable login shell with -l in that worktree, with TERM=xterm-256color and PLAYHOUSE_TASK_ID set, and the same answer on a fresh CLI/XPC connection; running that shell in that folder prints the worktree path and the task ID. Clicking the button slides a terminal panel in from the window's right edge, floating over the conversation's right side without moving or resizing the conversation, whose shell runs in the task's worktree with the task ID in its environment and which uses macOS Terminal's Clear Dark ANSI palette (such as its blue, distinct from the emulator's own default) on a solid black background, switching to the Clear Light profile's white background and blue when the app's appearance turns light and back when it returns to dark; hiding the panel keeps the same shell, so reopening it reaches the same process. Hovering the panel's left border shows the left-right resize cursor, and dragging it resizes the panel against the right edge, between a 320-point minimum and leaving 260 points of conversation uncovered, without resizing the conversation, and reopening the panel keeps the dragged width. Typing exit shows that the shell exited, and Restart starts a new shell, with a different process, in the same worktree. A task whose worktree no longer exists reports terminal_unavailable from the CLI, and the panel shows that error with a Try Again action that opens the shell once the worktree is back; an unknown task ID and the standalone chat's ID are not_found, and the standalone chat offers no terminal button.
    def test_task_terminal_opens_shell_in_task_worktree(self):
        repository = self.data_directory / "terminal-repository"
        repository.mkdir()
        (repository / "README.md").write_text("Terminal fixture.\n", encoding="utf-8")
        self.run_git(repository, "init", "--initial-branch=main")
        self.run_git(repository, "config", "user.name", "Playhouse Bridge Test")
        self.run_git(repository, "config", "user.email", "playhouse-bridge-test@example.invalid")
        self.run_git(repository, "add", "README.md")
        self.run_git(repository, "commit", "-m", "Baseline")
        task_id = self.create_task(title="Terminal task", roots=[])["id"]
        added, _ = self.call_cli("task", "repository", "add", task_id, "--repo", str(repository))
        worktree = next(
            item["worktreePath"] for item in self.assert_success(added)["repositoryWorktrees"]
            if item["repositoryPath"] == str(repository)
        )

        response, _ = self.call_cli("task", "terminal", task_id)
        launch = self.assert_success(response)
        self.assertEqual(launch["taskID"], task_id)
        self.assertEqual(launch["directory"], os.path.normpath(worktree), "The terminal opens in the task's worktree, not its source repository.")
        self.assertNotEqual(os.path.realpath(launch["directory"]), os.path.realpath(repository))
        self.assertTrue(os.path.isabs(launch["shell"]) and os.access(launch["shell"], os.X_OK), launch["shell"])
        self.assertEqual(launch["arguments"], ["-l"])
        self.assertEqual(launch["environment"]["TERM"], "xterm-256color")
        self.assertEqual(launch["environment"]["PLAYHOUSE_TASK_ID"], task_id)
        fresh, _ = self.call_cli("task", "terminal", task_id)
        self.assertEqual(self.assert_success(fresh), launch, "A fresh CLI/XPC connection resolves the same terminal.")

        # The reported launch is runnable as given: that shell, in that folder, with those variables.
        shell = subprocess.run(
            [launch["shell"], *launch["arguments"], "-c", 'pwd -P; printf "%s\\n" "$PLAYHOUSE_TASK_ID"'],
            cwd=launch["directory"],
            env={**os.environ, **launch["environment"]},
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(shell.returncode, 0, shell.stderr)
        self.assertEqual(shell.stdout.strip().splitlines()[-2:], [os.path.realpath(worktree), task_id])

        # A pending worktree is named and created when the task starts; the terminal waits for it
        # rather than creating it early, and never opens in the source repository instead.
        pending = self.create_repo_task("Terminal pending task", [str(repository)])
        self.assertTrue(pending["repositoryWorktrees"][0]["isPending"])
        response, _ = self.call_cli("task", "terminal", pending["id"], expected_status=1)
        self.assert_failure(response, "terminal_unavailable")
        self.assertIn("once the task's worktree is created", response["error"]["message"])
        still_pending = self.assert_success(self.call_cli("task", "get", pending["id"])[0])["repositoryWorktrees"][0]
        self.assertTrue(still_pending["isPending"], "Asking for the terminal does not create the worktree.")
        self.assertEqual(still_pending["branch"], "auto", "The branch is still named when the task starts.")

        # A folder-only task has no worktree, so the terminal refuses rather than open in the folder.
        folder = self.data_directory / "terminal-folder"
        folder.mkdir()
        folder_task_id = self.create_task(title="Terminal folder task", roots=[str(folder)])["id"]
        response, _ = self.call_cli("task", "terminal", folder_task_id, expected_status=1)
        self.assert_failure(response, "terminal_unavailable")
        self.assertIn("Add a repository", response["error"]["message"])
        # Once it has a created worktree, the terminal opens there, never in the folder.
        repaired = self.assert_success(self.call_cli("task", "repository", "add", folder_task_id, "--repo", str(repository))[0])
        repaired_worktree = repaired["repositoryWorktrees"][0]["worktreePath"]
        self.assertFalse(repaired["repositoryWorktrees"][0]["isPending"])
        response, _ = self.call_cli("task", "terminal", folder_task_id)
        repaired_launch = self.assert_success(response)
        self.assertEqual(repaired_launch["directory"], os.path.normpath(repaired_worktree))
        self.assertNotEqual(repaired_launch["directory"], os.path.normpath(str(folder)))
        self.assertNotEqual(os.path.realpath(repaired_launch["directory"]), os.path.realpath(repository))

        shutil.rmtree(repaired_launch["directory"])
        response, _ = self.call_cli("task", "terminal", folder_task_id, expected_status=1)
        self.assert_failure(response, "terminal_unavailable")
        self.assertIn("no longer exists", response["error"]["message"])
        response, _ = self.call_cli("task", "terminal", "00000000-0000-0000-0000-000000000000", expected_status=3)
        self.assert_failure(response, "not_found")
        chat_id = self.assert_success(self.call_cli("chat", "open")[0])["id"]
        response, _ = self.call_cli("task", "terminal", chat_id, expected_status=3)
        self.assert_failure(response, "not_found")
    # case-contract: test_task_terminal_splits_per_repository_worktree | A task with more than one created repository worktree opens its terminal as a split view with one shell per worktree. The CLI reports one pane per created worktree, in the task's repository order, each naming its source repository's folder and opening in that repository's worktree, never in a source repository, and the launch's directory is the first pane's; a single-repository task reports exactly one pane, and a worktree that no longer exists is left out while the others still open. In the app, opening the terminal for a two-repository task stacks one terminal pane per worktree in the panel, the first above the second, each headed by its repository's name and each shell running in its own worktree as a different process; hiding and reopening the panel keeps both shells. Exiting one pane's shell offers Restart only in that pane while the other shell keeps running, and Restart starts a new shell in that pane's worktree. A repository added to the task while its shells run gets its own pane when the panel is next opened, while the existing shells keep running.
    def test_task_terminal_splits_per_repository_worktree(self):
        first_repository = self.make_skill_repository("terminal-split-first", {})
        second_repository = self.make_skill_repository("terminal-split-second", {})
        task_id = self.create_task(title="Terminal split task", roots=[])["id"]
        added = self.assert_success(self.call_cli("task", "repository", "add", task_id, "--repo", str(first_repository))[0])
        self.assertEqual(len(added["repositoryWorktrees"]), 1)
        single = self.assert_success(self.call_cli("task", "terminal", task_id)[0])
        self.assertEqual(len(single["panes"]), 1, "A single-repository task opens one shell.")
        self.assertEqual(single["panes"][0]["directory"], single["directory"])

        added = self.assert_success(self.call_cli("task", "repository", "add", task_id, "--repo", str(second_repository))[0])
        worktrees = {item["repositoryPath"]: os.path.normpath(item["worktreePath"]) for item in added["repositoryWorktrees"]}
        self.assertFalse(any(item["isPending"] for item in added["repositoryWorktrees"]))
        launch = self.assert_success(self.call_cli("task", "terminal", task_id)[0])
        self.assertEqual(
            [(pane["repositoryPath"], pane["name"], pane["directory"]) for pane in launch["panes"]],
            [
                (str(first_repository), "terminal-split-first", worktrees[str(first_repository)]),
                (str(second_repository), "terminal-split-second", worktrees[str(second_repository)]),
            ],
            "Each created worktree gets its own pane, in the task's repository order.",
        )
        self.assertEqual(launch["directory"], launch["panes"][0]["directory"], "The launch's directory is the first pane's.")
        for pane, repository in zip(launch["panes"], (first_repository, second_repository)):
            self.assertNotEqual(os.path.realpath(pane["directory"]), os.path.realpath(repository), "A pane never opens in a source repository.")
            shell = subprocess.run(
                [launch["shell"], *launch["arguments"], "-c", 'pwd -P; printf "%s\\n" "$PLAYHOUSE_TASK_ID"'],
                cwd=pane["directory"],
                env={**os.environ, **launch["environment"]},
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(shell.returncode, 0, shell.stderr)
            self.assertEqual(shell.stdout.strip().splitlines()[-2:], [os.path.realpath(pane["directory"]), task_id])
        fresh = self.assert_success(self.call_cli("task", "terminal", task_id)[0])
        self.assertEqual(fresh, launch, "A fresh CLI/XPC connection resolves the same split.")

        # A worktree that no longer exists is left out; the remaining one still opens.
        missing = worktrees[str(first_repository)]
        os.rename(missing, missing + "-moved")
        try:
            remaining = self.assert_success(self.call_cli("task", "terminal", task_id)[0])
            self.assertEqual([pane["directory"] for pane in remaining["panes"]], [worktrees[str(second_repository)]])
            self.assertEqual(remaining["directory"], worktrees[str(second_repository)])
        finally:
            os.rename(missing + "-moved", missing)
        restored = self.assert_success(self.call_cli("task", "terminal", task_id)[0])
        self.assertEqual(len(restored["panes"]), 2, "The pane returns with its worktree.")
    # case-contract: test_task_token_usage_records_claude_turn_breakdown | A task starts with no recorded tokens, and its Token Stats modal says so plainly with no totals shown. Running a real Claude Code fixture turn parses that turn's reported usage into Playhouse's four buckets, adds them to the task's running totals, and records a per-turn row naming the provider and the tools, skills and MCP servers that ran in it. A second turn adds to the totals and appends its own row rather than replacing the first, and the per-tool rollup counts the turns each tool took part in. Call-level accounting spans the main agent and its subagents: an empty task's `callUsage` reports itself unavailable, and after a turn it reports exact model-call, total-sent, output and final-transcript figures read from the session files (counting each message ID once, ignoring repeated and zero-usage lines, and including the subagent's own file), which a second turn adds to rather than replaces. A Claude turn whose session files cannot be read still counts its calls live from the stream. The task card replaces its old dot with a compact live counter of total sent, which is hidden while that total is still zero, whose tooltip names the sent total, call count and final transcript size, and both the Token Stats context-menu item and a click on the counter itself, a button that highlights on hover, open a modal labelling 'Final transcript size' and 'Total sent (incl. subagents)' beside the call and output counts, the per-tool rollup and the per-turn breakdown. Excluding cache reads (uncached input + cache write + output, subagent included) is 855 per turn, doubling after a second turn, and also reaches the live stream when the session files cannot be read; an empty task reports it unavailable. A task saved before the cache split existed (call usage without the split, plus turn-level buckets) still loads, reports its call counts and total sent, omits the per-call excluding-cache figures, and falls back to the turn buckets minus cache reads (170 for 100 input, 50 output, 400 cache read and 20 cache write); its modal hides the Excluding cache reads headline. The modal also labels 'Excluding cache reads (incl. subagents)' with its main-agent and subagent split.
    def test_task_token_usage_records_claude_turn_breakdown(self):
        # Matches TURN_USAGE in scripts/fixtures/claude-code-fixture.py.
        expected_turn_usage = {
            "inputTokens": 1000, "outputTokens": 200, "cacheReadTokens": 300, "cacheCreationTokens": 100,
        }
        turn_total = sum(expected_turn_usage.values())
        # Matches STORY_MAIN_CALLS / STORY_SUBAGENT_CALLS in the fixture: per turn, two main
        # calls sending 550 and 650 (output 20 + 40) and two subagent calls sending 300 and
        # 340 (output 10 + 15), with a repeated line and a zero-usage line to be ignored.
        call_usage_per_turn = {
            "totalCalls": 4, "totalSentTokens": 1840, "totalOutputTokens": 85, "finalTranscriptTokens": 650,
        }
        # The same calls without their cache reads (input + cache write + output): main
        # (100+50+20) + (120+30+40) = 360, subagent (200+20+10) + (240+10+15) = 495.
        excluding_cache_per_turn = {"main": 360, "subagents": 495, "total": 855}
        environment = self.install_claude_fixture("claude-fixture-token-usage")
        # The session files the fixture writes live under Claude Code's config directory.
        session_files = self.data_directory / "claude-config"
        file_environment = {**environment, "CLAUDE_CONFIG_DIR": str(session_files)}
        task_id = self.assert_success(self.call_cli(
            "task", "create", "--title", "Claude token usage", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )[0])["id"]

        empty = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])
        self.assertFalse(empty["callUsage"]["available"], "A task with no turns has no call-level usage yet.")
        self.assertIsNone(empty["callUsage"].get("totalTokensExcludingCacheReads"), "No calls means no cache-excluded call total.")
        self.assertEqual(empty["tokensExcludingCacheReads"], 0, "An empty task falls back to the turn buckets, which are zero.")
        self.assertEqual(empty["callUsage"]["totalCalls"], 0)
        self.assertEqual(empty["totalTokens"], 0, "A task with no turns has recorded no tokens.")
        self.assertEqual(empty["turns"], [])
        self.assertEqual(empty["tools"], [])

        # "Tell me a story." is one of the fixture's few branches that reports a
        # task outcome, so it ends in exactly one Claude `result` message; a
        # prompt that leaves the outcome unreported (like "inspect") makes
        # Playhouse send several internal nudge turns in the same session,
        # each contributing its own `result` and inflating this fixture's
        # flat per-result usage well past one turn's worth.
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Tell me a story.",
            extra_environment=file_environment,
        )[0])
        first = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])
        calls = first["callUsage"]
        self.assertTrue(calls["available"])
        for key, value in call_usage_per_turn.items():
            self.assertEqual(calls[key], value, f"callUsage.{key} should count each call once, subagent included.")
        self.assertEqual(calls["mainAgent"], {
            "calls": 2, "sentTokens": 1200, "outputTokens": 60, "finalTranscriptTokens": 650, "tokensExcludingCacheReads": excluding_cache_per_turn["main"],
        })
        self.assertEqual(calls["subagents"], {
            "count": 1, "calls": 2, "sentTokens": 640, "outputTokens": 25, "tokensExcludingCacheReads": excluding_cache_per_turn["subagents"],
        })
        self.assertEqual(calls["mainAgent"]["tokensExcludingCacheReads"], excluding_cache_per_turn["main"])
        self.assertEqual(
            calls["totalTokensExcludingCacheReads"], excluding_cache_per_turn["total"],
            "Excluding cache reads sums uncached input + cache write + output over the main agent and the subagent.",
        )
        self.assertEqual(first["tokensExcludingCacheReads"], excluding_cache_per_turn["total"])
        self.assertEqual(first["usage"], expected_turn_usage, "Claude's usage buckets should reach the task totals.")
        self.assertEqual(first["totalTokens"], turn_total)
        self.assertEqual(len(first["turns"]), 1, "The completed turn should be recorded once.")
        turn = first["turns"][0]
        self.assertEqual(turn["provider"], "claude")
        self.assertEqual(turn["usage"], expected_turn_usage)
        self.assertEqual(turn["totalTokens"], turn_total)
        self.assertIn("Bash", turn["tools"], "The turn should name the tool it ran.")
        self.assertEqual(
            [tool for tool in first["tools"] if tool["id"] == "Bash"],
            [{"id": "Bash", "turnCount": 1, "totalTokens": turn_total}],
            "The rollup should credit the Bash tool with the turn it ran in.",
        )

        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Tell me a story.",
            extra_environment=file_environment,
        )[0])
        second = self.assert_success(self.call_cli("task", "token-usage", task_id)[0])
        for key in ("totalCalls", "totalSentTokens", "totalOutputTokens"):
            self.assertEqual(second["callUsage"][key], call_usage_per_turn[key] * 2, f"A second turn adds to callUsage.{key}.")
        self.assertEqual(second["callUsage"]["finalTranscriptTokens"], 650)
        self.assertEqual(second["callUsage"]["totalTokensExcludingCacheReads"], excluding_cache_per_turn["total"] * 2)
        self.assertEqual(second["callUsage"]["subagents"]["count"], 2, "Each turn's subagent has its own file.")
        self.assertEqual(second["totalTokens"], turn_total * 2, "A second turn adds to the running total.")
        self.assertEqual(second["usage"]["inputTokens"], expected_turn_usage["inputTokens"] * 2)
        self.assertEqual(len(second["turns"]), 2, "Each turn keeps its own row.")
        self.assertEqual(len({turn["id"] for turn in second["turns"]}), 2, "Turn rows must not share an id.")
        self.assertTrue(
            all(turn["totalTokens"] == turn_total for turn in second["turns"]),
            "Each turn row should carry only its own cost.",
        )

        # With no readable session files the counts come from the stream alone,
        # which is also what the card's counter follows while a turn is running.
        live_id = self.assert_success(self.call_cli(
            "task", "create", "--title", "Claude live token usage", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )[0])["id"]
        self.assert_success(self.call_cli(
            "conversation", "send", live_id, "--message", "Tell me a story.", extra_environment=environment,
        )[0])
        live = self.assert_success(self.call_cli("task", "token-usage", live_id)[0])["callUsage"]
        for key, value in call_usage_per_turn.items():
            self.assertEqual(live[key], value, f"The live stream should reach callUsage.{key}.")
        self.assertEqual(
            live["totalTokensExcludingCacheReads"], excluding_cache_per_turn["total"],
            "The live stream carries the cache split too, subagent calls included.",
        )
        self.assertEqual(live["subagents"]["tokensExcludingCacheReads"], excluding_cache_per_turn["subagents"])

        # A task saved before the cache split existed: call usage without the split fields plus turn buckets.
        legacy_title = "Claude legacy token usage"
        legacy_id = self.create_task(title=legacy_title, provider="claude")["id"]
        legacy_snapshots = '{"claude:legacy":{"provider":"claude","updatedAt":800000000,"main":{"calls":2,"sentTokens":1200,"outputTokens":60,"lastContextTokens":650},"subagents":{"old":{"calls":1,"sentTokens":300,"outputTokens":10,"lastContextTokens":300}}}}'.encode("utf-8")
        with sqlite3.connect(self.data_directory / "Playhouse-v2.store") as database:
            seeded = database.execute(
                "UPDATE ZBOARDTASK SET ZCALLUSAGESNAPSHOTSDATA = ?, ZTOTALINPUTTOKENS = 100, ZTOTALOUTPUTTOKENS = 50, "
                "ZTOTALCACHEREADTOKENS = 400, ZTOTALCACHECREATIONTOKENS = 20 WHERE ZTITLE = ?",
                (legacy_snapshots, legacy_title),
            )
            self.assertEqual(seeded.rowcount, 1, "Seed the real SwiftData row with pre-split call usage.")
        # The running daemon holds the task in memory; a fresh daemon (its own service name) reads the seeded row.
        fresh_daemon = {
            "PLAYHOUSE_BRIDGE_SERVICE_NAME": f"{arguments.service_name}.legacy-{uuid.uuid4().hex[:8]}",
            "PLAYHOUSE_BRIDGE_IDLE_GRACE_SECONDS": "3",
        }
        legacy = self.assert_success(self.call_cli("task", "token-usage", legacy_id, extra_environment=fresh_daemon)[0])
        self.assertTrue(legacy["callUsage"]["available"], "Old call usage still decodes.")
        self.assertEqual((legacy["callUsage"]["totalCalls"], legacy["callUsage"]["totalSentTokens"]), (3, 1500))
        self.assertIsNone(legacy["callUsage"].get("totalTokensExcludingCacheReads"), "Without the split there is no per-call figure.")
        self.assertIsNone(legacy["callUsage"]["subagents"].get("tokensExcludingCacheReads"))
        self.assertEqual(legacy["tokensExcludingCacheReads"], 170, "The fallback is the turn buckets minus cache reads.")

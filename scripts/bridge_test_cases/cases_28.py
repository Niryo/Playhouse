from test_bridge_support import *
from test_bridge_support import __file__


class BridgeTestCases28:
    def optimized_claude_fixture(self, name, report_outcome=False):
        executable = self.data_directory / name
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        if report_outcome:
            environment["PLAYHOUSE_E2E_CLAUDE_FIXTURE_REPORT_OUTCOME"] = "1"
        return executable, environment

    def claude_fixture_turns(self, executable):
        history = Path(str(executable) + ".history")
        turns = json.loads(history.read_text(encoding="utf-8"))["turns"] if history.is_file() else []
        return [turn for turn in turns if not (turn.get("userText") or "").startswith("Write a concise task title")]

    def claude_turn_ending(self, executable, message):
        matches = [turn for turn in self.claude_fixture_turns(executable) if (turn.get("userText") or "").endswith(message)]
        self.assertTrue(matches, f"The Claude fixture never received a turn ending with {message!r}.")
        return matches[-1]

    # case-contract: test_standalone_chat_new_page_skips_last_page_context | A standalone chat's next message can start a new page, so it runs without the last page's context. Without it, a message continues the active page and resumes that page's provider session. The CLI's conversation send --new-page, and in the chat the small New page plus button, centered on the line between the chat and its composer (absent from an empty chat), open a page titled "New page" that Playhouse marks as the user's own, before the turn, whose turn starts a fresh provider session, never resuming the last page's: its prompt carries a Playhouse page header naming that "New page" as the current page, telling the agent the user started it for a new topic and to name it in close-turn, and listing the earlier page by title and ID only so it can still be read, while none of the last page's turns travel with it. While the turn runs it is already on that page, still titled "New page" with no messages, and the chat shows a "New page" separator without a remove button above the sent message and no plus button. The agent's close-turn --new-title names that page instead of opening another one, so the chat gains exactly one page, holding the turn, the earlier page keeps its own messages, and the next message without New page resumes the new page's session; a close-turn with --continues true and no title leaves the page to the fallback classifier, which names it from the message, so it never keeps its placeholder title. A New page send that fails leaves its empty page, which another New page send reuses, running there in a fresh session that opens with the New page header again and names it, and a send without New page instead removes it and continues the page before it, resuming that page's session; in the chat, a New page send that fails keeps its removable New page separator, so the next message still starts that page. In the chat, pressing the button replaces it with a "New page" separator with a remove button; removing it brings the button back and the next message continues the active page, and once a message is sent with it the turn sits under the page's separator showing its real title and the button comes back; no plus button shows while any turn runs, a plain one included. --new-page on a board task is invalid_argument. The page is opened in Playhouse's provider-neutral turn path before the provider session is chosen and the header reaches either provider as the same seeded context, so one representative provider (Claude) covers the case.
    def test_standalone_chat_new_page_skips_last_page_context(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable, environment = self.optimized_claude_fixture("claude-fixture-chat-new-page")
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        first_prompt = "Name the largest moon of Jupiter."
        new_page_prompt = "Suggest a quick pasta dinner."
        header_line = "The user started this new page for their message"

        def send(message, *extra):
            self.assert_success(self.call_cli(
                "conversation", "send", chat_id, "--message", message, *extra, extra_environment=environment
            )[0])

        def status():
            return self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])

        def pages():
            return self.assert_success(self.call_cli("chat", "page", "list", extra_environment=environment)[0])["pages"]

        def page_texts(page_id):
            read = self.assert_success(self.call_cli("chat", "page", "read", page_id, extra_environment=environment)[0])
            return [message["text"] for message in read["messages"]]

        send(first_prompt)
        first_page = status()["activePage"]
        first_turn = self.claude_turn_ending(executable, first_prompt)

        # Without New page, the next message continues the active page in its own session.
        send(new_page_prompt)
        continued = self.claude_turn_ending(executable, new_page_prompt)
        self.assertTrue(continued["resumed"], "A message without New page resumes the active page's session.")
        self.assertEqual(continued["sessionID"], first_turn["sessionID"])
        self.assertNotIn(header_line, continued["userText"])
        self.assertEqual(status()["activePage"]["id"], first_page["id"], "The message stays on the active page.")

        # New page: a fresh session that gets the page header but none of the last page's turns.
        # While the turn runs, it is already on the user's page, still titled "New page".
        hold = Path(str(executable) + ".hold-new-page")
        hold.touch()
        command = ("conversation", "send", chat_id, "--message", new_page_prompt, "--new-page")
        process = self.start_cli(*command, extra_environment=environment)
        try:
            self.wait_for(lambda: Path(str(executable) + ".new-page-active").exists(), "The New page turn is held.", timeout=30)
            running = status()["activePage"]
            self.assertEqual(running["title"], "New page", "The running turn is on the user's page.")
            self.assertEqual(running["messageCount"], 0)
            self.assertNotEqual(running["id"], first_page["id"])
        finally:
            Path(str(executable) + ".new-page-release").write_text("Release the New page turn.\n", encoding="utf-8")
        self.finish_cli(process, command)
        fresh = self.claude_turn_ending(executable, new_page_prompt)
        self.assertFalse(fresh["resumed"], "A New page message never resumes the last page's session.")
        self.assertNotEqual(fresh["sessionID"], first_turn["sessionID"])
        self.assertIn('Current page: "New page" (id: ', fresh["userText"], "The header names the user's new page.")
        self.assertIn(header_line, fresh["userText"], "The header tells the agent the user started a new topic.")
        self.assertIn(f'- "{first_page["title"]}" (id: {first_page["id"]}, ', fresh["userText"],
                      "The earlier page stays listed by title and ID, so the agent can still read it.")
        for earlier in ("Ganymede", "Cacio e pepe", first_prompt):
            self.assertNotIn(earlier, fresh["userText"], "None of the last page's turns travel with a New page message.")
        close_turns = [item for item in fresh["reportCommands"] if " chat page close-turn " in item["command"]]
        self.assertEqual(len(close_turns), 1)
        self.assertIn("--continues false", close_turns[0]["command"])

        settled = status()
        self.assertFalse(settled["missedPreviousPageSignal"])
        new_page = settled["activePage"]
        self.assertEqual(new_page["id"], running["id"], "The turn is filed on the page it ran on.")
        self.assertEqual(new_page["title"], "Pasta dinner", "close-turn names the user's page.")
        listed = pages()
        self.assertEqual([page["id"] for page in listed], [new_page["id"], first_page["id"]],
                         "close-turn names the user's page rather than opening another one.")
        self.assertEqual(page_texts(new_page["id"]), [new_page_prompt, "Cacio e pepe takes fifteen minutes."],
                         "The New page turn is filed on the new page.")
        self.assertEqual(len(page_texts(first_page["id"])), 4, "The earlier page keeps its own messages.")
        self.assertIsNotNone(listed[1]["closedAt"], "The earlier page is closed.")

        # The next message without New page continues the new page's own session.
        send(new_page_prompt)
        follow_up = self.claude_turn_ending(executable, new_page_prompt)
        self.assertTrue(follow_up["resumed"])
        self.assertEqual(follow_up["sessionID"], fresh["sessionID"])
        self.assertEqual(status()["activePage"]["id"], new_page["id"])

        # A New page send that fails leaves its empty page; trying New page again reuses it.
        def failed_new_page_send():
            Path(str(executable) + ".fail-new-page").touch()
            self.call_cli("conversation", "send", chat_id, "--message", new_page_prompt, "--new-page",
                          expected_status=1, extra_environment=environment)
            return status()["activePage"]
        failed = failed_new_page_send()
        self.assertEqual((failed["title"], failed["messageCount"]), ("New page", 0))
        self.assertEqual(failed_new_page_send()["id"], failed["id"], "Retrying New page reuses its unfilled page.")
        self.assertEqual(len(pages()), 3)
        # Sending without New page then undoes that page and continues the page before it.
        send(new_page_prompt)
        undone = self.claude_turn_ending(executable, new_page_prompt)
        self.assertTrue(undone["resumed"], "Without New page the message continues the earlier page's session.")
        self.assertEqual(undone["sessionID"], fresh["sessionID"])
        self.assertNotIn(header_line, undone["userText"])
        self.assertEqual(status()["activePage"]["id"], new_page["id"])
        self.assertEqual([page["id"] for page in pages()], [new_page["id"], first_page["id"]],
                         "The unfilled New page is gone.")
        # A failed New page send followed by another New page send runs on the kept page, fresh.
        kept = failed_new_page_send()
        send(new_page_prompt, "--new-page")
        retried = self.claude_turn_ending(executable, new_page_prompt)
        self.assertFalse(retried["resumed"], "The retried New page message starts a fresh session.")
        self.assertNotEqual(retried["sessionID"], fresh["sessionID"])
        self.assertIn(header_line, retried["userText"], "The retry opens with the New page header again.")
        self.assertNotIn("Cacio e pepe", retried["userText"])
        retried_page = status()["activePage"]
        self.assertEqual(retried_page["id"], kept["id"], "The retry lands on the kept page.")
        self.assertEqual(retried_page["title"], "Pasta dinner")
        self.assertEqual(len(pages()), 3)

        # An agent that closes a New page turn with --continues true and no title leaves the page
        # to the fallback classifier, which names it from the message.
        Path(str(executable) + ".continue-new-page").touch()
        send(new_page_prompt, "--new-page")
        named = None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            named = status()
            if not named["missedPreviousPageSignal"] and named["activePage"]["title"] != "New page":
                break
            time.sleep(0.1)
        self.assertEqual(named["activePage"]["title"], "Classified pasta", "The user's page never keeps its placeholder title.")
        self.assertNotEqual(named["activePage"]["id"], retried_page["id"])
        self.assertEqual(page_texts(named["activePage"]["id"]), [new_page_prompt, "Cacio e pepe takes fifteen minutes."])
        self.assertEqual(len(pages()), 4)

        # Chat pages belong to the standalone chat only.
        board_task = self.create_task("New page rejection")
        self.assert_failure(self.call_cli(
            "conversation", "send", board_task["id"], "--message", "Hello", "--new-page", expected_status=2,
        )[0], "invalid_argument")

    # case-contract: test_claude_optimized_follow_up_starts_fresh_seeded_session | With optimized context on, a Claude task's follow-up starts a brand-new Claude session (launched with --session-id, never --resume) that becomes the task's session, while the first message, sent in Plan mode, started the conversation's original session. The fresh session's prompt begins with a Playhouse optimized context block, not part of the user's message, that maps the whole conversation by position (each turn's user message, agent message and tool-call counts, plan or final answer position), lists every message the user wrote in order with its position, leaves out the plan's text (the outline only gives its position), states the conversation's total messages, tool calls and turns, and ends with the user's new message; a later follow-up rotates again, lists both earlier user messages and the latest final answer but still not the plan, and never repeats the agent's commentary. Its system prompt says the task uses optimized context, that the block is a summary, and points the agent at conversation read and conversation outline. Playhouse's own outcome nudges keep the session they nudge. With the mode back on full, the next follow-up resumes the latest session without a context block. Every turn stays in the visible transcript, and the plan turn is still recorded as a plan in conversation outline.
    def test_claude_optimized_follow_up_starts_fresh_seeded_session(self):
        executable, environment = self.optimized_claude_fixture("claude-fixture-optimized-follow-up")
        task_id = self.create_task(title="Optimized Claude follow-up", provider="claude")["id"]

        def send(message, *extra):
            return self.assert_success(self.call_cli(
                "conversation", "send", task_id, "--message", message, *extra, extra_environment=environment
            )[0])

        first_message = "Inspect the readme and plan the change."
        send(first_message, "--mode", "plan")
        first = self.claude_turn_ending(executable, first_message)
        original_session = self.assert_success(self.call_cli("task", "get", task_id)[0])["claudeSessionID"]
        self.assertEqual(first["sessionID"], original_session)
        self.assertFalse(first["resumed"])
        self.assertNotIn("This task uses optimized context", first["arguments"][first["arguments"].index("--append-system-prompt") + 1],
                         "A task on full context never gets the optimized-context guidance.")

        self.assertEqual(self.assert_success(self.call_cli("conversation", "context-mode", task_id)[0])["mode"], "full",
                         "A task that never chose resumes its whole conversation.")
        updated = self.assert_success(self.call_cli("conversation", "context-mode", task_id, "set", "optimized")[0])
        self.assertEqual(updated["conversationContextMode"], "optimized")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "context-mode", task_id)[0])["mode"], "optimized")

        second_message = "Second request: keep the summary short."
        send(second_message)
        second = self.claude_turn_ending(executable, second_message)
        second_session = self.assert_success(self.call_cli("task", "get", task_id)[0])["claudeSessionID"]
        self.assertNotEqual(second_session, original_session, "An optimized follow-up starts a session of its own.")
        self.assertEqual(second["sessionID"], second_session, "The fresh session becomes the task's session.")
        self.assertFalse(second["resumed"], "An optimized follow-up launches with --session-id, never --resume.")
        self.assertNotIn("--resume", second["arguments"])
        prompt = second["userText"]
        self.assertTrue(prompt.startswith("<playhouse-handoff-context>"), prompt[:200])
        self.assertIn("Playhouse optimized context, not part of the user's message.", prompt)
        self.assertIn(f"Read anything else of task {task_id.upper()} with conversation read", prompt)
        self.assertIn("run help conversation --for task for its options", prompt,
                      "The seed points at help for the command's options instead of copying them.")
        self.assertIn(f"@1: {first_message}", prompt, "The seed lists the user's messages with their positions.")
        self.assertIn("- Turn 1 (Plan mode): user @1; 1 agent message, 1 tool call; plan @3; ends @3", prompt,
                      "The outline places the plan turn's user message, its work and its plan by position.")
        self.assertNotIn("Inspection done: the workspace is ready.", prompt, "The plan is not seeded; the outline gives its position.")
        self.assertNotIn("The latest plan", prompt)
        self.assertNotIn("I'll inspect the workspace first.", prompt, "The agent's commentary is not seeded; it is read on demand.")
        self.assertTrue(prompt.endswith(f"</playhouse-handoff-context>\n\n{second_message}"))
        instructions = second["arguments"][second["arguments"].index("--append-system-prompt") + 1]
        self.assertIn("This task uses optimized context.", instructions)
        self.assertIn("It is a summary, not the whole conversation", instructions)
        self.assertIn(" conversation read ", instructions)
        self.assertIn(" conversation outline ", instructions)

        nudges = [turn for turn in self.claude_fixture_turns(executable)
                  if "playhouse internal outcome nudge:" in (turn.get("userText") or "").lower()]
        self.assertTrue(nudges, "Turns that report no outcome get Playhouse's nudge.")
        for nudge in nudges:
            self.assertTrue(nudge["resumed"], "A Playhouse nudge resumes the session it nudges.")
            self.assertIn(nudge["sessionID"], {original_session, second_session})
            self.assertNotIn("<playhouse-handoff-context>", nudge["userText"])

        third_message = "Third request: list the next steps."
        before_third = self.assert_success(self.call_cli("conversation", "outline", task_id)[0])
        send(third_message)
        third = self.claude_turn_ending(executable, third_message)
        third_session = self.assert_success(self.call_cli("task", "get", task_id)[0])["claudeSessionID"]
        self.assertNotIn(third_session, {original_session, second_session}, "Every optimized follow-up rotates the session.")
        self.assertFalse(third["resumed"])
        outline = self.assert_success(self.call_cli("conversation", "outline", task_id)[0])
        second_position = next(turn["userPositions"][0] for turn in outline["turns"]
                               if turn["startedBy"] == "user" and turn["turn"] > 1)
        self.assertIn(f"@1: {first_message}", third["userText"])
        self.assertIn(f"@{second_position}: {second_message}", third["userText"])
        self.assertNotIn("Inspection done: the workspace is ready.", third["userText"], "Later follow-ups never carry the plan either.")
        self.assertIn("The latest final answer (@", third["userText"])

        def counted(value, noun):
            return f"{value} {noun}{'' if value == 1 else 's'}"
        self.assertIn(
            f"Conversation outline: {counted(before_third['totalMessages'], 'message')} and "
            f"{counted(before_third['totalToolCalls'], 'tool call')} in {counted(before_third['totalTurns'], 'turn')}.",
            third["userText"], "The seed states the conversation's total messages, tool calls and turns.")
        self.assertTrue(outline["turns"][0]["plan"], "The Plan mode turn stays recorded as a plan.")
        fresh = [turn for turn in outline["turns"] if turn["freshSession"]]
        self.assertEqual(len(fresh), 2, "The outline marks the turns that started fresh sessions.")

        self.assert_success(self.call_cli("conversation", "context-mode", task_id, "set", "full")[0])
        fourth_message = "Fourth request: wrap up."
        send(fourth_message)
        fourth = self.claude_turn_ending(executable, fourth_message)
        self.assertTrue(fourth["resumed"], "Back on full context, a follow-up resumes the latest session.")
        self.assertEqual(fourth["sessionID"], third_session)
        self.assertNotIn("<playhouse-handoff-context>", fourth["userText"])

        visible = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        texts = [message["text"] for message in visible["messages"] if message["role"] == "user"]
        for message in (first_message, second_message, third_message, fourth_message):
            self.assertIn(message, texts, "Rotating sessions never hides a turn from the transcript.")
        self.assertFalse(any("<playhouse-handoff-context>" in text for text in texts),
                         "The transcript keeps what the user typed, not the seed.")

    # case-contract: test_codex_optimized_follow_up_starts_fresh_seeded_session | With optimized context on, a Codex task's follow-up starts a new Codex thread with thread/start instead of resuming the old one with thread/resume, runs its turn/start on that new thread, and the task's Codex thread ID follows it. The new thread's developer instructions carry the optimized-context guidance, and the turn's input begins with the Playhouse optimized context block listing the earlier user messages and the Plan mode turn's plan by position only, without the plan's text, followed by the user's new message; the Plan mode turn's commentary, command and plan are numbered as for Claude, so conversation read at 2.1 returns the command. While a Codex goal is set, a follow-up keeps the goal's thread with no context block and no thread/start, and once the goal is cleared the next follow-up rotates again. A follow-up sent with the mode back on full resumes the latest thread with thread/resume and no context block. With the mode on again, switching the task to Claude gives Claude's first session the optimized seed, listing the messages Codex answered, instead of the full provider-switch handoff.
    def test_codex_optimized_follow_up_starts_fresh_seeded_session(self):
        executable = self.data_directory / "codex-fixture-optimized-goal-fresh-threads-unique-turns-success"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        task_id = self.create_task(title="Optimized Codex follow-up", provider="codex")["id"]

        def send(message, *extra):
            self.assert_success(self.call_cli(
                "conversation", "send", task_id, "--message", message, *extra, extra_environment=environment
            )[0])

        def fixture_history():
            return json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))

        def turn_ending(message):
            matches = [turn for turn in fixture_history()["turns"] if (turn.get("userMessage") or "").endswith(message)]
            self.assertTrue(matches, f"The Codex fixture never received a turn ending with {message!r}.")
            return matches[-1]

        first_message = "Draft the rollout plan. Run one command first."
        send(first_message, "--mode", "plan")
        original_thread = self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"]
        self.assertEqual(turn_ending(first_message)["turnThreadID"], original_thread)
        starts_before = len(fixture_history().get("threadStarts", []))

        self.assert_success(self.call_cli("conversation", "context-mode", task_id, "set", "optimized")[0])
        second_message = "Now estimate the rollout effort."
        send(second_message)
        new_thread = self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"]
        self.assertNotEqual(new_thread, original_thread, "An optimized follow-up starts a new Codex thread.")
        history = fixture_history()
        starts = history.get("threadStarts", [])
        self.assertEqual(len(starts), starts_before + 1, "The follow-up sent thread/start once.")
        self.assertEqual(starts[-1]["threadID"], new_thread)
        self.assertIn("This task uses optimized context.", starts[-1]["developerInstructions"] or "",
                      "The new thread's developer instructions carry the optimized-context guidance.")
        self.assertNotIn(new_thread, history.get("threadResumes", []), "The fresh thread is started, never resumed, for its first turn.")
        second = turn_ending(second_message)
        self.assertEqual(second["turnThreadID"], new_thread, "turn/start runs on the new thread.")
        prompt = second["userMessage"]
        self.assertTrue(prompt.startswith("<playhouse-handoff-context>"), prompt[:200])
        self.assertIn("Playhouse optimized context, not part of the user's message.", prompt)
        self.assertIn(f"@1: {first_message}", prompt)
        self.assertIn("- Turn 1 (Plan mode): user @1; 1 agent message, 1 tool call; plan @3; ends @3", prompt,
                      "Codex's commentary, command and plan are numbered the same way as Claude's.")
        command = self.assert_success(self.call_cli("conversation", "read", task_id, "--at", "2.1")[0])["entries"]
        self.assertEqual(command[0]["kind"], "tool", "The Codex command follows its commentary, message 2.")
        self.assertIn("git status", command[0]["title"] + " " + command[0]["text"])
        self.assertNotIn("The latest plan", prompt, "The plan is not seeded; the outline gives its position.")
        plan = self.assert_success(self.call_cli("conversation", "read", task_id, "--at", "3")[0])["entries"][0]
        self.assertEqual(plan["kind"], "plan")
        self.assertNotIn(plan["text"], prompt, "The Codex plan's text is not seeded either.")
        self.assertTrue(prompt.endswith(f"</playhouse-handoff-context>\n\n{second_message}"))

        # A Codex goal belongs to its thread, so while one is set a follow-up keeps that thread.
        self.assert_success(self.call_cli("conversation", "goal", task_id, "set", "--text", "Ship the rollout.", extra_environment=environment)[0])
        goal_message = "Keep going toward the goal."
        send(goal_message)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"], new_thread,
                         "A follow-up keeps the thread that holds the goal.")
        goal_turn = turn_ending(goal_message)
        self.assertEqual(goal_turn["turnThreadID"], new_thread)
        self.assertNotIn("<playhouse-handoff-context>", goal_turn["userMessage"], "A follow-up that keeps its thread gets no seed.")
        self.assertEqual(len(fixture_history().get("threadStarts", [])), starts_before + 1, "No thread starts while the goal is set.")
        self.assert_success(self.call_cli("conversation", "goal", task_id, "clear", extra_environment=environment)[0])
        cleared_message = "The goal is done; summarize the rollout."
        send(cleared_message)
        cleared_thread = self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"]
        self.assertNotEqual(cleared_thread, new_thread, "Once the goal is cleared, follow-ups rotate again.")
        self.assertTrue(turn_ending(cleared_message)["userMessage"].startswith("<playhouse-handoff-context>"))

        self.assert_success(self.call_cli("conversation", "context-mode", task_id, "set", "full")[0])
        third_message = "Confirm the estimate."
        send(third_message)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["codexThreadID"], cleared_thread,
                         "Back on full context, the task keeps its latest thread.")
        third = turn_ending(third_message)
        self.assertEqual(third["turnThreadID"], cleared_thread)
        self.assertIn(cleared_thread, fixture_history().get("threadResumes", []), "A full-context follow-up resumes the latest thread.")
        self.assertNotIn("<playhouse-handoff-context>", third["userMessage"])

        # A provider's first session in an optimized task gets the optimized seed, not the full handoff.
        claude_executable, claude_environment = self.optimized_claude_fixture("claude-fixture-optimized-after-switch")
        both = {**environment, **claude_environment}
        self.assert_success(self.call_cli("conversation", "context-mode", task_id, "set", "optimized")[0])
        self.assert_success(self.call_cli("conversation", "provider", task_id, "set", "claude", extra_environment=both)[0])
        switch_message = "Claude, take over from here."
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", switch_message, extra_environment=both)[0])
        switched = self.claude_turn_ending(claude_executable, switch_message)
        self.assertFalse(switched["resumed"])
        self.assertTrue(switched["userText"].startswith("<playhouse-handoff-context>\nPlayhouse optimized context"),
                        "The new provider's first session gets the optimized seed.")
        self.assertIn(f"@1: {first_message}", switched["userText"])
        self.assertIn(f": {third_message}", switched["userText"], "The seed lists the messages Codex answered.")
        self.assertNotIn("continued with another assistant while you were not active", switched["userText"],
                         "The optimized seed replaces the full provider-switch handoff.")

    # case-contract: test_conversation_read_positions_messages_and_tools | conversation outline and conversation read share one numbering of a task's whole conversation: messages take whole-number positions from 1 in order (the user's message, the agent's commentary, its final answer) and each tool call takes a decimal position under the message it followed, such as 2.1. The outline reports totals and, for each turn, its user message, agent message and tool-call counts, its final answer position and whether it ran in Plan mode. read --at returns exactly the listed entries with their kind and text, a range returns messages only unless --include-tools adds the tool calls with their title and status, and --kinds final lists every turn's final answer without the work before it. A position that is not a number, a position past the end, a range whose start follows its end, --at combined with a range, and an unknown kind are each rejected with a clear error.
    def test_conversation_read_positions_messages_and_tools(self):
        executable, environment = self.optimized_claude_fixture("claude-fixture-conversation-read", report_outcome=True)
        task_id = self.create_task(title="Conversation positions", provider="claude")["id"]
        first_message = "Inspect the readme for the positions check."
        second_message = "Reply briefly for the positions check."
        for message, extra in ((first_message, ["--mode", "plan"]), (second_message, [])):
            self.assert_success(self.call_cli(
                "conversation", "send", task_id, "--message", message, *extra, extra_environment=environment
            )[0])

        outline = self.assert_success(self.call_cli("conversation", "outline", task_id)[0])
        self.assertEqual(outline["totalTurns"], 2, outline)
        first_turn, second_turn = outline["turns"]
        self.assertEqual(first_turn["userPositions"], ["1"])
        self.assertEqual(first_turn["agentMessages"], 1, "The commentary before the answer is the turn's one agent message.")
        self.assertEqual(first_turn["toolCalls"], 2, "The Read call and the outcome report are the turn's tool calls.")
        self.assertTrue(first_turn["plan"])
        self.assertEqual(first_turn["finalAnswerPositions"], ["3"])
        self.assertEqual(outline["latestPlanPosition"], "3")
        self.assertEqual(second_turn["userPositions"], ["4"])
        self.assertFalse(second_turn["plan"])
        self.assertEqual(outline["latestFinalAnswerPosition"], second_turn["finalAnswerPositions"][-1])
        self.assertEqual(outline["totalMessages"], int(second_turn["lastPosition"]))
        self.assertEqual(outline["totalToolCalls"], first_turn["toolCalls"] + second_turn["toolCalls"])

        picked = self.assert_success(self.call_cli("conversation", "read", task_id, "--at", "1,3")[0])
        self.assertEqual([(entry["position"], entry["kind"]) for entry in picked["entries"]], [("1", "user"), ("3", "plan")])
        self.assertEqual(picked["entries"][0]["text"], first_message)
        self.assertEqual(picked["entries"][1]["text"], "Inspection done: the workspace is ready.")
        self.assertEqual(picked["totalMessages"], outline["totalMessages"])
        self.assertEqual(picked["totalToolCalls"], outline["totalToolCalls"])

        messages = self.assert_success(self.call_cli("conversation", "read", task_id, "--from", "1", "--to", "3")[0])["entries"]
        self.assertEqual([entry["position"] for entry in messages], ["1", "2", "3"], "A range holds messages only by default.")
        self.assertEqual(messages[1]["kind"], "agent")
        self.assertEqual(messages[1]["text"], "I'll inspect the workspace first.")
        with_tools = self.assert_success(self.call_cli(
            "conversation", "read", task_id, "--from", "1", "--to", "3", "--include-tools"
        )[0])["entries"]
        tools = [entry for entry in with_tools if entry["kind"] == "tool"]
        self.assertEqual(len(tools), 2)
        self.assertTrue(all("." in entry["position"] for entry in tools), "Tool calls take decimal positions.")
        self.assertEqual([entry["position"] for entry in tools], ["2.1", "2.2"],
                         "The Read call follows the commentary, message 2, and the outcome report follows it.")
        self.assertIn("README.md", tools[0]["title"])
        self.assertTrue(tools[0]["status"])
        self.assertEqual([entry["position"] for entry in with_tools if entry["kind"] != "tool"], ["1", "2", "3"])
        positions = [entry["position"] for entry in with_tools]
        self.assertLess(positions.index("2.1"), positions.index("3"), "A tool call sits between its message and the next.")
        single_tool = self.assert_success(self.call_cli("conversation", "read", task_id, "--at", "2.1")[0])["entries"]
        self.assertIn("README.md", single_tool[0]["title"])

        finals = self.assert_success(self.call_cli("conversation", "read", task_id, "--kinds", "final,plan")[0])["entries"]
        self.assertEqual([entry["position"] for entry in finals],
                         first_turn["finalAnswerPositions"] + second_turn["finalAnswerPositions"])
        self.assertEqual({entry["kind"] for entry in finals}, {"plan", "final"})

        for arguments, code, fragment in (
            (["--at", "two"], "invalid_argument", "is not a conversation position"),
            (["--at", "999"], "not_found", "Nothing is at position 999"),
            (["--from", "999"], "not_found", "past the end of the conversation"),
            (["--from", "3", "--to", "1"], "invalid_argument", "comes after"),
            (["--at", "1", "--from", "1"], "invalid_argument", "choose one"),
            (["--kinds", "thinking"], "invalid_argument", "Unknown entry kind"),
        ):
            # The CLI exits 3 when the bridge reports something not found, 2 for invalid input.
            failed, _ = self.call_cli("conversation", "read", task_id, *arguments,
                                      expected_status=3 if code == "not_found" else 2)
            self.assert_failure(failed, code)
            self.assertIn(fragment, failed["error"]["message"])

    # case-contract: test_optimized_context_steer_and_queued_follow_ups | With optimized context on, a steer joins the running turn in that turn's own session instead of starting a new one, and follow-ups queued while the turn runs are each delivered afterwards in a fresh seeded session of their own, including the second one, which was queued against a session the first follow-up replaced, so no queued follow-up is stranded. The queued follow-ups are listed while they wait. The context mode is one setting shared by every board task, reported by task get and conversation context-mode: turning it on in one task turns it on in another task, including one created afterwards, turning it off there turns it off in the first task too, and it survives a restart (of the daemon from the CLI, of the app in the window, where the button is still on in both tasks); an unknown mode is rejected, and the standalone chat, which pages its own context, has no context mode to set and no Optimized context button in its composer.
    def test_optimized_context_steer_and_queued_follow_ups(self):
        executable, environment = self.optimized_claude_fixture("claude-fixture-optimized-steer-queue", report_outcome=True)
        task_id = self.create_task(title="Optimized steer and queue", provider="claude")["id"]
        rejected, _ = self.call_cli("conversation", "context-mode", task_id, "set", "compact", expected_status=2)
        self.assert_failure(rejected, "invalid_argument")
        self.assertIn("full, optimized", rejected["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["conversationContextMode"], "full")
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        chat_rejected, _ = self.call_cli("conversation", "context-mode", chat_id, "set", "optimized", expected_status=2)
        self.assert_failure(chat_rejected, "invalid_argument")
        self.assertIn("already splits its context into pages", chat_rejected["error"]["message"])

        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Start the conversation.", extra_environment=environment
        )[0])
        self.assert_success(self.call_cli("conversation", "context-mode", task_id, "set", "optimized")[0])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["conversationContextMode"], "optimized")
        # One setting shared by every board task: a task created afterwards starts optimized too.
        other_id = self.create_task(title="Optimized shared by another task", provider="claude")["id"]
        self.assertEqual(self.assert_success(self.call_cli("task", "get", other_id)[0])["conversationContextMode"], "optimized",
                         "Optimized context is on for another task once turned on in one.")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "context-mode", other_id)[0])["mode"], "optimized")

        held_message = "Hold for a steer while optimized."
        Path(str(executable) + ".steer-answer-pause").write_text("Hold the steered answer.\n", encoding="utf-8")
        command = ["conversation", "send", task_id, "--message", held_message]
        process = self.start_cli(*command, extra_environment=environment)
        try:
            ready = Path(str(executable) + ".steer-ready")
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not ready.exists() and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The held turn should be waiting for a steer.")
            held_session = self.assert_success(self.call_cli("task", "get", task_id)[0])["claudeSessionID"]
            steered = self.assert_success(self.call_cli(
                "conversation", "steer", task_id, "--message", "Steer: keep it short.", extra_environment=environment
            )[0])
            self.assertTrue(steered["accepted"])
            self.assertFalse(steered.get("queued", False), "A steer joins the running turn.")
            for text in ("First queued follow-up.", "Second queued follow-up."):
                self.assert_success(self.call_cli(
                    "conversation", "queue", task_id, "--message", text, extra_environment=environment
                )[0])
            waiting = [item["text"] for item in self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0])]
            self.assertEqual(waiting, ["First queued follow-up.", "Second queued follow-up."], "The queued follow-ups are listed while they wait.")
            answer_ready = Path(str(executable) + ".steer-answer-ready")
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not answer_ready.exists():
                time.sleep(0.02)
            self.assertTrue(answer_ready.exists(), "The steer reached the held turn.")
            Path(str(executable) + ".steer-answer-release").write_text("Release.\n", encoding="utf-8")
            self.assert_success(self.finish_cli(process, command)[0])
        finally:
            if process.poll() is None:
                Path(str(executable) + ".steer-answer-release").write_text("Release.\n", encoding="utf-8")
                process.communicate(timeout=30)

        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0]):
            time.sleep(0.1)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0]), [],
                         "Every queued follow-up is delivered, none stranded on a replaced session.")
        held = self.claude_turn_ending(executable, held_message)
        self.assertEqual(held["sessionID"], held_session)
        # A seed legitimately repeats the steer; what matters is that no turn was sent for it.
        sessions_with_steer = [turn for turn in self.claude_fixture_turns(executable)
                               if (turn.get("userText") or "").split("</playhouse-handoff-context>")[-1].strip()
                               == "Steer: keep it short."]
        self.assertEqual(sessions_with_steer, [], "The steer is never sent as a turn of its own.")
        first = self.claude_turn_ending(executable, "First queued follow-up.")
        second = self.claude_turn_ending(executable, "Second queued follow-up.")
        self.assertEqual(len({held_session, first["sessionID"], second["sessionID"]}), 3,
                         "Each queued follow-up starts its own fresh session.")
        for turn in (first, second):
            self.assertFalse(turn["resumed"])
            self.assertIn(f"{held_message}", turn["userText"], "The seed lists the earlier user messages.")
        self.assertIn("(steer): Steer: keep it short.", second["userText"], "The seed marks a steer the user sent.")
        self.assertIn("First queued follow-up.", second["userText"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["claudeSessionID"], second["sessionID"])

        # The mode is saved with the task, so a new daemon reads it back after the old one dies.
        private = self.restart_service_environment("claude", executable)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "context-mode", task_id, extra_environment=private)[0])["mode"], "optimized")
        self.kill_daemon(private)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "context-mode", task_id, extra_environment=private)[0])["mode"], "optimized",
                         "Optimized context survives a daemon restart.")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "context-mode", other_id, extra_environment=private)[0])["mode"], "optimized",
                         "The shared setting survives a daemon restart for every task.")
        # Turning it off in the other task turns it off in the first one as well.
        self.assert_success(self.call_cli("conversation", "context-mode", other_id, "set", "full", extra_environment=private)[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "context-mode", task_id, extra_environment=private)[0])["mode"], "full",
                         "Turning optimized context off in one task turns it off in every task.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id, extra_environment=private)[0])["conversationContextMode"], "full")

    # case-contract: test_conversation_open_reads_reconciled_history_and_shows_loading | Opening a task reads its newest history page and the task as that read reconciled it in one request: conversation history --include-task returns the task record beside the messages, which a plain read leaves out, so a submitted prompt whose turn never started comes back from that read as Waiting Response with the prompt in its saved draft, while a task that doesn't exist fails as not found with no record. While the opening read hasn't answered (held by PLAYHOUSE_E2E_HISTORY_READ_DELAY_SECONDS), the transcript shows Loading conversation… and never the empty conversation prompt; once it answers the stored messages replace the loading state, and a task with no messages shows its empty conversation prompt only then. A brand-new task shows its empty state at once, never the loading state, and the standalone chat opens through the same read: its opening read returns the chat beside its messages, and the chat shows the loading state until they arrive. Opening is shared presentation over one daemon read, so one representative provider (Codex) covers it.
    def test_conversation_open_reads_reconciled_history_and_shows_loading(self):
        env = self.install_codex_fixture("codex-fixture-open-history-success")
        task_id = self.create_task(title="Opened history", roots=[self.primary])["id"]
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Say hello.", extra_environment=env)[0])
        plain = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertNotIn("task", plain, "A plain read returns only the conversation.")
        self.assertIn("assistant", [message["role"] for message in plain["messages"]])
        # The read a window makes when it opens the task, held as long as the test asks.
        held = {**env, "PLAYHOUSE_E2E_HISTORY_READ_DELAY_SECONDS": "1"}
        started = time.monotonic()
        opened = self.assert_success(self.call_cli(
            "conversation", "history", task_id, "--limit", "80", "--defer-images", "--include-task", extra_environment=held
        )[0])
        self.assertGreaterEqual(time.monotonic() - started, 1, "The test delay holds the opening read.")
        self.assertEqual([message["text"] for message in opened["messages"]], [message["text"] for message in plain["messages"]])
        stored = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual((opened["task"]["id"], opened["task"]["status"]), (task_id, stored["status"]), "The read returns the task beside its messages.")
        # The standalone chat opens through the same read.
        chat_id = self.assert_success(self.call_cli("chat", "open")[0])["id"]
        self.assert_success(self.call_cli("conversation", "send", chat_id, "--message", "Say hello in the chat.", extra_environment=env)[0])
        chat = self.assert_success(self.call_cli("conversation", "history", chat_id, "--include-task", extra_environment=held)[0])
        self.assertIn("Say hello in the chat.", [message["text"] for message in chat["messages"]])
        self.assertIn("assistant", [message["role"] for message in chat["messages"]])
        self.assertEqual(chat["task"]["id"], chat_id, "A chat's opening read returns the chat beside its messages.")

        # A submitted prompt whose turn never started is reconciled by the same read.
        never_started = self.create_task(title="Opened never-started prompt")["id"]
        submitted = "Submitted before Playhouse restarted."
        self.assert_success(self.call_cli("task", "draft", never_started, "--text", "")[0])
        self.assert_success(self.call_cli(
            "task", "prompt", never_started, "--text", submitted, "--status", "In Progress", "--submitted", "true"
        )[0])
        reopened = self.assert_success(self.call_cli("conversation", "history", never_started, "--include-task")[0])
        self.assertEqual(reopened["messages"], [], "A task with no messages has an empty conversation.")
        recovered = reopened["task"]
        self.assertEqual(recovered["status"], "Waiting Response")
        self.assertIsNone(recovered.get("pendingSubmittedPrompt"))
        self.assertEqual(recovered["savedPrompt"], submitted)
        self.assertTrue(recovered["hasUnsentDraft"])
        self.assertEqual(self.assert_success(self.call_cli("task", "get", never_started)[0])["status"], "Waiting Response",
                         "The read saved the status it reconciled.")
        # Opening a task that doesn't exist fails without a task record.
        missing, _ = self.call_cli("conversation", "history", "A8AC713C-BDD7-4B54-9B4A-6D6CCD7F957C", "--include-task", expected_status=3)
        self.assert_failure(missing, "not_found")
        self.assertNotIn("result", missing, "A failed opening read returns no task.")

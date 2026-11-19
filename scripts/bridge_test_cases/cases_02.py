from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases02:
    # case-contract: test_standalone_chat_separate_model_and_pages_round_trip | The Chat button opens the standalone chat — its own model rather than a board task — in a sliding sidebar that never appears on the board, task commands cannot reach it by ID, and the bridge rejects any attempt to add a repository or worktree root to it. The GUI composer works without a configured repository parent and omits task status, repository controls, the Changes sidebar, and the no-repository-selected banner. Its CLI page close-turn signal keeps a continuing reply on the active page and starts a new titled page on a topic change, a completed turn's user and assistant messages persist onto the active page without leaking onto other pages, and pages are findable by search. Each page is also stored in a separate atomic JSON file in a discoverable archive directory; pages already present before file archiving are backfilled once, and each file tracks current metadata and messages. A turn that omits close-turn is tracked as missed, then a background low-effort Luna fallback rejects one malformed classification and retries, moves both messages to its correctly titled page, keeps page evaluation visually quiet while the primary answer remains usable, then updates the transcript separator with the title when classification completes; a following send waits for that decision, and preserves chronological order on a later append. An explicit page start during a pending fallback cancels its stale result, keeps the missed turn on its original page, and clears the warning. If all helper results are invalid, the pending decision remains durable, blocks the next provider send, and retries after the helper recovers; the UI keeps the unresolved state visually quiet and sends successfully once recovery completes. Earlier pages stay visible in the transcript after their page session rotates, and a board task conversation rejects a chat page as turn context. While a chat turn is held active, queuing a follow-up on the chat resolves the chat rather than a board task and the queued message can be removed, and selecting the provider the chat already uses returns the chat unchanged instead of failing. The chat's own turn state changes (In Progress, then Waiting Response) during a send, and it never renders as a card on the visible Kanban board in any state. A chat turn that ran close-turn gets no nudge, and a Codex chat turn that skipped it gets exactly one nudge through the shared recovery loop, asking for close-turn on its reply and never for a task outcome, because the chat has no board status; its developer instructions teach it that task language means Playhouse's own board and give it the Playhouse task CLI, and they never ask it to write the page title into its visible answer. Opening a board task while the chat sidebar is showing replaces it with that task's conversation view instead of showing both at once, and returning to the board reveals the chat sidebar again, with the chat's own model left untouched by the unrelated task. The visible chat panel opens at full board-content height, overlaps the logo header and narrow board sidebar, and hides the covered branding and sidebar controls from accessibility navigation while open; it raises the board's minimum width by the chat panel width, so the window grows to keep the shifted columns visible; it pushes the columns to the panel’s right edge; closing chat reveals the sidebar while the window keeps its grown width, and the columns center in the board, now wider than they are. Dragging the chat sidebar's right border resizes it, between a 320-point minimum and the larger of its default width and the screen width the board's minimum width leaves free; at that minimum the composer keeps inside the chat, its provider, model and send moving to a row under its actions, while a task's wider composer keeps them on the actions' row, and reopening the sidebar, even after an app relaunch, keeps the dragged width. The border's grab strip extends only out over the board, never over the transcript's scroller along its inner side, so pressing and dragging just inside the border leaves the width unchanged; hovering the border shows the left-right resize cursor, and hovering just inside it does not. While the edge moves, the chat keeps the width it was last laid out at, clipped to the panel, and its transcript reflows to the panel's width when the drag ends.
    def test_standalone_chat_separate_model_and_pages_round_trip(self):
        opened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(opened["title"], "Chat")
        self.assertEqual(opened["repositoryWorktrees"], [])
        self.assertEqual(opened["workspaceRoots"], [])
        chat_task_id = opened["id"]

        reopened = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(reopened["id"], chat_task_id, "Opening chat twice must reuse the same chat.")

        tasks = self.assert_success(self.call_cli("task", "list")[0])["tasks"]
        self.assertFalse(
            any(task["id"] == chat_task_id for task in tasks),
            "The standalone chat must never appear in board.list/task.list.",
        )

        # A board task existing (and, in the GUI, being opened to cover the chat sidebar) must
        # not disturb the chat's own model — the two are separate records, not a shared view state.
        covering_task = self.assert_success(
            self.call_cli("task", "create", "--title", "Covers standalone chat", "--prompt", "Fixture task description.")[0]
        )
        reopened_chat = self.assert_success(self.call_cli("chat", "open")[0])
        self.assertEqual(reopened_chat["id"], chat_task_id, "An unrelated board task must not affect the chat identity.")
        self.assertEqual(reopened_chat["title"], "Chat")
        refreshed_task = self.assert_success(self.call_cli("task", "get", covering_task["id"])[0])
        self.assertEqual(refreshed_task["id"], covering_task["id"])
        self.assertTrue(
            self.assert_success(self.call_cli("task", "delete", covering_task["id"])[0])["deleted"],
            "Clean up the covering task so later board-emptiness assertions in this case stay valid.",
        )

        # The chat is its own model, not a task, so task commands cannot reach it at all.
        # This is the separation itself, not a filter that could be forgotten somewhere.
        response, _ = self.call_cli("task", "get", chat_task_id, expected_status=3)
        self.assert_failure(response, "not_found")
        response, _ = self.call_cli("task", "move", chat_task_id, "Done", expected_status=3)
        self.assert_failure(response, "not_found")
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        self.assertIsNone(self.assert_success(self.call_cli("settings", "get")[0])["defaultParentFolder"])

        kyoto = self.assert_success(self.call_cli("chat", "page", "new", "--title", "Trip to Kyoto")[0])["page"]
        self.assertEqual(kyoto["title"], "Trip to Kyoto")
        self.assertEqual(kyoto["messageCount"], 0)

        continued = self.assert_success(
            self.call_cli("chat", "page", "close-turn", chat_task_id, "--continues", "true")[0]
        )["page"]
        self.assertEqual(continued["id"], kyoto["id"], "Continuing must append to the already-active page.")

        recipes = self.assert_success(
            self.call_cli(
                "chat", "page", "close-turn", chat_task_id,
                "--continues", "false", "--new-title", "Dinner recipes",
            )[0]
        )["page"]
        self.assertNotEqual(recipes["id"], kyoto["id"], "A topic change must start a new page.")
        self.assertEqual(recipes["title"], "Dinner recipes")

        self.call_cli(
            "chat", "page", "close-turn", chat_task_id, "--continues", "false",
            expected_status=2,
        )

        page_listing = self.assert_success(self.call_cli("chat", "page", "list")[0])
        pages = page_listing["pages"]
        self.assertEqual({page["id"] for page in pages}, {kyoto["id"], recipes["id"]})
        archive_directory = self.data_directory / "StandaloneChat-Pages"
        self.assertEqual(page_listing["archiveDirectory"], str(archive_directory))
        self.assertEqual(
            {path.stem for path in archive_directory.glob("*.json")},
            {kyoto["id"], recipes["id"]},
            "Every page should have a separate JSON file with its page ID as the filename.",
        )
        # Recreate the pre-archive database state: pages exist, but the one-time
        # export migration marker does not. The next manager open must backfill.
        with sqlite3.connect(self.data_directory / "StandaloneChat-v1.sqlite") as connection:
            connection.execute("DELETE FROM chat_archive_migrations WHERE version = 1")
        (archive_directory / f"{kyoto['id']}.json").unlink()
        self.assert_success(self.call_cli("chat", "page", "list")[0])
        self.assertTrue((archive_directory / f"{kyoto['id']}.json").is_file(), "Opening a pre-archive database should backfill missing page files once.")
        for page in pages:
            archive = json.loads((archive_directory / f"{page['id']}.json").read_text(encoding="utf-8"))
            self.assertEqual(archive["page"]["title"], page["title"])
            self.assertEqual(archive["messages"], [])

        matches = self.assert_success(self.call_cli("chat", "page", "search", "Kyoto")[0])["matches"]
        self.assertTrue(
            any(match["page"]["id"] == kyoto["id"] for match in matches),
            "Searching the old page's title should find it even after a newer page is active.",
        )

        read_back = self.assert_success(self.call_cli("chat", "page", "read", kyoto["id"])[0])
        self.assertEqual(read_back["page"]["id"], kyoto["id"])
        self.assertEqual(read_back["messages"], [])

        # A real provider turn that continues the active page ("Dinner recipes") must persist
        # both the user's message and the assistant's reply into that page, not just bookkeeping.
        self.complete_standalone_chat_fixture_turn(chat_task_id, "What's a good side dish?", continues=True, executable_name="codex-fixture-chat-unique-turns-hold-release")
        recipes_archive_path = archive_directory / f"{recipes['id']}.json"
        recipes_archive = json.loads(recipes_archive_path.read_text(encoding="utf-8"))
        self.assertEqual(recipes_archive["page"]["title"], "Dinner recipes")
        self.assertTrue(any(message["text"] == "What's a good side dish?" for message in recipes_archive["messages"]))
        recipes_messages = self.assert_success(self.call_cli("chat", "page", "read", recipes["id"])[0])["messages"]
        self.assertTrue(
            any(message["role"] == "user" and message["text"] == "What's a good side dish?" for message in recipes_messages),
            "The user's message should be persisted on the page the agent's close-turn call selected.",
        )
        self.assertTrue(
            any(message["role"] == "assistant" and message["text"] for message in recipes_messages),
            "The assistant's reply should also be persisted on that page.",
        )
        # A send moves the chat's own turn state away from Backlog. That state used to belong to
        # a hidden BoardTask, which is how the chat leaked onto the visible Kanban board; it now
        # lives on the chat's own model, so no status value can put it in a board column.
        chat_turn_state = self.assert_success(self.call_cli("chat", "open")[0])["status"]
        self.assertIn(chat_turn_state, ["In Progress", "Waiting Response"], "A completed send should move the chat's own turn state.")
        self.assertEqual(
            self.assert_success(self.call_cli("task", "list")[0])["tasks"], [],
            "The standalone chat must stay absent from task/board listing in every turn state.",
        )
        # A chat turn that ran close-turn is settled, so no nudge follows it.
        chat_fixture_history = json.loads(
            Path(str(self.data_directory / "codex-fixture-chat-unique-turns-hold-release") + ".history").read_text(encoding="utf-8")
        )
        self.assertTrue(chat_fixture_history.get("turns"), "The chat fixture should have recorded its turns.")
        self.assertFalse(
            any("playhouse internal outcome nudge:" in (turn.get("userMessage") or "").lower() for turn in chat_fixture_history["turns"]),
            "A standalone chat turn that ran close-turn must not get a nudge.",
        )
        # The chat must know it is Playhouse's own chat and own the board through the CLI,
        # instead of reaching for an unrelated task tool that the user can never see.
        chat_instructions = chat_fixture_history.get("threadStartDeveloperInstructions") or ""
        self.assertIn("task create", chat_instructions, "The chat must be taught the Playhouse task CLI.")
        self.assertIn("they always mean Playhouse", chat_instructions)
        self.assertIn("`task create` requires --prompt", chat_instructions, "The chat must create tasks with a full description.")
        # Its capabilities come from the CLI's own help, never from a copied command list that
        # drifts from the CLI, and it may call something impossible only after checking help.
        self.assertIn(f"'{self.cli}' help --for chat", chat_instructions)
        self.assertIn("Say that something isn't possible only after its help shows no command for it.", chat_instructions)
        self.assertNotIn('task create --title "<title>"', chat_instructions)
        self.assertNotIn("say so plainly", chat_instructions)
        self.assertIn("Never start, move or schedule a task unless the user asks you to", chat_instructions)
        self.assertIn("Before you delete anything, such as a task, skill, rule or MCP server, confirm with the user.", chat_instructions)
        # Page titles reach the user as transcript separators, parsed from close-turn.
        # Assert the prohibition positively too: pinning only the old wording would let the
        # instruction come back phrased differently.
        self.assertIn("never write the page name", chat_instructions)
        self.assertNotIn("Page: <current page title>", chat_instructions)
        recipes_read = self.assert_success(self.call_cli("chat", "page", "read", recipes["id"])[0])
        self.assertEqual(recipes_read["filePath"], str(recipes_archive_path))
        recipes_archive = json.loads(Path(recipes_read["filePath"]).read_text(encoding="utf-8"))
        self.assertEqual(recipes_archive["page"]["title"], "Dinner recipes")
        self.assertEqual(
            [message["text"] for message in recipes_archive["messages"]],
            [message["text"] for message in recipes_messages],
            "The per-page file should contain the current persisted transcript.",
        )
        self.assertEqual(
            self.assert_success(self.call_cli("chat", "page", "read", kyoto["id"])[0])["messages"], [],
            "Messages from the recipes turn must not leak onto an unrelated page.",
        )

        # The compliant turn above must be reflected as compliant in chat status.
        status = self.assert_success(self.call_cli("chat", "status")[0])
        self.assertFalse(status["missedPreviousPageSignal"], "A turn that called close-turn must not be flagged as missed.")
        self.assertEqual(status["activePage"]["id"], recipes["id"])

        # Standalone chat can never gain a repository/worktree, regardless of who tries.
        self.assert_failure(
            self.call_cli("task", "repository", "add", chat_task_id, "--repo", str(self.primary), expected_status=2)[0],
            "invalid_argument",
        )

        # The primary agent omits close-turn; the cheap, background Codex fallback must
        # classify the distinct topic and move that turn onto a titled page.
        classifier_executable = self.data_directory / "codex-fixture-chat-unique-turns-hold-release"
        classifier_hold = Path(str(classifier_executable) + ".hold-classifier")
        classifier_active = Path(str(classifier_executable) + ".classifier-active")
        classifier_release = Path(str(classifier_executable) + ".classifier-release")
        classifier_active.unlink(missing_ok=True)
        classifier_release.unlink(missing_ok=True)
        classifier_hold.touch()
        self.complete_standalone_chat_fixture_turn(
            chat_task_id,
            "Tell me about Saturn's rings",
            skip_close_turn=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        # The same shared recovery loop nudges a Codex chat turn that skipped close-turn: once,
        # for the page signal, never for a task outcome.
        codex_nudges = [
            turn for turn in json.loads(Path(str(classifier_executable) + ".history").read_text(encoding="utf-8")).get("turns", [])
            if "playhouse internal outcome nudge:" in (turn.get("userMessage") or "").lower()
        ]
        self.assertEqual(len(codex_nudges), 1, "A Codex chat turn that skipped close-turn gets exactly one nudge.")
        self.assertIn(f"chat page close-turn {chat_task_id}", codex_nudges[0]["userMessage"])
        self.assertNotIn("task outcome", codex_nudges[0]["userMessage"])
        codex_visible = self.assert_success(self.call_cli(
            "conversation", "history", chat_task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])["messages"]
        self.assertTrue(
            any(message["role"] == "user" and "This is the only reminder for that reply." in message["text"] for message in codex_visible),
            "The Codex chat nudge stays in the chat transcript.",
        )
        classifier_command = ("chat", "status")
        classifier_process = self.start_cli(
            *classifier_command,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "The fixture should hold the fallback after the primary send returns.")
        # The decision lands after its turn ended; only a revision tells open windows to reread pages.
        revision_while_held = self.assert_success(self.call_cli("conversation", "runtime")[0]).get("conversationRevisions", {}).get(chat_task_id, 0)

        followup_command = ("conversation", "send", chat_task_id, "--message", "One more thought about Saturn")
        followup_turn_hold = Path(str(classifier_executable) + ".hold-release")
        followup_turn_active = Path(str(classifier_executable) + ".turn-active")
        followup_turn_release = Path(str(classifier_executable) + ".turn-release")
        followup_turn_active.unlink(missing_ok=True)
        followup_turn_release.unlink(missing_ok=True)
        followup_turn_hold.touch()
        followup_process = self.start_cli(
            *followup_command,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        try:
            time.sleep(0.2)
            self.assertIsNone(followup_process.poll(), "A follow-up turn must wait until the pending page decision finishes.")
            pending_history = json.loads(Path(str(classifier_executable) + ".history").read_text(encoding="utf-8"))
            self.assertFalse(
                any((turn.get("userMessage") or "").startswith("One more thought about Saturn") for turn in pending_history.get("turns", [])),
                "The next provider turn must not overtake the held page classification.",
            )
        finally:
            classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, classifier_command)
        fallback_status = self.assert_success(classifier_response)
        fallback_archive_path = archive_directory / f"{fallback_status['activePage']['id']}.json"
        fallback_archive = json.loads(fallback_archive_path.read_text(encoding="utf-8"))
        self.assertEqual(fallback_archive["page"]["title"], "Saturn Rings")
        revision_after_decision = self.assert_success(self.call_cli("conversation", "runtime")[0]).get("conversationRevisions", {}).get(chat_task_id, 0)
        self.assertGreater(revision_after_decision, revision_while_held, "A late page decision should raise the chat's conversation revision.")
        self.assertTrue(any(message["text"] == "Tell me about Saturn's rings" for message in fallback_archive["messages"]))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not followup_turn_active.exists():
            time.sleep(0.02)
        self.assertTrue(followup_turn_active.exists(), "The queued follow-up should reach the fixture after classification resolves.")
        # Queuing is a conversation action, so it must resolve the chat and not look for a
        # board task. The turn is held active here, which is exactly when a follow-up queues.
        queued_in_chat = self.assert_success(
            self.call_cli("conversation", "queue", chat_task_id, "--message", "Queue this for after the chat turn.")[0]
        )
        self.assertEqual(queued_in_chat["text"], "Queue this for after the chat turn.")
        self.assertEqual(queued_in_chat["taskID"], chat_task_id)
        self.assert_success(self.call_cli("conversation", "queue-remove", chat_task_id, queued_in_chat["id"])[0])
        # Selecting the provider the chat already uses is a no-op that must return the chat.
        unchanged_provider = self.assert_success(
            self.call_cli("conversation", "provider", chat_task_id, "set", "codex")[0]
        )
        self.assertEqual(unchanged_provider["id"], chat_task_id)
        self.assertEqual(unchanged_provider["conversationProvider"], "codex")
        followup_turn_release.write_text("Release follow-up turn.\n", encoding="utf-8")
        # The follow-up skips close-turn too, so its one nudge turn is held the same way.
        deadline = time.monotonic() + 60
        while followup_process.poll() is None and time.monotonic() < deadline:
            if followup_turn_active.exists() and not followup_turn_release.exists():
                followup_turn_release.write_text("Release the follow-up's nudge turn.\n", encoding="utf-8")
            time.sleep(0.02)
        followup_response, _ = self.finish_cli(followup_process, followup_command)
        followup_turn_hold.unlink(missing_ok=True)
        followup_turn_active.unlink(missing_ok=True)
        followup_turn_release.unlink(missing_ok=True)
        self.assert_success(followup_response)
        followup_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(followup_status["missedPreviousPageSignal"])
        self.assertEqual(followup_status["activePage"]["title"], "Saturn Rings")

        self.assertFalse(fallback_status["missedPreviousPageSignal"], "The background fallback should clear the missed-signal warning after applying its classification.")
        self.assertEqual(fallback_status["activePage"]["title"], "Saturn Rings", "The fallback title should appear as soon as its result is persisted.")
        classifier_history = json.loads(Path(str(classifier_executable) + ".history").read_text(encoding="utf-8"))
        classifier_turns = classifier_history.get("turns", [])
        classifier_turns = [turn for turn in classifier_turns if (turn.get("userMessage") or "").startswith("Classify the latest user message for Playhouse's continuous chat page index.")]
        self.assertEqual(len(classifier_turns), 3, "The fallback should reject one malformed result, retry, and classify the held follow-up.")
        classifier_turn = classifier_turns[-1]
        self.assertEqual(classifier_turn.get("modelID"), "gpt-6-luna", "The Codex fallback should use Luna.")
        self.assertEqual(classifier_turn.get("reasoningEffort"), "low", "The fallback must use low effort.")
        self.assertIn("Saturn Rings", self.assert_success(self.call_cli("chat", "page", "list")[0])["pages"][0]["title"])
        fallback_read = self.assert_success(self.call_cli("chat", "page", "read", fallback_status["activePage"]["id"])[0])
        fallback_archive = json.loads(Path(fallback_read["filePath"]).read_text(encoding="utf-8"))
        self.assertEqual(fallback_archive["page"]["title"], "Saturn Rings")
        missed_messages = fallback_read["messages"]
        self.assertEqual([message["text"] for message in fallback_archive["messages"]], [message["text"] for message in missed_messages])
        self.assertTrue(
            any(message["role"] == "user" and message["text"] == "Tell me about Saturn's rings" for message in missed_messages),
            "The fallback-classified turn's messages must be moved onto its new page.",
        )
        self.assertFalse(
            any(message["role"] == "user" and message["text"] == "Tell me about Saturn's rings"
                for message in self.assert_success(self.call_cli("chat", "page", "read", recipes["id"])[0])["messages"]),
            "The fallback-classified turn must not remain duplicated on the prior page.",
        )

        # Compliance resumes once the agent calls close-turn again on a later turn.
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Thanks, that's all for now.", continues=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        recovered_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(recovered_status["missedPreviousPageSignal"], "Compliance should clear once close-turn is called again.")
        recovered_messages = self.assert_success(self.call_cli("chat", "page", "read", fallback_status["activePage"]["id"])[0])["messages"]
        ordered = [message["text"] for message in recovered_messages]
        self.assertEqual(ordered, [
            "Tell me about Saturn's rings", "Answers received: Blue / fixture-secret.",
            "One more thought about Saturn", "Answers received: Blue / fixture-secret.",
            "Thanks, that's all for now.", "Answers received: Blue / fixture-secret.",
        ], "After fallback moves a turn, a later append must follow it in transcript order.")

        # Codex answers visible history from its own thread, and page sessions rotate, so the
        # transcript must restore earlier pages from the local archive instead of losing them.
        visible = self.assert_success(self.call_cli(
            "conversation", "history", chat_task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        visible_texts = [message["text"] for message in visible["messages"]]
        self.assertTrue(
            any(text.endswith("What's a good side dish?") for text in visible_texts),
            "An earlier Codex page must stay visible after its page session rotated.",
        )
        self.assertTrue(
            any(text.endswith("Thanks, that's all for now.") for text in visible_texts),
            "The live Codex page must stay visible alongside the restored earlier pages.",
        )
        # A chat page only belongs to the standalone chat, never to a board task.
        board_task = self.create_task("Context page rejection")
        self.assert_failure(self.call_cli(
            "conversation", "send", board_task["id"], "--message", "Hello",
            "--context-page", fallback_status["activePage"]["id"], expected_status=2,
        )[0], "invalid_argument")

        # An explicit page start while the fallback is in flight supersedes its
        # eventual Neptune classification without moving the old turn.
        neptune_classifier_hold = Path(str(classifier_executable) + ".hold-neptune-classifier")
        neptune_classifier_hold.touch()
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Tell me about Neptune", skip_close_turn=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        classifier_process = self.start_cli(
            "chat", "status",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "The second fallback should be held before the explicit page start.")
        explicit_page = self.assert_success(self.call_cli("chat", "page", "new", "--title", "Explicit topic")[0])["page"]
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "list")[0])["pages"][0]["id"], explicit_page["id"])
        classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, ("chat", "status"))
        self.assert_success(classifier_response)
        final_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(final_status["missedPreviousPageSignal"], "Explicit page creation should clear the missed-signal warning.")
        self.assertEqual(final_status["activePage"]["id"], explicit_page["id"], "A stale classifier must not replace an explicit page start.")
        self.assertEqual(final_status["activePage"]["title"], "Explicit topic")
        explicit_messages = self.assert_success(self.call_cli("chat", "page", "read", explicit_page["id"])[0])["messages"]
        self.assertEqual(explicit_messages, [], "The missed turn remains archived on its original page.")
        old_page_messages = self.assert_success(self.call_cli("chat", "page", "read", fallback_status["activePage"]["id"])[0])["messages"]
        self.assertTrue(any(message["text"] == "Tell me about Neptune" for message in old_page_messages))
        self.assertTrue(any(message["role"] == "assistant" for message in old_page_messages[-1:]))

        # Exhausted helper retries keep the pending turn authoritative and prevent
        # a later provider turn from overtaking it. Once the helper is healthy, retry.
        classifier_failure = Path(str(classifier_executable) + ".fail-classifier")
        classifier_failure.touch()
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Tell me about Mars", skip_close_turn=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        failed_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertTrue(failed_status["missedPreviousPageSignal"], "An invalid fallback response must leave the page decision pending.")
        blocked_response, _ = self.call_cli(
            "conversation", "send", chat_task_id, "--message", "Do not overtake Mars",
            expected_status=1,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )
        self.assert_failure(blocked_response, "operation_failed")
        blocked_history = json.loads(Path(str(classifier_executable) + ".history").read_text(encoding="utf-8"))
        self.assertFalse(
            any((turn.get("userMessage") or "") == "Do not overtake Mars" for turn in blocked_history.get("turns", [])),
            "An unresolved page decision must prevent the rejected prompt from reaching Codex.",
        )
        classifier_failure.unlink()
        recovered_status = self.assert_success(self.call_cli(
            "chat", "status",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(classifier_executable)},
        )[0])
        self.assertFalse(recovered_status["missedPreviousPageSignal"])
        self.assertEqual(recovered_status["activePage"]["title"], "Mars")
        self.complete_standalone_chat_fixture_turn(
            chat_task_id, "Another thought about Mars", continues=True,
            executable_name="codex-fixture-chat-unique-turns-hold-release",
        )
        recovered_messages = self.assert_success(self.call_cli("chat", "page", "read", recovered_status["activePage"]["id"])[0])["messages"]
        self.assertFalse(any(message["text"] == "Do not overtake Mars" for message in recovered_messages))
        self.assertIn("Another thought about Mars", [message["text"] for message in recovered_messages])
    # case-contract: test_standalone_chat_page_sessions_isolate_context | Each standalone chat page is its own provider session: the first turn of a page starts a fresh session carrying the system prompt, which explains the page metadata header and tells the agent to run chat page read only for a page the message continues, plus a Playhouse page metadata header, never a User line, that names the current page by title and ID with a shortened excerpt of its latest exchange and lists recent pages newest first by title and ID only. Later turns on that page resume it without repeating the header, and a different page never shares it, so an earlier page's turns never reach a later page. An annotation that quotes an earlier page carries that whole page into the current turn, marked as a Playhouse page. A page whose latest answer is long sends only the start of that answer, and the agent loads the whole page itself with the real chat page read command. Rotating sessions still leaves every page's messages visible in the transcript.
    def test_standalone_chat_page_sessions_isolate_context(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "claude-fixture-chat-page-sessions"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        history_path = Path(str(executable) + ".history")

        def wait_for_page(title):
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
                if not status["missedPreviousPageSignal"] and status["activePage"]["title"] == title:
                    return status
                time.sleep(0.1)
            self.fail(f"The chat never settled on page {title!r}.")

        def send(message, *extra):
            self.assert_success(self.call_cli(
                "conversation", "send", chat_id, "--message", message, *extra, extra_environment=environment
            )[0])

        def answer_turns():
            turns = json.loads(history_path.read_text(encoding="utf-8"))["turns"]
            return [
                turn for turn in turns
                if not (turn.get("userText") or "").startswith("Classify the latest user message")
            ]

        def turn_for(message):
            matches = [turn for turn in answer_turns() if (turn.get("userText") or "").endswith(message)]
            self.assertTrue(matches, f"The fixture never received a turn ending with {message!r}.")
            return matches[-1]

        send("Tell me about volcanoes")
        volcanoes = wait_for_page("Volcanoes")["activePage"]
        send("Tell me about Saturn's rings")
        saturn = wait_for_page("Saturn Rings")["activePage"]
        self.assertNotEqual(saturn["id"], volcanoes["id"])
        send("One more thought about Saturn")
        wait_for_page("Saturn Rings")

        first = turn_for("Tell me about volcanoes")
        second = turn_for("Tell me about Saturn's rings")
        third = turn_for("One more thought about Saturn")
        # The turn that opens a page still answers in the page it was sent into; only once the
        # classifier moves it does the next turn get that new page's own session.
        self.assertEqual(first["sessionID"], second["sessionID"], "One page answers in one session.")
        self.assertNotEqual(
            third["sessionID"], first["sessionID"],
            "A different page must never share another page's provider session.",
        )
        for turn in (first, third):
            self.assertFalse(turn["resumed"], "A page's first turn starts that page's own session.")
            instructions = turn["arguments"][turn["arguments"].index("--append-system-prompt") + 1]
            self.assertIn(
                "chat page close-turn", instructions,
                "Every page session must carry the standalone chat system prompt.",
            )
        self.assertTrue(second["resumed"], "A turn sent into an existing page resumes its session.")
        third_instructions = third["arguments"][third["arguments"].index("--append-system-prompt") + 1]
        self.assertIn("Playhouse page metadata block", third_instructions,
                      "The chat instructions explain the page metadata header.")
        self.assertIn("chat page read <page-id> to load that page before answering", third_instructions,
                      "The chat instructions tell the agent to load a continued page itself.")
        self.assertIn(
            "User: Tell me about Saturn's rings", third["userText"],
            "A fresh page session gets its own page's latest exchange as an excerpt.",
        )
        self.assertIn("Playhouse chat page metadata, not part of the user's message.", third["userText"])
        self.assertIn(f'Current page: "Saturn Rings" (id: {saturn["id"]}, ', third["userText"],
                      "The header names the current page by title and ID.")
        self.assertIn(f'Recent pages, newest first:\n- "Volcanoes" (id: {volcanoes["id"]}, ', third["userText"],
                      "The header lists earlier pages by title and ID.")
        self.assertNotIn("[Page:", third["userText"], "A page title is never written as a user line.")
        self.assertNotIn(
            "Tell me about volcanoes", third["userText"],
            "An earlier page's turns are never sent as context for a later page, only its title and ID.",
        )
        self.assertNotIn("Tell me about volcanoes", second["userText"])

        # A later turn on the same page resumes its session without repeating the page block.
        send("Another thought about Mars")
        wait_for_page("Saturn Rings")
        fourth = turn_for("Another thought about Mars")
        self.assertEqual(fourth["sessionID"], third["sessionID"], "The same page keeps one session.")
        self.assertTrue(fourth["resumed"], "A continuing turn resumes the page's session.")
        self.assertNotIn(
            "<playhouse-handoff-context>", fourth["userText"],
            "A resumed page session already holds its page, so it must not repeat the context block.",
        )

        # An annotation that quotes an earlier page carries only that page into this turn.
        send("What did we say before?", "--context-page", volcanoes["id"])
        wait_for_page("Saturn Rings")
        annotated = turn_for("What did we say before?")
        self.assertIn(
            "User: Tell me about volcanoes", annotated["userText"],
            "A page referenced by an annotation travels whole with the turn that quotes it.",
        )
        self.assertIn(f'Playhouse page "Volcanoes" (id: {volcanoes["id"]}, ', annotated["userText"],
                      "An attached page is marked as a Playhouse page, not as a user line.")
        self.assertNotIn("[Page:", annotated["userText"])

        # A page whose answer is long: the next turn, in that page's fresh session, gets only a
        # shortened excerpt of the latest exchange, and loads the whole page with chat page read.
        send("Open a lava page long-answer-page:Lava-Flows")
        lava = wait_for_page("Lava Flows")["activePage"]
        recall = f"recall-earlier-pages page-id:{lava['id']}"
        send(recall)
        wait_for_page("Lava Flows")
        recalled = turn_for(recall)
        self.assertFalse(recalled["resumed"], "The new page's first turn starts that page's own session.")
        header = recalled["userText"]
        self.assertIn(f'Current page: "Lava Flows" (id: {lava["id"]}, ', header)
        self.assertIn(f'- "Saturn Rings" (id: {saturn["id"]}, ', header, "Recent pages are listed newest first.")
        self.assertLess(header.index('- "Saturn Rings"'), header.index('- "Volcanoes"'))
        self.assertIn("Claude: Lava Flows full answer: lava detail", header, "The excerpt keeps the start of the latest answer.")
        self.assertIn(" […]", header, "A long answer is shortened in the excerpt.")
        self.assertNotIn("END-OF-LONG-ANSWER", header, "The whole answer is not sent until the agent reads the page.")
        self.assertNotIn("Lava Flows opening note.", header, "Only the latest exchange is excerpted.")
        self.assertNotIn("One more thought about Saturn", header, "Another page's turns never travel with the header.")
        self.assertLess(len(header) - len(recall), 3_500, "The header stays small however long the page is.")
        reads = [item for item in recalled["reportCommands"] if " chat page read " in item["command"]]
        self.assertEqual(len(reads), 1, "The agent loads the continued page itself.")
        loaded = json.loads(reads[0]["output"])["result"]
        self.assertEqual(loaded["page"]["id"], lava["id"])
        self.assertTrue(any(message["text"].endswith("END-OF-LONG-ANSWER") for message in loaded["messages"]),
                        "chat page read returns the whole page, long answer included.")

        # Rotating sessions must not hide earlier pages from the visible transcript.
        visible = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        texts = [message["text"] for message in visible["messages"]]
        self.assertTrue(any(text.endswith("Tell me about volcanoes") for text in texts))
        self.assertTrue(any(text.endswith("One more thought about Saturn") for text in texts))
    # case-contract: test_standalone_chat_answer_stays_final_around_close_turn | A standalone chat reports no task outcome, so it ends every turn with Playhouse's own chat page close-turn signal. When Claude runs that signal after its answer and before its closing line, the answer and closing line form one final answer, not commentary, in the streamed final answer, fresh CLI/XPC history, and the visible transcript, so the response is never left buried inside the collapsed Worked for disclosure; text written before an ordinary tool earlier in the same turn still stays commentary there, and the close-turn command really runs and succeeds. The chat instructions ask for close-turn before the final reply, which must end the turn, keep exactly one real close-turn per turn and no page bookkeeping in the answer, and carry no hidden escalation. A turn that runs close-turn first and answers after it shows exactly one final answer, filed onto the active page, with no nudge. When the turn ends on close-turn and Claude Code adds its own no-visible-output notice to the same turn, the notice streams once as a user-side message and stays in fresh history between the answer and what Claude writes after it, rendering as an automatic message from Claude Code rather than the user's bubble; that later text is a separate final message, so no bubble holds the answer twice, and the notice is never filed into a chat page. This classification is Claude-specific because Playhouse derives each message's phase from Claude's tool stream and only Claude Code adds such a notice inside a turn, while Codex reports the phase in its own protocol and never injects a hidden message into a turn.
    def test_standalone_chat_answer_stays_final_around_close_turn(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "claude-fixture-chat-close-turn"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]

        intent = "Let me check the newer release first."
        answer = "Confirmed: 2.1.309 registers the new model and 2.1.308 does not."
        final_answer = answer + "\n\nTell me if you want the upgrade command."

        sent, events = self.call_cli(
            "conversation", "send", chat_id, "--message", "Summarize the release notes.",
            extra_environment=environment,
        )
        self.assert_success(sent)
        self.assertEqual(
            [event["payload"]["text"] for event in events if event["type"] == "assistant_final"], [final_answer],
            "The page close-turn signal is Playhouse bookkeeping, so the answer and its closing line stay one final answer.",
        )
        progress = [event["payload"]["text"] for event in events if event["type"] == "assistant_progress"]
        self.assertFalse(any(answer in text for text in progress),
                         f"The answer must never be demoted to commentary by the close-turn signal: {progress}")
        self.assertIn(intent, progress, "Text written before an ordinary tool still stays commentary.")

        turns = [
            turn for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
            if not (turn.get("userText") or "").startswith("Classify the latest user message")
        ]
        self.assertEqual(len(turns[-1]["reportCommands"]), 1, "The fixture should run the chat page close-turn command.")
        self.assertIn(" chat page close-turn ", turns[-1]["reportCommands"][0]["command"])
        self.assertIn('"ok":true', turns[-1]["reportCommands"][0]["output"], turns[-1]["reportCommands"])

        history = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        assistant = [(message["phase"], message["text"]) for message in history["messages"] if message["role"] == "assistant"]
        self.assertEqual(assistant, [("commentary", intent), ("final_answer", final_answer)],
                         "A fresh history read keeps the answer and its closing line as one final answer.")

        status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertFalse(status["missedPreviousPageSignal"],
                         "A close-turn signal that really ran must satisfy the page signal instead of falling back to the classifier.")

        def chat_turns():
            return [
                turn for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
                if not (turn.get("userText") or "").startswith("Classify the latest user message")
            ]

        # The order the instructions now ask for: close-turn first, then the final reply. With no
        # answer pending when the signal runs, the reply after it is the turn's one final answer.
        arguments = chat_turns()[-1]["arguments"]
        instructions = arguments[arguments.index("--append-system-prompt") + 1]
        close_turn_at = instructions.find("chat page close-turn")
        self.assertGreater(close_turn_at, -1, "The chat instructions must still teach close-turn.")
        self.assertIn("before you write your final reply", instructions,
                      "The instructions must put close-turn before the final reply.")
        self.assertIn("never end a turn on a tool call", instructions)
        self.assertIn("Run exactly one close-turn per turn", instructions)
        self.assertIn("never just write it as text in your reply", instructions)
        self.assertIn("never write the page name", instructions)
        self.assertIn("previous response had no visible output but you already answered in this turn, do not repeat the answer", instructions)
        self.assertNotIn("At the end of every single turn", instructions)
        self.assertNotIn("CRITICAL, READ FIRST", instructions, "No hidden escalation is prepended to the chat instructions.")
        close_first_prompt = "Name the largest moon of Jupiter."
        close_first_answer = "Ganymede is the largest moon of Jupiter."
        sent, events = self.call_cli("conversation", "send", chat_id, "--message", close_first_prompt, extra_environment=environment)
        self.assert_success(sent)
        self.assertEqual([event["payload"]["text"] for event in events if event["type"] == "assistant_final"], [close_first_answer],
                         "The reply written after close-turn is the turn's single final answer.")
        self.assertIn('"ok":true', chat_turns()[-1]["reportCommands"][0]["output"], chat_turns()[-1]["reportCommands"])
        self.assertFalse(any("playhouse internal outcome nudge:" in (turn.get("userText") or "").lower() for turn in chat_turns()),
                         "A turn whose close-turn ran is settled, so Playhouse sends it no nudge.")
        history = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        close_first_turn = next(message["turnID"] for message in history["messages"] if message["role"] == "user" and message["text"] == close_first_prompt)
        self.assertEqual(
            [(message["role"], message.get("phase"), message["text"]) for message in history["messages"] if message.get("turnID") == close_first_turn],
            [("user", None, close_first_prompt), ("assistant", "final_answer", close_first_answer)],
            "Fresh history shows the prompt and exactly one final answer for the close-turn-first turn.",
        )
        active_page = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]
        page_messages = self.assert_success(self.call_cli("chat", "page", "read", active_page["id"], extra_environment=environment)[0])["messages"]
        self.assertEqual([message["text"] for message in page_messages if message["turnID"] == close_first_turn],
                         [close_first_prompt, close_first_answer], "The close-turn-first turn is filed onto the active page.")

        # Claude Code's own "no visible output" notice, after a turn that ended on close-turn:
        # it is recorded as an automatic message from Claude Code, and the text Claude writes
        # after it is a separate final message rather than appended to the answer.
        notice_prompt = "Name the largest moon of Saturn."
        notice_answer = "Titan is the largest moon of Saturn."
        notice_reply = "I already answered above."
        notice_text = "[Your previous response had no visible output. Please continue and produce a user-visible response.]"
        sent, events = self.call_cli("conversation", "send", chat_id, "--message", notice_prompt, extra_environment=environment)
        self.assert_success(sent)
        self.assertEqual([event["payload"]["text"] for event in events if event["type"] == "assistant_final"], [notice_answer, notice_reply],
                         "The answer and the text after Claude Code's notice stream as two finals, never merged.")
        steered = [event["payload"].get("message") for event in events if event["type"] == "steered_message"]
        self.assertEqual(steered, ["Claude Code automatic notice:\n" + notice_text], "The notice streams once, as a user-side message.")
        self.assertFalse(any(notice_text in (event["payload"].get("text") or "") for event in events if event["type"] == "assistant_progress"),
                         "The notice never streams as assistant progress.")
        history = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        notice_turn = next(message["turnID"] for message in history["messages"] if message["role"] == "user" and message["text"] == notice_prompt)
        self.assertEqual(
            [(message["role"], message.get("phase"), message["text"]) for message in history["messages"] if message.get("turnID") == notice_turn],
            [
                ("user", None, notice_prompt),
                ("assistant", "final_answer", notice_answer),
                ("user", None, "Claude Code automatic notice:\n" + notice_text),
                ("assistant", "final_answer", notice_reply),
            ],
            "Fresh history keeps the answer, Claude Code's notice and the reply as separate messages in turn order.",
        )
        self.assertFalse(any(notice_answer in message["text"] and notice_reply in message["text"] for message in history["messages"]),
                         "No bubble may hold the answer together with what Claude wrote after the notice.")
        page_messages = self.assert_success(self.call_cli("chat", "page", "read", active_page["id"], extra_environment=environment)[0])["messages"]
        self.assertEqual([message["text"] for message in page_messages if message["turnID"] == notice_turn],
                         [notice_prompt, notice_answer, notice_reply], "Claude Code's notice is never filed into a chat page.")
        self.assertFalse(any("playhouse internal outcome nudge:" in (turn.get("userText") or "").lower() for turn in chat_turns()),
                         "The notice turn ran close-turn, so it is settled and gets no Playhouse nudge.")
    # case-contract: test_standalone_chat_missed_close_turn_gets_visible_nudge | When a standalone chat turn ends without its chat page close-turn signal, Playhouse sends exactly one follow-up turn through the same unsettled-turn recovery loop task conversations use. Its prompt starts with the Playhouse nudge marker, asks for close-turn on the previous reply and never for a task outcome, and stays in the chat transcript as an automatic message from Playhouse, followed by the agent's reply. A close-turn run in that nudge settles the turn and classifies the user's turn, which moves to the new titled page without the fallback classifier; the nudge turn and its reply are never filed into a chat page or replayed into a page's seeded context. A nudge that goes unanswered is not retried, the background classifier then decides the page, the chat never gets a board status such as Blocked, and task outcome is rejected for the chat. The nudge loop, the close-turn CLI and the turn outcome store are shared by Claude and Codex, so one representative provider (Claude) covers this case, and the round-trip case shows a Codex chat turn reaching the same nudge.
    def test_standalone_chat_missed_close_turn_gets_visible_nudge(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "claude-fixture-chat-close-turn-nudge"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        prompt = "Plan a weekend hiking trip."
        answer = "Pick a loop trail under 15 km and start early."

        def chat_turns():
            return [
                turn for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
                if not (turn.get("userText") or "").startswith("Classify the latest user message")
            ]

        def nudge_turns():
            return [turn for turn in chat_turns() if "playhouse internal outcome nudge:" in (turn.get("userText") or "").lower()]

        # The turn answers but never runs close-turn, so Playhouse sends one visible nudge,
        # which the agent answers by running close-turn for that reply.
        sent, events = self.call_cli("conversation", "send", chat_id, "--message", prompt, extra_environment=environment)
        self.assert_success(sent)
        self.assertEqual([event["payload"]["text"] for event in events if event["type"] == "assistant_final"], [answer, "Filed."],
                         "The answer streams first, then the nudge's one-line reply.")
        self.assertEqual(len(nudge_turns()), 1, "A chat turn that skipped close-turn gets exactly one nudge.")
        nudge = nudge_turns()[0]
        self.assertIn(f"chat page close-turn {chat_id}", nudge["userText"], "The chat nudge asks for close-turn on the previous reply.")
        self.assertNotIn("task outcome", nudge["userText"], "A chat is never asked for a task outcome.")
        self.assertIn('"ok":true', nudge["reportCommands"][0]["output"], nudge["reportCommands"])

        history = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        visible = [(message["role"], message["text"]) for message in history["messages"]]
        nudge_messages = [text for role, text in visible if role == "user" and "Playhouse internal outcome nudge:" in text]
        self.assertEqual(len(nudge_messages), 1, "The nudge is kept in the chat transcript, where it renders as an automatic message.")
        self.assertIn("This is the only reminder for that reply.", nudge_messages[0])
        self.assertEqual(
            [(role, text) for role, text in visible if text in (prompt, answer, "Filed.") or text == nudge_messages[0]],
            [("user", prompt), ("assistant", answer), ("user", nudge_messages[0]), ("assistant", "Filed.")],
            "The transcript shows the turn, then the nudge and its reply.",
        )

        # The nudge's close-turn classifies the user's turn: it moves to the new titled page,
        # and the nudge turn itself is never filed into a page.
        status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertFalse(status["missedPreviousPageSignal"], "The nudge's close-turn settles the page decision without the fallback classifier.")
        self.assertEqual(status["activePage"]["title"], "Hiking trip")
        hiking_page = status["activePage"]
        page_messages = self.assert_success(self.call_cli("chat", "page", "read", hiking_page["id"], extra_environment=environment)[0])["messages"]
        self.assertEqual([message["text"] for message in page_messages], [prompt, answer],
                         "Only the user's turn is filed on its page, never the nudge or its reply.")
        self.assertFalse(any("Classify the latest user message" in (turn.get("userText") or "")
                             for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]),
                         "A nudge that got close-turn run leaves nothing for the fallback classifier.")
        chat_state = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["status"]
        self.assertIn(chat_state, ["In Progress", "Waiting Response"], "A chat nudge never sets a board status such as Blocked.")
        self.assert_failure(
            self.call_cli("task", "outcome", chat_id, "completed", expected_status=2, extra_environment=environment)[0],
            "invalid_argument",
        )

        # A second missed turn whose nudge goes unanswered: still only one nudge, still no
        # Blocked, and the background classifier decides the page as before. The new page's
        # fresh session is seeded with its own turn, never with the nudge or its reply.
        sent, _ = self.call_cli("conversation", "send", chat_id, "--message", "Tell me about volcanoes", extra_environment=environment)
        self.assert_success(sent)
        seeded = next(turn for turn in chat_turns() if (turn.get("userText") or "").endswith("Tell me about volcanoes"))
        self.assertIn(prompt, seeded["userText"], "The new page's session is seeded with its own turn.")
        self.assertIn(answer, seeded["userText"])
        self.assertNotIn("Playhouse internal outcome nudge:", seeded["userText"], "A nudge is never replayed into page context.")
        self.assertNotIn("Filed.", seeded["userText"], "A nudge's reply is never replayed into page context.")
        self.assertEqual(len(nudge_turns()), 2, "The second missed turn gets its own single nudge.")
        self.assertEqual(nudge_turns()[-1]["reportCommands"], [], "This nudge goes unanswered.")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
            if not status["missedPreviousPageSignal"] and status["activePage"]["title"] == "Volcanoes":
                break
            time.sleep(0.1)
        self.assertEqual(status["activePage"]["title"], "Volcanoes", "An unanswered nudge leaves the page to the fallback classifier.")
        self.assertFalse(status["missedPreviousPageSignal"])
        self.assertEqual(len(nudge_turns()), 2, "An unanswered chat nudge is not retried.")
        chat_state = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["status"]
        self.assertIn(chat_state, ["In Progress", "Waiting Response"], "An unanswered chat nudge never marks the chat Blocked.")
    # case-contract: test_standalone_chat_recalls_loaded_pages | When a standalone chat's agent loads an earlier page into its context with `chat page read`, the conversation renders one deterministic "Recalling <page title>" line per loaded page, titled from the page archive rather than from anything the agent wrote, in the order the pages were read. The lines are visible in the turn that read them without opening the Worked for disclosure, stay once the turn settles and after a later turn and a reopen, and the read commands really run and succeed so the history carries each call and the page's own title. The line is derived from Playhouse's own provider-neutral command activity (a shell call titled "Running <command>" for both Claude and Codex) and the page store, so provider selection cannot change it; one representative provider (Claude) covers the shared path.
    def test_standalone_chat_recalls_loaded_pages(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "claude-fixture-chat-recall"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        titles = ["Volcano research", "Saturn notes"]
        pages = [
            self.assert_success(self.call_cli("chat", "page", "new", "--title", title, extra_environment=environment)[0])["page"]
            for title in titles
        ]
        self.assert_success(self.call_cli("chat", "page", "new", "--title", "Current topic", extra_environment=environment)[0])

        message = "recall-earlier-pages " + " ".join(f"page-id:{page['id']}" for page in pages)
        self.assert_success(self.call_cli("conversation", "send", chat_id, "--message", message, extra_environment=environment)[0])

        turns = [
            turn for turn in json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
            if not (turn.get("userText") or "").startswith("Classify the latest user message")
        ]
        reads = [item for item in turns[-1]["reportCommands"] if " chat page read " in item["command"]]
        self.assertEqual(len(reads), 2, "The fixture should really run one chat page read per earlier page.")
        for page, title, read in zip(pages, titles, reads):
            self.assertTrue(read["command"].endswith(page["id"]), read)
            self.assertEqual(json.loads(read["output"])["result"]["page"]["title"], title, "Each read should load the page's own title.")

        history = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        recalls = [row for row in history["activities"] if row["id"].startswith("toolu_recall_")]
        self.assertEqual([row["id"] for row in recalls], ["toolu_recall_0", "toolu_recall_1"],
                         "Each page read should be recorded in order for the conversation to render as a Recalling line.")
        for page, row in zip(pages, recalls):
            self.assertIn(f"chat page read {page['id']}", row["title"])
            self.assertEqual(row["status"], "completed")

        self.assert_success(self.call_cli("conversation", "send", chat_id, "--message", "recall-earlier-pages", extra_environment=environment)[0])
        later = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])
        message_ids = {message["id"] for message in later["messages"]}
        placed = [row for row in later["timelineActivities"] if row["id"].startswith("toolu_recall_")]
        self.assertEqual([row["id"] for row in placed], ["toolu_recall_0", "toolu_recall_1"],
                         "The earlier turn's reads stay placed in the timeline after a later turn.")
        self.assertTrue(all(row.get("afterMessageID") in message_ids for row in placed),
                        "Each placed read follows a message the conversation still shows.")
        self.assert_failure(self.call_cli("chat", "page", "read", "no-such-page", expected_status=1, extra_environment=environment)[0], "operation_failed")

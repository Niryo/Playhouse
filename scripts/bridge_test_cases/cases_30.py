from test_bridge_support import *
from test_bridge_support import __file__


SALAD_PROMPT = "Suggest a quick salad lunch."
SALAD_ANSWER = "A Greek salad takes ten minutes."
SOUP_PROMPT = "Suggest a quick soup supper."
SOUP_ANSWER = "Tomato soup takes twenty minutes."
DRESSING_PROMPT = "Add a dressing."
DRESSING_ANSWER = "Lemon and olive oil."
JUPITER_PROMPT = "Name the largest moon of Jupiter."
JUPITER_ANSWER = "Ganymede is the largest moon of Jupiter."
PASTA_PROMPT = "Suggest a quick pasta dinner."
PASTA_ANSWER = "Cacio e pepe takes fifteen minutes."
TACO_PROMPT = "Suggest a quick taco breakfast."
TACO_ANSWER = "Egg tacos take five minutes."


class BridgeTestCases30:
    def parallel_chat(self, name):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable, environment = self.optimized_claude_fixture(name)
        chat_id = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])["id"]
        return executable, environment, chat_id

    def parallel_bubbles(self, environment):
        return self.assert_success(self.call_cli("chat", "bubble", "list", extra_environment=environment)[0])["bubbles"]

    def parallel_history(self, task_id, environment):
        return self.history_texts(task_id, environment)[0]

    def hold_parallel(self, executable, slug):
        Path(str(executable) + f".hold-parallel-{slug}").touch()

    def release_parallel(self, executable, slug):
        Path(str(executable) + f".parallel-{slug}-release").write_text("Release the parallel turn.\n", encoding="utf-8")

    # case-contract: test_parallel_chat_bubble_runs_alongside_and_returns_to_its_placeholder | The standalone chat can ask a question in parallel: the CLI's chat bubble send, and in the chat the Send in parallel button beside Send, put the message on a new page of its own that runs in a parallel bubble, its own conversation with a fresh provider session that opens like a New page turn, while the chat itself stays free: a message sent in the chat while the bubble answers runs and finishes there at once. chat bubble list reports the bubble with its question, whether it is still answering, and the chat's turn that was last when it was sent; in the app the bubble floats out of the chat sidebar's right edge showing its question and a spinner, and the chat shows a small placeholder with the question where the bubble's page will return. Once answered, the bubble shows it is done and opens into a larger view of its own conversation, where a follow-up continues the bubble's page in the same provider session. Closing it removes the bubble and its placeholder and inserts the bubble's page, all its turns together, into the chat at that spot, keeping the chat's order by time without splitting a page: right after the turn that was last when it was sent, unless the chat went on with that turn's page, in which case it returns above that page, and never at or after the chat's current page. So a bubble sent on the current page returns above it, a bubble whose page the chat went on with and then left for a new page returns above that earlier page, and a bubble sent at the end of a page the chat then left returns between the two. The returned page belongs to the chat, is listed among the chat's pages in that place, its messages are filed on it, the page labels show it there and jumping to its label shows its window. Bubbles, placement and the merge are Playhouse-owned, and the bubble's turns run through the standalone chat's provider-neutral New page path, so one representative provider (Claude) covers the case.
    def test_parallel_chat_bubble_runs_alongside_and_returns_to_its_placeholder(self):
        executable, environment, chat_id = self.parallel_chat("claude-fixture-parallel-bubbles")

        def send(message, *extra):
            self.assert_success(self.call_cli(
                "conversation", "send", chat_id, "--message", message, *extra, extra_environment=environment
            )[0])

        send(JUPITER_PROMPT)
        status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        jupiter_page = status["activePage"]
        anchor_turn = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])["messages"][-1]["turnID"]

        # The bubble runs on its own while the chat keeps answering.
        self.hold_parallel(executable, "salad-lunch")
        command = ("chat", "bubble", "send", "--message", SALAD_PROMPT)
        process = self.start_cli(*command, extra_environment=environment)
        try:
            self.wait_for(lambda: Path(str(executable) + ".parallel-salad-lunch-active").exists(), "The parallel turn is held.", timeout=30)
            listed = self.parallel_bubbles(environment)
            self.assertEqual(len(listed), 1)
            salad = listed[0]
            self.assertEqual((salad["prompt"], salad["isRunning"], salad["anchorTurnID"], salad["chatID"]),
                             (SALAD_PROMPT, True, anchor_turn, chat_id))
            send(JUPITER_PROMPT)
            self.assertEqual(self.parallel_history(chat_id, environment),
                             [JUPITER_PROMPT, JUPITER_ANSWER, JUPITER_PROMPT, JUPITER_ANSWER],
                             "The chat answers while the bubble is still running, and shows none of the bubble's turns.")
            self.assertNotIn(SALAD_PROMPT, [page["title"] for page in self.chat_pages(environment)])
        finally:
            self.release_parallel(executable, "salad-lunch")
        sent = self.assert_success(self.finish_cli(process, command, timeout=60)[0])
        self.assertEqual(sent["bubble"]["id"], salad["id"])
        fresh = self.claude_turn_ending(executable, SALAD_PROMPT)
        jupiter_turn = self.claude_turn_ending(executable, JUPITER_PROMPT)
        self.assertFalse(fresh["resumed"], "The bubble starts a provider session of its own.")
        self.assertNotEqual(fresh["sessionID"], jupiter_turn["sessionID"])
        self.assertIn("The user started this new page for their message", fresh["userText"])
        self.assertNotIn(JUPITER_ANSWER, fresh["userText"], "None of the chat's turns travel with the bubble's question.")
        self.assertFalse(self.parallel_bubbles(environment)[0]["isRunning"])

        # A follow-up continues the bubble's page in its own session.
        self.assert_success(self.call_cli(
            "conversation", "send", salad["id"], "--message", DRESSING_PROMPT, extra_environment=environment
        )[0])
        follow_up = self.claude_turn_ending(executable, DRESSING_PROMPT)
        self.assertTrue(follow_up["resumed"])
        self.assertEqual(follow_up["sessionID"], fresh["sessionID"])
        self.assertEqual(self.parallel_history(salad["id"], environment), [SALAD_PROMPT, SALAD_ANSWER, DRESSING_PROMPT, DRESSING_ANSWER])

        # The chat kept adding to the anchor's page, so the bubble's page returns above it.
        closed = self.assert_success(self.call_cli("chat", "bubble", "close", salad["id"], extra_environment=environment)[0])
        self.assertIsNone(closed.get("afterTurnID"))
        self.assertEqual(self.parallel_bubbles(environment), [])
        self.assertEqual(self.parallel_history(chat_id, environment), [
            SALAD_PROMPT, SALAD_ANSWER, DRESSING_PROMPT, DRESSING_ANSWER,
            JUPITER_PROMPT, JUPITER_ANSWER, JUPITER_PROMPT, JUPITER_ANSWER,
        ])
        pages = self.chat_pages(environment)
        salad_page = next(page for page in pages if page["title"] == "Salad lunch")
        self.assertEqual(closed["pageIDs"], [salad_page["id"]])
        self.assertEqual(salad_page["chatID"], "default", "The returned page belongs to the chat.")
        self.assertIsNotNone(salad_page["closedAt"])
        self.assertEqual([page["id"] for page in pages], [jupiter_page["id"], salad_page["id"]],
                         "The returned page is listed before the page it returned above.")
        self.assertEqual(self.chat_page_texts(salad_page["id"], environment), [SALAD_PROMPT, SALAD_ANSWER, DRESSING_PROMPT, DRESSING_ANSWER])
        self.assertEqual(self.chat_page_texts(jupiter_page["id"], environment), [JUPITER_PROMPT, JUPITER_ANSWER, JUPITER_PROMPT, JUPITER_ANSWER])
        self.assertEqual(self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]["id"],
                         jupiter_page["id"], "The chat's current page stays current.")
        window = self.assert_success(self.call_cli(
            "conversation", "history", chat_id, "--page", salad_page["id"], "--limit", "4", extra_environment=environment
        )[0])
        self.assertEqual([message["text"] for message in window["messages"]], [SALAD_PROMPT, SALAD_ANSWER, DRESSING_PROMPT, DRESSING_ANSWER])

        def last_turn_id():
            messages = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])["messages"]
            return messages[-1]["turnID"]

        # A bubble whose page the chat goes on with, and then leaves, returns above that page;
        # a bubble sent at the end of a page the chat then leaves returns between the two pages.
        history = self.assert_success(self.call_cli("conversation", "history", chat_id, extra_environment=environment)[0])["messages"]
        salad_turn = next(message["turnID"] for message in history if message["text"] == DRESSING_ANSWER)
        soup = self.assert_success(self.call_cli("chat", "bubble", "send", "--message", SOUP_PROMPT, extra_environment=environment)[0])["bubble"]
        send(JUPITER_PROMPT)
        third_jupiter_turn = last_turn_id()
        taco = self.assert_success(self.call_cli("chat", "bubble", "send", "--message", TACO_PROMPT, extra_environment=environment)[0])["bubble"]
        self.assertEqual(taco["anchorTurnID"], third_jupiter_turn)
        send(PASTA_PROMPT, "--new-page")
        pasta_page = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]
        self.assertEqual(pasta_page["title"], "Pasta dinner")
        jupiter_texts = [JUPITER_PROMPT, JUPITER_ANSWER] * 3
        closed_soup = self.assert_success(self.call_cli("chat", "bubble", "close", soup["id"], extra_environment=environment)[0])
        self.assertEqual(closed_soup["afterTurnID"], salad_turn, "The soup page returns above the page the chat went on with.")
        self.assertEqual(self.parallel_history(chat_id, environment), [
            SALAD_PROMPT, SALAD_ANSWER, DRESSING_PROMPT, DRESSING_ANSWER, SOUP_PROMPT, SOUP_ANSWER,
            *jupiter_texts, PASTA_PROMPT, PASTA_ANSWER,
        ])
        closed_taco = self.assert_success(self.call_cli("chat", "bubble", "close", taco["id"], extra_environment=environment)[0])
        self.assertEqual(closed_taco["afterTurnID"], third_jupiter_turn, "The taco page returns right after the page it was sent at the end of.")
        self.assertEqual(self.parallel_history(chat_id, environment), [
            SALAD_PROMPT, SALAD_ANSWER, DRESSING_PROMPT, DRESSING_ANSWER, SOUP_PROMPT, SOUP_ANSWER,
            *jupiter_texts, TACO_PROMPT, TACO_ANSWER, PASTA_PROMPT, PASTA_ANSWER,
        ])
        pages = self.chat_pages(environment)
        soup_page = next(page for page in pages if page["title"] == "Soup supper")
        taco_page = next(page for page in pages if page["title"] == "Taco breakfast")
        self.assertEqual([page["id"] for page in pages],
                         [pasta_page["id"], taco_page["id"], jupiter_page["id"], soup_page["id"], salad_page["id"]])
        self.assertEqual(self.chat_page_texts(jupiter_page["id"], environment), jupiter_texts, "No page is split.")
        self.assertEqual(self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]["id"], pasta_page["id"])

    # case-contract: test_parallel_chat_bubble_close_refused_while_generating | A parallel bubble cannot close while it is still answering: chat bubble close is invalid_transition, and in the app the bubble's close button is disabled while its spinner shows, so the bubble, its placeholder and its unfinished page stay where they are, and the chat lists no new page; once the answer arrives the same close succeeds. An unknown bubble is not_found, and a parallel send without a message is invalid_argument and opens no bubble. The close check reads Playhouse's own turn reservation, so one representative provider (Claude) covers the case.
    def test_parallel_chat_bubble_close_refused_while_generating(self):
        executable, environment, chat_id = self.parallel_chat("claude-fixture-parallel-refused")
        self.assert_failure(self.call_cli(
            "chat", "bubble", "send", "--message", "   ", expected_status=2, extra_environment=environment
        )[0], "invalid_argument")
        self.assertEqual(self.parallel_bubbles(environment), [])
        self.assert_failure(self.call_cli(
            "chat", "bubble", "close", str(uuid.uuid4()), expected_status=3, extra_environment=environment
        )[0], "not_found")

        self.hold_parallel(executable, "salad-lunch")
        command = ("chat", "bubble", "send", "--message", SALAD_PROMPT)
        process = self.start_cli(*command, extra_environment=environment)
        try:
            self.wait_for(lambda: Path(str(executable) + ".parallel-salad-lunch-active").exists(), "The parallel turn is held.", timeout=30)
            bubble = self.wait_for(lambda: next(iter(self.parallel_bubbles(environment)), None), "The bubble is listed.")
            self.assert_failure(self.call_cli(
                "chat", "bubble", "close", bubble["id"], expected_status=1, extra_environment=environment
            )[0], "invalid_transition")
            self.assertEqual([item["id"] for item in self.parallel_bubbles(environment)], [bubble["id"]])
            self.assertEqual(self.chat_pages(environment), [])
        finally:
            self.release_parallel(executable, "salad-lunch")
        self.assert_success(self.finish_cli(process, command, timeout=60)[0])
        closed = self.assert_success(self.call_cli("chat", "bubble", "close", bubble["id"], extra_environment=environment)[0])
        self.assertEqual(self.parallel_bubbles(environment), [])
        self.assertEqual([page["id"] for page in self.chat_pages(environment)], closed["pageIDs"])
        self.assertEqual(self.parallel_history(chat_id, environment), [SALAD_PROMPT, SALAD_ANSWER])

    # case-contract: test_parallel_chat_bubbles_persist_across_restart | Open parallel bubbles survive a restart: after the bridge daemon is killed while one bubble is still answering and another has answered (in the app, after a relaunch), chat bubble list still reports both with their questions and the chat turn each returns after, and the app shows both bubbles again with their placeholders. The new daemon follows the bubble turn that was running and files it on the bubble's own page, named by its close-turn, never on a page of the chat, which keeps its own messages. Both bubbles then close into place above the chat's current page, oldest first, with all their messages. The bubble is a standalone chat conversation of its own, so it recovers through the chat's provider-neutral restart path; one representative provider (Claude) covers the case.
    def test_parallel_chat_bubbles_persist_across_restart(self):
        executable, environment, chat_id = self.start_reattach_chat("claude-fixture-reattach-parallel")
        main_question = "Name a moon of Mars."
        self.send_filed_chat_turn(executable, environment, chat_id, main_question)
        main_page = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])["activePage"]
        main_texts = [main_question, "Before restart.", "After restart."]

        # One bubble answers before the restart.
        ready = Path(str(executable) + ".reattach-ready")
        ready.unlink(missing_ok=True)
        hike_question = "Plan a weekend hike."
        command = ("chat", "bubble", "send", "--message", hike_question)
        sender = self.start_cli(*command, extra_environment=environment)
        self.wait_for(ready.is_file, "The first bubble's turn runs.")
        self.close_held_chat_turn(executable, "Weekend hike")
        Path(str(executable) + ".reattach-release-quiet").touch()
        hike = self.assert_success(self.finish_cli(sender, command, timeout=60)[0])["bubble"]
        self.wait_for(lambda: not self.claude_runs(environment), "The finished bubble turn's run is removed.")

        # The other is still answering when the daemon dies.
        ready.unlink(missing_ok=True)
        packing_question = "Write a packing list for the hike."
        sent = {}
        thread = threading.Thread(target=lambda: sent.setdefault("turn", self.call_cli(
            "chat", "bubble", "send", "--message", packing_question,
            expected_status=69, timeout=60, extra_environment=environment)), daemon=True)
        thread.start()
        self.wait_for(ready.is_file, "The second bubble's turn runs before the daemon dies.")
        agent = self.reattach_agent(environment)
        self.kill_daemon(environment)
        thread.join(timeout=20)
        self.assert_failure(sent["turn"][0], "service_unavailable")
        self.assertTrue(self.agent_process_alive(agent), "The agent outlives the daemon that started the bubble's turn.")

        bubbles = self.parallel_bubbles(environment)
        self.assertEqual([(bubble["prompt"], bubble["anchorTurnID"] is not None) for bubble in bubbles],
                         [(hike_question, True), (packing_question, True)])
        packing = bubbles[1]
        self.close_held_chat_turn(executable, "Packing list")
        Path(str(executable) + ".reattach-release-quiet").touch()
        self.wait_for(lambda: "After restart." in self.parallel_history(packing["id"], environment), "The followed bubble turn finishes.", timeout=40)
        self.wait_for(lambda: not self.parallel_bubbles(environment)[1]["isRunning"], "The followed bubble turn ends.", timeout=40)
        self.assertEqual([page["id"] for page in self.chat_pages(environment)], [main_page["id"]],
                         "The followed bubble turn is never filed on a page of the chat.")
        self.assertEqual(self.chat_page_texts(main_page["id"], environment), main_texts)

        self.assert_success(self.call_cli("chat", "bubble", "close", hike["id"], extra_environment=environment)[0])
        closed = self.assert_success(self.call_cli("chat", "bubble", "close", packing["id"], extra_environment=environment)[0])
        pages = self.chat_pages(environment)
        packing_page = next(page for page in pages if page["title"] == "Packing list")
        hike_page = next(page for page in pages if page["title"] == "Weekend hike")
        self.assertEqual(closed["pageIDs"], [packing_page["id"]])
        self.assertEqual(self.chat_page_texts(packing_page["id"], environment), [packing_question, "Before restart.", "After restart."])
        self.assertEqual([page["id"] for page in pages], [main_page["id"], packing_page["id"], hike_page["id"]])
        self.assertEqual(self.parallel_history(chat_id, environment), [
            hike_question, "Before restart.", "After restart.",
            packing_question, "Before restart.", "After restart.",
            *main_texts,
        ])
        self.assertEqual(self.parallel_bubbles(environment), [])

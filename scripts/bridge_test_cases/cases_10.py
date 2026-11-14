from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases10:
    # case-contract: test_conversation_adds_ordered_text_annotations | Selecting text in assistant and user messages, including wrapped multiline selections, shows a Side chat hint above the selected lines in place of the Add comment hint; clicking it opens the side chat bubble at the selected lines, and the bubble's Comment button adds what is typed in its composer as a comment on the selection and closes it. Added ranges render orange and persist after reopening. The composer shows the pending comment count. Structurally recognized comment context is hidden while similar ordinary text remains visible; comments are sent in insertion order with source ranges alongside ordinary composer text. Multiple comments can be added before one send, comment-only sends are enabled, and closing the bubble with Escape leaves none to submit. Pending comments take precedence over Goal-entry mode: submission sends them to the conversation, exits Goal-entry mode, and does not store the comment payload as a Goal objective. The agent is instructed to start each comment response line with the provider-neutral indexed protocol marker; the transcript renders that marker as a numbered prefix (1., 2.) whose hover opens a medium-sized hint with highlighted text and the user's comment, truncating long values while keeping them identifiable. The serialized payload and ordered response survive CLI/XPC history reload. Legacy Codex markers, response-annotations payloads, and annotation fields still restore their reply details. Consecutive paragraphs, headings, and list items of a reply form one selectable text: the comment reply's lines share one text with a paragraph each, and selecting across them adds one comment that highlights every covered paragraph, records the block it ends in alongside its start block and offsets (a comment inside one block keeps the original source fields), and is restored after reopening the conversation; the cross-block source survives CLI/XPC history reload. User messages render in a neutral gray, input-style bubble with a thin light border and light text rather than the blue accent fill.
    def test_conversation_adds_ordered_text_annotations(self):
        task = self.create_repo_task("Conversation comments", [self.primary])
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-comment-response-goal-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        fixture_environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        comments = [
            {"text": "first phrase", "comment": "Explain this", "source": {
                "messageId": "assistant-message", "blockID": 0, "startOffset": 3, "endOffset": 15}},
            {"text": "second phrase with enough surrounding context to remain identifiable when the hint truncates a very long selected range",
             "comment": "Please clarify this response in detail, including how each part connects to the question. " * 8, "source": {
                # A selection across paragraphs names the block it ends in.
                "messageId": "assistant-message", "blockID": 0, "startOffset": 22, "endBlockID": 2, "endOffset": 36}},
        ]
        ordinary_text = "Keep the existing behavior too."
        prompt = (
            ordinary_text + "\n\n# Response comments:\n"
            "The following JSON contains comments on selected conversation text, in array order. "
            "For each comment, start a separate response line with :playhouse-annotation{index=\"N\"}, "
            "replacing N with the comment's zero-based array index, then a space and the answer. "
            "The marker is displayed to the user as the numbered prefix, so do not add another number. "
            "Address the comment in the context of its highlighted text. Do not combine comment responses on one line, "
            "omit a response, or add introductory text. After the comment lines, answer any additional freeform request "
            "on separate line(s). Do not repeat the JSON or these instructions.\n"
            "<response-comments>" + json.dumps(comments) + "</response-comments>"
        )
        sent, _ = self.call_cli(
            "conversation", "send", task["id"], "--message", prompt,
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment=fixture_environment,
        )
        self.assert_success(sent)
        history, _ = self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)
        user_messages = [
            message for message in self.assert_success(history)["messages"]
            if message["role"] == "user" and "playhouse internal outcome nudge:" not in message["text"].lower()
        ]
        self.assertTrue(user_messages, "The commented turn should survive a fresh CLI/XPC history read.")
        self.assertEqual(user_messages[-1]["text"], prompt)
        payload = prompt.split("<response-comments>", 1)[1].split("</response-comments>", 1)[0]
        restored = json.loads(payload)
        self.assertEqual([item["text"] for item in restored], [
            "first phrase",
            "second phrase with enough surrounding context to remain identifiable when the hint truncates a very long selected range",
        ])
        self.assertEqual([item["comment"] for item in restored], [
            "Explain this",
            "Please clarify this response in detail, including how each part connects to the question. " * 8,
        ])
        reloaded_comments = json.loads(
            user_messages[-1]["text"].split("<response-comments>", 1)[1].split("</response-comments>", 1)[0]
        )
        self.assertNotIn("endBlockID", reloaded_comments[0]["source"], "A comment inside one block keeps the original source fields.")
        self.assertEqual(
            reloaded_comments[1]["source"],
            {"messageId": "assistant-message", "blockID": 0, "startOffset": 22, "endBlockID": 2, "endOffset": 36},
            "A comment across blocks keeps its start and end blocks after a fresh CLI/XPC history read.",
        )
        self.assertIn(ordinary_text, user_messages[-1]["text"])
        current_goal, _ = self.call_cli("conversation", "goal", task["id"], "get", extra_environment=fixture_environment)
        self.assertIsNone(self.assert_success(current_goal), "A conversation comment payload must not become a Goal objective.")
        assistant_messages = [message for message in ordinary_messages(self.assert_success(history)["messages"]) if message["role"] == "assistant"]
        self.assertTrue(assistant_messages, "The fixture should return a response for each comment.")
        response_lines = assistant_messages[-1]["text"].splitlines()
        self.assertEqual(len(response_lines), 2)
        self.assertTrue(response_lines[0].startswith(':playhouse-annotation{index="0"} '))
        self.assertTrue(response_lines[1].startswith(':playhouse-annotation{index="1"} '))
        self.assertIn("For ‘first phrase’: Explain this", response_lines[0])
        self.assertIn("Please clarify this response", response_lines[1])

        legacy_prompt = (
            "# Response annotations:\nThe following JSON contains comments on selected conversation text, in array order.\n"
            "<response-annotations>" + json.dumps([{
                "text": "legacy highlighted words", "annotation": "A detail from older saved history",
                "source": {"messageId": "legacy-source", "blockID": 0, "startOffset": 0, "endOffset": 24},
            }]) + "</response-annotations>"
        )
        legacy_sent, _ = self.call_cli(
            "conversation", "send", task["id"], "--message", legacy_prompt,
            "--answer", "color=Blue", "--answer", "token=fixture-secret",
            extra_environment=fixture_environment,
        )
        self.assert_success(legacy_sent)
        legacy_history, _ = self.call_cli("conversation", "history", task["id"], extra_environment=fixture_environment)
        legacy_assistant = next(
            message for message in reversed(ordinary_messages(self.assert_success(legacy_history)["messages"]))
            if message["role"] == "assistant"
        )
        self.assertIn("legacy highlighted words", legacy_assistant["text"])
        self.assertIn("A detail from older saved history", legacy_assistant["text"])
        self.assertIn(':codex-annotation{index="0"}', legacy_assistant["text"])

        comment_only_prompt = (
            "<playhouse-comment-context>\n# Response comments:\n"
            "For each comment, start a separate response line with :playhouse-annotation{index=\"N\"}.\n"
            "<response-comments>" + json.dumps(comments[:1]) + "</response-comments>\n"
            "</playhouse-comment-context>"
        )
        self.assert_success(self.call_cli(
            "conversation", "send", task["id"], "--message", comment_only_prompt,
            extra_environment=fixture_environment,
        )[0])
        comment_only_history = self.assert_success(self.call_cli(
            "conversation", "history", task["id"], extra_environment=fixture_environment,
        )[0])
        self.assertEqual(
            [item for item in ordinary_messages(comment_only_history["messages"]) if item["role"] == "user"][-1]["text"],
            comment_only_prompt,
        )
        self.assertIn(
            ':playhouse-annotation{index="0"}',
            [item for item in ordinary_messages(comment_only_history["messages"]) if item["role"] == "assistant"][-1]["text"],
        )
    # case-contract: test_conversation_persists_unsent_comments | Unsent conversation comments are saved with the task draft. Through CLI/XPC, a saved comment list reports its count on a fresh read, malformed input is rejected with invalid_argument and leaves the saved comments unchanged, a later draft save keeps them, appending a list adds only comments not already saved (how a send that ends without delivering its comments returns them without overwriting newer ones), and an empty list clears them. Saving comments after a sent prompt leaves hasUnsentDraft false, so the sent prompt never returns to the composer as a draft. In the app, comments added to a conversation are saved as they are added and survive switching to another task and back and quitting and relaunching: the composer shows the pending comment count and the highlights are restored. Sending them delivers their source ranges, clears the saved comments, and reopening the task shows no pending comment and no duplicate. Once sent, a comment can no longer be edited (task comments edit reports not_found), and clicking its text reopens it read-only in the side chat bubble, whose Comment button can still add a new comment there.
    def test_conversation_persists_unsent_comments(self):
        task = self.create_repo_task("Unsent comments", [self.primary])
        sent_prompt = "Already sent prompt."
        # The created task's description is its draft; clear it so the submitted prompt is the last sent one.
        self.assert_success(self.call_cli("task", "draft", task["id"], "--text", "")[0])
        self.assert_success(self.call_cli("task", "prompt", task["id"], "--text", sent_prompt, "--status", "In Progress", "--submitted", "true")[0])
        pending = [{
            "id": "11111111-1111-1111-1111-111111111111", "messageID": "assistant-message", "blockID": 0,
            "startOffset": 3, "endBlockID": 0, "endOffset": 15, "text": "first phrase", "comment": "Explain this", "pending": True,
        }, {
            "id": "22222222-2222-2222-2222-222222222222", "messageID": "assistant-message", "blockID": 0,
            "startOffset": 22, "endBlockID": 2, "endOffset": 36, "text": "second phrase", "comment": "And this", "pending": True,
        }]
        saved = self.assert_success(self.call_cli("task", "comments", task["id"], "--json", json.dumps(pending))[0])
        self.assertEqual(saved["pendingCommentCount"], 2)
        self.assertFalse(saved["hasUnsentDraft"], "Comments must not turn the sent prompt back into a draft.")
        self.assertEqual(saved["savedPrompt"], sent_prompt)
        reread = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(reread["pendingCommentCount"], 2, "Saved comments persist across a fresh CLI/XPC read.")
        self.assertFalse(reread["hasUnsentDraft"])
        rejected, _ = self.call_cli("task", "comments", task["id"], "--json", "not json", expected_status=2)
        self.assert_failure(rejected, "invalid_argument")
        rejected, _ = self.call_cli("task", "comments", task["id"], "--json", json.dumps([{"comment": "missing fields"}]), expected_status=2)
        self.assert_failure(rejected, "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["pendingCommentCount"], 2,
                         "Rejected input leaves the saved comments unchanged.")
        drafted = self.assert_success(self.call_cli("task", "draft", task["id"], "--text", "A typed draft")[0])
        self.assertEqual(drafted["pendingCommentCount"], 2, "A draft save keeps the saved comments.")
        self.assertTrue(drafted["hasUnsentDraft"])
        # A send that ends without delivering its comments appends them back: saved ones are kept,
        # and a comment already saved is not duplicated.
        returned = [dict(pending[1]), {
            "id": "33333333-3333-3333-3333-333333333333", "messageID": "assistant-message", "blockID": 1,
            "startOffset": 0, "endBlockID": 1, "endOffset": 4, "text": "word", "comment": "Returned", "pending": True,
        }]
        appended = self.assert_success(
            self.call_cli("task", "comments", task["id"], "--json", json.dumps(returned), "--append")[0]
        )
        self.assertEqual(appended["pendingCommentCount"], 3, "Appending adds only comments not already saved.")
        cleared = self.assert_success(self.call_cli("task", "comments", task["id"], "--json", "[]")[0])
        self.assertEqual(cleared["pendingCommentCount"], 0)
        self.assertEqual(cleared["savedPrompt"], "A typed draft", "Clearing comments leaves the typed draft alone.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["pendingCommentCount"], 0)
        # A send clears the saved comments the same way, after which they are no longer editable.
        self.assert_failure(self.call_cli(
            "task", "comments", task["id"], "edit", pending[0]["id"], "--text", "Too late", expected_status=3,
        )[0], "not_found")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["pendingCommentCount"], 0,
                         "Editing a sent comment must not bring it back.")
    # case-contract: test_side_chat_and_comment_reopen_from_highlighted_text | Clicking commented or side-chatted conversation text, without selecting any, reopens its bubble with that selection's comment and side chat. A side chat opened on a selection is saved on the task with its source range, selected text, provider conversation, model and every answered exchange; closing its bubble keeps it, its text renders purple while no comment covers it and orange once a comment does, and reopening it shows its history and continues the same forked conversation, so its next answer is saved after the earlier ones. An unsent comment opens in an editable field: saving changed text keeps the comment with the new text, and clearing it and saving deletes it, leaving the side chat and its purple text. Through CLI/XPC, conversation side-chats lists the saved side chats, a side chat's source must name a message and a non-empty range, task comments edit changes an unsent comment's text, empty text deletes it, and an unknown comment is not_found. Edits and side chats survive a fresh read and relaunching the app.
    def test_side_chat_and_comment_reopen_from_highlighted_text(self):
        task, _, environment = self.open_side_chat_task("claude", "claude-fixture-side-chat")
        _, history = self.history_texts(task["id"], environment)
        reply = next(message for message in reversed(history["messages"]) if message["role"] == "assistant" and message["text"])
        source = {"messageID": reply["id"], "blockID": 0, "startOffset": 0, "endBlockID": 0, "endOffset": 10}
        self.assertEqual(self.assert_success(self.call_cli("conversation", "side-chats", task["id"], extra_environment=environment)[0]), [],
                         "A task starts with no saved side chats.")
        for bad_source in ("not json", json.dumps({**source, "messageID": ""}), json.dumps({**source, "endOffset": 0})):
            self.assert_failure(self.call_cli(
                "conversation", "side-chat", task["id"], "--selection", "the parser", "--source", bad_source,
                "--message", "Why?", extra_environment=environment, expected_status=2,
            )[0], "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "side-chats", task["id"], extra_environment=environment)[0]), [],
                         "A rejected side chat is not saved.")

        opened = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--selection", "the parser", "--source", json.dumps(source),
            "--message", "What does this mean?", extra_environment=environment,
        )[0])
        saved = opened["sideChat"]
        self.assertEqual(saved["id"], opened["sideChatID"])
        self.assertEqual(saved["source"], source)
        self.assertEqual(saved["selectedText"], "the parser")
        self.assertEqual(saved["provider"], "claude")
        self.assertEqual(saved["messages"], [{"isUser": True, "text": "What does this mean?"}, {"isUser": False, "text": opened["reply"]}])
        fork_session = saved["threadID"]
        self.assertNotEqual(fork_session, task["claudeSessionID"])
        self.assert_success(self.call_cli("conversation", "side-chat-close", task["id"], opened["sideChatID"], extra_environment=environment)[0])
        listed = self.assert_success(self.call_cli("conversation", "side-chats", task["id"], extra_environment=environment)[0])
        self.assertEqual(listed, [saved], "A closed side chat stays saved on its task.")

        continued = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--side-chat", opened["sideChatID"], "--message", "And then?",
            extra_environment=environment,
        )[0])
        self.assertEqual(continued["reply"], f"Side chat follow-up 2 on {fork_session}: And then?",
                         "Reopening continues the side chat's own forked session.")
        self.assertEqual([message["text"] for message in continued["sideChat"]["messages"]],
                         ["What does this mean?", opened["reply"], "And then?", continued["reply"]])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "side-chats", task["id"], extra_environment=environment)[0]),
                         [continued["sideChat"]], "The next exchange is saved after the earlier ones.")
        self.assertEqual(self.task_for(task["id"], environment)["claudeSessionID"], task["claudeSessionID"],
                         "Saving a side chat leaves the task's own session alone.")
        self.assert_failure(self.call_cli(
            "conversation", "side-chat", task["id"], "--source", json.dumps(source), "--side-chat", opened["sideChatID"],
            "--message", "Both?", extra_environment=environment, expected_status=2,
        )[0], "invalid_argument")

        comment = {"id": "44444444-4444-4444-4444-444444444444", **source, "text": "the parser", "comment": "Explain this", "pending": True}
        other = {**comment, "id": "55555555-5555-5555-5555-555555555555", "comment": "Keep this one"}
        self.assert_success(self.call_cli("task", "comments", task["id"], "--json", json.dumps([comment, other]))[0])
        edited = self.assert_success(self.call_cli("task", "comments", task["id"], "edit", comment["id"], "--text", "  Explain it again  ")[0])
        self.assertEqual(edited["pendingCommentCount"], 2, "Editing keeps the comment.")
        self.assert_failure(self.call_cli(
            "task", "comments", task["id"], "edit", "66666666-6666-6666-6666-666666666666", "--text", "Nobody", expected_status=3,
        )[0], "not_found")
        deleted = self.assert_success(self.call_cli("task", "comments", task["id"], "edit", other["id"], "--text", "  ")[0])
        self.assertEqual(deleted["pendingCommentCount"], 1, "Saving a comment empty deletes it.")
        # The saved list keeps the edited text: appending it back again adds nothing.
        appended = self.assert_success(self.call_cli(
            "task", "comments", task["id"], "--json", json.dumps([{**comment, "comment": "Explain it again"}]), "--append")[0])
        self.assertEqual(appended["pendingCommentCount"], 1)
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["pendingCommentCount"], 1,
                         "The edit and the deletion survive a fresh read.")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "side-chats", task["id"], extra_environment=environment)[0]),
                         [continued["sideChat"]], "Editing comments leaves the side chat saved.")
    # case-contract: test_claude_auto_branch_uses_generated_title_and_fallback | An Untitled Claude task with a pending auto repository branch uses its selected provider to generate the title before worktree creation; the branch and title persist across fresh CLI/XPC reads and the visible task. If Claude title generation returns no title, the prompt becomes the title and branch fallback, and the conversation still starts in that worktree. A fresh `task title` request reproduces the generated title and provider (null when generation yields nothing), and `task reconcile` returns the settled task unchanged.
    def test_claude_auto_branch_uses_generated_title_and_fallback(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        for suffix, prompt, title, branch in [
            ("title-success", "Explain the selected Claude task.", "Generated Claude title", "generated-claude-title"),
            ("title-failure", "Explain Claude fallback title", "Explain Claude fallback title", "explain-claude-fallback-title"),
        ]:
            executable = self.data_directory / f"claude-fixture-{suffix}"
            copy_file(source, executable)
            executable.chmod(0o755)
            (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
                "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
            )
            environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
            task = self.assert_success(self.call_cli(
                "task", "create", "--title", "Untitled task", "--prompt", "Fixture task description.", "--repo", self.primary, "--provider", "claude"
            )[0])
            self.assertEqual(task["repositoryWorktrees"][0]["branch"], "auto")
            self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
            # The create-time prompt is an unsent draft that a send leaves alone; clear it so the sent prompt is the saved prompt.
            self.assert_success(self.call_cli("task", "draft", task["id"], "--text", "")[0])
            self.assert_success(self.call_cli(
                "conversation", "send", task["id"], "--message", prompt, extra_environment=environment
            )[0])
            fresh = self.assert_success(self.call_cli("task", "get", task["id"])[0])
            self.assertEqual(fresh["conversationProvider"], "claude")
            self.assertEqual(fresh["title"], title)
            record = fresh["repositoryWorktrees"][0]
            self.assertEqual(record["branch"], branch)
            self.assertFalse(record["isPending"])
            self.assertTrue(Path(record["worktreePath"]).is_dir())
            self.assertTrue(self.branch_exists(self.primary, branch))
            self.assertEqual(fresh["savedPrompt"], prompt)
            history = self.assert_success(self.call_cli(
                "conversation", "history", task["id"], extra_environment=environment
            )[0])
            self.assertIn(prompt, [item["text"] for item in history["messages"] if item["role"] == "user"])
            fixture_turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
            self.assertTrue(any(turn["userText"].startswith("Write a concise task title") for turn in fixture_turns))
            self.assertEqual(Path(fixture_turns[-1]["cwd"]).resolve(), Path(record["worktreePath"]).resolve())
            generated = self.assert_success(self.call_cli(
                "task", "title", task["id"], "--prompt", prompt, extra_environment=environment
            )[0])
            if suffix == "title-success":
                self.assertEqual(generated, {"title": title, "provider": "claude"})
            else:
                self.assertIsNone(generated, "A provider that returns no title leaves the caller to fall back.")
            reconciled = self.assert_success(self.call_cli(
                "task", "reconcile", task["id"], extra_environment=environment
            )[0])
            self.assertEqual((reconciled["id"], reconciled["status"], reconciled["title"]), (task["id"], fresh["status"], title))
    # case-contract: test_conversation_runs_concurrent_claude_sends_in_parallel | Claude turns for different conversations run at the same time instead of queueing on a shared turn slot. While one task's turn is held active, a second task's send starts in its own Claude process, runs its own tool, and completes with its own user and assistant messages before the held turn is released. Each turn's process uses its own task working directory, each conversation keeps only its own activity rows and measured durations, diagnostics record no queued-slot event and no prompt text, and the second conversation's answer is available while the first turn is still running.
    def test_conversation_runs_concurrent_claude_sends_in_parallel(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-parallel-sends"
        copy_file(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        first = self.assert_success(self.call_cli(
            "task", "create", "--title", "Held Claude conversation", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )[0])
        second = self.assert_success(self.call_cli(
            "task", "create", "--title", "Parallel Claude conversation", "--prompt", "Fixture task description.", "--root", self.secondary, "--provider", "claude"
        )[0])
        first_prompt = "Please hold-claude-turn-for-concurrency."
        second_prompt = "Inspect the workspace while the other conversation is busy."
        first_command = ["conversation", "send", first["id"], "--message", first_prompt]
        second_command = ["conversation", "send", second["id"], "--message", second_prompt]
        ready = Path(str(executable) + ".concurrent-turn-ready")
        release = Path(str(executable) + ".concurrent-turn-release")
        first_process = self.start_cli(*first_command, extra_environment=environment)
        second_process = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and first_process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The first Claude fixture turn should become active.")
            pending = second_process = self.start_cli(*second_command, extra_environment=environment)
            second_result, _ = self.finish_cli(pending, second_command)
            second_process = None
            self.assert_success(second_result)
            # The held turn is still running, so the second conversation ran its
            # own Claude process instead of waiting for a shared turn slot.
            self.assertIsNone(first_process.poll(), "The parallel Claude turn must complete while the first turn is still held.")
            release.write_text("Release the first Claude turn.\n", encoding="utf-8")
            first_result, _ = self.finish_cli(first_process, first_command)
            self.assert_success(first_result)
        finally:
            if first_process.poll() is None:
                release.write_text("Release the first Claude turn.\n", encoding="utf-8")
                try:
                    first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    first_process.communicate()
            if second_process is not None and second_process.poll() is None:
                second_process.terminate()
                second_process.communicate()

        first_history = self.assert_success(self.call_cli("conversation", "history", first["id"], extra_environment=environment)[0])
        self.assertIn(first_prompt, [message["text"] for message in first_history["messages"] if message["role"] == "user"])
        self.assertIn("OK.", [message["text"] for message in first_history["messages"] if message["role"] == "assistant"])
        second_history = self.assert_success(self.call_cli("conversation", "history", second["id"], extra_environment=environment)[0])
        self.assertIn(second_prompt, [message["text"] for message in second_history["messages"] if message["role"] == "user"])
        self.assertIn(
            "Inspection done: the workspace is ready.",
            [message["text"] for message in second_history["messages"] if message["role"] == "assistant"],
        )

        # Activity rows and their measured durations belong to the conversation
        # that ran them, not to whichever Claude turn finished last.
        parallel_rows = [row for row in second_history["activities"] if row["id"] == "toolu_read"]
        self.assertEqual(len(parallel_rows), 1, second_history["activities"])
        self.assertEqual(parallel_rows[0]["status"], "completed")
        self.assertGreater(parallel_rows[0].get("durationMs", 0), 0, parallel_rows[0])
        self.assertEqual([], [row for row in first_history["activities"] if row["id"] == "toolu_read"])

        turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
        working_directories = {
            turn["userText"]: Path(turn["cwd"]).resolve()
            for turn in turns if turn.get("userText") in {first_prompt, second_prompt}
        }
        self.assertEqual(working_directories.get(first_prompt), Path(self.primary).resolve())
        self.assertEqual(working_directories.get(second_prompt), Path(self.secondary).resolve())

        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("claude.turn.queued", diagnostics, "Parallel Claude turns must not wait on a shared turn slot.")
        self.assertNotIn(second_prompt, diagnostics, "Diagnostics must not include conversation prompt text.")
        first_record = self.assert_success(self.call_cli("task", "get", first["id"])[0])
        second_record = self.assert_success(self.call_cli("task", "get", second["id"])[0])
        fixture_sessions = {turn.get("sessionID") for turn in turns}
        self.assertIn(first_record.get("claudeSessionID"), fixture_sessions, turns)
        self.assertIn(second_record.get("claudeSessionID"), fixture_sessions, turns)
    # case-contract: test_conversation_isolates_failing_claude_turn_from_parallel_send | A failing Claude turn does not disturb a conversation running in parallel. While one task's turn is held and then fails, a second task's send from a separate process completes on its own session and reaches Waiting Response; the failing task keeps its user message in its conversation, where the open and reopened task show it, with an empty composer and no unsent draft, records no final answer, and its provider process exit is the only failure in diagnostics. The UI shows the parallel answer after reopening its task with fresh history. While the failing task's conversation is open and its turn held, the parallel turn starts, finishes and advances only its own revision: CLI/XPC runtime still reports the held session active and interruptible and the parallel session inactive, and the open conversation still offers an enabled Stop and never shows the parallel answer.
    def test_conversation_isolates_failing_claude_turn_from_parallel_send(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-parallel-failure"
        copy_file(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        first = self.assert_success(self.call_cli(
            "task", "create", "--title", "Failing Claude conversation", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )[0])
        second = self.assert_success(self.call_cli(
            "task", "create", "--title", "Unaffected Claude conversation", "--prompt", "Fixture task description.", "--root", self.secondary, "--provider", "claude"
        )[0])
        # The create-time prompt is an unsent draft that a send leaves alone; clear it so the
        # assertions below see only what the sent prompt does.
        self.assert_success(self.call_cli("task", "draft", first["id"], "--text", "")[0])
        first_prompt = "Please fail-after-hold-claude-turn-for-concurrency."
        second_prompt = "Second Claude turn after failure."
        first_command = ["conversation", "send", first["id"], "--message", first_prompt]
        second_command = ["conversation", "send", second["id"], "--message", second_prompt]
        ready = Path(str(executable) + ".concurrent-turn-ready")
        release = Path(str(executable) + ".concurrent-turn-release")
        first_process = self.start_cli(*first_command, extra_environment=environment)
        second_process = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and first_process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The failing Claude turn should reach its held active state.")
            pending = second_process = self.start_cli(*second_command, extra_environment=environment)
            completed, _ = self.finish_cli(pending, second_command)
            second_process = None
            self.assert_success(completed)
            self.assertIsNone(first_process.poll(), "The unaffected conversation must complete while the failing turn is still held.")
            # The parallel turn started, finished and advanced its own revision; the held turn's
            # runtime state is untouched by it.
            held_session = self.assert_success(self.call_cli("task", "get", first["id"])[0]).get("claudeSessionID")
            parallel_session = self.assert_success(self.call_cli("task", "get", second["id"])[0]).get("claudeSessionID")
            self.assertTrue(held_session and parallel_session and held_session != parallel_session)
            runtime = self.assert_success(self.call_cli("conversation", "runtime")[0])
            self.assertIn(held_session, runtime.get("activeThreadIDs", []), runtime)
            self.assertIn(held_session, runtime.get("interruptibleThreadIDs", []), runtime)
            self.assertNotIn(parallel_session, runtime.get("activeThreadIDs", []), runtime)
            self.assertIn(second["id"], runtime.get("conversationRevisions", {}), runtime)
            release.write_text("Fail the first Claude turn.\n", encoding="utf-8")
            failed, _ = self.finish_cli(first_process, first_command, expected_status=1)
            self.assertFalse(failed.get("ok"), failed)
            self.assertIn("Claude Code exited with status 1.", failed.get("error", {}).get("message", ""), failed)
        finally:
            if first_process.poll() is None:
                release.write_text("Fail the first Claude turn.\n", encoding="utf-8")
                try:
                    first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    first_process.communicate()
            if second_process is not None and second_process.poll() is None:
                second_process.terminate()
                second_process.communicate()

        second_record = self.assert_success(self.call_cli("task", "get", second["id"])[0])
        self.assertEqual(second_record.get("status"), "Waiting Response")
        second_history = self.assert_success(self.call_cli("conversation", "history", second["id"], extra_environment=environment)[0])
        self.assertIn(second_prompt, [message["text"] for message in second_history["messages"] if message["role"] == "user"])
        self.assertIn("OK.", [message["text"] for message in second_history["messages"] if message["role"] == "assistant"])
        first_history = self.assert_success(self.call_cli("conversation", "history", first["id"], extra_environment=environment)[0])
        self.assertIn(first_prompt, [message["text"] for message in first_history["messages"] if message["role"] == "user"])
        self.assertEqual(
            [],
            [message for message in first_history["messages"] if message.get("phase") == "final_answer"],
            "The failing conversation must not record an answer.",
        )

        diagnostics = (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8")
        first_record = self.assert_success(self.call_cli("task", "get", first["id"])[0])
        self.assertFalse(first_record["hasUnsentDraft"], "The failing turn's prompt stays in history, not in an unsent draft.")
        exits = [
            json.loads(line) for line in diagnostics.splitlines()
            if '"event":"claude.process.exited"' in line and json.loads(line).get("exitStatus") == "1"
        ]
        self.assertTrue(exits, diagnostics)
        self.assertEqual(
            {item.get("activeThreadID") for item in exits},
            {first_record.get("claudeSessionID")},
            "Only the failing conversation's Claude process should exit with a failure.",
        )
    # case-contract: test_claude_stop_leaves_parallel_conversation_running | Stopping one Claude turn pauses only that conversation while a second Claude conversation runs in parallel. The parallel conversation answers and keeps its own activity rows and measured durations while the first turn is still thinking; the stopped task moves to Waiting Response with no failure reason, records no answer, and leaves the parallel task's Waiting Response result untouched. A fresh CLI/XPC read confirms both results.
    def test_claude_stop_leaves_parallel_conversation_running(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-parallel-stop"
        copy_file(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        stopped = self.assert_success(self.call_cli(
            "task", "create", "--title", "Stopped Claude conversation", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )[0])
        running = self.assert_success(self.call_cli(
            "task", "create", "--title", "Running Claude conversation", "--prompt", "Fixture task description.", "--root", self.secondary, "--provider", "claude"
        )[0])
        parallel_prompt = "Inspect the workspace while the other conversation is busy."
        hold_command = ["conversation", "send", stopped["id"], "--message", "Hold until stopped."]
        parallel_command = ["conversation", "send", running["id"], "--message", parallel_prompt]
        ready = Path(str(executable) + ".interrupt-ready")
        received = Path(str(executable) + ".interrupt-received")
        release = Path(str(executable) + ".interrupt-release")
        hold_process = self.start_cli(*hold_command, extra_environment=environment)
        parallel_process = None
        stop_results = {}
        stop_failures = []
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.is_file() and hold_process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.is_file(), "The stopped conversation should reach its active thinking state.")
            pending = parallel_process = self.start_cli(*parallel_command, extra_environment=environment)
            parallel_result, _ = self.finish_cli(pending, parallel_command)
            parallel_process = None
            self.assert_success(parallel_result)
            self.assertIsNone(hold_process.poll(), "The parallel conversation must finish while the other turn is still thinking.")

            def stop_turn():
                try:
                    stop_results["response"] = self.call_cli(
                        "conversation", "stop", stopped["id"], timeout=20, extra_environment=environment
                    )[0]
                except Exception as error:  # noqa: BLE001 - surfaced through stop_failures
                    stop_failures.append(error)

            stopper = threading.Thread(target=stop_turn, daemon=True)
            stopper.start()
            interrupt_deadline = time.monotonic() + 10
            while not received.is_file() and time.monotonic() < interrupt_deadline:
                time.sleep(0.02)
            self.assertTrue(received.is_file(), "Claude should receive its native interrupt for the stopped conversation.")
            release.write_text("acknowledge interrupt\n", encoding="utf-8")
            stopper.join(timeout=20)
            self.assertFalse(stopper.is_alive(), "The Claude interrupt acknowledgment should settle.")
            self.assertEqual(stop_failures, [])
            self.assertTrue(self.assert_success(stop_results["response"])["interrupted"])
            interrupted_send, _ = self.finish_cli(hold_process, hold_command, expected_status=1)
            self.assertFalse(interrupted_send.get("ok", True), interrupted_send)
        finally:
            if hold_process.poll() is None:
                release.write_text("acknowledge interrupt\n", encoding="utf-8")
                try:
                    hold_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    hold_process.kill()
                    hold_process.communicate()
            if parallel_process is not None and parallel_process.poll() is None:
                parallel_process.terminate()
                parallel_process.communicate()

        # Only the stopped conversation carries the paused result.
        stopped_record = self.assert_success(self.call_cli("task", "get", stopped["id"])[0])
        self.assertEqual(stopped_record["status"], "Waiting Response")
        self.assertIsNone(stopped_record.get("statusMessage"), "A user-requested stop should not leave a failure reason.")
        running_record = self.assert_success(self.call_cli("task", "get", running["id"])[0])
        self.assertEqual(running_record["status"], "Waiting Response")
        self.assertIsNone(running_record.get("statusMessage"))

        stopped_history = self.assert_success(self.call_cli("conversation", "history", stopped["id"], extra_environment=environment)[0])
        self.assertEqual(
            [],
            [message for message in stopped_history["messages"] if message.get("phase") == "final_answer"],
            "The stopped conversation must not record an answer.",
        )
        running_history = self.assert_success(self.call_cli("conversation", "history", running["id"], extra_environment=environment)[0])
        self.assertIn(parallel_prompt, [message["text"] for message in running_history["messages"] if message["role"] == "user"])
        self.assertIn(
            "Inspection done: the workspace is ready.",
            [message["text"] for message in running_history["messages"] if message["role"] == "assistant"],
        )
        running_rows = [row for row in running_history["activities"] if row["id"] == "toolu_read"]
        self.assertEqual(len(running_rows), 1, running_history["activities"])
        self.assertGreater(running_rows[0].get("durationMs", 0), 0, running_rows[0])
        self.assertEqual([], [row for row in stopped_history["activities"] if row["id"] == "toolu_read"])
    # case-contract: test_conversation_serializes_concurrent_sends | Two concurrent sends for the same task are serialized across the app and CLI/XPC paths against the local Codex app-server fixture; the second waits for the first, both complete on the persisted thread, the task remains In Progress while a send is active, and successful turns without outcome calls finish in Waiting Response.
    def test_conversation_serializes_concurrent_sends(self):
        task = self.create_repo_task("Concurrent conversation sends", [self.primary])
        task_id = task["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-concurrent-serial-success-wait"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )

        first_prompt = "First serialized message."
        second_prompt = "Second serialized message."
        first_command = ["conversation", "send", task_id, "--message", first_prompt]
        second_command = ["conversation", "send", task_id, "--message", second_prompt]
        first_process = self.start_cli(
            *first_command,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        second_process = None
        release_marker = Path(str(executable) + ".resolve-continue")
        first_ready = Path(str(executable) + ".resolve-ready")
        second_started = Path(str(executable) + ".serial-second-turn-started")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not first_ready.exists() and first_process.poll() is None:
                time.sleep(0.02)
            if not first_ready.exists():
                release_marker.write_text("Release the first serialized turn.\n", encoding="utf-8")
                try:
                    output, error_output = first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    output, error_output = first_process.communicate()
                self.fail(
                    "The first fixture send did not reach its pause before starting the second send: "
                    f"exit={first_process.returncode}; stdout={output}; stderr={error_output}"
                )

            time.sleep(0.1)
            steer_message = "Keep the current approach and prioritize the smaller change."
            steered, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steer_message,
                extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            self.assertTrue(self.assert_success(steered)["accepted"], "Steering should use the active XPC client and turn ID.")

            second_process = self.start_cli(
                *second_command,
                extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            time.sleep(0.25)
            self.assertIsNone(second_process.poll(), "The second send should wait for the conversation-turn reservation held by the first send.")
            self.assertFalse(
                second_started.exists(),
                "The shared app-server fixture must not receive the second turn until the first send releases its reservation.",
            )
            active = self.assert_success(self.call_cli("task", "get", task_id)[0])
            self.assertEqual(active["status"], "In Progress", "A queued send must not mark the task Blocked.")

            release_marker.write_text("Release the first serialized turn.\n", encoding="utf-8")
            first_response, _ = self.finish_cli(first_process, first_command)
            self.assert_success(first_response)
            second_response, _ = self.finish_cli(second_process, second_command)
            self.assert_success(second_response)
        finally:
            if first_process.poll() is None:
                release_marker.write_text("Release the first serialized turn.\n", encoding="utf-8")
                try:
                    first_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    first_process.kill()
                    first_process.communicate()
            if second_process is not None and second_process.poll() is None:
                try:
                    second_process.communicate(timeout=20)
                except subprocess.TimeoutExpired:
                    second_process.kill()
                    second_process.communicate()

        saved_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(
            [turn["userMessage"] for turn in saved_history["messages"]
             if "playhouse internal outcome nudge:" not in (turn["userMessage"] or "").lower()],
            [first_prompt, second_prompt],
            "Both sequential turns should persist in the same Codex thread history.",
        )
        thread_id = saved_history["threadID"]
        thread_events = [event for event in saved_history["events"] if event["method"].startswith("thread/")]
        self.assertEqual([event["method"] for event in thread_events].count("thread/start"), 1)
        self.assertGreaterEqual([event["method"] for event in thread_events].count("thread/resume"), 1)
        self.assertTrue(all(event["threadID"] == thread_id for event in saved_history["events"]))
        visible_turns = [turn for turn in saved_history["messages"]
                         if "playhouse internal outcome nudge:" not in (turn["userMessage"] or "").lower()]
        self.assertTrue(all(turn["threadID"] == thread_id for turn in visible_turns))
        turn_ids = [turn["turnID"] for turn in visible_turns]
        self.assertEqual(len(turn_ids), 2)
        self.assertEqual(len(set(turn_ids)), 2, "Each serialized send should have its own Codex turn ID.")
        self.assertEqual(
            [event["turnID"] for event in saved_history["events"]
             if event["method"] == "turn/start" and "playhouse internal outcome nudge:" not in (event.get("userMessage") or "").lower()],
            turn_ids,
        )
        completed = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(completed["codexThreadID"], thread_id)
        self.assertEqual(completed["status"], "Waiting Response")
        self.assertEqual(len(saved_history.get("steerRequests", [])), 1)
        steer_params = saved_history["steerRequests"][0]
        self.assertEqual(steer_params["threadId"], thread_id)
        self.assertEqual(steer_params["input"], [{"type": "text", "text": steer_message}])
        self.assertTrue(steer_params["expectedTurnId"], "Steering must identify the matching active turn.")

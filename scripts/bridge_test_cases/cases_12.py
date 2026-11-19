from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases12:
    # case-contract: test_conversation_shows_mcp_and_dynamic_tool_activity | MCP and dynamic tool lifecycle updates coalesce by stable item ID into distinct visible conversation rows; each call reports its start and measured duration, and completed durations persist through history reload. While a tool call holds the sent turn active, the transcript never shows blank space: the submitted user message is in view, or, once the turn's activity has outgrown the viewport and the transcript follows it, the message sits above the latest live activity, which is in view. The latest active process, including a long command, appears outside Working for on one truncated line; older active processes remain inside, and completion moves it inside. The conversation header has no live activity line while responding. Working for renders open while the turn runs, so its progress is visible without a click and lists the in-flight calls instead of a Thinking row, and it is still open after leaving and reopening the task mid-turn; every in-flight call is readable from mid-turn history. A collapse the reader performs mid-turn is honored and survives the activity updates that follow, and the final answer closes the section back into a clean collapsed Worked for. The expanded Working for list shows each call's live or completed duration. In-progress, completed, and failed statuses, server/tool identity, and safe result summaries render without duplicate rows in the live turn and in history reloaded from Playhouse's store. Arguments and raw result text are never exposed.
    def test_conversation_shows_mcp_and_dynamic_tool_activity(self):
        task_id = self.create_task(title="Tool activity")['id']
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-tool-activity"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
            "PLAYHOUSE_FIXTURE_WORKSPACE": str(self.primary),
        }
        send_command = ("conversation", "send", task_id, "--message", "Show tool activity.")
        process = self.start_cli(*send_command, extra_environment=env, binary_output=True)
        ready = Path(str(executable) + ".tool-ready")
        release_latest = Path(str(executable) + ".tool-release-latest")
        release = Path(str(executable) + ".tool-release")
        captured_lines = []
        stream_buffer = bytearray()
        active_rows = {}
        completed_rows = {}
        expected_tool_ids = {"item_fixture_mcp_call", "item_fixture_dynamic_call", "item_fixture_dynamic_legacy", "item_fixture_active_long_command"}
        try:
            deadline = time.monotonic() + 20
            while (not ready.exists() or not expected_tool_ids.issubset(active_rows)) and time.monotonic() < deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        stream_buffer.extend(chunk)
                        while b"\n" in stream_buffer:
                            line, _, remainder = stream_buffer.partition(b"\n")
                            stream_buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured_lines.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            if event.get("type") == "activity" and activity.get("status") == "inProgress":
                                active_rows[activity.get("id")] = activity
                            elif event.get("type") == "activity" and activity.get("status") in {"completed", "failed"}:
                                completed_rows[activity.get("id")] = activity
            self.assertTrue(ready.exists(), "The fixture should hold both tool calls after their start notifications.")
            self.assertTrue(expected_tool_ids.issubset(active_rows), "All expected tool calls should publish their started state.")
            held_history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
            held_messages = self.assert_success(held_history)["messages"]
            self.assertIn("Show tool activity.", [message["text"] for message in held_messages], "The submitted user message should remain in persisted history while the provider turn is held active.")
            # The turn's activity section renders open before the final answer, so every
            # in-flight call must be readable mid-turn, not only once the turn settles.
            held_activities = {row["id"]: row for row in self.assert_success(held_history)["activities"]}
            self.assertTrue(expected_tool_ids.issubset(held_activities), f"Every in-flight tool call should be readable mid-turn; got {sorted(held_activities)}.")
            for tool_id in expected_tool_ids:
                self.assertEqual(held_activities[tool_id]["status"], "inProgress", f"{tool_id} should still read as in progress while the turn is held.")
            self.assertEqual(active_rows["item_fixture_mcp_call"]["toolKind"], "mcp")
            self.assertEqual(active_rows["item_fixture_dynamic_call"]["toolKind"], "dynamic")
            self.assertEqual(active_rows["item_fixture_dynamic_legacy"]["toolKind"], "dynamic")
            self.assertTrue(active_rows["item_fixture_active_long_command"]["title"].startswith("Running long-command-name"))
            self.assertGreater(len(active_rows["item_fixture_active_long_command"]["title"]), 200)
            self.assertTrue(all(row.get("startedAt") for row in active_rows.values()), "Every active call should report its start time.")
            release_latest.write_text("Finish the newest call first.\n", encoding="utf-8")
            latest_deadline = time.monotonic() + 20
            while "item_fixture_active_long_command" not in completed_rows and time.monotonic() < latest_deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        stream_buffer.extend(chunk)
                        while b"\n" in stream_buffer:
                            line, _, remainder = stream_buffer.partition(b"\n")
                            stream_buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured_lines.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            if event.get("type") == "activity" and activity.get("status") in {"completed", "failed"}:
                                completed_rows[activity.get("id")] = activity
            self.assertIn("item_fixture_active_long_command", completed_rows, "The newest command should finish before older active calls.")
            self.assertGreater(completed_rows["item_fixture_active_long_command"].get("durationMs", 0), 0)
            self.assertNotIn("item_fixture_dynamic_call", completed_rows, "Finishing the newest call must leave older calls active.")
            release.write_text("Release tool completions.\n", encoding="utf-8")
            remaining_stdout, remaining_stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {send_command}: {remaining_stderr!r}")
            all_output = "\n".join(captured_lines).encode("utf-8") + b"\n" + remaining_stdout
            response_lines = [line for line in all_output.splitlines() if line.strip()]
            sent = json.loads(response_lines[-1])
            self.assertEqual(sent.get("version"), 1)
            self.assertTrue(sent.get("ok"), sent.get("error"))
        finally:
            if process.poll() is None:
                release_latest.write_text("Release newest call after assertion failure.\n", encoding="utf-8")
                release.write_text("Release tool completions after assertion failure.\n", encoding="utf-8")
                process.communicate(timeout=30)
        result = self.assert_success(sent)
        activities = result["activities"]
        mcp_rows = [row for row in activities if row["id"] == "item_fixture_mcp_call"]
        dynamic_rows = [row for row in activities if row["id"] == "item_fixture_dynamic_call"]
        self.assertEqual(len(mcp_rows), 1)
        self.assertEqual(len(dynamic_rows), 1)
        self.assertEqual(mcp_rows[0]["status"], "completed")
        self.assertEqual(mcp_rows[0]["server"], "fixture-server")
        self.assertEqual(mcp_rows[0]["tool"], "lookup")
        self.assertIn("Returned 1 result item", mcp_rows[0]["detail"])
        self.assertEqual(dynamic_rows[0]["status"], "failed")
        self.assertEqual(dynamic_rows[0]["durationMs"], 37)
        legacy_rows = [row for row in activities if row["id"] == "item_fixture_dynamic_legacy"]
        self.assertEqual(len(legacy_rows), 1)
        self.assertEqual(legacy_rows[0]["status"], "completed")
        self.assertGreater(legacy_rows[0].get("durationMs", 0), 0)
        self.assertGreater(mcp_rows[0].get("durationMs", 0), 0)
        self.assertIn("Returned 1 result item", legacy_rows[0]["detail"])
        serialized = json.dumps(activities)
        self.assertNotIn("RAW_ARGUMENT_SECRET", serialized)
        self.assertNotIn("RAW_RESULT_SECRET", serialized)
        reloaded_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_rows = self.assert_success(reloaded_response)["activities"]
        reloaded_mcp = [row for row in reloaded_rows if row["id"] == "item_fixture_mcp_call"]
        reloaded_dynamic = [row for row in reloaded_rows if row["id"] == "item_fixture_dynamic_call"]
        reloaded_legacy = [row for row in reloaded_rows if row["id"] == "item_fixture_dynamic_legacy"]
        self.assertEqual(len(reloaded_mcp), 1)
        self.assertEqual(len(reloaded_dynamic), 1)
        self.assertEqual(len(reloaded_legacy), 1)
        self.assertEqual(reloaded_mcp[0]["tool"], "lookup")
        self.assertEqual(reloaded_dynamic[0]["tool"], "summarize")
        self.assertEqual(reloaded_dynamic[0]["durationMs"], 37)
        self.assertGreater(reloaded_legacy[0].get("durationMs", 0), 0)
        self.assertGreater(reloaded_mcp[0].get("durationMs", 0), 0)
        reloaded_serialized = json.dumps(reloaded_rows)
        self.assertNotIn("RAW_ARGUMENT_SECRET", reloaded_serialized)
        self.assertNotIn("RAW_RESULT_SECRET", reloaded_serialized)
        reloaded_result = self.assert_success(reloaded_response)
        self.assertIn("Show tool activity.", [message["text"] for message in reloaded_result["messages"]])
    # case-contract: test_conversation_shows_context_compaction | contextCompaction item/started and item/completed coalesce into one concise timeline event; missing summaries ignore malformed opaque payload fields and never render their data, and the event survives a fresh history reload from Playhouse's transcript store with correct prompt/response ordering.
    def test_conversation_shows_context_compaction(self):
        task_id = self.create_task(title="Context compaction")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-context-compaction"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable), "PLAYHOUSE_FIXTURE_WORKSPACE": str(self.primary)}
        command = ("conversation", "send", task_id, "--message", "Compact the context.")
        process = self.start_cli(*command, extra_environment=env, binary_output=True)
        ready = Path(str(executable) + ".compaction-ready")
        release = Path(str(executable) + ".compaction-release")
        captured, buffer, active = [], bytearray(), []
        try:
            deadline = time.monotonic() + 20
            while (not ready.exists() or not active) and time.monotonic() < deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        buffer.extend(os.read(process.stdout.fileno(), 65536))
                        while b"\n" in buffer:
                            line, _, remainder = buffer.partition(b"\n")
                            buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            if event.get("type") == "activity" and activity.get("isContextCompaction"):
                                active.append(activity)
            self.assertTrue(ready.exists())
            self.assertEqual(len(active), 1)
            self.assertEqual(active[0]["status"], "inProgress")
            release.write_text("Release compaction completion.\n", encoding="utf-8")
            stdout, stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {command}: {stderr!r}")
            sent = json.loads(("\n".join(captured).encode() + b"\n" + stdout).splitlines()[-1])
        finally:
            if process.poll() is None:
                release.write_text("Release compaction after assertion failure.\n", encoding="utf-8")
                process.communicate(timeout=30)
        result = self.assert_success(sent)
        rows = [item for item in result["activities"] if item.get("isContextCompaction")]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["id"], "item_playhouse_compaction")
        self.assertEqual(rows[0]["status"], "completed")
        self.assertEqual(rows[0]["detail"], "")
        reloaded_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded = self.assert_success(reloaded_response)
        reloaded_rows = [item for item in reloaded["activities"] if item.get("isContextCompaction")]
        self.assertEqual(len(reloaded_rows), 1)
        self.assertEqual(reloaded_rows[0]["status"], "completed")
        self.assertNotIn("COMPACTION_OPAQUE_SENTINEL", json.dumps(reloaded_rows))
        user = next(item for item in reloaded["messages"] if item.get("role") == "user")
        assistant = next(item for item in reloaded["messages"] if item.get("role") == "assistant")
        self.assertLess(user["timelineOrder"], reloaded_rows[0]["timelineOrder"])
        self.assertLess(reloaded_rows[0]["timelineOrder"], assistant["timelineOrder"])
    # case-contract: test_conversation_loads_newest_messages_before_older_history | Reopening a 120-message conversation, whose turns Playhouse holds in its own store, immediately presents only the latest user question, pinned to the top of the viewport with its answer below, which is taller than the viewport and runs on past its bottom. Scrolling upward reveals earlier messages automatically, a few at a time, starting from a reader already at the top of the rendered messages; they are revealed while the reader is near the oldest rendered message and stop once the reader rests away from it, while the message the reader is on stays in place and chronological order is preserved. A conversation that was empty when it opened establishes no window: when its sent turn streams sixty replies, each stored as its own message in order, it keeps the newest 40 of those 61 messages rendered as they arrive. Reopened once that turn settles, its sixty replies, all the turn's own with none of them progress that collapses, make a newest turn far longer than what a conversation renders when it opens: it opens at its end on the newest reply, renders only the messages above it that fill the viewport (more than the six it opens with, fewer than 40) and not the turn's question, and scrolling up reveals the earlier replies and reaches that question. Reloading history in place reopens on that same latest turn, pinned the same way, and keeps upward paging working: scrolling on to the top reveals every message, reading the stored page as needed, and reaches the first messages. CLI/XPC history remains complete and ordered across fresh reads and across an in-place provider switch, and a paged read returns only the newest 80 messages with the count of the 40 before them, while paging backward returns those earlier messages in order.
    def test_conversation_loads_newest_messages_before_older_history(self):
        task_id = self.create_task(title="Long conversation history")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-long-history-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable), "PLAYHOUSE_FIXTURE_WORKSPACE": str(self.primary)}
        sent, _ = self.call_cli("conversation", "send", task_id, "--message", "Create a long history.", extra_environment=env)
        self.assert_success(sent)
        # The sent turn's sixty replies arrive as one turn, each its own message in order: more than
        # the newest batch a conversation that was empty when it opened keeps rendered.
        live = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])["messages"]
        self.assertEqual(
            [message["text"] for message in live],
            ["Create a long history."] + [f"Live long history reply {index:02d}." for index in range(1, 61)],
        )
        # All sixty are the newest turn's own replies, none of them progress that collapses once
        # the turn settles, so reopening finds a newest turn far longer than the few messages a
        # conversation renders when it opens.
        self.assertEqual({message.get("turnID") for message in live[1:]}, {live[0].get("turnID")})
        self.assertNotIn(None, {message.get("turnID") for message in live})
        self.assertEqual({message.get("phase") for message in live[1:]}, {"final_answer"})
        # Earlier sessions' turns are already in Playhouse's own store; the provider holds none of them.
        self.seed_long_history(task_id, tall_latest_answer=True)
        history_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        messages = self.assert_success(history_response)["messages"]
        self.assertEqual(len(messages), 120)
        self.assertEqual(messages[0]["text"], "Long history user 01.")
        # The newest answer runs to many paragraphs, so the visible transcript can tell a
        # reopened conversation pinned to its question from one opened at its end.
        closing = messages[-1]["text"].split("\n\n")
        self.assertEqual(closing[0], "Long history assistant 60.")
        self.assertEqual(closing[1:], [f"Long history closing paragraph {number:02d}." for number in range(1, 31)])
        self.assertEqual(
            [message["text"] for message in messages[:4]],
            ["Long history user 01.", "Long history assistant 01.", "Long history user 02.", "Long history assistant 02."],
        )
        fresh_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        fresh_messages = self.assert_success(fresh_response)["messages"]
        self.assertEqual([message["text"] for message in fresh_messages], [message["text"] for message in messages])
        # An in-place reload (the provider switch the UI performs without
        # leaving the conversation) must keep the whole transcript available to
        # the window the transcript reopens on.
        switched, _ = self.call_cli("conversation", "provider", task_id, "set", "claude", extra_environment=env)
        self.assertEqual(self.assert_success(switched)["conversationProvider"], "claude")
        reloaded_response, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_messages = self.assert_success(reloaded_response)["messages"]
        self.assertEqual([message["text"] for message in reloaded_messages], [message["text"] for message in messages])
        # Paging reads only the stored turns that hold the requested messages.
        newest = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80", extra_environment=env)[0])
        self.assertEqual(newest["earlierMessageCount"], 40)
        self.assertEqual([message["text"] for message in newest["messages"]], [message["text"] for message in messages[40:]])
        # The transcript reports its size and pages backward from this count,
        # so the page and the count must add up to the whole.
        self.assertEqual(len(newest["messages"]) + newest["earlierMessageCount"], len(messages))
        older = self.assert_success(self.call_cli(
            "conversation", "history", task_id, "--limit", "80", "--before", newest["messages"][0]["id"], extra_environment=env
        )[0])
        self.assertEqual(older["earlierMessageCount"], 0)
        self.assertEqual([message["text"] for message in older["messages"]], [message["text"] for message in messages[:40]])
        paged_reads = [event for event in self.diagnostic_events()
                       if event.get("event") == "conversation.history.read" and event.get("taskID") == task_id.upper()
                       and event.get("messageLimit") == "80"]
        self.assertEqual([read["source"] for read in paged_reads], ["stored-page", "stored-page"],
                         "A Codex conversation pages straight from Playhouse's store, never from the app-server.")
    # case-contract: test_conversation_settled_history_renders_lazily | In a 120-message conversation whose history has been revealed, the messages before the newest turn render lazily: once the reader is back at the latest turn, the oldest messages that scrolled far out of view are no longer kept as views, and they render again, in order, when the reader scrolls back to them. A message scrolled away and back by the same distance lands where it was. A command an earlier turn ran stays inline after the message it followed, with its whole output in fresh CLI/XPC history, and a call the reader expanded is still expanded when its row renders again. A message holding an open side chat keeps rendering while the reader scrolls far away, so its bubble and unsent draft are still there when the reader returns. Changing the transcript's width keeps the reader on the message they were reading, with the older messages above still in order.
    def test_conversation_settled_history_renders_lazily(self):
        task_id = self.create_task(title="Lazy long history")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-long-history-lazy-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable), "PLAYHOUSE_FIXTURE_WORKSPACE": str(self.primary)}
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Create a long history.", extra_environment=env)[0])
        self.seed_long_history(task_id, mid_history_command=True)
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        messages = history["messages"]
        self.assertEqual([message["text"] for message in messages],
                         [f"Long history {role} {index:02d}." for index in range(1, 61) for role in ("user", "assistant")],
                         "The whole history is returned in order; the transcript renders it lazily.")
        # The earlier turn's command is a timeline activity placed after the message it followed,
        # carrying the whole output the expanded row shows.
        calls = [activity for activity in history.get("timelineActivities", []) if activity["id"] == "item_long_history_command_21"]
        self.assertEqual(len(calls), 1, "The mid-history command should be returned once as a timeline activity.")
        self.assertEqual(calls[0]["afterMessageID"], "item_long_history_user_21", "The command follows the question of its own turn.")
        self.assertEqual(calls[0]["output"].strip().splitlines(), [f"history-file-{line}.txt" for line in range(1, 7)],
                         "Every output line is kept, not only the ones a collapsed row shows.")
        self.assertNotIn("item_long_history_command_21", {activity["id"] for activity in history["activities"]},
                         "An earlier turn's call is not part of the latest turn's activities.")
        # The transcript shows a call inline only once its turn is settled, so the call's turn
        # must be an earlier turn than the latest one, shared with the question it follows.
        turn_by_message = {message["id"]: message.get("turnID") for message in messages}
        self.assertIsNotNone(turn_by_message["item_long_history_user_21"])
        self.assertNotEqual(turn_by_message["item_long_history_user_21"], turn_by_message["item_long_history_user_60"],
                            "Each history turn is its own turn, so turn 21 is settled once turn 60 exists.")
        self.assertEqual(calls[0].get("turnID"), turn_by_message["item_long_history_user_21"], "The call belongs to its question's turn.")
        fresh = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertEqual([message["id"] for message in fresh["messages"]], [message["id"] for message in messages])
        self.assertEqual([activity["id"] for activity in fresh.get("timelineActivities", [])],
                         [activity["id"] for activity in history.get("timelineActivities", [])],
                         "A fresh read returns the same timeline.")
    # case-contract: test_sent_prompt_stays_out_of_composer_past_history_page | A sent prompt followed by 120 stored messages, so that it lies outside the newest history page, never returns to the composer when the task is reopened: the composer is empty, the task keeps hasUnsentDraft false and its last sent prompt as the saved prompt, and the CLI newest page of 80 messages leaves out the earlier messages. Only the saved draft flag decides draft restoration, so the same task restores a real unsent draft after it is typed.
    def test_sent_prompt_stays_out_of_composer_past_history_page(self):
        task_id = self.create_task(title="Sent prompt past history page")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-long-history-with-prompt-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable), "PLAYHOUSE_FIXTURE_WORKSPACE": str(self.primary)}
        # The create-time prompt is an unsent draft that a send leaves alone. Clear it, as the
        # visible case clears the composer, so the sent prompt is the last sent prompt.
        created = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertTrue(created["hasUnsentDraft"], "A prompt given at creation is an unsent draft.")
        cleared_draft = self.assert_success(self.call_cli("task", "draft", task_id, "--text", "")[0])
        self.assertFalse(cleared_draft["hasUnsentDraft"])
        sent, _ = self.call_cli("conversation", "send", task_id, "--message", "Create a long history.", extra_environment=env)
        self.assert_success(sent)
        saved = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertFalse(saved["hasUnsentDraft"], "A sent prompt is the last sent prompt, not an unsent draft.")
        self.assertEqual(saved["savedPrompt"], "Create a long history.")
        self.seed_long_history(task_id, sent_prompt=True)
        full = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=env)[0])
        self.assertEqual(len(full["messages"]), 121)
        self.assertEqual(full["messages"][0]["text"], "Create a long history.", "The sent prompt is the first stored message.")
        # The view reads the newest page on reopen; the sent prompt's turn is outside it.
        reopened = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80", extra_environment=env)[0])
        self.assertEqual(len(reopened["messages"]), 80)
        self.assertEqual(reopened["earlierMessageCount"], 41)
        self.assertNotIn("Create a long history.", [message["text"] for message in reopened["messages"]])
        after_reopen = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertFalse(after_reopen["hasUnsentDraft"], "Reading a long history must not mark the sent prompt as a draft.")
        self.assertEqual(after_reopen["savedPrompt"], "Create a long history.")
        # A real unsent draft still survives reopening on the same long conversation.
        drafted = self.assert_success(self.call_cli("task", "draft", task_id, "--text", "Keep this draft.")[0])
        self.assertTrue(drafted["hasUnsentDraft"])
        reread = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertTrue(reread["hasUnsentDraft"])
        self.assertEqual(reread["savedPrompt"], "Keep this draft.")
    # case-contract: test_conversation_history_pages_claude_transcript_from_store | Claude turns are stored row by row in the SQLite conversation store: a user image is kept out of the message text payload, and recording a later turn writes only that turn's own rows without rewriting earlier turns. CLI/XPC history stays complete by default; with --limit it reads only the stored turns covering the newest messages and returns those messages plus the count of earlier ones, and --before pages backward to the first message, with pages that join into the complete ordered history, carry its activities, and fill in the image only on the page that holds its message; this still holds after another turn completes. A non-positive or non-numeric limit fails with invalid_argument, an unknown --before message fails with not_found, and an empty conversation returns an empty page. Reopening the conversation in the visible UI reads only the newest page and pins the latest turn, scrolling straight down from that pin keeps the latest question near the top and the latest answer below it with no blank overscroll, and scrolling up then reads the older page from the store ahead of the reader, while loaded messages still remain above the rendered ones, until the first turn and its image are shown, and a turn sent afterwards from the composer keeps the earlier pages loaded without reading them again. A Claude conversation that never chose a model resolves it from its stored turns, in CLI/XPC reads and in the reopened composer’s picker: the newest assistant message that names a model, not an older turn’s model or the provider-wide remembered selection.
    def test_conversation_history_pages_claude_transcript_from_store(self):
        claude = self.data_directory / "claude-fixture-long-history"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", claude)
        claude.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        fixtures = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude)}
        task_id = self.create_task("Claude paged history", roots=[self.primary])["id"]
        self.assert_success(self.call_cli("conversation", "provider", task_id, "set", "claude")[0])
        empty = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "10")[0])
        self.assertEqual((empty["messages"], empty["earlierMessageCount"]), ([], 0), "An empty conversation is an empty page.")

        image = self.data_directory / "first-turn.png"
        image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Long history turn 1.", "--image", str(image), extra_environment=fixtures
        )[0])
        database = self.conversation_database()
        key = task_id.upper()
        with sqlite3.connect(database, timeout=30) as connection:
            stored_turns_before = {row[0] for row in connection.execute("SELECT id FROM conversation_turns WHERE task_id = ?", (key,))}
            image_rows = connection.execute(
                "SELECT payload, image_data_urls FROM conversation_messages WHERE task_id = ? AND image_data_urls IS NOT NULL", (key,)
            ).fetchall()
            # Every later row write is logged, so the next turn proves it left earlier turns alone.
            connection.executescript("""
                CREATE TABLE test_row_writes (kind TEXT NOT NULL, turn_id TEXT NOT NULL);
                CREATE TRIGGER test_message_insert AFTER INSERT ON conversation_messages BEGIN INSERT INTO test_row_writes VALUES ('message', NEW.turn_id); END;
                CREATE TRIGGER test_message_update AFTER UPDATE ON conversation_messages BEGIN INSERT INTO test_row_writes VALUES ('message', NEW.turn_id); END;
                CREATE TRIGGER test_message_delete AFTER DELETE ON conversation_messages BEGIN INSERT INTO test_row_writes VALUES ('message', OLD.turn_id); END;
                CREATE TRIGGER test_activity_write AFTER UPDATE ON conversation_activities BEGIN INSERT INTO test_row_writes VALUES ('activity', NEW.turn_id); END;
                CREATE TRIGGER test_turn_write AFTER UPDATE ON conversation_turns BEGIN INSERT INTO test_row_writes VALUES ('turn', NEW.id); END;
            """)
        self.assertTrue(stored_turns_before, "The first Claude turn is stored as rows.")
        self.assertEqual(len(image_rows), 1, "The user image is stored once, in its own column.")
        image_payload, image_column = image_rows[0]
        self.assertEqual(json.loads(image_payload)["imageDataURLs"], [], "Image data stays out of the message text payload.")
        self.assertTrue(json.loads(image_column)[0].startswith("data:image/png;base64,"))

        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Long history turn 2.", extra_environment=fixtures)[0])
        with sqlite3.connect(database, timeout=30) as connection:
            writes = connection.execute("SELECT kind, turn_id FROM test_row_writes").fetchall()
            connection.executescript("""
                DROP TRIGGER test_message_insert; DROP TRIGGER test_message_update; DROP TRIGGER test_message_delete;
                DROP TRIGGER test_activity_write; DROP TRIGGER test_turn_write; DROP TABLE test_row_writes;
            """)
        self.assertGreaterEqual(len([write for write in writes if write[0] == "message"]), 31, "The second turn records its own messages.")
        self.assertEqual([write for write in writes if write[1] in stored_turns_before], [],
                         "Recording a later turn must not rewrite any row of an earlier turn.")
        for message in ("Long history turn 3.", "Say hello."):
            self.assert_success(self.call_cli("conversation", "send", task_id, "--message", message, extra_environment=fixtures)[0])

        full = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        messages = ordinary_messages(full["messages"])
        self.assertIsNone(full.get("earlierMessageCount"), "Default history is complete, not a page.")
        self.assertEqual(len(messages), 95)
        self.assertEqual([message["text"] for message in messages[:2]], ["Long history turn 1.", "Long history turn 1, message 1."])
        self.assertEqual(messages[31]["text"], "Long history turn 2.")
        self.assertEqual(messages[-2]["text"], "Say hello.")
        self.assertEqual(messages[-1]["text"], "OK.")
        self.assertEqual(len(messages[0]["imageDataURLs"]), 1, "Complete history includes the stored image.")
        self.assertTrue(all(not message["imageDataURLs"] for message in messages[1:]))

        def history_reads():
            return [event for event in self.diagnostic_events()
                    if event.get("event") == "conversation.history.read" and event.get("taskID") == key]

        def read_pages(full_history):
            reads_before = len(history_reads())
            pages = [self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "40")[0])]
            while pages[0]["earlierMessageCount"]:
                before = pages[0]["messages"][0]["id"]
                pages.insert(0, self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "40", "--before", before)[0]))
            self.assertEqual([message for page in pages for message in page["messages"]], full_history["messages"],
                             "Pages join into the complete ordered history, images included.")
            for page in pages:
                self.assertEqual(page["activities"], full_history["activities"], "Every page carries the conversation's activities.")
                self.assertEqual(page["providerBoundaries"], full_history["providerBoundaries"])
            self.assertTrue(all(not message["imageDataURLs"] for page in pages[1:] for message in page["messages"]),
                            "Only the page holding the image message carries image data.")
            reads = history_reads()[reads_before:]
            self.assertEqual({read["source"] for read in reads}, {"stored-page"},
                             "A Claude page is read from the stored turns it covers, not by composing the whole history.")
            self.assertEqual([read["hydratedImageMessageCount"] for read in reads], ["0"] * (len(pages) - 1) + ["1"])
            return pages

        pages = read_pages(full)
        # The status nudges Playhouse sent are messages too: 95 ordinary ones plus 4 nudge prompts and replies.
        self.assertEqual(len(full["messages"]), 99)
        self.assertEqual([len(page["messages"]) for page in pages], [19, 40, 40])
        self.assertEqual([page["earlierMessageCount"] for page in pages], [0, 19, 59])

        for limit in ("0", "-3", "many"):
            rejected, _ = self.call_cli("conversation", "history", task_id, "--limit", limit, expected_status=2)
            self.assert_failure(rejected, "invalid_argument")
        unknown, _ = self.call_cli("conversation", "history", task_id, "--limit", "5", "--before", "no-such-message", expected_status=3)
        self.assert_failure(unknown, "not_found")

        # Another completed turn leaves the earlier pages joinable and the first image intact.
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Say hello again.", extra_environment=fixtures)[0])
        grown = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        grown_ordinary = ordinary_messages(grown["messages"])
        self.assertEqual(len(grown_ordinary), 97)
        self.assertEqual(grown_ordinary[:95], messages, "A later turn does not change earlier messages.")
        pages = read_pages(grown)
        total = len(grown["messages"])
        self.assertEqual([page["earlierMessageCount"] for page in pages], [0, total - 80, total - 40])

        # A conversation that never chose a model resolves it from its stored turns: the newest
        # assistant message that names one, read without loading the whole conversation.
        model_task_id = self.create_task("Claude history model", roots=[self.primary])["id"]
        self.assert_success(self.call_cli("conversation", "provider", model_task_id, "set", "claude")[0])
        for _ in range(3):
            self.assert_success(self.call_cli("conversation", "send", model_task_id, "--message", "Say hello.", extra_environment=fixtures)[0])
        model_key = model_task_id.upper()
        with sqlite3.connect(database, timeout=30) as connection:
            turn_ids = [row[0] for row in connection.execute(
                "SELECT id FROM conversation_turns WHERE task_id = ? ORDER BY seq", (model_key,)
            )]
            self.assertGreaterEqual(len(turn_ids), 3)
            # The oldest turn ran on one model, the later ones on another, and the newest turn
            # predates recording a model at all.
            connection.execute(
                "UPDATE conversation_messages SET payload = json_set(payload, '$.modelID', 'claude-history-newer') "
                "WHERE task_id = ? AND json_extract(payload, '$.role') = 'assistant'", (model_key,)
            )
            connection.execute(
                "UPDATE conversation_messages SET payload = json_set(payload, '$.modelID', 'claude-history-older') "
                "WHERE task_id = ? AND turn_id = ? AND json_extract(payload, '$.role') = 'assistant'", (model_key, turn_ids[0])
            )
            connection.execute(
                "UPDATE conversation_messages SET payload = json_remove(payload, '$.modelID') WHERE task_id = ? AND turn_id = ?",
                (model_key, turn_ids[-1])
            )
        # The provider-wide remembered selection moves elsewhere; the conversation keeps its own.
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "claude-preference-choice")[0])
        for _ in range(2):
            self.assertEqual(
                self.assert_success(self.call_cli("conversation", "model", model_task_id)[0])["modelID"], "claude-history-newer",
                "The model comes from the newest stored assistant message that names one, not the oldest turn or the remembered selection.",
            )
    # case-contract: test_conversation_shows_subagent_delegation | During a parent turn, Working for renders open and active agents appear as individual named rows, each with an arrow that opens it, outside it, with available path/model/reasoning metadata and started-working wording; a mid-turn collapse the reader performs is honored. When the final answer arrives, all agent rows collapse inside Worked for alongside other Codex activity; expanding it reveals clickable agent rows. The UI fixture pauses after the final answer to verify this before turn completion while Stop response remains available. Completed, interrupted, and unknown states survive history reload and remain inspectable after reopening. The child thread opens as read-only through thread/read, thread/turns/list, and thread/items/list without editable controls or thread/resume, and diagnostics retain safe RPC outcomes while excluding conversation text, command output, and diffs. Multiple Codex message deltas and command-output deltas are summarized per item with counts and byte totals, flushed at turn completion, and excluded from individual notification records; lifecycle notifications remain individually logged, and diagnostics exclude conversation text, command output, and diffs. A fresh `conversation subagent-history` read returns the completed child's stored conversation content.
    def test_conversation_shows_subagent_delegation(self):
        task_id = self.create_task(title="Subagent delegation")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-subagent"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
            "PLAYHOUSE_FIXTURE_WORKSPACE": str(self.primary),
        }
        send_command = ("conversation", "send", task_id, "--message", "Delegate this task.")
        process = self.start_cli(*send_command, extra_environment=env, binary_output=True)
        ready = Path(str(executable) + ".subagent-ready")
        release = Path(str(executable) + ".subagent-release")
        captured_lines = []
        stream_buffer = bytearray()
        active_children = {}
        active_updates = []
        try:
            deadline = time.monotonic() + 15
            while (
                not ready.exists()
                or len(active_children) < 2
                or sum(
                    activity.get("childThreadID") == "00000000-0000-0000-0000-000000000002"
                    for activity in active_updates
                ) < 2
            ) and time.monotonic() < deadline:
                if process.stdout is not None:
                    readable, _, _ = select.select([process.stdout], [], [], 0.02)
                    if readable:
                        chunk = os.read(process.stdout.fileno(), 65536)
                        stream_buffer.extend(chunk)
                        while b"\n" in stream_buffer:
                            line, _, remainder = stream_buffer.partition(b"\n")
                            stream_buffer = bytearray(remainder)
                            if not line.strip():
                                continue
                            captured_lines.append(line.decode("utf-8"))
                            event = json.loads(line)
                            activity = event.get("payload", {}).get("activity", {})
                            child_thread_id = activity.get("childThreadID")
                            if event.get("type") == "activity" and child_thread_id and activity.get("status") == "inProgress":
                                active_children[child_thread_id] = activity
                                active_updates.append(activity)
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should expose an active child interval before completion.")
            self.assertEqual(set(active_children), {
                "00000000-0000-0000-0000-000000000002",
                "00000000-0000-0000-0000-000000000003",
            }, "Both child rows should be projected as active XPC events before completion.")
            self.assertIn("gpt-6-sol", active_children["00000000-0000-0000-0000-000000000002"]["detail"])
            self.assertEqual(active_children["00000000-0000-0000-0000-000000000003"]["title"], "Some agent")
            self.assertIn("/agents/some_agent", active_children["00000000-0000-0000-0000-000000000003"]["detail"])
            same_child_updates = [
                activity for activity in active_updates
                if activity.get("childThreadID") == "00000000-0000-0000-0000-000000000002"
            ]
            self.assertEqual(len(same_child_updates), 2, "Started and interacted updates should both target the same active child row.")
            self.assertEqual({activity["id"] for activity in same_child_updates}, {"00000000-0000-0000-0000-000000000002"})
            task_while_active, _ = self.call_cli("task", "get", task_id)
            self.assertEqual(self.assert_success(task_while_active)["status"], "In Progress")
            release.write_text("Release child completion.\n", encoding="utf-8")
            remaining_stdout, remaining_stderr = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, f"CLI exit mismatch for {send_command}: {remaining_stderr!r}")
            all_output = "\n".join(captured_lines).encode("utf-8") + b"\n" + remaining_stdout
            response_lines = [line for line in all_output.splitlines() if line.strip()]
            self.assertTrue(response_lines, f"CLI returned no JSON output for {send_command}.")
            sent = json.loads(response_lines[-1])
            self.assertEqual(sent.get("version"), 1)
            self.assertTrue(sent.get("ok"), sent.get("error"))
        finally:
            if process.poll() is None:
                release.write_text("Release child completion after assertion failure.\n", encoding="utf-8")
                process.communicate(timeout=30)
        result = self.assert_success(sent)
        activities = result["activities"]
        subagent = next(activity for activity in activities if activity["title"] == "Task delegated to subagent")
        self.assertEqual(subagent["status"], "completed")
        self.assertIn("Inspect the project structure", subagent["detail"])
        self.assertIn("Inspected the project structure", subagent["detail"])
        children = {activity["childThreadID"]: activity for activity in activities if activity.get("childThreadID")}
        self.assertEqual(set(children), {
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000003",
            "00000000-0000-0000-0000-000000000004",
        })
        sandbox_review = children["00000000-0000-0000-0000-000000000002"]
        self.assertEqual(sandbox_review["title"], "Sandbox review")
        self.assertEqual(sandbox_review["status"], "completed")
        self.assertIn("/agents/Sandbox review", sandbox_review["detail"])
        self.assertIn("gpt-6-sol", sandbox_review["detail"])
        self.assertIn("high", sandbox_review["detail"])
        docs_review = children["00000000-0000-0000-0000-000000000003"]
        self.assertEqual(docs_review["title"], "Some agent")
        self.assertEqual(docs_review["status"], "interrupted")
        self.assertNotIn("model", docs_review)
        self.assertNotIn("reasoningEffort", docs_review)
        self.assertEqual(children["00000000-0000-0000-0000-000000000004"]["status"], "futureKind")

        diagnostics = self.diagnostic_events()
        delta_summaries = [event for event in diagnostics if event.get("event") == "codex.notification.summary"]
        self.assertTrue(delta_summaries, "Streamed Codex deltas should be summarized rather than logged individually.")
        message_summary = next(event for event in delta_summaries if event.get("method") == "item/agentMessage/delta")
        self.assertGreaterEqual(int(message_summary.get("notificationCount", "0")), 2)
        self.assertGreater(int(message_summary.get("payloadBytes", "0")), 0)
        self.assertEqual(message_summary.get("flushReason"), "turn_completed")
        output_summary = next(event for event in delta_summaries if event.get("method") == "item/commandExecution/outputDelta")
        self.assertEqual(int(output_summary.get("notificationCount", "0")), 2)
        self.assertGreater(int(output_summary.get("payloadBytes", "0")), 0)
        self.assertEqual(output_summary.get("flushReason"), "turn_completed")
        self.assertFalse(any(
            event.get("event") == "codex.notification" and event.get("method") in {
                "item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"
            } for event in diagnostics
        ), "High-volume delta notifications should not each occupy a diagnostics record.")
        rpc_start = next(event for event in diagnostics if event.get("event") == "codex.rpc.request.started" and event.get("method") == "turn/start")
        self.assertIn("input", rpc_start.get("parameterNames", ""))
        self.assertTrue(any(
            event.get("event") == "codex.rpc.response.succeeded" and event.get("method") == "turn/start"
            for event in diagnostics
        ))
        command_event = next(
            event for event in diagnostics
            if event.get("event") == "codex.notification"
            and event.get("method") == "item/completed"
            and event.get("itemType") == "commandExecution"
        )
        self.assertEqual(command_event.get("command"), "git status --short")
        # The thread cwd Playhouse requested, as real Codex reports it.
        self.assertEqual(command_event.get("workingDirectory"), str(self.primary))
        self.assertGreater(int(command_event["outputBytes"]), 0)
        file_event = next(
            event for event in diagnostics
            if event.get("event") == "codex.notification"
            and event.get("method") == "item/completed"
            and event.get("itemType") == "fileChange"
        )
        self.assertEqual(file_event.get("changedPathCount"), "1")
        self.assertEqual(file_event.get("changedPaths"), "README.md")
        self.assertEqual(file_event.get("changeKinds"), "update")
        serialized_diagnostics = json.dumps(diagnostics)
        self.assertNotIn("CODEX_OUTPUT_NOT_LOGGED", serialized_diagnostics)
        self.assertNotIn("CODEX_DIFF_NOT_LOGGED", serialized_diagnostics)
        self.assertNotIn("CODEX_STREAMED_OUTPUT_NOT_LOGGED", serialized_diagnostics)
        self.assertNotIn("Delegate this task.", serialized_diagnostics)

        reloaded, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        history = self.assert_success(reloaded)
        self.assertEqual(
            {activity["id"]: activity for activity in history["activities"]},
            {activity["id"]: activity for activity in activities},
        )
        history_children = {activity["childThreadID"]: activity for activity in history["activities"] if activity.get("childThreadID")}
        self.assertEqual(
            {thread_id: activity["status"] for thread_id, activity in history_children.items()},
            {thread_id: activity["status"] for thread_id, activity in children.items()},
        )
        self.assertTrue(any("subagent inspected" in message["text"].lower() for message in history["messages"]))
        inspected = self.assert_success(self.call_cli(
            "conversation", "subagent-history", task_id, "--activity", json.dumps(sandbox_review), extra_environment=env
        )[0])
        self.assertTrue(
            any("found the required profile" in message["text"] for message in inspected["messages"]),
            "A fresh read-only subagent inspection should return the child conversation's stored content.",
        )
    # case-contract: test_plan_mode_renders_markdown_in_conversation | Selecting Plan mode keeps planning active across completed turns and reopening; follow-up instructions start another plan turn, and Start Implementing is hidden until a first message is sent and while the agent waits on answers to its questions, then stays enabled with an empty composer, switches to Code mode, and starts an implementation turn; subsequent composer messages remain Code turns. The plan renders automatically as Markdown with visible spacing, remains selectable and copyable as one complete text view, and CLI events and bridge history preserve the exact plan text and latest implementation handoff. Ordered list items stay on separate lines instead of being merged, including a list that starts on the line right after a paragraph without a blank line, a list that starts at 2 after a heading (rendered as items 2-5 with their real numbers, while a "3. " line inside a paragraph stays prose), and a fenced code block renders as a distinct block with its declared language label and a copy action that places its exact source on the pasteboard. A Markdown pipe table renders as a distinct bordered grid with a header row and data rows instead of raw pipe/dash text, preserving cell content and column alignment and wrapping a long cell onto every line it needs instead of cutting it off with an ellipsis, while CLI/XPC history preserves the exact raw table source text. Multiple plan deltas are summarized per item with count and byte totals at turn completion, with no per-delta notification records and no plan text in diagnostics. While the first plan is still streaming in and fits the viewport, the question that started it stays pinned near the top of the transcript, consistent with the user message preceding its final answer in CLI/XPC history. The plan streams in four held deltas that end inside a paragraph, inside a list item after it, and inside the fenced code block; CLI/XPC events carry exactly those deltas in order, and at each held stage the plan's one prose text view and its code block show exactly the text streamed so far, with nothing repeated or left over from an earlier stage, before the completed plan shows its whole code block.
    def test_plan_mode_renders_markdown_in_conversation(self):
        task_id = self.create_task(title="Plan mode Markdown", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-markdown"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        markdown_reply = "## Implementation plan\n\nStart with the **workspace model**.\n\nA separate paragraph confirms readable spacing between plan sections.\n\n- Implementation detail 01: verify the saved conversation state and rendered result\n- Implementation detail 02: verify the saved conversation state and rendered result\n- Implementation detail 03: verify the saved conversation state and rendered result\n- Implementation detail 04: verify the saved conversation state and rendered result\n- Implementation detail 05: verify the saved conversation state and rendered result\n- Implementation detail 06: verify the saved conversation state and rendered result\n- Implementation detail 07: verify the saved conversation state and rendered result\n- Implementation detail 08: verify the saved conversation state and rendered result\n- Implementation detail 09: verify the saved conversation state and rendered result\n- Implementation detail 10: verify the saved conversation state and rendered result\n- Implementation detail 11: verify the saved conversation state and rendered result\n- Implementation detail 12: verify the saved conversation state and rendered result\n- Implementation detail 13: verify the saved conversation state and rendered result\n- Implementation detail 14: verify the saved conversation state and rendered result\n- Implementation detail 15: verify the saved conversation state and rendered result\n- Implementation detail 16: verify the saved conversation state and rendered result\n- Implementation detail 17: verify the saved conversation state and rendered result\n- Implementation detail 18: verify the saved conversation state and rendered result\n- Implementation detail 19: verify the saved conversation state and rendered result\n- Implementation detail 20: verify the saved conversation state and rendered result\n- Implementation detail 21: verify the saved conversation state and rendered result\n- Implementation detail 22: verify the saved conversation state and rendered result\n- Implementation detail 23: verify the saved conversation state and rendered result\n- Implementation detail 24: verify the saved conversation state and rendered result\n- Implementation detail 25: verify the saved conversation state and rendered result\n- Implementation detail 26: verify the saved conversation state and rendered result\n- Implementation detail 27: verify the saved conversation state and rendered result\n- Implementation detail 28: verify the saved conversation state and rendered result\n- Implementation detail 29: verify the saved conversation state and rendered result\n- Final verification: confirm the latest message is visible after reopening\n\nTwo numbered steps follow on the very next lines:\n1. First numbered step: capture the baseline state before changes.\n\n2. Second numbered step: apply the fix and confirm there are no regressions.\n\n```javascript\nconsole.log(\"Hello, world!\");\n```\n\n| Step | Status |\n| --- | :---: |\n| Verify fixture | Done |\n| Render table | Pending |\n| Wrap long cell | This status note is deliberately long so that it has to wrap onto several lines inside its column instead of being cut off with an ellipsis, and it keeps going for a while longer so that even a wide window still needs at least three lines to show every word of it |\n\n## Still open\n\n2. Open question two: should the installed app differ from the dev build?\n3. Open question three: when should the app restart?\n4. Open question four: which version numbers do we use?\n5. Open question five: may we use the local test feed?\n\nModel sizes vary a lot in practice, and\n3. 5 billion parameters is a common size."
        sent, events = self.call_cli(
            "conversation", "send", task_id, "--message", "Plan the task.", "--mode", "plan",
            extra_environment=env,
        )
        deltas = [event["payload"]["text"] for event in events if event["type"] == "text_delta"]
        self.assertEqual("".join(deltas), markdown_reply, "The live plan deltas should stream the full plan.")
        list_item_end = markdown_reply.index("- Implementation detail 11: verify") + len("- Implementation detail 11: verify")
        code_end = markdown_reply.index('console.log("Hello') + len('console.log("Hello')
        self.assertEqual(
            deltas,
            [markdown_reply[:64], markdown_reply[64:list_item_end], markdown_reply[list_item_end:code_end], markdown_reply[code_end:]],
            "The plan should stream as it grows: ending inside a paragraph, a list item after it, then the code block.",
        )
        delta_positions = [index for index, event in enumerate(events) if event["type"] == "text_delta"]
        final_positions = [index for index, event in enumerate(events) if event["type"] == "assistant_final"]
        self.assertEqual(len(final_positions), 1, "The plan should produce one final assistant event.")
        self.assertLess(max(delta_positions), final_positions[0], "Plan deltas should arrive before completion.")
        self.assertEqual(
            [event["payload"]["text"] for event in events if event["type"] == "assistant_final"],
            [markdown_reply],
            "The completed plan item should publish one final assistant response.",
        )
        messages = self.assert_success(sent)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply
                            and message["phase"] == "final_answer" for message in messages))
        followup, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Revise the plan to clarify the persistence step.", "--mode", "plan",
            extra_environment=env,
        )
        self.assert_success(followup)
        implementation, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Start implementing the plan.", "--mode", "default",
            extra_environment=env,
        )
        implementation_messages = self.assert_success(implementation)["messages"]
        self.assertEqual(implementation_messages[-2]["text"], "Start implementing the plan.")
        continued, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Continue the implementation.", "--mode", "default",
            extra_environment=env,
        )
        continued_messages = self.assert_success(continued)["messages"]
        self.assertEqual(continued_messages[-2]["text"], "Continue the implementation.")
        fixture_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        turn_modes = [turn["conversationMode"] for turn in fixture_history["turns"]
                      if "playhouse internal outcome nudge:" not in (turn["userMessage"] or "").lower()]
        self.assertEqual(turn_modes, ["plan", "plan", "default", "default"], "Follow-up planning remains in Plan mode until implementation starts, and later implementation turns remain in Code mode.")
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=env)
        reloaded_messages = self.assert_success(history)["messages"]
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == markdown_reply
                            and message["phase"] == "final_answer" for message in reloaded_messages))
        # Playhouse sends an outcome nudge after a turn ends, and the store records it as
        # sent; the fixture completes it without a reply. Whether one has landed when history
        # is read depends on timing, so the assertions hold either way: the user's prompts are
        # stored once each in order, and nothing but nudges follows the latest reply.
        nudge_prefix = "Playhouse internal outcome nudge:"
        self.assertEqual([message["text"] for message in reloaded_messages
                          if message["role"] == "user" and not message["text"].startswith(nudge_prefix)],
                         ["Plan the task.", "Revise the plan to clarify the persistence step.",
                          "Start implementing the plan.", "Continue the implementation."],
                         "Each sent prompt is stored once, in order.")
        last_reply = max(index for index, message in enumerate(reloaded_messages) if message["role"] == "assistant")
        self.assertEqual([message for message in reloaded_messages[last_reply + 1:]
                          if not (message["role"] == "user" and message["text"].startswith(nudge_prefix))], [],
                         "The latest response should be last in bridge history, followed only by outcome nudges.")
        reloaded_plan = next(message["text"] for message in reloaded_messages
                             if message["role"] == "assistant" and message["phase"] == "final_answer")
        self.assertIn("| Step | Status |\n| --- | :---: |\n| Verify fixture | Done |", reloaded_plan,
                      "Bridge history should preserve the plan's raw Markdown table source for the client to render.")
        self.assertIn("| Wrap long cell | This status note is deliberately long", reloaded_plan,
                      "Bridge history should preserve a long table cell in full for the client to wrap.")
        self.assertIn("## Still open\n\n2. Open question two:", reloaded_plan,
                      "Bridge history should preserve a list that starts at 2 after a heading as raw Markdown for the client to render.")
        self.assertIn("\n\nModel sizes vary a lot in practice, and\n3. 5 billion parameters is a common size.", reloaded_plan,
                      "Bridge history should preserve a mid-paragraph '3. ' line untouched.")
        plan_diagnostics = self.diagnostic_events()
        plan_summary = next(event for event in plan_diagnostics
                            if event.get("event") == "codex.notification.summary"
                            and event.get("method") == "item/plan/delta")
        self.assertGreaterEqual(int(plan_summary.get("notificationCount", "0")), 2)
        self.assertGreater(int(plan_summary.get("payloadBytes", "0")), 0)
        self.assertEqual(plan_summary.get("flushReason"), "turn_completed")
        self.assertFalse(any(event.get("event") == "codex.notification" and event.get("method") == "item/plan/delta"
                             for event in plan_diagnostics))
        self.assertNotIn(markdown_reply, json.dumps(plan_diagnostics))
    # case-contract: test_start_implementing_explains_missing_repository | A task with neither a repository nor a working folder can still plan, but once the plan exists its Start Implementing button is disabled and explains why: its tooltip and accessibility value read "Add a repository to this task to start implementing.", and a visible No repository warning beside it carries the same reason and opens the repository picker. Bridge state for the planned task has no workspace roots and no repository worktrees. Adding a repository gives the task a workspace root; in the still-open conversation the warning disappears and Start Implementing enables without reopening the task, then switches to Code mode and starts an implementation turn recorded after the plan turn, which runs in the task's created repository worktree as its only workspace root.
    def test_start_implementing_explains_missing_repository(self):
        task_id = self.create_task(title="Plan without repository", roots=[])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-plan-handoff-markdown"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        planned, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Plan the task.", "--mode", "plan",
            extra_environment=env,
        )
        messages = self.assert_success(planned)["messages"]
        self.assertTrue(any(message["role"] == "user" and message["text"] == "Plan the task." for message in messages))
        self.assertTrue(any(message["role"] == "assistant" and message["phase"] == "final_answer" for message in messages),
                        "Planning needs no repository or folder.")
        # The handoff's availability reads these: with neither, Start Implementing explains the missing repository.
        response, _ = self.call_cli("task", "get", task_id)
        task = self.assert_success(response)
        self.assertEqual(task["workspaceRoots"], [], "A task created without a folder or repository has no workspace root.")
        self.assertEqual(task["repositoryWorktrees"], [])

        repository = self.data_directory / "plan-handoff-repository"
        repository.mkdir()
        (repository / "README.md").write_text("Plan handoff fixture.\n", encoding="utf-8")
        self.run_git(repository, "init", "--initial-branch=main")
        self.run_git(repository, "config", "user.name", "Playhouse Bridge Test")
        self.run_git(repository, "config", "user.email", "playhouse-bridge-test@example.invalid")
        self.run_git(repository, "add", "README.md")
        self.run_git(repository, "commit", "-m", "Baseline")
        added, _ = self.call_cli("task", "repository", "add", task_id, "--repo", str(repository))
        record = next(item for item in self.assert_success(added)["repositoryWorktrees"]
                      if item["repositoryPath"] == str(repository))
        self.assertFalse(record["isPending"], "Adding a repository to a started task creates its worktree.")
        self.assertTrue(Path(record["worktreePath"]).is_dir())
        response, _ = self.call_cli("task", "get", task_id)
        self.assertIn(record["worktreePath"], self.assert_success(response)["workspaceRoots"],
                      "A fresh read sees the worktree as the root implementation runs in.")

        implementation, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Start implementing the plan.", "--mode", "default",
            extra_environment=env,
        )
        self.assertEqual(self.assert_success(implementation)["messages"][-2]["text"], "Start implementing the plan.")
        fixture_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        turn_modes = [turn["conversationMode"] for turn in fixture_history["turns"]
                      if "playhouse internal outcome nudge:" not in (turn["userMessage"] or "").lower()]
        self.assertEqual(turn_modes, ["plan", "default"], "The handoff runs in Code mode after the plan turn.")
        response, _ = self.call_cli("task", "get", task_id)
        handed_off = self.assert_success(response)
        worktree = next(item for item in handed_off["repositoryWorktrees"] if item["repositoryPath"] == str(repository))
        self.assertFalse(worktree["isPending"])
        self.assertNotEqual(os.path.realpath(worktree["worktreePath"]), os.path.realpath(repository))
        self.assertEqual([os.path.realpath(root) for root in handed_off["workspaceRoots"]], [os.path.realpath(worktree["worktreePath"])],
                         "The implementation turn runs in the task's created worktree as its only root.")

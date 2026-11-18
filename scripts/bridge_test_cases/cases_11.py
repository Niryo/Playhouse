from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases11:
    # case-contract: test_conversation_steers_and_queues_active_turn | When a steer misses its active turn, CLI/XPC and UI accept it into the durable queue for its own turn; opening an empty task waits for the model-aware prompt and omits the generic Start a conversation heading; with no active turn, missed composer and queued-row steers start their own turns without blocking other steering and leave the queue; queued fallback survives process exit or app relaunch and is drained exactly once; a missed regular or queued-row steer arriving during targeted queue dispatch is drained afterward exactly once; a follow-up being delivered stays claimed as dispatching and leaves the visible queue while its own turn runs; a missed queued-row steer from the CLI returns to the waiting queue and shows its row again in the app before the targeted turn ends; a failed targeted turn remains needs-action and does not drain later messages; malformed steer images fail validation; CLI/XPC steering routes image data to a UI-owned active turn and appears in the conversation. Command-Return steers the active turn with attached text and images, then clears the accepted draft and image preview; if the active turn changes before delivery, it clears the draft and queues the complete message for its own turn; a steer the provider refuses for any other reason reports the provider's error, is not queued, and returns its text and image to the composer with no message left in the transcript. Plain Return queues a follow-up with its attached image, clears the preview, and marks the row with its image count; the queued image persists across reopening without returning to the composer, and malformed queued images fail validation. Its row Steer uses the active turn ID, delivers both text and image to the provider, appears in the transcript with its image, and removes the item only after acceptance. The obsolete footer Queue and Steer buttons are absent and the active response control is labeled Stop response. Follow-ups persist across reopening, expose per-row Steer, delete, and more actions, and a distinct after-turn follow-up dispatches once after a matching completion and is removed only after successful delivery; removing an unknown queue ID fails without changing the queue.
    def test_conversation_steers_and_queues_active_turn(self):
        task = self.create_repo_task("Active turn message controls", [self.primary])
        task_id = task["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-steer-queue-serial-success-wait"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        Path(str(executable) + ".reject-next-steer").write_text("The expected turn ID is stale.\n", encoding="utf-8")
        first_prompt = "Start the active turn before steering and queueing."
        steering_text = "Keep the current approach and simplify the final change."
        queued_text = "After the current work, verify the saved follow-up."
        send_command = ["conversation", "send", task_id, "--message", first_prompt]
        process = self.start_cli(
            *send_command,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        ready = Path(str(executable) + ".resolve-ready")
        release = Path(str(executable) + ".resolve-continue")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture should hold the first turn active for steering and queueing.")
            time.sleep(0.1)
            invalid_image = self.data_directory / "invalid-steer.png"
            invalid_image.write_bytes(b"not an image")
            invalid_steer, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steering_text, "--image", str(invalid_image),
                expected_status=2,
                extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            self.assertEqual(invalid_steer["error"]["code"], "invalid_argument")
            steer_image = self.data_directory / "steer.png"
            steer_image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
            missed_steer, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steering_text, "--image", str(steer_image),
                extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            missed_result = self.assert_success(missed_steer)
            self.assertTrue(missed_result["accepted"])
            self.assertTrue(missed_result["queued"])
            missed_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            missed_item = next(item for item in self.assert_success(missed_queue) if item["text"] == steering_text)
            self.assertEqual(missed_item["state"], "queued", "A stale steer should become an ordinary durable follow-up.")
            self.assertTrue(missed_item["imageDataURLs"][0].startswith("data:image/png;base64,"), "A queued CLI steer should retain its image.")
            steered, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", steering_text, "--image", str(steer_image),
                extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            self.assertTrue(self.assert_success(steered)["accepted"])
            # A refusal that is not a missed turn is an error: nothing is queued in its place.
            queue_before_refusal = self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0])
            Path(str(executable) + ".reject-next-steer").write_text("The fixture refused this steer.\n", encoding="utf-8")
            refused, _ = self.call_cli(
                "conversation", "steer", task_id, "--message", "Refuse this steer.", "--image", str(steer_image),
                expected_status=1, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
            )
            self.assertIn("refused this steer", refused["error"]["message"])
            self.assertEqual(
                self.assert_success(self.call_cli("conversation", "queue-list", task_id)[0]), queue_before_refusal,
                "A refused steer must not be queued for a turn of its own.",
            )
            queued, _ = self.call_cli("conversation", "queue", task_id, "--message", queued_text)
            queued_record = self.assert_success(queued)
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            persisted_ids = {item["id"] for item in self.assert_success(persisted)}
            self.assertEqual(persisted_ids, {queued_record["id"], missed_item["id"]}, "Fresh XPC reads should preserve both the ordinary follow-up and missed steer.")
            removable, _ = self.call_cli("conversation", "queue", task_id, "--message", "Remove this queued follow-up.")
            removable_record = self.assert_success(removable)
            removed, _ = self.call_cli("conversation", "queue-remove", task_id, removable_record["id"])
            self.assertTrue(self.assert_success(removed)["removed"])
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            self.assertEqual({item["id"] for item in self.assert_success(persisted)}, {queued_record["id"], missed_item["id"]})
            invalid_queue, _ = self.call_cli(
                "conversation", "queue", task_id, "--message", "Reject this queued image.", "--image", str(invalid_image),
                expected_status=2,
            )
            self.assertEqual(invalid_queue["error"]["code"], "invalid_argument", "A queued follow-up must validate its images.")
            steerable, _ = self.call_cli(
                "conversation", "queue", task_id, "--message", "Steer this queued follow-up now.", "--image", str(steer_image)
            )
            steerable_record = self.assert_success(steerable)
            self.assertTrue(steerable_record["imageDataURLs"][0].startswith("data:image/png;base64,"), "A queued follow-up should keep its image.")
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            steerable_item = next(item for item in self.assert_success(persisted) if item["id"] == steerable_record["id"])
            self.assertEqual(steerable_item["imageDataURLs"], steerable_record["imageDataURLs"], "A fresh read should return the queued image.")
            queued_steer, _ = self.call_cli("conversation", "queue-steer", task_id, steerable_record["id"])
            queued_steer_result = self.assert_success(queued_steer)
            self.assertTrue(queued_steer_result["accepted"])
            self.assertFalse(queued_steer_result["queued"])
            self.assertEqual(queued_steer_result["images"], steerable_record["imageDataURLs"], "A queued-row steer should report the image it delivered.")
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            self.assertEqual({item["id"] for item in self.assert_success(persisted)}, {queued_record["id"], missed_item["id"]})
            missed_row_item, _ = self.call_cli("conversation", "queue", task_id, "--message", "Keep this after a missed row steer.")
            missed_row_record = self.assert_success(missed_row_item)
            Path(str(executable) + ".reject-next-steer").write_text("expected active turn id stale-turn but found fixture-turn\n", encoding="utf-8")
            missed_queue_steer, _ = self.call_cli("conversation", "queue-steer", task_id, missed_row_record["id"])
            self.assertTrue(self.assert_success(missed_queue_steer)["accepted"])
            self.assertTrue(self.assert_success(missed_queue_steer)["queued"])
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            persisted_messages = self.assert_success(persisted)
            persisted_by_id = {item["id"]: item for item in persisted_messages}
            self.assertEqual(set(persisted_by_id), {queued_record["id"], missed_item["id"], missed_row_record["id"]})
            self.assertEqual(persisted_by_id[missed_row_record["id"]]["state"], "queued", "A missed row steer should return to ordinary queue delivery.")
            missing_remove, _ = self.call_cli(
                "conversation", "queue-remove", task_id, "00000000-0000-0000-0000-000000000000", expected_status=1
            )
            self.assert_failure(missing_remove, "invalid_transition")
            persisted, _ = self.call_cli("conversation", "queue-list", task_id)
            self.assertEqual(
                {item["id"] for item in self.assert_success(persisted)},
                {queued_record["id"], missed_item["id"], missed_row_record["id"]},
                "An unknown queue removal must leave all existing queued messages unchanged.",
            )
        finally:
            release.write_text("Release the active turn.\n", encoding="utf-8")
        self.finish_cli(process, send_command)

        history_response, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        history = self.assert_success(history_response)
        self.assertEqual([message["text"] for message in history["messages"] if message["role"] == "user"].count(queued_text), 1)
        self.assertEqual([message["text"] for message in history["messages"] if message["role"] == "user"].count("Keep this after a missed row steer."), 1)
        protocol_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(len(protocol_history["rejectedSteerRequests"]), 3, "Codex should have rejected both missed-turn steers, delivered later from the queue, and the refused one.")
        self.assertNotIn("Refuse this steer.", [turn["userMessage"] for turn in protocol_history["messages"]], "A refused steer never runs as a turn of its own.")
        missed_delivery = next(turn for turn in protocol_history["messages"] if turn["userMessage"] == steering_text)
        self.assertTrue(missed_delivery["images"][0].startswith("data:image/png;base64,"), "The missed CLI steer image should reach Codex on its own turn.")
        self.assertEqual(len(protocol_history["steerRequests"]), 2)
        steer = protocol_history["steerRequests"][0]
        self.assertEqual(steer["threadId"], protocol_history["threadID"])
        self.assertEqual(steer["input"][0], {"type": "text", "text": steering_text})
        self.assertEqual(steer["input"][1]["type"], "image")
        self.assertTrue(steer["input"][1]["url"].startswith("data:image/png;base64,"))
        self.assertEqual(steer["expectedTurnId"], protocol_history["messages"][0]["turnID"])
        self.assertEqual(
            protocol_history["steerRequests"][1]["input"],
            [{"type": "text", "text": "Steer this queued follow-up now."}, {"type": "image", "url": steerable_record["imageDataURLs"][0]}],
            "Steering a queued row should deliver its image to the active turn, not only its text.",
        )
        self.assertEqual(protocol_history["steerRequests"][1]["expectedTurnId"], protocol_history["messages"][0]["turnID"])
        queue_after_completion, _ = self.call_cli("conversation", "queue-list", task_id)
        self.assertEqual(self.assert_success(queue_after_completion), [], "Successful dispatch must be durable and nonduplicating across reload.")

        targeted_text = "Retry this row as its own turn."
        targeted_row, _ = self.call_cli("conversation", "queue", task_id, "--message", targeted_text)
        targeted_record = self.assert_success(targeted_row)
        Path(str(executable) + ".hold-next-queued-turn").write_text("hold targeted delivery\n", encoding="utf-8")
        targeted_command = ["conversation", "queue-steer", task_id, targeted_record["id"]]
        targeted_process = self.start_cli(
            *targeted_command,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        targeted_ready = Path(str(executable) + ".queued-turn-ready")
        targeted_release = Path(str(executable) + ".queued-turn-release")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not targeted_ready.exists():
            time.sleep(0.02)
        self.assertTrue(targeted_ready.exists(), "A missed queued-row steer should begin its own targeted turn.")
        targeted_result, _ = self.finish_cli(targeted_process, targeted_command)
        self.assertTrue(self.assert_success(targeted_result)["accepted"], "The steer request should return while its fallback turn is still running.")
        delivering_queue, _ = self.call_cli("conversation", "queue-list", task_id)
        delivering_item = next(item for item in self.assert_success(delivering_queue) if item["id"] == targeted_record["id"])
        self.assertEqual(delivering_item["state"], "dispatching", "A follow-up stays durably claimed while its own turn runs.")
        available_row, _ = self.call_cli("conversation", "queue", task_id, "--message", "Another follow-up remains steerable.")
        available_id = self.assert_success(available_row)["id"]
        available_result, _ = self.call_cli("conversation", "queue-steer", task_id, available_id)
        self.assertFalse(self.assert_success(available_result)["queued"], "Another queued message should steer the held fallback turn.")
        overlap_text = "Queue this steer behind the targeted turn."
        Path(str(executable) + ".reject-next-steer").write_text("no active turn to steer\n", encoding="utf-8")
        overlap_steer, _ = self.call_cli(
            "conversation", "steer", task_id, "--message", overlap_text,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assertTrue(self.assert_success(overlap_steer)["queued"], "A second missed steer should queue while targeted delivery is active.")
        overlap_queue, _ = self.call_cli("conversation", "queue-list", task_id)
        overlap_item = next(item for item in self.assert_success(overlap_queue) if item["text"] == overlap_text)
        self.assertEqual(overlap_item["state"], "queued")
        targeted_release.write_text("Release targeted delivery.\n", encoding="utf-8")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            if self.assert_success(current_queue) == []:
                break
            time.sleep(0.05)
        self.assertEqual(self.assert_success(current_queue), [], "A pending full drain should deliver the overlapping steer after targeted dispatch.")
        overlap_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        delivered_texts = [message["text"] for message in self.assert_success(overlap_history)["messages"] if message["role"] == "user"]
        self.assertEqual(delivered_texts.count(targeted_text), 1)
        self.assertEqual(delivered_texts.count(overlap_text), 1)

        targeted_row_text = "Retry another row as its own turn."
        targeted_row, _ = self.call_cli("conversation", "queue", task_id, "--message", targeted_row_text)
        targeted_row_record = self.assert_success(targeted_row)
        Path(str(executable) + ".hold-next-queued-turn").write_text("hold targeted row delivery\n", encoding="utf-8")
        targeted_row_command = ["conversation", "queue-steer", task_id, targeted_row_record["id"]]
        targeted_row_process = self.start_cli(
            *targeted_row_command,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not targeted_ready.exists():
            time.sleep(0.02)
        self.assertTrue(targeted_ready.exists(), "A second targeted row delivery should become active before the overlapping row steer.")
        missed_row_text = "Queue this missed row steer behind targeted dispatch."
        missed_row, _ = self.call_cli("conversation", "queue", task_id, "--message", missed_row_text)
        missed_row_record = self.assert_success(missed_row)
        Path(str(executable) + ".reject-next-steer").write_text("expected active turn id stale-turn but found fixture-turn\n", encoding="utf-8")
        overlapping_row_steer, _ = self.call_cli("conversation", "queue-steer", task_id, missed_row_record["id"])
        overlapping_row_result = self.assert_success(overlapping_row_steer)
        self.assertTrue(overlapping_row_result["accepted"])
        self.assertTrue(overlapping_row_result["queued"], "A missed queued-row steer should stay queued while targeted dispatch is active.")
        returned_queue, _ = self.call_cli("conversation", "queue-list", task_id)
        returned_item = next(item for item in self.assert_success(returned_queue) if item["id"] == missed_row_record["id"])
        self.assertEqual(returned_item["state"], "queued", "A missed queued-row steer from the CLI returns to the waiting queue before the targeted turn ends.")
        targeted_release.write_text("Release targeted row delivery.\n", encoding="utf-8")
        self.finish_cli(targeted_row_process, targeted_row_command)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            current_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            if self.assert_success(current_queue) == []:
                break
            time.sleep(0.05)
        self.assertEqual(self.assert_success(current_queue), [], "A missed queued-row steer should drain after the targeted row turn.")
        final_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        final_delivered = [message["text"] for message in self.assert_success(final_history)["messages"] if message["role"] == "user"]
        self.assertEqual(final_delivered.count(targeted_row_text), 1)
        self.assertEqual(final_delivered.count(missed_row_text), 1)

        regular_text = "Deliver a missed regular steer without blocking."
        Path(str(executable) + ".hold-next-queued-turn").write_text("hold regular fallback\n", encoding="utf-8")
        regular_result, _ = self.call_cli("conversation", "steer", task_id, "--message", regular_text, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)})
        self.assertTrue(self.assert_success(regular_result)["queued"], "The regular steer must return before its held fallback completes.")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not targeted_ready.exists():
            time.sleep(0.02)
        self.assertTrue(targeted_ready.exists(), "The missed regular steer should start its own held turn.")
        regular_available, _ = self.call_cli("conversation", "queue", task_id, "--message", "Steer while regular fallback runs.")
        regular_available_id = self.assert_success(regular_available)["id"]
        regular_steer, _ = self.call_cli("conversation", "queue-steer", task_id, regular_available_id, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)})
        self.assertFalse(self.assert_success(regular_steer)["queued"], "A second row should steer the held regular fallback.")
        targeted_release.write_text("Release regular fallback.\n", encoding="utf-8")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            regular_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            if self.assert_success(regular_queue) == []:
                break
            time.sleep(0.05)
        self.assertEqual(self.assert_success(regular_queue), [])
        regular_history, _ = self.call_cli("conversation", "history", task_id, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)})
        self.assertEqual([m["text"] for m in self.assert_success(regular_history)["messages"] if m["role"] == "user"].count(regular_text), 1)

        immediate_text = "Deliver this missed row immediately as its own turn."
        immediate_row, _ = self.call_cli("conversation", "queue", task_id, "--message", immediate_text)
        immediate_record = self.assert_success(immediate_row)
        immediate_steer, _ = self.call_cli(
            "conversation", "queue-steer", task_id, immediate_record["id"],
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        immediate_result = self.assert_success(immediate_steer)
        self.assertTrue(immediate_result["accepted"])
        self.assertTrue(immediate_result["queued"], "A missed no-active-turn steer should fall back through the ordinary queue.")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            immediate_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            if self.assert_success(immediate_queue) == []:
                break
            time.sleep(0.05)
        self.assertEqual(self.assert_success(immediate_queue), [], "The own-turn drain should finish after the request returns.")
        immediate_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        immediate_messages = [message["text"] for message in self.assert_success(immediate_history)["messages"] if message["role"] == "user"]
        self.assertEqual(immediate_messages.count(immediate_text), 1)

        failed_target_text = "This targeted queued turn should need action."
        later_text = "Keep this later message queued after a failure."
        failed_target, _ = self.call_cli("conversation", "queue", task_id, "--message", failed_target_text)
        failed_target_record = self.assert_success(failed_target)
        later_item, _ = self.call_cli("conversation", "queue", task_id, "--message", later_text)
        later_record = self.assert_success(later_item)
        Path(str(executable) + ".fail-next-turn-start").write_text("fail targeted turn start\n", encoding="utf-8")
        failed_steer, _ = self.call_cli("conversation", "queue-steer", task_id, failed_target_record["id"])
        failed_steer_result = self.assert_success(failed_steer)
        self.assertTrue(failed_steer_result["accepted"])
        self.assertTrue(failed_steer_result["queued"])
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            failure_queue, _ = self.call_cli("conversation", "queue-list", task_id)
            failure_items = {item["id"]: item for item in self.assert_success(failure_queue)}
            if failure_items.get(failed_target_record["id"], {}).get("state") == "needsAction":
                break
            time.sleep(0.05)
        self.assertEqual(failure_items[failed_target_record["id"]]["state"], "needsAction")
        self.assertEqual(failure_items[later_record["id"]]["state"], "queued", "A failed targeted send must not drain later queued messages.")
    # case-contract: test_conversation_sends_image_attachments | Backlog draft images persist through fresh CLI/XPC reads and reopening the conversation, with the preview restored; saving more than 8 draft images fails with invalid_argument and preserves the existing attachment. The conversation composer also accepts pasted images, compresses large clipboard images to fit the 10 MB payload limit, sends PNG and JPEG data URLs through CLI/XPC and to Codex using the tagged image URL payload, stores those image URLs with the turn in Playhouse's transcript store, and keeps earlier images visible after a later text turn and history refresh. The provider-neutral conversation present-image API is included in agent instructions, validates and persists agent-produced PNG and JPEG files as assistant messages, and reopening the conversation renders each image visibly. Diagnostics record image MIME and encoded size without storing image payloads. Clicking a composer attachment, a user transcript attachment, or an agent-published assistant image opens the original image in a large viewer, which can be closed to return to the conversation; a published assistant image preserves the original file bytes.
    def test_conversation_sends_image_attachments(self):
        task_id = self.create_task(title="Image conversation") ["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-image-serial-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        image = self.data_directory / "tiny.png"
        image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        backlog_task = self.create_task(title="Backlog image draft")
        draft_result, _ = self.call_cli("task", "prompt", backlog_task["id"], "--text", "", "--image", str(image))
        saved_draft = self.assert_success(draft_result)
        self.assertEqual(len(saved_draft["draftImageDataURLs"]), 1)
        self.assertTrue(saved_draft["draftImageDataURLs"][0].startswith("data:image/png;base64,"))
        fresh_draft, _ = self.call_cli("task", "get", backlog_task["id"])
        self.assertEqual(self.assert_success(fresh_draft)["draftImageDataURLs"], saved_draft["draftImageDataURLs"])
        excess_draft, _ = self.call_cli(
            "task", "prompt", backlog_task["id"], "--text", "",
            *[argument for _ in range(9) for argument in ("--image", str(image))],
            expected_status=2,
        )
        self.assertEqual(excess_draft.get("error", {}).get("code"), "invalid_argument")
        unchanged_draft, _ = self.call_cli("task", "get", backlog_task["id"])
        self.assertEqual(self.assert_success(unchanged_draft)["draftImageDataURLs"], saved_draft["draftImageDataURLs"])
        result, _ = self.call_cli(
            "conversation", "send", task_id, "--image", str(image),
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        initial_history = self.assert_success(result)
        sent = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(len(sent["images"]), 1)
        self.assertTrue(sent["images"][0].startswith("data:image/png;base64,"))
        self.assertEqual(sent["imageInputs"], [{"type": "image", "url": sent["images"][0]}])
        first_user_message = next(message for message in initial_history["messages"] if message["role"] == "user")
        self.assertEqual(first_user_message["imageDataURLs"], sent["images"], "History should expose inline images through Codex's `url` field.")
        jpeg = self.data_directory / "tiny.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", str(image), "--out", str(jpeg)], check=True, capture_output=True)
        jpeg_result, _ = self.call_cli(
            "conversation", "send", task_id, "--image", str(jpeg),
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(jpeg_result)
        sent = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertTrue(sent["images"][0].startswith("data:image/jpeg;base64,"))
        self.assertLessEqual(len(base64.b64decode(sent["images"][0].split(",", 1)[1])), 10_000_000)
        text_prompt = "Describe this screenshot."
        mixed, _ = self.call_cli(
            "conversation", "send", task_id, "--message", text_prompt, "--image", str(image),
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assert_success(mixed)
        sent = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(sent["userMessage"], text_prompt)
        self.assertEqual(len(sent["images"]), 1)
        self.assertEqual(sent["imageInputs"], [{"type": "image", "url": sent["images"][0]}])
        followup, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Continue using the earlier image as context.",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        followed_history = self.assert_success(followup)
        restored_messages = [message for message in ordinary_messages(followed_history["messages"]) if message["role"] == "user"]
        self.assertEqual(len(restored_messages), 4)
        self.assertTrue(all(message["imageDataURLs"] for message in restored_messages[:3]), "History refresh after a later text turn must retain every earlier image.")
        self.assertEqual(restored_messages[2]["text"], text_prompt)
        invalid, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "image", "--image", str(self.data_directory / "missing.png"),
            expected_status=2,
        )
        self.assertNotEqual(invalid.get("error", {}).get("code"), None)
        diagnostics = self.diagnostic_events()
        image_request = next(
            event for event in diagnostics
            if event.get("event") == "bridge.request.succeeded"
            and event.get("command") == "conversation.send"
            and event.get("argument.images.0.mime") == "image/png"
        )
        self.assertGreater(int(image_request["argument.images.0.encodedCharacterCount"]), 0)
        serialized_diagnostics = json.dumps(diagnostics)
        self.assertNotIn("data:image/png;base64,", serialized_diagnostics)
        self.assertNotIn(sent["images"][0], serialized_diagnostics)
        published, _ = self.call_cli(
            "conversation", "present-image", task_id, "--image", str(image), "--caption", "Agent screenshot",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        published_message = self.assert_success(published)
        self.assertEqual(published_message["role"], "assistant")
        self.assertEqual(published_message["text"], "Agent screenshot")
        self.assertTrue(published_message["imageDataURLs"][0].startswith("data:image/png;base64,"))
        fresh_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        saved_agent_image = next(
            message for message in reversed(self.assert_success(fresh_history)["messages"])
            if message["id"] == published_message["id"]
        )
        self.assertEqual(saved_agent_image["id"], published_message["id"])
        self.assertEqual(saved_agent_image["imageDataURLs"], published_message["imageDataURLs"])
        self.assertEqual(
            base64.b64decode(saved_agent_image["imageDataURLs"][0].split(",", 1)[1]),
            image.read_bytes(),
            "The assistant image the viewer opens must keep the original published file bytes.",
        )
        thread_instructions = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["threadStartDeveloperInstructions"]
        self.assertIn("conversation present-image", thread_instructions)
        jpeg = self.data_directory / "agent-image.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", str(image), "--out", str(jpeg)], check=True, capture_output=True)
        published_jpeg, _ = self.call_cli(
            "conversation", "present-image", task_id, "--image", str(jpeg), "--caption", "Agent JPEG screenshot",
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        jpeg_message = self.assert_success(published_jpeg)
        self.assertTrue(jpeg_message["imageDataURLs"][0].startswith("data:image/jpeg;base64,"))
        fresh_jpeg_history, _ = self.call_cli(
            "conversation", "history", task_id,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        saved_jpeg = next(
            message for message in reversed(self.assert_success(fresh_jpeg_history)["messages"])
            if message["id"] == jpeg_message["id"]
        )
        self.assertEqual(saved_jpeg["imageDataURLs"], jpeg_message["imageDataURLs"])
        invalid_image = self.data_directory / "invalid-agent-image.png"
        invalid_image.write_bytes(b"not an image")
        invalid_publish, _ = self.call_cli(
            "conversation", "present-image", task_id, "--image", str(invalid_image),
            expected_status=2, extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
        )
        self.assertEqual(invalid_publish.get("error", {}).get("code"), "invalid_argument")
    # case-contract: test_claude_agent_image_published_during_active_turn | While a Claude Code turn is active in the app process, the agent's CLI/XPC image publication joins that active Claude transcript turn; after the provider finishes, history places the image before the later assistant answer, and reopening the conversation renders the exact published image. Codex records the same active-turn attribution in the shared store, covered by test_codex_agent_image_published_during_active_turn.
    def test_claude_agent_image_published_during_active_turn(self):
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-active-image"
        copy_file(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        created, _ = self.call_cli("task", "create", "--title", "Claude active image", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude")
        task_id = self.assert_success(created)["id"]
        image = self.data_directory / "active-agent-image.png"
        image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        prompt = "Please publish-image-during-active-turn."
        send = self.start_cli("conversation", "send", task_id, "--message", prompt, extra_environment=environment)
        ready = Path(str(executable) + ".image-turn-ready")
        release = Path(str(executable) + ".image-turn-release")
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and send.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "Claude should hold the active turn before producing its answer.")
            published, _ = self.call_cli(
                "conversation", "present-image", task_id, "--image", str(image), "--caption", "During Claude turn",
                extra_environment=environment,
            )
            image_message = self.assert_success(published)
        finally:
            release.write_text("Release Claude's turn.\n", encoding="utf-8")
        self.finish_cli(send, ("conversation", "send", task_id, "--message", prompt), timeout=30)
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=environment)
        messages = self.assert_success(history)["messages"]
        image_index = next(index for index, message in enumerate(messages) if message["id"] == image_message["id"])
        answer_index = next(index for index, message in enumerate(messages) if message["text"] == "Claude answer after the image.")
        self.assertLess(image_index, answer_index, "The image should precede Claude's later answer in transcript order.")
    # case-contract: test_claude_large_image_message_reaches_idle_agent | A Claude Code agent that has answered initialize and gone idle receives a user message carrying a screenshot larger than its input FIFO's buffer: the send completes with Claude's answer, the agent receives the whole image, the user message keeps that image when history is read over a fresh CLI/XPC connection and when the conversation is reopened, and a later text turn in the same conversation still completes. Claude Code's runtime, like the kqueue-reading fixture, is never woken by one oversized blocking write, so such a message must reach it without freezing the daemon. Codex agents talk over a socket and are not affected.
    def test_claude_large_image_message_reaches_idle_agent(self):
        task_id = self.create_task(title="Claude screenshot", provider="claude")["id"]
        executable = self.data_directory / "claude-fixture-large-image"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        screenshot = self.data_directory / "large-screenshot.png"
        write_noise_png(screenshot, 160, 160)
        prompt = "Describe this screenshot."

        # The send starts a fresh agent, which answers initialize and waits in kqueue before
        # the message arrives; a single blocking write of the message would never complete.
        sent = self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", prompt, "--image", str(screenshot),
            extra_environment=environment,
        )[0])
        self.assertIn("OK.", [message["text"] for message in ordinary_messages(sent["messages"]) if message["role"] == "assistant"])
        history = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        user_messages = [message for message in ordinary_messages(history["messages"])
                         if message["role"] == "user" and message["text"] == prompt]
        self.assertEqual(len(user_messages), 1, "A fresh CLI/XPC read shows the screenshot message once.")
        image_urls = user_messages[0]["imageDataURLs"]
        self.assertEqual(len(image_urls), 1)
        self.assertTrue(image_urls[0].startswith("data:image/png;base64,"))
        encoded_length = len(image_urls[0].split(",", 1)[1])
        self.assertGreater(encoded_length, 64 * 1024, "The screenshot must not fit in a FIFO's buffer.")
        turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
        image_turns = [turn for turn in turns if (turn.get("userText") or "").endswith(prompt)]
        self.assertEqual(len(image_turns), 1, "Claude Code received the screenshot message once.")
        self.assertEqual(image_turns[0]["images"], [{"mediaType": "image/png", "base64Length": encoded_length}],
                         "Claude Code received the whole image.")

        followup = "Thanks, that is all."
        answered = self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", followup, extra_environment=environment,
        )[0])
        replies = [message["text"] for message in ordinary_messages(answered["messages"]) if message["role"] == "assistant"]
        self.assertEqual(replies.count("OK."), 2, "A later text turn in the same conversation still completes.")
        turns = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))["turns"]
        followup_turn = next(turn for turn in turns if (turn.get("userText") or "").endswith(followup))
        self.assertEqual(followup_turn["images"], [])
    # case-contract: test_codex_agent_image_published_during_active_turn | While a Codex turn is active, CLI/XPC image publication avoids requesting provider history; the assistant image is tied to that turn, is recorded in Playhouse's store when published, so it follows the turn's prompt and precedes the answer that arrives later and the next turn in ordered history, as for Claude, and remains visible after reopening the conversation.
    def test_codex_agent_image_published_during_active_turn(self):
        source = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-image-serial-success-wait"
        copy_file(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        created, _ = self.call_cli("task", "create", "--title", "Codex active image", "--prompt", "Fixture task description.", "--root", self.primary)
        task_id = self.assert_success(created)["id"]
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        prompt = "Please publish-image-during-active-turn."
        send = self.start_cli("conversation", "send", task_id, "--message", prompt, extra_environment=environment)
        ready = Path(str(executable) + ".resolve-ready")
        resume = Path(str(executable) + ".resolve-continue")
        observe_history = Path(str(executable) + ".observe-history-while-active")
        history_read = Path(str(executable) + ".history-read-while-active")
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and send.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "Codex should hold the active turn before its native response.")
            image = self.data_directory / "active-codex-agent-image.png"
            image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
            observe_history.touch()
            published, _ = self.call_cli(
                "conversation", "present-image", task_id, "--image", str(image), "--caption", "Generated while Codex was responding",
                extra_environment=environment,
            )
            image_message = self.assert_success(published)
            self.assertEqual(image_message["role"], "assistant")
            self.assertEqual(image_message["text"], "Generated while Codex was responding")
            self.assertTrue(image_message.get("turnID"), "The published image should carry the active Codex turn ID.")
            self.assertFalse(history_read.exists(), "Publishing during a Codex turn must not request its busy provider history.")
        finally:
            observe_history.unlink(missing_ok=True)
            resume.write_text("Release Codex's turn.\n", encoding="utf-8")
        self.finish_cli(send, ("conversation", "send", task_id, "--message", prompt), timeout=30)
        followup_text = "Start a later turn after the generated image."
        followup, _ = self.call_cli(
            "conversation", "send", task_id, "--message", followup_text,
            extra_environment=environment,
        )
        self.assert_success(followup)
        history, _ = self.call_cli("conversation", "history", task_id, extra_environment=environment)
        messages = self.assert_success(history)["messages"]
        image_index = next(index for index, message in enumerate(messages) if message["id"] == image_message["id"])
        answer_index = next(index for index, message in enumerate(messages) if message["text"] == "Answers received: Blue / fixture-secret.")
        followup_index = next(index for index, message in enumerate(messages) if message["role"] == "user" and message["text"] == followup_text)
        self.assertEqual(messages[image_index]["turnID"], messages[answer_index]["turnID"], "The image should share the active Codex response's turn ID.")
        prompt_index = next(index for index, message in enumerate(messages) if message["role"] == "user" and message["text"] == prompt)
        self.assertGreater(image_index, prompt_index, "The image should follow the prompt of the turn it was published in.")
        self.assertLess(image_index, answer_index, "Playhouse records the image when it is published, before the answer that arrives later.")
        self.assertLess(image_index, followup_index, "The image should remain before the next Codex turn.")
        self.assertEqual(messages[image_index]["imageDataURLs"], image_message["imageDataURLs"])
    # case-contract: test_claude_turn_progress_reaches_other_windows_mid_turn | While a Claude Code fixture turn started by another caller is still running, its commentary and tool activity raise the task's conversation revision in the daemon's runtime snapshot, a held turn with no visible output yet leaves that revision unchanged, and mid-turn history, read from Playhouse's own Claude transcript, already returns the prompt, the commentary, and the in-progress tool activity before any final answer. A conversation reopened after its send, and so no longer reading that turn's stream, shows the commentary and the running tool row while the turn is still held, then the final answer once it settles; the revision rises again when the turn ends.
    def test_claude_turn_progress_reaches_other_windows_mid_turn(self):
        self.assert_turn_progress_reaches_followers_mid_turn(
            "claude", "claude-fixture-follow-active-turn", "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE", "claudeSessionID", "toolu_follow_active_step"
        )
    # case-contract: test_codex_turn_progress_reaches_other_windows_mid_turn | While a Codex app-server fixture turn started by another caller is still running, its commentary and tool activity raise the task's conversation revision in the daemon's runtime snapshot, a held turn with no visible output yet leaves that revision unchanged, and mid-turn history, read from Playhouse's own transcript store while the turn holds, already returns the prompt, the commentary, and the in-progress tool activity before any final answer. A conversation reopened after its send, and so no longer reading that turn's stream, shows the commentary and the running tool row while the turn is still held, then the final answer once it settles; the revision rises again when the turn ends. With a non-default model selected, those mid-turn history reads never send thread/resume, since history comes from Playhouse's store.
    def test_codex_turn_progress_reaches_other_windows_mid_turn(self):
        self.assert_turn_progress_reaches_followers_mid_turn(
            "codex", "codex-fixture-follow-active-turn", "PLAYHOUSE_E2E_CODEX_EXECUTABLE", "codexThreadID", "item_follow_active_command",
            send_arguments=("--model", "gpt-6-sol"),
        )
    # case-contract: test_conversation_follows_latest_streamed_messages | While a Claude Code fixture reply streams in held stages below its question, mid-turn CLI/XPC history holds every streamed line before the newest, which Claude may still extend as its answer, once each and in order after the question, with no final line until the reply is released, and the settled turn ends with its final line after every streamed line. In the visible transcript, a reader at the bottom follows the reply: once it outgrows the viewport, the newest streamed line stays in view and the question scrolls away. Scrolling up stops following, so the next stage leaves the reader's position unchanged and its lines out of view; scrolling back to the bottom resumes following, so the next stage's newest line is in view while the turn is still running; reopening the conversation while that turn is still running opens it at that newest line instead of at the question and keeps following, so the next stage's newest line is in view while the turn is still running and the settled turn leaves its final line in view. A short follow-up with a tool call then becomes the newest turn, and the newest history page ends with its question, tool call, and answer after the streamed turn. Scrolled as far down as it goes, the transcript has no blank overscroll: while the held reply outgrows the viewport it ends at its newest line, and the settled reply, whose streamed lines fold into Worked for, and the short follow-up, both once it settles and after the settled conversation is reopened, keep the newest question pinned near the top. Following is shared transcript presentation, so one representative provider covers it.
    def test_conversation_follows_latest_streamed_messages(self):
        executable = self.data_directory / "claude-fixture-stream-follow"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        task_id = self.create_task("Streamed follow turn", provider="claude")["id"]
        prompt = "Please stream-follow-latest."
        stages = (20, 8, 8, 8, 8)
        final_text = "Streamed follow reply finished."

        def line(number):
            return (f"Streamed follow line {number:02d}: the reply keeps growing below the question "
                    "so the transcript has to scroll to keep its newest text in view.")

        def history_texts():
            history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
            return [message["text"] for message in history["messages"]]

        send = self.start_cli("conversation", "send", task_id, "--message", prompt, extra_environment=environment)
        try:
            shown = 0
            for stage, count in enumerate(stages, start=1):
                ready = Path(str(executable) + f".stream-follow-ready-{stage}")
                self.wait_for_marker(ready, True, f"The fixture should hold streamed stage {stage}.", timeout=20)
                shown += count
                expected = [line(number) for number in range(1, shown + 1)]
                # Claude's newest text can still turn out to be its answer, so it
                # is recorded once something follows it; every earlier line is history.
                texts = []
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    texts = history_texts()
                    if expected[-2] in texts:
                        break
                    time.sleep(0.1)
                streamed = [text for text in texts if text.startswith("Streamed follow line ")]
                self.assertIn(len(streamed), (shown - 1, shown), f"Mid-turn history at stage {stage} should hold every line before the newest.")
                self.assertEqual(
                    streamed, expected[:len(streamed)],
                    f"Mid-turn history at stage {stage} should hold the streamed lines once each and in order.",
                )
                self.assertLess(texts.index(prompt), texts.index(expected[0]), "The streamed reply should follow its question.")
                self.assertNotIn(final_text, texts, "The final line must not exist while the reply is still held.")
                Path(str(executable) + f".stream-follow-release-{stage}").write_text("Continue.\n", encoding="utf-8")
        except BaseException:
            for stage in range(1, len(stages) + 1):
                Path(str(executable) + f".stream-follow-release-{stage}").write_text("Release after failure.\n", encoding="utf-8")
            raise
        self.finish_cli(send, ("conversation", "send", task_id, "--message", prompt), timeout=60)
        texts = history_texts()
        expected = [line(number) for number in range(1, sum(stages) + 1)]
        self.assertEqual([text for text in texts if text.startswith("Streamed follow line ")], expected)
        self.assertIn(final_text, texts, "The settled turn should end with its final line.")
        self.assertGreater(texts.index(final_text), texts.index(expected[-1]), "The final line should come after every streamed line.")

        # A short follow-up with a tool call becomes the newest turn, and the newest page a
        # reopened conversation reads ends with that whole turn: question, tool, then answer.
        follow_up = "Summarize the release notes."
        closing = "Tell me if you want the upgrade command."
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", follow_up, extra_environment=environment)[0])
        page = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80", extra_environment=environment)[0])
        page_messages = ordinary_messages(page["messages"])
        last_user = max(index for index, message in enumerate(page_messages) if message["role"] == "user")
        self.assertEqual(page_messages[last_user]["text"], follow_up, "The follow-up should be the newest question.")
        self.assertEqual(page_messages[-1]["text"], closing, "The newest page should end with the follow-up's answer.")
        self.assertIn("toolu_chat_read", {activity["id"] for activity in page["activities"]},
                      "The follow-up's tool call should belong to the newest turn.")
        page_texts = [message["text"] for message in page_messages]
        self.assertLess(page_texts.index(final_text), last_user,
                        "The streamed turn should sit before the follow-up, where a reopened window holds it back.")
    # case-contract: test_claude_earlier_turn_tool_calls_render_inline | A Claude Code fixture turn that writes commentary, runs shell commands (one failing) and an MCP call, then answers keeps each call in Playhouse's own transcript placed after the message written before it. Once a later turn starts, CLI/XPC history still returns the earlier turn's calls as timeline activities, apart from the latest turn's activities: each shell call carries its stated purpose, its exact command and the output it returned, the failing call reports failed, and the MCP call exposes neither its arguments nor its raw result. A history page returns only the calls placed on its own messages, so the newest page carries none of them and the page before it carries them all. While its turn is the latest, a call stays in Worked for and is not shown inline. Once a later turn starts, the visible conversation shows each earlier call inline between those messages, in order, as a row with the tool's name, its purpose, and IN and OUT blocks clipped until expanded; the MCP row has no IN or OUT block, the turn's answer renders a numbered list written right under a paragraph line as separate items whose inline code text is unchanged, and the rows are still there after reopening the task.
    def test_claude_earlier_turn_tool_calls_render_inline(self):
        environment = self.install_claude_fixture("claude-fixture-timeline-tools")
        self.assert_earlier_turn_tool_calls_in_history(
            "claude", environment,
            ("toolu_timeline_status", "toolu_timeline_list", "toolu_timeline_fail", "toolu_timeline_mcp"),
            ("Check repository status", "List fixture files"),
        )
    # case-contract: test_codex_earlier_turn_tool_calls_render_inline | A Codex app-server fixture thread whose earlier turn reports commentary, command executions (one failing) and an MCP call between its messages keeps those items in their place in history: once a later turn starts, CLI/XPC history returns each earlier call as a timeline activity placed after the message the thread listed before it, with its working directory, exact command and aggregated output, the failing command reports failed, and the MCP call exposes neither its arguments nor its raw result. Commentary on either side of a call stays a separate message instead of merging across it. A history page returns only the calls placed on its own messages, so the newest page carries none of them and the page before it carries them all. While its turn is the latest, a call stays in Worked for and is not shown inline. Once a later turn starts, the visible conversation shows each earlier call inline between those messages, in order, as a row with the tool's name, its working directory, and IN and OUT blocks clipped until expanded; the MCP row has no IN or OUT block, the turn's answer renders a numbered list written right under a paragraph line as separate items whose inline code text is unchanged, and the rows are still there after reopening the task.
    def test_codex_earlier_turn_tool_calls_render_inline(self):
        executable = self.data_directory / "codex-fixture-unique-turns-timeline-tool-calls"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        self.assert_earlier_turn_tool_calls_in_history(
            "codex", {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)},
            ("item_timeline_status", "item_timeline_list", "item_timeline_fail", "item_timeline_mcp"),
            ("in /tmp/playhouse-fixture", "in /tmp/playhouse-fixture"),
        )
    # case-contract: test_conversation_rejects_invalid_image_attachments | Malformed image data is rejected with a visible composer error and an invalid_argument bridge response, without creating conversation history or advancing task status.
    def test_conversation_rejects_invalid_image_attachments(self):
        task_id = self.create_task(title="Invalid image conversation")["id"]
        invalid_image = self.data_directory / "invalid.png"
        invalid_image.write_bytes(b"not an image")
        result, _ = self.call_cli(
            "conversation", "send", task_id, "--image", str(invalid_image), expected_status=2,
        )
        self.assertEqual(result.get("error", {}).get("code"), "invalid_argument")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "Backlog")
        history, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(history)["messages"], [])

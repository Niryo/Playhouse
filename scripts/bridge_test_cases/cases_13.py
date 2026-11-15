from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases13:
    # case-contract: test_conversation_mode_rejects_unknown_mode_without_starting_a_turn | The composer keeps the committed model and effort stable while the picker is open, then updates when it is dismissed. Its popover lists provider models and includes an accessible discrete effort slider with Low, Medium, High, and Extra High choices, constrained by model-reported effort support when available; the visible opaque white knob has no focus border, the 6-point track is visibly thick, and the slider responds to dragging and keyboard arrows. A saved selection belongs to its conversation, persists through fresh CLI/XPC reads and reopening, and stays isolated between providers; legacy per-conversation selections remain available, while a provider-wide preference supplies the default for conversations without a selection. Effort persists per conversation. Malformed model IDs and unsupported efforts are rejected without replacing prior choices. The UI opens a second conversation, changes its model independently, and restores the first conversation's selection; unsupported modes and malformed model IDs are rejected before creating history.
    def test_conversation_mode_rejects_unknown_mode_without_starting_a_turn(self):
        title = "Conversation mode validation"
        task_id = self.create_task(title=title)["id"]
        # The model list comes from the provider, so read it from the fixture, never the host's own Codex.
        response, _ = self.call_cli("conversation", "models", task_id, extra_environment=self.install_codex_fixture("codex-fixture-models"))
        models = self.assert_success(response)["models"]
        self.assertTrue(models)
        self.assertTrue(all(model.get("id") and model.get("name") for model in models))
        selected_model_id = models[0]["id"]
        legacy_data = json.dumps({"codex": selected_model_id}).encode("utf-8")
        with sqlite3.connect(self.data_directory / "Playhouse-v2.store") as database:
            seeded = database.execute(
                "UPDATE ZBOARDTASK SET ZCONVERSATIONMODELIDSDATA = ? WHERE ZTITLE = ?",
                (legacy_data, title),
            )
            self.assertEqual(seeded.rowcount, 1, "Seed the real SwiftData row with its pre-global provider model.")
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"],
            selected_model_id,
            "The first read should keep the legacy model associated with its conversation.",
        )
        global_model_id = next(model["id"] for model in models if model["id"] != selected_model_id)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id, "set", global_model_id)[0])["modelID"], global_model_id)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], global_model_id)
        second_task_id = self.create_task(title="Global model selection")['id']
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", second_task_id)[0])["modelID"],
            global_model_id,
            "A conversation without a saved choice should inherit the provider's default selection.",
        )
        self.assert_success(self.call_cli("conversation", "model", second_task_id, "set", selected_model_id)[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", second_task_id)[0])["modelID"], selected_model_id)
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"],
            global_model_id,
            "Changing a second conversation's model must not alter the first conversation.",
        )
        invalid_model, _ = self.call_cli("conversation", "model", task_id, "set", "bad model!", expected_status=2)
        self.assert_failure(invalid_model, "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], global_model_id)
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "medium")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id, "set", "xhigh")[0])["conversationEffort"], "xhigh")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")
        invalid_effort, _ = self.call_cli("conversation", "effort", task_id, "set", "ultra", expected_status=2)
        self.assert_failure(invalid_effort, "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")

        response, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Hello", "--mode", "unsupported", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("Valid modes: default, plan", response["error"]["message"])
        response, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Hello", "--model", "invalid model!", expected_status=2
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("Model ID must contain only", response["error"]["message"])
        history, _ = self.call_cli("conversation", "history", task_id)
        self.assertEqual(self.assert_success(history)["messages"], [])
        self.assertEqual(self.assert_success(history)["activities"], [])
    # case-contract: test_conversation_models_cache_and_refresh | Codex and Claude filtered model lists persist across fresh CLI/XPC requests; an unavailable workspace fails refresh without clearing the previous cache. The visible Claude picker shows the seeded cached option before replacing it with the filtered versioned provider list, and retains an offline cached option when the provider executable is unavailable.
    def test_conversation_models_cache_and_refresh(self):
        codex_fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        codex_executable = self.data_directory / "codex-fixture-model-cache"
        copy_file(codex_fixture, codex_executable)
        codex_executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        codex_environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(codex_executable)}
        task_id = self.create_task(title="Codex model cache")["id"]
        response, _ = self.call_cli("conversation", "models", task_id, extra_environment=codex_environment)
        models = self.assert_success(response)["models"]
        cached, _ = self.call_cli("conversation", "models", task_id, "--cached")
        self.assertEqual(self.assert_success(cached)["models"], models, "A fresh XPC request should read the persisted Codex model cache.")

        claude = self.data_directory / "claude-fixture-model-list"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", claude)
        claude.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        claude_environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude)}
        claude_task, _ = self.call_cli("task", "create", "--title", "Claude model cache", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude")
        claude_task_id = self.assert_success(claude_task)["id"]
        first_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, extra_environment=claude_environment)
        first_claude_models = self.assert_success(first_claude_models)["models"]
        self.assertEqual([model["id"] for model in first_claude_models], ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"])
        self.assertNotIn("default", [model["id"] for model in first_claude_models])
        cached_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, "--cached")
        self.assertEqual(self.assert_success(cached_claude_models)["models"], first_claude_models)
        refreshed_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, extra_environment=claude_environment)
        refreshed_claude_models = self.assert_success(refreshed_claude_models)["models"]
        self.assertEqual([model["id"] for model in refreshed_claude_models], ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"])
        persisted_claude_models, _ = self.call_cli("conversation", "models", claude_task_id, "--cached")
        self.assertEqual(self.assert_success(persisted_claude_models)["models"], refreshed_claude_models)

        unavailable_root = self.data_directory / "claude-model-cache-unavailable-root"
        unavailable_root.mkdir()
        root_owner_marker = unavailable_root / ".playhouse-test-owner"
        root_owner_value = "Playhouse model cache test owns this workspace root.\n"
        root_owner_marker.write_text(root_owner_value, encoding="utf-8")
        unavailable_task, _ = self.call_cli(
            "task", "create", "--title", "Unavailable Claude model root", "--prompt", "Fixture task description.", "--root", unavailable_root, "--provider", "claude"
        )
        unavailable_task_id = self.assert_success(unavailable_task)["id"]
        initial_unavailable_models, _ = self.call_cli("conversation", "models", unavailable_task_id, extra_environment=claude_environment)
        initial_unavailable_models = self.assert_success(initial_unavailable_models)["models"]
        self.assertEqual(initial_unavailable_models, refreshed_claude_models)
        self.assertEqual(root_owner_marker.read_text(encoding="utf-8"), root_owner_value)
        shutil.rmtree(unavailable_root)
        failed_refresh, _ = self.call_cli("conversation", "models", unavailable_task_id, expected_status=1, extra_environment=claude_environment)
        self.assertFalse(failed_refresh.get("ok"), "An unavailable workspace must fail discovery instead of clearing cached models.")
        retained_after_failure, _ = self.call_cli("conversation", "models", unavailable_task_id, "--cached")
        self.assertEqual(self.assert_success(retained_after_failure)["models"], initial_unavailable_models)
    # case-contract: test_conversation_models_keep_newest_version_per_family | The model picker removes the Default entry, superseded aliases, older versions, and duplicate snapshots, keeping only the newest concrete version in each family. GPT-6 Luna replaces GPT-5.6 Luna, and Claude Opus 5.5 replaces the Opus alias and older snapshots. Claude Code names its newest release only through an alias entry's resolved model, so that resolved version supersedes the older concrete Opus 5 and keeps Claude Code's own display name. Alias entries with no resolved model are omitted. A remembered selection the filtered list no longer offers moves to its family's newest offered model and is written back, surviving a later refresh whose list no longer offers that family, while a still-offered selection is left alone. A cached intermediate version advances again when live discovery returns a newer version, and the picker and persisted selection converge. A remembered bare alias migrates to its family's offered release, but a dated snapshot pinned through the CLI is left in place because its family's undated release is not a higher version. The shared CLI/XPC list applies the same filtering to Codex and Claude, and the visible picker matches the Codex list. The model popover opens above its composer control.
    def test_conversation_models_keep_newest_version_per_family(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-model-versions"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        task_id = self.create_task(title="Model versions")["id"]
        models = self.assert_success(self.call_cli("conversation", "models", task_id, extra_environment=environment)[0])["models"]
        self.assertEqual([model["id"] for model in models], ["gpt-6-luna", "gpt-6-sol", "gpt-6-mini"])
        self.assertNotIn("gpt-5.6-luna", [model["id"] for model in models])

        # A remembered model the filtered list no longer offers follows its family forward.
        # The Sol family is used because its newest entry is not the default model, so the
        # paired UI case cannot mistake an unloaded composer for a superseded selection.
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-5.6-sol")[0])
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-6-sol",
            "A superseded selection should move to its family's newest offered model.",
        )
        models_override = Path(str(executable) + ".models-override")
        models_override.write_text(json.dumps([
            {"id": "gpt-6-luna", "displayName": "GPT-6 Luna", "isDefault": True,
             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]},
            {"id": "gpt-7-sol", "displayName": "GPT-7 Sol", "isDefault": False,
             "supportedReasoningEfforts": ["low", "medium", "high", "xhigh"]},
            {"id": "gpt-6-mini", "displayName": "GPT-6 Mini", "isDefault": False,
             "supportedReasoningEfforts": ["low", "medium"]},
        ]), encoding="utf-8")
        try:
            refreshed_models = self.assert_success(
                self.call_cli("conversation", "models", task_id, extra_environment=environment)[0]
            )["models"]
            self.assertIn("gpt-7-sol", [model["id"] for model in refreshed_models])
            self.assertEqual(
                self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-7-sol",
                "A live catalog newer than the cached replacement should advance the persisted selection again.",
            )
        finally:
            models_override.unlink()
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-mini")[0])
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-6-mini",
            "A selection the provider still offers must be left alone.",
        )

        # The same shared filter removes Claude's Default/Opus aliases and collapses dated duplicates.
        claude_fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        claude_executable = self.data_directory / "claude-fixture-model-versions"
        copy_file(claude_fixture, claude_executable)
        claude_executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        claude_environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude_executable)}
        created, _ = self.call_cli("task", "create", "--title", "Claude model versions", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude")
        claude_task_id = self.assert_success(created)["id"]
        claude_models = self.assert_success(
            self.call_cli("conversation", "models", claude_task_id, extra_environment=claude_environment)[0]
        )["models"]
        self.assertEqual(
            [model["id"] for model in claude_models],
            ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-6"],
        )
        # Claude Code only names its newest release through the alias entry's resolvedModel,
        # so the alias must become that concrete model rather than losing to the older
        # claude-opus-5 that does carry a value of its own.
        self.assertNotIn("claude-opus-5", [model["id"] for model in claude_models])
        self.assertEqual(
            next(model["name"] for model in claude_models if model["id"] == "claude-opus-5-5"), "Opus 5.5",
            "The resolved alias should keep Claude Code's display name for the release.",
        )
        # A dated snapshot is a deliberate pin only the CLI can set. Its own family's
        # undated release carries the same version numbers, so the pin stays put.
        self.assert_success(self.call_cli("conversation", "model", claude_task_id, "set", "claude-opus-5-5-20251001")[0])
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", claude_task_id)[0])["modelID"],
            "claude-opus-5-5-20251001",
            "A pinned dated snapshot must not be rewritten to its family's undated release.",
        )
        # A bare alias remembered by an older Playhouse build has no version to compare
        # against, so it migrates to whatever its family now offers.
        self.assert_success(self.call_cli("conversation", "model", claude_task_id, "set", "opus")[0])
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", claude_task_id)[0])["modelID"], "claude-opus-5-5",
            "A remembered bare alias should migrate to its family's offered release.",
        )

        # The real user migration: a remembered claude-opus-5 moves to claude-opus-5-5 and
        # is written back. Re-reading alone cannot prove the write, because the read
        # re-derives the same answer while the cache still offers a superseding entry. So
        # refresh the cache with a list that has no Opus family at all: only a persisted
        # migration survives that, a re-derived one falls back to the stale claude-opus-5.
        self.assert_success(self.call_cli("conversation", "model", claude_task_id, "set", "claude-opus-5")[0])
        self.assertEqual(
            self.assert_success(self.call_cli("conversation", "model", claude_task_id)[0])["modelID"], "claude-opus-5-5",
            "A remembered Claude model superseded by its alias's resolved release should move forward.",
        )
        models_override = Path(str(claude_executable) + ".models-override")
        models_override.write_text(json.dumps([
            {"value": "sonnet", "resolvedModel": "claude-sonnet-5-5", "displayName": "Sonnet 5.5"},
            {"value": "haiku", "resolvedModel": "claude-haiku-4-6", "displayName": "Haiku 4.6"},
        ]), encoding="utf-8")
        try:
            opusless_models = self.assert_success(
                self.call_cli("conversation", "models", claude_task_id, extra_environment=claude_environment)[0]
            )["models"]
            self.assertEqual([model["id"] for model in opusless_models], ["claude-sonnet-5-5", "claude-haiku-4-6"])
            self.assertEqual(
                self.assert_success(self.call_cli("conversation", "model", claude_task_id)[0])["modelID"], "claude-opus-5-5",
                "The superseded selection must have been persisted, not re-derived on every read.",
            )
        finally:
            models_override.unlink()

        aliases_fixture = self.data_directory / "claude-fixture-model-versions-aliases-only"
        copy_file(claude_fixture, aliases_fixture)
        aliases_fixture.chmod(0o755)
        aliases_only = self.assert_success(self.call_cli(
            "conversation", "models", claude_task_id,
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(aliases_fixture)},
        )[0])["models"]
        self.assertEqual(aliases_only, [], "Claude aliases should not be exposed without a concrete versioned choice.")
    # case-contract: test_codex_message_timestamps | Codex records a timestamp when a message event arrives and restores it after reload when provider history omits a time. A provider-supplied timestamp takes precedence over the locally observed time.
    def test_codex_message_timestamps(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-timestamps-unique-turns-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8")
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        task_id = self.create_task(title="Codex message timestamps")["id"]
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Check message time.", extra_environment=environment)[0])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        message = next(m for m in history["messages"] if m["id"] == "item_assistant_fixture_1")
        self.assertIsNotNone(message.get("createdAt"))
        self.assertIn("item_assistant_fixture_1", self.conversation_state(task_id)["messageTimestamps"])
        Path(str(executable) + ".provider-timestamp").touch()
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        message = next(m for m in history["messages"] if m["id"] == "item_assistant_fixture_1")
        self.assertEqual(message["createdAt"], "2026-10-26T12:34:00Z")
    # case-contract: test_conversation_effort_dispatches_to_codex | The selected effort persists through CLI/XPC reads and reaches Codex turn/start collaborationMode.settings.reasoningEffort; a model's advertised effort limit rejects unsupported requests before history is created. The UI selects Extra High and sends a Sol turn, then simulates a legacy transcript with no Codex turn metadata and sends a Luna turn; the old reply remains provider-only and the new reply is attributed to Luna. The latest reply shows its locally recorded timestamp after history reload, while a legacy history item without a known time has no timestamp label.
    def test_conversation_effort_dispatches_to_codex(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-effort-unique-turns-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        task_id = self.create_task(title="Codex effort dispatch")["id"]
        models = self.assert_success(self.call_cli("conversation", "models", task_id, extra_environment=environment)[0])["models"]
        limited_model = next(model for model in models if model["id"] == "gpt-6-mini")
        self.assertEqual(limited_model["supportedEfforts"], ["low", "medium"])
        self.assert_success(self.call_cli("conversation", "effort", task_id, "set", "xhigh")[0])
        unsupported, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Unsupported effort.", "--model", "gpt-6-mini",
            expected_status=2, extra_environment=environment
        )
        self.assert_failure(unsupported, "invalid_argument")
        self.assertIn("not supported by model 'gpt-6-mini'", unsupported["error"]["message"])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "history", task_id)[0])["messages"], [])
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-sol")[0])
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-6-sol",
                          "The selected (non-default) model persists for the UI label to read back.")
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Check Codex effort.", "--model", "gpt-6-sol",
            extra_environment=environment
        )[0])
        history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        effort_turn = next(turn for turn in reversed(history["turns"]) if turn.get("userMessage", "").endswith("Check Codex effort."))
        self.assertEqual(effort_turn["reasoningEffort"], "xhigh")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-6-sol",
                          "Sending a turn must not silently fall back to the default model.")
        transcript = self.conversation_state(task_id)
        for segment in transcript["segments"]:
            segment["codexTurnIDs"] = []
            segment.pop("codexTurnModelIDs", None)
        transcript.pop("messageTimestamps", None)  # Simulate a transcript from before local timestamps.
        self.write_conversation_state(task_id, transcript)
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-luna")[0])
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Check the next model.", "--model", "gpt-6-luna", extra_environment=environment)[0])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        assistants = [message for message in ordinary_messages(history["messages"]) if message["role"] == "assistant"]
        self.assertGreaterEqual(len(assistants), 2)
        self.assertIsNone(assistants[0].get("modelID"), "Legacy replies without stored model attribution must remain provider-only.")
        self.assertIsNone(assistants[0].get("createdAt"), "Legacy provider history without a timestamp must stay timestamp-free.")
        self.assertEqual(assistants[-1]["modelID"], "gpt-6-luna")
        self.assertIsNotNone(assistants[-1].get("createdAt"), "Locally observed time survives a history reload.")
    # case-contract: test_codex_history_keeps_loaded_thread_model | Right after a Codex turn on a non-default model (Sol) ends, loading history with Sol still selected reuses the loaded thread. When the selection moves to another non-default model (Mini), history resumes with Mini even though Codex still reports Sol and remains readable. A subsequent send on Luna also resumes despite Codex reporting Sol, starts the turn with Luna, shows its reply without an error, and records Luna for that turn. The selected model remains associated with the conversation. A second Codex conversation that never chose a model keeps the model its own turn ran on, in CLI/XPC reads and in the reopened composer’s picker, after the provider-wide remembered selection moves to another model.
    def test_codex_history_keeps_loaded_thread_model(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-kept-model-unique-turns-success"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        kept_model = Path(str(executable) + ".resume-keeps-model")
        task_id = self.create_task(title="Codex kept model history")["id"]
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-sol")[0])
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Run on Sol.", "--model", "gpt-6-sol", extra_environment=environment
        )[0])
        # The turn just ended and the selected model is still Sol: history reuses the
        # loaded thread instead of resuming it with the hardcoded default (Luna).
        kept_model.write_text("gpt-6-sol\n", encoding="utf-8")
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        self.assertTrue(any(message["role"] == "assistant" for message in history["messages"]))
        self.assertTrue(kept_model.is_file(), "History must not resume a thread already loaded with the task's model.")
        # The selection moves to Mini (neither Sol nor the default) while Codex still
        # holds the thread on Sol: history resumes with Mini, Codex keeps Sol, and the
        # read still succeeds.
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-mini")[0])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        self.assertFalse(kept_model.exists(), "History must have resumed the thread and read Codex's reported model.")
        recorded = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(recorded["threadResumeKeptModels"][-1], {"requested": "gpt-6-mini", "reported": "gpt-6-sol"},
                         "History resumes with the task's selected model, not the hardcoded default.")
        self.assertTrue(any(message["role"] == "assistant" for message in history["messages"]))
        # The thread still reports Sol, but the next turn must switch to the
        # model the conversation selected instead of rejecting the send.
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-luna")[0])
        kept_model.write_text("gpt-6-sol\n", encoding="utf-8")
        switched, _ = self.call_cli(
            "conversation", "send", task_id, "--message", "Run on Luna.", "--model", "gpt-6-luna",
            extra_environment=environment
        )
        self.assert_success(switched)
        self.assertFalse(kept_model.exists())
        recorded = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertEqual(recorded["threadResumeKeptModels"][-1], {"requested": "gpt-6-luna", "reported": "gpt-6-sol"})
        luna_turn = next(turn for turn in reversed(recorded["turns"]) if turn.get("userMessage", "").endswith("Run on Luna."))
        self.assertEqual(luna_turn["modelID"], "gpt-6-luna", "The resumed thread should start the requested Luna turn.")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", task_id)[0])["modelID"], "gpt-6-luna")
        recorded = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertTrue(any(message.get("modelID") == "gpt-6-luna" for message in self.assert_success(
            self.call_cli("conversation", "history", task_id, extra_environment=environment)[0]
        )["messages"]), "Fresh history should preserve the switched turn's model attribution.")
        # A conversation that never chose a model keeps the one its own turns ran on, after the
        # provider-wide remembered selection moves to another model.
        unselected_task_id = self.create_task(title="Codex history model")["id"]
        self.assert_success(self.call_cli(
            "conversation", "send", unselected_task_id, "--message", "Run on the remembered model.", extra_environment=environment
        )[0])
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-mini")[0])
        for _ in range(2):
            self.assertEqual(
                self.assert_success(self.call_cli("conversation", "model", unselected_task_id)[0])["modelID"], "gpt-6-luna",
                "The model comes from the conversation's own latest Codex turn, not the remembered selection.",
            )
    # case-contract: test_conversation_effort_dispatches_to_claude | Claude's model picker omits Default and aliases, showing Opus 5.5 resolved from Claude Code's bare alias entry as the concrete latest choice in place of the older Opus 5. Selecting it changes the prompt and reply label to Claude · Opus 5.5, and later model changes preserve the old reply's model attribution. The selected effort persists through CLI/XPC reads and reaches Claude Code as CLAUDE_CODE_EFFORT_LEVEL; the UI selects Extra High and sends a Claude fixture turn whose recorded environment value is xhigh.
    def test_conversation_effort_dispatches_to_claude(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-effort"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        created, _ = self.call_cli("task", "create", "--title", "Claude effort dispatch", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude")
        task_id = self.assert_success(created)["id"]
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "claude-opus-5-5")[0])
        self.assert_success(self.call_cli("conversation", "effort", task_id, "set", "xhigh")[0])
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Check Claude effort.", "--model", "claude-opus-5-5", extra_environment=environment)[0])
        history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        effort_turn = next(turn for turn in reversed(history["turns"]) if turn.get("userText") == "Check Claude effort.")
        self.assertEqual(effort_turn["effort"], "xhigh")
        arguments = effort_turn["arguments"]
        self.assertIn("--model", arguments)
        model_argument_index = arguments.index("--model")
        self.assertEqual(arguments[model_argument_index + 1], "claude-opus-5-5")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "effort", task_id)[0])["effort"], "xhigh")
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "claude-sonnet-5-5")[0])
        visible = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        assistant = next(message for message in visible["messages"] if message["role"] == "assistant")
        self.assertEqual(assistant["modelID"], "claude-opus-5-5", "Changing the selected model must not rewrite prior turn attribution.")
    # case-contract: test_thread_goal_lifecycle_persists_through_cli_xpc | CLI/XPC Goal set/get/pause/resume/clear persist the objective and lifecycle state across fresh connections and enable the Goals app-server feature; setting a first Goal on an Untitled task generates and persists its title from the objective before the Goal starts, while title failure uses the first eight objective words as fallback; setting the same active Goal preserves its timer generation, clearing then setting another Goal creates a new generation with a fresh baseline, setting a Goal moves the task to In Progress, and invalid blank objectives preserve the current Goal. The UI shows the generated title after reopening the task and restores saved Goals; the opt-in live Codex integration confirms native startup, verifies the first Goal retains its elapsed duration, restores a legacy completion without timing metadata, and confirms a second Goal timer begins near zero; renders each achieved summary as a conversation item that visibly moves with scrolling and is anchored to its completing turn, verifies a later user follow-up appears after the prior achievement through turn completion, and preserves both items and their ordering in the read-only Done archive. Native turn activation is owned by the retained GUI runtime.
    def test_thread_goal_lifecycle_persists_through_cli_xpc(self):
        task_id = self.create_task(title="Untitled task", roots=[self.primary])["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-goal"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        env = {
            "CODEX_HOME": str(self.data_directory / "codex-home"),
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable),
        }
        (self.data_directory / "codex-home").mkdir()
        goal_text = "Migrate the project and keep the full test suite green."
        result, _ = self.call_cli("conversation", "goal", task_id, "set", "--text", goal_text, extra_environment=env)
        self.assertEqual(self.assert_success(result)["objective"], goal_text)
        titled_task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(titled_task)["title"], "Generated fixture title",
                         "The first Goal should generate and persist the Untitled task's title from its objective.")
        launch_arguments = json.loads(Path(str(executable) + ".launch-args").read_text(encoding="utf-8"))
        self.assertIn("features.goals=true", launch_arguments, "CLI/XPC Goal commands must enable Codex's Goals app-server feature.")
        task, _ = self.call_cli("task", "get", task_id)
        self.assertEqual(self.assert_success(task)["status"], "In Progress")
        for action, expected in (("get", "active"), ("pause", "paused"), ("resume", "active")):
            response, _ = self.call_cli("conversation", "goal", task_id, action, extra_environment=env)
            self.assertEqual(self.assert_success(response)["status"], expected)
            reread, _ = self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)
            self.assertEqual(self.assert_success(reread)["objective"], goal_text)
        generation_key = f"playhouse.codex.goal-generation.{task_id.upper()}"
        generation_before, _ = self.read_default(generation_key)
        same_goal, _ = self.call_cli("conversation", "goal", task_id, "set", "--text", goal_text, extra_environment=env)
        self.assertEqual(self.assert_success(same_goal)["objective"], goal_text)
        generation_after, _ = self.read_default(generation_key)
        self.assertEqual(generation_after, generation_before, "Setting the same active objective should preserve its timer generation.")
        invalid, _ = self.call_cli("conversation", "goal", task_id, "set", "--text", "   ", expected_status=2, extra_environment=env)
        self.assert_failure(invalid, "invalid_argument")
        current, _ = self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)
        active_goal = self.assert_success(current)
        self.assertEqual(active_goal["objective"], goal_text)
        prior_reported_seconds = float(active_goal.get("timeUsedSeconds") or 0)
        cleared, _ = self.call_cli("conversation", "goal", task_id, "clear", extra_environment=env)
        self.assert_success(cleared)
        current, _ = self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)
        self.assertIsNone(self.assert_success(current))
        cleared_generation = generation_after
        replacement_text = "Build the next feature and keep its timer independent."
        replacement, _ = self.call_cli(
            "conversation", "goal", task_id, "set", "--text", replacement_text, extra_environment=env
        )
        replacement_goal = self.assert_success(replacement)
        self.assertEqual(replacement_goal["objective"], replacement_text)
        replacement_generation, _ = self.read_default(generation_key)
        self.assertNotEqual(replacement_generation, cleared_generation, "A Goal set after clear must receive a fresh timer generation.")
        baseline_key = f"playhouse.codex.goal-generation-time-baseline.{task_id.upper()}"
        replacement_baseline, _ = self.read_default(baseline_key)
        replacement_reported_seconds = float(replacement_goal.get("timeUsedSeconds") or 0)
        expected_baseline = prior_reported_seconds if replacement_reported_seconds >= prior_reported_seconds else 0
        self.assertAlmostEqual(float(replacement_baseline), expected_baseline, places=3, msg="A new Goal must use only the prior total when Codex reports cumulative time.")

        failure_fixture = self.data_directory / "codex-fixture-goal-title-failure"
        copy_file(fixture, failure_fixture)
        failure_fixture.chmod(0o755)
        failure_home = self.data_directory / "codex-home-title-failure"
        failure_home.mkdir()
        failure_environment = {
            "CODEX_HOME": str(failure_home),
            "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(failure_fixture),
        }
        failure_task_id = self.create_task(title="Untitled task", roots=[self.primary])["id"]
        failure_objective = "Explain how repository setup works for new contributors"
        fallback_goal, _ = self.call_cli(
            "conversation", "goal", failure_task_id, "set", "--text", failure_objective,
            extra_environment=failure_environment,
        )
        self.assertEqual(self.assert_success(fallback_goal)["objective"], failure_objective)
        fallback_task, _ = self.call_cli("task", "get", failure_task_id)
        self.assertEqual(self.assert_success(fallback_task)["title"], failure_objective,
                         "A failed first-Goal title generation should use the deterministic objective fallback.")
    # case-contract: test_codex_window_and_cli_share_one_app_server | A window and the CLI use one Codex app-server per Codex home. Every Codex request against one data folder (sends on two tasks, Goal set/get/pause/clear, history and usage refreshes, from the CLI and, in the UI, from an open window as well) runs on the same recorded server process, which listens on the shared unix socket with features.goals=true and the caller's CODEX_HOME and is the one live Codex manifest; it keeps running after every CLI Goal call, including a rejected blank objective, and a CLI call that spells the same CODEX_HOME differently reuses it. A send on the second task while the first task's Goal is active leaves that Goal active. The work turn Codex runs for the Goal is active and interruptible whether the window or the CLI set it; a history read during it, even with another model selected, never resumes the thread, and once pausing the Goal ends the turn, history resumes the thread with the selected model. A usage read the server never answers times out without stopping the server and keeps the last known Codex account, and the next refresh reads it again. In the UI, the window sets a Goal and follows the turn Codex starts for it, which stays active and interruptible while the CLI sends on the second task and ends when the window pauses the Goal; a Goal the CLI sets appears in the open window without reopening the task, the window's pause and clear reach the CLI's Goal reads, and the Agents info block shows the Codex account read through that server.
    def test_codex_window_and_cli_share_one_app_server(self):
        name = "codex-fixture-single-server-goal-success"
        state = self.data_directory / "single-server-fixture-state"
        state.mkdir()
        codex_home = self.data_directory / "codex-home"
        codex_home.mkdir()
        env = {
            **self.install_codex_fixture(name),
            "CODEX_HOME": str(codex_home),
            "PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY": str(state),
        }
        launches = state / f"{name}.app-servers"
        task_id = self.create_task("Shared Codex server", provider="codex")["id"]

        def assert_one_live_server(context, expected_pid=None):
            servers = self.recorded_codex_app_servers(launches)
            self.assertEqual(len(servers), 1, f"{context}: one app-server runs per Codex home, got {servers}")
            server = servers[0]
            self.assertTrue(self.process_is_running(server["pid"]), f"{context}: the shared app-server keeps running.")
            live = [m for kind, _, m in self.agent_manifests() if kind == "codex" and self.agent_process_alive(m.get("process"))]
            self.assertEqual([m["process"]["pid"] for m in live], [server["pid"]],
                             f"{context}: the one live Codex manifest is the recorded server.")
            if expected_pid is not None:
                self.assertEqual(server["pid"], expected_pid, f"{context}: the same app-server serves every request.")
            return server

        sent, _ = self.call_cli("conversation", "send", task_id, "--message", "Hello from the CLI.", extra_environment=env)
        self.assert_success(sent)
        server = assert_one_live_server("After a CLI send")
        pid = server["pid"]
        self.assertTrue(server["listen"].startswith("unix://"), "The shared app-server listens on its unix socket.")
        self.assertIn("features.goals=true", server["arguments"], "The one app-server always enables Codex Goals.")
        self.assertEqual(server["codexHome"], str(codex_home), "The app-server runs on the caller's Codex home.")

        objective = "Keep the shared server running."
        goal = self.assert_success(self.call_cli("conversation", "goal", task_id, "set", "--text", objective, extra_environment=env)[0])
        self.assertEqual(goal["objective"], objective)
        assert_one_live_server("After a CLI Goal set", pid)

        # Codex runs a work turn for the Goal. A history read meanwhile, even with another model
        # selected, never resumes the thread under it, and the turn stays active and interruptible.
        thread_id = self.task_for(task_id, env)["codexThreadID"]
        resumes = state / f"{name}.resumes"
        thread_resumes = lambda: [entry for entry in self.jsonl(resumes) if entry["threadId"] == thread_id]
        self.assert_success(self.call_cli("conversation", "model", task_id, "set", "gpt-6-sol")[0])
        resumed_before = len(thread_resumes())
        texts, _ = self.history_texts(task_id, env)
        self.assertIn("Hello from the CLI.", texts)
        self.assertEqual(thread_resumes()[resumed_before:], [], "A history read never resumes a thread under its running Goal turn.")
        runtime = self.assert_success(self.call_cli("conversation", "runtime", extra_environment=env)[0])
        self.assertIn(thread_id, runtime["activeThreadIDs"], "The Goal's work turn is active even when only the CLI set the Goal.")
        self.assertIn(thread_id, runtime["interruptibleThreadIDs"])

        # A send on another task, while this task's Goal is active, runs on the same server.
        other_id = self.create_task("Second Codex task", provider="codex")["id"]
        self.assert_success(self.call_cli("conversation", "send", other_id, "--message", "Hello from the second task.", extra_environment=env)[0])
        self.assertNotEqual(self.task_for(other_id, env)["codexThreadID"], self.task_for(task_id, env)["codexThreadID"])
        current = self.assert_success(self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)[0])
        self.assertEqual((current["objective"], current["status"]), (objective, "active"),
                         "A send on another task leaves this task's Goal active.")
        assert_one_live_server("After a send on the second task", pid)

        paused = self.assert_success(self.call_cli("conversation", "goal", task_id, "pause", extra_environment=env)[0])
        self.assertEqual(paused["status"], "paused")
        self.wait_for(lambda: thread_id not in self.assert_success(self.call_cli("conversation", "runtime", extra_environment=env)[0])["activeThreadIDs"],
                      "Pausing the Goal ends its work turn.")
        assert_one_live_server("After a CLI Goal pause", pid)
        blank, _ = self.call_cli("conversation", "goal", task_id, "set", "--text", "   ", expected_status=2, extra_environment=env)
        self.assert_failure(blank, "invalid_argument")
        assert_one_live_server("After a rejected CLI Goal set", pid)

        texts, _ = self.history_texts(task_id, env)
        self.assertIn("Hello from the CLI.", texts)
        self.assertEqual(thread_resumes()[-1]["model"], "gpt-6-sol", "Once the turn ends, history resumes the thread with the selected model.")

        def codex_usage(environment):
            providers = self.assert_success(self.call_cli("usage", "get", "--refresh", timeout=20, extra_environment=environment)[0])["providers"]
            return next(entry for entry in providers if entry["provider"] == "codex")
        self.assertEqual(codex_usage(env).get("account"), "codex-fixture@example.com", "Usage is read through the shared app-server.")
        assert_one_live_server("After CLI history and a usage refresh", pid)
        # A read the server never answers times out without stopping it; the last account stays.
        hang = state / f"{name}.account-read-hang"
        hang.touch()
        started = time.monotonic()
        timed_out = codex_usage({**env, "PLAYHOUSE_E2E_CODEX_ACCOUNT_READ_TIMEOUT_SECONDS": "2"})
        self.assertLess(time.monotonic() - started, 15, "An unanswered usage read gives up after its timeout.")
        self.assertFalse(hang.exists(), "The refresh asked the shared server for the account.")
        self.assertEqual(timed_out.get("account"), "codex-fixture@example.com", "A timed-out read keeps the last known account.")
        assert_one_live_server("After an unanswered usage read", pid)
        self.assertEqual(codex_usage(env).get("account"), "codex-fixture@example.com", "The next refresh reads the account again.")

        # The same Codex home spelled differently is the same server.
        respelled = {**env, "CODEX_HOME": str(codex_home) + "/."}
        current = self.assert_success(self.call_cli("conversation", "goal", task_id, "get", extra_environment=respelled)[0])
        self.assertEqual(current["status"], "paused")
        assert_one_live_server("After a CLI call with CODEX_HOME spelled differently", pid)

        self.assertIsNone(self.assert_success(self.call_cli("conversation", "goal", task_id, "clear", extra_environment=env)[0]))
        self.assertIsNone(self.assert_success(self.call_cli("conversation", "goal", task_id, "get", extra_environment=env)[0]))
        assert_one_live_server("After a CLI Goal clear", pid)
    # case-contract: test_codex_legacy_keyed_server_retires_after_restart | A Codex app-server started under the earlier shared-client key, which also held two goal flags, is retired by the next daemon. When its daemon dies and a fresh daemon starts for the data folder, it reconnects to the legacy server only to retire it: with no turn left to follow, the server is stopped and its manifest removed, and the next Codex send, from the CLI or, in the UI, from the window, runs on one new server under the current key (executable, Codex home, data folder), leaving one live Codex server.
    def test_codex_legacy_keyed_server_retires_after_restart(self):
        name = "codex-fixture-single-server-goal-success"
        executable = self.install_provider_fixture("codex", name)
        state = self.data_directory / "legacy-server-fixture-state"
        state.mkdir()
        codex_home = self.data_directory / "codex-home"
        codex_home.mkdir()
        environment = self.restart_service_environment(
            "codex", executable, CODEX_HOME=str(codex_home), PLAYHOUSE_E2E_FIXTURE_STATE_DIRECTORY=str(state))
        service = environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]
        task_id = self.create_task("Legacy Codex server", provider="codex")["id"]
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Before the upgrade.", extra_environment=environment)[0])
        path, manifest = next((p, m) for kind, p, m in self.agent_manifests() if kind == "codex" and m["serviceName"] == service)
        self.assertEqual(len(manifest["keyParts"]), 3, "A current server's key is its executable, Codex home and data folder.")
        legacy_server = manifest["process"]
        self.kill_daemon(environment)
        self.assertTrue(self.agent_process_alive(legacy_server), "The server outlives its daemon.")
        legacy_path = self.rewrite_codex_manifest_as_legacy(path, manifest, str(codex_home))

        # The fresh daemon's first request reconnects to the legacy server only to retire it. With
        # a 30s idle limit the watch checks every 7.5s: only retiring stops the server in time.
        environment["PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS"] = "30"
        self.assert_success(self.call_cli("task", "list", extra_environment=environment)[0])
        self.wait_for(lambda: not self.agent_process_alive(legacy_server), "The legacy-keyed server is retired once idle.")
        self.wait_for(lambda: not legacy_path.exists(), "The retired server's manifest is removed.")

        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "After the upgrade.", extra_environment=environment)[0])
        live = [m for kind, _, m in self.agent_manifests()
                if kind == "codex" and m["serviceName"] == service and self.agent_process_alive(m.get("process"))]
        self.assertEqual(len(live), 1, f"One live Codex server remains: {live}")
        self.assertEqual(len(live[0]["keyParts"]), 3, "The new server uses the current key.")
        self.assertNotEqual(live[0]["process"]["pid"], legacy_server["pid"])
        running = [server for server in self.recorded_codex_app_servers(state / f"{name}.app-servers")
                   if self.process_is_running(server["pid"])]
        self.assertEqual([server["pid"] for server in running], [live[0]["process"]["pid"]], "One app-server runs on the Codex home.")
        texts, _ = self.history_texts(task_id, environment)
        self.assertIn("After the upgrade.", texts)
    # case-contract: test_pending_question_repair_restores_thread_owner | A misplaced pending question can be repaired through CLI/XPC only into its owning conversation. Repair rejects a wrong owner and a conflicting destination without mutation, applies both tasks' state atomically, preserves request identity and mode, clears only the misplaced source, and is retryable. Fresh history and the visible UI restore the question only on the original task; answering it clears pending state and the safe response survives reopening. Retrying an interrupted repair after the destination question was answered rejects the stale source without resurrecting the question.
    def test_pending_question_repair_restores_thread_owner(self):
        target = self.create_task("Repair original question", roots=[self.primary])["id"]
        source = self.create_task("Repair misplaced question", roots=[self.secondary])["id"]
        stranger = self.create_task("Repair wrong destination", roots=[self.primary])["id"]
        executable = self.data_directory / "codex-fixture-restart-question"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text("Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8")
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        failed, _ = self.call_cli("conversation", "send", target, "--message", "Ask a restart-safe question.", "--mode", "plan", expected_status=1, extra_environment=env)
        self.assertFalse(failed["ok"])
        stranger_executable = self.data_directory / "codex-fixture-title-success"
        copy_file(executable, stranger_executable)
        stranger_executable.chmod(0o755)
        self.assert_success(self.call_cli("conversation", "send", stranger, "--message", "Start another real conversation.", extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(stranger_executable)})[0])
        original = self.conversation_state(target)
        request = original.pop("pendingUserInputRequest")
        self.write_conversation_state(target, original)
        misplaced_state = {"version": 1, "segments": [], "turns": [], "pendingUserInputRequest": request}
        self.write_conversation_state(source, misplaced_state)
        before = (self.conversation_state(target), self.conversation_state(source))
        rejected, _ = self.call_cli("conversation", "repair-user-input", stranger, "--from-task", source, expected_status=1)
        self.assert_failure(rejected, "invalid_transition")
        self.assertEqual(before, (self.conversation_state(target), self.conversation_state(source)))
        conflict = dict(request, id="a-different-pending-request")
        original["pendingUserInputRequest"] = conflict
        self.write_conversation_state(target, original)
        conflicting = (self.conversation_state(target), self.conversation_state(source))
        rejected, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source, expected_status=1)
        self.assert_failure(rejected, "invalid_transition")
        self.assertEqual(conflicting, (self.conversation_state(target), self.conversation_state(source)),
                         "A rejected repair leaves both tasks' state untouched.")
        original.pop("pendingUserInputRequest")
        self.write_conversation_state(target, original)
        repaired, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source)
        self.assertEqual(self.assert_success(repaired), request)
        self.assertIsNone(self.conversation_state(source).get("pendingUserInputRequest"))
        repaired_target = self.conversation_state(target)
        self.assertEqual(repaired_target["pendingUserInputRequest"], request)
        self.assertEqual(repaired_target["userInputRepairs"], [{"sourceTaskID": source.upper(), "request": request}],
                         "The destination records a receipt of the repair in the same transaction.")
        self.assertFalse((self.data_directory / "conversation-transcripts").exists(),
                         "Repairs no longer write JSON transcript backups; SQLite applies both tasks atomically.")
        again, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source)
        self.assertEqual(self.assert_success(again), request)
        fresh, _ = self.call_cli("conversation", "history", target, extra_environment=env)
        self.assertEqual(self.assert_success(fresh)["pendingUserInputRequest"], request)
        answered, _ = self.call_cli("conversation", "answer-user-input", target, request["id"], "--answer", "color=Green", "--answer", "token=fixture-secret", extra_environment=env)
        self.assertTrue(self.assert_success(answered)["accepted"])
        reopened, _ = self.call_cli("conversation", "history", target, extra_environment=env)
        history = self.assert_success(reopened)
        self.assertIsNone(history.get("pendingUserInputRequest"))
        self.assertTrue(any(item["text"] == "[Response to private answer hidden]" for item in history["messages"]))
        self.assertNotIn("fixture-secret", json.dumps(history))
        self.assertNotIn("Continue this conversation by applying", json.dumps(history))
        # Destination published and answered before a crashed repair cleared source.
        self.write_conversation_state(source, misplaced_state)
        retry, _ = self.call_cli("conversation", "repair-user-input", target, "--from-task", source, expected_status=1)
        self.assert_failure(retry, "invalid_transition")
        self.assertIsNone(self.conversation_state(target).get("pendingUserInputRequest"))
    # case-contract: test_codex_questions_can_be_answered_over_cli_xpc | MCP tool/requestUserInput structured questions raised in Plan mode remain in the conversation and move the task to Waiting Response while unanswered; leaving and reopening the conversation preserves the pending question, keyed answers resume the provider turn in In Progress, and the answered turn reports no outcome, so Playhouse drives a private status nudge; when that private turn cannot complete, the task settles in Blocked naming that reason instead of Waiting Response. A parallel conversation retains its own question and thread; the original conversation receives and answers a second question in its original Plan mode, and completing either conversation preserves the other pending request.
    def test_codex_questions_can_be_answered_over_cli_xpc(self):
        task_id = self.create_task("Codex questions", roots=[self.primary])["id"]
        other_id = self.create_task("Parallel Codex questions", roots=[self.secondary])["id"]
        executable = self.data_directory / "codex-fixture-question-isolation-plan-slow"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text("Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8")
        env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        invalid, _ = self.call_cli("conversation", "send", task_id, "--message", "Ask questions.", "--answer", "color= ", expected_status=2)
        self.assert_failure(invalid, "invalid_argument")

        # Standalone CLI connections have distinct XPC service processes. Exercise
        # the GUI's shared-client topology with unchanged production managers,
        # then read the durable result through the real bundled CLI/XPC.
        root = Path(__file__).resolve().parent.parent
        probe = self.data_directory / "codex-question-ownership-probe"
        core = [
            'BoardTask', 'ConversationSubject', 'WorkspaceSupport', 'HoverRevealScrollers',
            'WorkspaceChanges', 'CodexAppServerClient', 'CodexBackgroundJobs', 'CodexSocketConnection', 'ConversationModel',
            'ClaudeCodeClient', 'ProviderRequestLog', 'ProcessCPUSampler', 'AgentRunHost',
            'ContextCompaction', 'AgentUsage', 'AgentUsageStore', 'ConversationTranscriptStore',
            'StandaloneChatStore', 'SkillCatalog', 'RuleCatalog', 'MentionCatalog',
            'McpCatalog', 'CodexConfigTOML', 'BridgeCore', 'TaskSchedule',
            'BoardConversationStorage', 'BoardLifecycleStatus', 'BoardOperationLocks', 'BoardPromptPersistence',
            'BoardPullRequestLifecycle', 'BoardRepositoryLifecycle', 'BoardScheduling', 'BoardTaskCRUD',
            'BoardTaskManager', 'BoardUsageReporting', 'ClaudeAccountUsage', 'ClaudeClientMapping',
            'ClaudeOutputHandling', 'ClaudeProcessLifecycle', 'ClaudeProcessProtocol', 'ClaudeSessionRunner',
            'ClaudeSessionSupport', 'ClaudeTurnControl', 'ClaudeTurnReporting', 'CodexAccountUsage',
            'CodexMessageConversion', 'CodexServerEvents', 'CodexServerTransport', 'CodexSharedServer',
            'CodexTaskInstructions', 'CodexThreadLifecycle', 'CodexTurnRecovery', 'CodexTurnSending',
            'ConversationCompaction', 'ConversationHistory', 'ConversationManager', 'ConversationMessages',
            'ConversationProviderSelection', 'ConversationStandaloneAutomation', 'ConversationTranscriptRecording', 'ConversationTurnControl',
            'ConversationTurnExecution', 'ConversationTurnRecovery', 'McpCatalogModels', 'PlayhouseBridgeConversationFlow',
            'PlayhouseBridgeConversationOperations', 'PlayhouseBridgeOverview', 'PlayhouseBridgePullRequests', 'PlayhouseBridgeRequestDiagnostics',
            'PlayhouseBridgeRuntime', 'PlayhouseBridgeSettings', 'PlayhouseBridgeTaskWorkspace', 'PlayhouseDiagnostics',
            'PlayhouseStore', 'PlayhouseWorktreeServices', 'ProviderTokenMap', 'PullRequestServices',
            'SkillCatalogModels', 'SkillManifest', 'WorkspaceActivity', 'WorkspaceTaskManagers',
        ]
        command = ["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "5", "-D", "DEBUG", "-Onone"]
        for framework in ("Foundation", "AppKit", "SwiftUI", "SwiftData", "Combine", "JavaScriptCore"):
            command.extend(["-framework", framework])
        grdb = subprocess.run([str(root / "scripts/build-grdb.sh")], capture_output=True, text=True, timeout=600)
        self.assertEqual(grdb.returncode, 0, grdb.stderr)
        grdb_module = grdb.stdout.strip().splitlines()[-1]
        command.extend(["-I", grdb_module, "-I", str(root / "Vendor/GRDB.swift/Sources/GRDBSQLite"), "-L", grdb_module, "-lGRDB"])
        command.extend(str(root / "Playhouse" / "App" / f"{name}.swift") for name in core)
        # BridgeCore's plugin.render uses the plugin core, as build-bridge.sh compiles it for the daemon.
        command.extend(sorted(str(path) for path in (root / "Playhouse/App/Plugins/Core").glob("*.swift")))
        command.extend([str(root / "Playhouse/Bridge/BridgeContract.swift"),
                        str(root / "scripts/test-codex-question-ownership.swift"), "-o", str(probe)])
        compiled = subprocess.run(command, capture_output=True, text=True, timeout=180)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        environment = os.environ.copy()
        environment.update({"PLAYHOUSE_DATA_DIRECTORY": str(self.data_directory),
                            "PLAYHOUSE_E2E_WORKTREE_DIRECTORY": str(self.worktree_directory),
                            "PLAYHOUSE_E2E_DEFAULTS_SUITE": self.defaults_suite,
                            "PLAYHOUSE_BRIDGE_SERVICE_NAME": arguments.service_name,
                            "CODEX_HOME": str(self.data_directory / "codex-home"), **env})
        checked = subprocess.run([str(probe), str(self.data_directory), str(executable), task_id, other_id],
                                 capture_output=True, text=True, env=environment, timeout=120)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        summary = json.loads(checked.stdout.splitlines()[-1])
        self.assertEqual(summary, {"sharedClientQuestionOwnership": True, "originalQuestions": 2, "parallelQuestions": 1})

        def history(owner):
            return self.assert_success(self.call_cli("conversation", "history", owner, extra_environment=env)[0])

        for owner in (task_id, other_id):
            saved = history(owner)
            self.assertIsNone(saved.get("pendingUserInputRequest"))
            self.assertTrue(any("Answers received: Blue / fixture-secret." in message["text"] for message in saved["messages"]))
            settled_record = self.assert_success(self.call_cli("task", "get", owner)[0])
            self.assertEqual(settled_record["status"], "Blocked",
                             "The answered turns leave every nudge unanswered, so they settle in Blocked.")
            self.assertIn("couldn't run the private turn", settled_record.get("statusMessage") or "",
                          "The Blocked reason must name why Playhouse stopped driving the work.")
        saved, _ = self.call_cli("task", "prompt", task_id, "--text", "A follow-up draft.")
        self.assertEqual(self.assert_success(saved)["status"], "Blocked")
        self.assertEqual(self.assert_success(saved)["savedPrompt"], "A follow-up draft.")
    # case-contract: test_claude_questions_can_be_answered_after_switching_conversations | Claude AskUserQuestion requests are delivered through the control path and move the task to Waiting Response while pending; the question's Markdown, including a long paragraph, header, and option descriptions reach the client unchanged, and the UI renders the question inline with its Markdown formatted at the reply text size and its long paragraph wrapped in full across several lines without truncation, its header, and each option's description, preserves it across conversation switching, and sends a later answer to Claude before the turn ends in Waiting Response.
    def test_claude_questions_can_be_answered_after_switching_conversations(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / "claude-fixture-question"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        task, _ = self.call_cli(
            "task", "create", "--title", "Claude question", "--prompt", "Fixture task description.", "--root", self.primary, "--provider", "claude"
        )
        task_id = self.assert_success(task)["id"]
        response, events = self.call_cli(
            "conversation", "send", task_id, "--message", "Ask a structured question.", "--answer", "question-1=Blue",
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)},
        )
        result = self.assert_success(response)
        user_input = next(event for event in events if event.get("type") == "user_input")
        request = user_input["payload"]["userInputRequest"]
        question = request["questions"][0]
        self.assertEqual(
            question["question"],
            "Which color should I use for **the primary button**?\n\nIt also tints `LinkText`.\n\n"
            "When the user clicks an \"Add here\" placeholder, which conversation should open: the task's active "
            "conversation, a new conversation started just for that placeholder, or the conversation the placeholder "
            "was originally added from?",
            "The question's Markdown, including its long multi-line paragraph, must reach the client unchanged and untruncated.",
        )
        self.assertEqual(question["header"], "Color")
        self.assertEqual(
            [(option["label"], option.get("description")) for option in question["options"]],
            [("Blue", "Use blue."), ("Green", "Use green.")],
            "Each option's description must reach the client so the form can show it.",
        )
        self.assertEqual(user_input["payload"].get("taskStatus"), "Waiting Response")
        self.assertTrue(any(
            event.get("type") == "task_status" and event.get("payload", {}).get("taskStatus") == "In Progress"
            for event in events
        ), "Submitting the answer should resume the active Claude turn.")
        self.assertTrue(any(message["text"] == "Answer received: Blue." for message in result["messages"]))
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Waiting Response")

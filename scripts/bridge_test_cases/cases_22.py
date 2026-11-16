from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases22:
    # case-contract: test_plugin_add_mode_toggles_and_shows_placeholders | Add Plugin mode is off by default; the Plugins menu's Add Plugin Mode item and `plugin mode --on` turn it on, `plugin mode` reports the saved state to a fresh CLI process, `--off` turns it off, and any other option is refused as invalid_argument. While it is on, a bar across the top of the window explains the mode and its Close button turns it off; the board's sidebar shows a labeled Add here button below Scheduled Tasks; an open task shows its sidebar expanded even when the sidebar was collapsed, with a labeled Add here button as the sidebar's first section, above Changes, an Add here icon beside the Terminal button and an Add here icon beside the composer's Skills button; and the standalone chat shows only the composer's Add here icon. Turning the mode off from the CLI removes every placeholder live and returns the sidebar to its saved collapsed state.
    def test_plugin_add_mode_toggles_and_shows_placeholders(self):
        self.assertEqual(self.assert_success(self.call_cli("plugin", "mode")[0]), {"enabled": False}, "Add Plugin mode starts off.")
        self.assertEqual(self.assert_success(self.call_cli("plugin", "mode", "--on")[0]), {"enabled": True})
        self.assertEqual(self.assert_success(self.call_cli("plugin", "mode")[0]), {"enabled": True},
                         "A fresh CLI process reads the saved mode.")
        writes, _ = self.call_cli("plugin", "mode", "--off")
        self.assertEqual(self.assert_success(writes), {"enabled": False})
        self.assertEqual(self.assert_success(self.call_cli("plugin", "mode")[0]), {"enabled": False})
        self.assert_failure(self.call_cli("plugin", "mode", "--sideways", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "mode", "--on", "--off", expected_status=2)[0], "invalid_argument")
        self.assertEqual(self.assert_success(self.call_cli("plugin", "mode")[0]), {"enabled": False}, "A refused option changes nothing.")
    # case-contract: test_plugin_draft_versions_and_restore | Plugin edits persist as an isolated draft, saving publishes a new version and preserves history, discard restores the saved preview, and restoring an older version publishes it as a new revision.
    def test_plugin_draft_versions_and_restore(self):
        source = self.PLUGIN_CONTEXT_SOURCE
        installed = self.write_installed_plugin("versioned", source, placement="mainSidebar")
        editor = self.assert_success(self.call_cli("plugin", "edit", "--id", "versioned")[0])["task"]
        draft = Path(editor["contextFolders"][0]) / "versioned"
        changed = source.replace("props.plugin.placement", '"draft change"')
        (draft / "index.js").write_text(changed, encoding="utf-8")
        self.assertEqual((installed / "index.js").read_text(), source)
        self.assertEqual(self.assert_success(self.call_cli("plugin", "edit", "--id", "versioned")[0])["task"]["id"], editor["id"])
        self.assertEqual((draft / "index.js").read_text(), changed)
        saved = self.assert_success(self.call_cli("plugin", "save", "--id", "versioned")[0])["plugin"]
        self.assertEqual(saved["version"], 1)
        self.assertEqual(json.loads((installed / "plugin.json").read_text())["version"], 1)
        self.assertEqual((installed / "index.js").read_text(), changed)
        self.assertEqual(self.assert_success(self.call_cli("plugin", "versions", "--id", "versioned")[0])["versions"], [0])
        self.assertEqual(json.loads((self.plugins_folder() / ".versions" / "versioned" / "0" / "plugin.json").read_text())["version"], 0)
        (draft / "index.js").write_text("invalid javascript !", encoding="utf-8")
        self.assertNotEqual(self.call_cli("plugin", "save", "--id", "versioned", expected_status=1)[0]["ok"], True)
        self.assertEqual((installed / "index.js").read_text(), changed)
        self.assert_success(self.call_cli("plugin", "discard", "--id", "versioned")[0])
        self.assertEqual((draft / "index.js").read_text(), changed)
        (draft / "index.js").write_text("unsaved changes", encoding="utf-8")
        self.assertNotEqual(self.call_cli("plugin", "restore", "--id", "versioned", "--version", "99", expected_status=1)[0]["ok"], True)
        self.assertEqual((draft / "index.js").read_text(), "unsaved changes")
        restored = self.assert_success(self.call_cli("plugin", "restore", "--id", "versioned", "--version", "0")[0])["plugin"]
        self.assertEqual((draft / "index.js").read_text(), "unsaved changes")
        self.assertEqual(restored["version"], 2)
        self.assertEqual((installed / "index.js").read_text(), source)
        self.assertEqual(self.assert_success(self.call_cli("plugin", "versions", "--id", "versioned")[0])["versions"], [1, 0])
        self.assert_success(self.call_cli("plugin", "discard", "--id", "versioned")[0])
        (draft / "index.js").write_text(changed, encoding="utf-8")
        draft.parent.chmod(0o500)
        try:
            published = self.assert_success(self.call_cli("plugin", "save", "--id", "versioned")[0])
        finally:
            draft.parent.chmod(0o700)
        self.assertTrue(published["draftSyncFailed"])
        self.assertEqual(published["plugin"]["version"], 3)
        self.assertEqual((installed / "index.js").read_text(), changed)
        self.assertEqual((draft / "index.js").read_text(), changed)

    # case-contract: test_plugin_authoring_task_starts_with_placement_and_skill | Plugin authoring starts with centered name and presentation setup, then opens a standalone conversation beside a live preview with an empty composer, guidance to describe the plugin, the chosen name, placement and presentation with a note that the user can ask to change any of them, no repository title, no provider turn, and no board card or task header. The editor header shows “Plugin editor” beside its back button. The user can choose a model and write an unsent description; the Plugins menu reopens the same conversation and preview with its draft and history. Name, presentation, placement and generated plugin identity persist in provider instructions, which let the user change any of those choices, even the name; a changed name, placement and presentation names the unsaved draft's editor and is published under the same plugin ID on save; invalid setup is rejected. Claude and Codex receive the setup and bundled skill without installing files in the user’s home.
    def test_plugin_authoring_task_starts_with_placement_and_skill(self):
        self.assert_failure(self.call_cli("plugin", "author", "--placement", "titleBar", expected_status=2)[0], "invalid_argument")
        self.assertFalse(self.plugins_folder().exists(), "A refused placement creates nothing.")
        expected_titles = {
            "mainSidebar": "Main sidebar", "conversationSidebar": "Conversation sidebar",
            "conversationToolbar": "Conversation sidebar toolbar", "composerActions": "Chat input actions",
        }
        started = {}
        for placement, title in expected_titles.items():
            provider = "codex" if placement == "conversationToolbar" else "claude"
            result = self.assert_success(self.call_cli("plugin", "author", "--placement", placement, "--provider", provider)[0])
            task, prompt = result["task"], result["prompt"]
            self.assertEqual(prompt, "", "The user writes the plugin description.")
            self.assertEqual(task["title"], title)
            self.assertEqual(task["status"], "Backlog")
            self.assertEqual(task["pluginPlacement"], placement)
            self.assertEqual(task["repositoryWorktrees"], [], "A plugin task needs no repository.")
            self.assertEqual([os.path.realpath(path) for path in task["contextFolders"]], [os.path.realpath(self.plugins_folder() / ".drafts" / "plugins")])
            self.assertEqual(task["conversationProvider"], provider)
            stored = self.assert_success(self.call_cli("plugin", "edit", "--id", task["authoredPluginID"])[0])["task"]
            self.assertEqual(stored["id"], task["id"])
            self.assertFalse(stored.get("savedPrompt"), "A fresh editor has no generated user prompt.")
            self.assertEqual(stored["pluginPlacement"], placement)
            started[placement] = (task, prompt)
        self.assert_failure(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", " ", "--presentation", "popover", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Timer", "--presentation", "unknown", expected_status=2)[0], "invalid_argument")
        configured = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Timer", "--presentation", "modal", "--provider", "claude")[0])
        authored = configured["task"]
        self.assertEqual(authored["title"], "Timer")
        self.assertEqual((authored.get("pluginAuthoringName"), authored.get("pluginAuthoringPresentation"), authored["pluginPlacement"]), ("Timer", "modal", "mainSidebar"),
                         "The editor keeps the chosen name, presentation and placement its empty conversation shows.")
        self.assertIsNone(authored.get("pendingSubmittedPrompt"), "Creating the authoring session leaves its prompt unsent.")
        self.assertEqual(configured["prompt"], "")
        stored_authored = self.assert_success(self.call_cli("plugin", "edit", "--id", authored["authoredPluginID"])[0])["task"]
        self.assertEqual(stored_authored["id"], authored["id"])
        self.assertNotIn(authored["id"], [entry["id"] for entry in self.assert_success(self.call_cli("board", "list")[0])["tasks"]])
        self.assert_failure(self.call_cli("plugin", "edit", "--id", "missing", expected_status=3)[0], "not_found")
        self.assertEqual(stored_authored["authoredPluginID"], authored["authoredPluginID"])
        self.assertEqual(stored_authored["pluginPlacement"], "mainSidebar")
        self.assertEqual((stored_authored.get("pluginAuthoringName"), stored_authored.get("pluginAuthoringPresentation")), ("Timer", "modal"), "Reopening keeps the chosen details.")
        self.assertFalse(stored_authored.get("savedPrompt"))
        selected_model = self.assert_success(self.call_cli("conversation", "model", authored["id"], "set", "claude-opus-5-5")[0])
        self.assertEqual(selected_model["modelID"], "claude-opus-5-5")
        self.assertEqual(self.assert_success(self.call_cli("conversation", "model", authored["id"])[0])["modelID"], "claude-opus-5-5")
        after_model_selection = self.assert_success(self.call_cli("plugin", "edit", "--id", authored["authoredPluginID"])[0])["task"]
        self.assertFalse(after_model_selection.get("savedPrompt"), "Choosing a model leaves the composer empty.")
        self.assertIsNone(after_model_selection.get("pendingSubmittedPrompt"), "Choosing a model does not send a turn.")
        self.assert_success(self.call_cli("task", "draft", authored["id"], "--text", "A countdown timer")[0])
        restored_draft = self.assert_success(self.call_cli("plugin", "edit", "--id", authored["authoredPluginID"])[0])["task"]
        self.assertEqual(restored_draft["savedPrompt"], "A countdown timer")
        self.assertIsNone(restored_draft.get("pendingSubmittedPrompt"))

        other = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Timer", "--presentation", "modal")[0])
        self.assertNotEqual(other["task"]["authoredPluginID"], authored["authoredPluginID"])
        # Every setup choice can change later, even the name: the draft manifest wins on save.
        renamed_id = other["task"]["authoredPluginID"]
        renamed_draft = self.plugins_folder() / ".drafts" / "plugins" / renamed_id
        renamed_draft.mkdir(parents=True, exist_ok=True)
        (renamed_draft / "plugin.json").write_text(json.dumps({"id": renamed_id, "name": "Stopwatch", "icon": "stopwatch", "placement": "conversationToolbar", "presentation": "sidebar"}), encoding="utf-8")
        (renamed_draft / "index.js").write_text(self.PLUGIN_CONTEXT_SOURCE, encoding="utf-8")
        renamed_session = next(entry for entry in self.assert_success(self.call_cli("plugin", "sessions")[0])["sessions"] if entry["authoredPluginID"] == renamed_id)
        self.assertEqual(renamed_session["title"], "Stopwatch", "An unsaved draft's editor is listed under the name the agent changed it to.")
        renamed_saved = self.assert_success(self.call_cli("plugin", "save", "--id", renamed_id)[0])["plugin"]
        self.assertEqual((renamed_saved["id"], renamed_saved["name"], renamed_saved["placement"], renamed_saved["presentation"]),
                         (renamed_id, "Stopwatch", "conversationToolbar", "sidebar"), "Saving publishes the changed name, placement and presentation under the same ID.")
        listed = next(entry for entry in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"] if entry["id"] == renamed_id)
        self.assertEqual((listed["name"], listed["placement"], listed["presentation"], listed["valid"]), ("Stopwatch", "conversationToolbar", "sidebar", True))
        self.assertEqual(self.assert_success(self.call_cli("plugin", "edit", "--id", renamed_id)[0])["task"]["id"], other["task"]["id"], "The changed plugin keeps its editor conversation.")
        self.write_installed_plugin("existing-editor", self.PLUGIN_CONTEXT_SOURCE, placement="composerActions")
        edits = []
        def open_existing():
            edits.append(self.assert_success(self.call_cli("plugin", "edit", "--id", "existing-editor")[0])["task"])
        workers = [threading.Thread(target=open_existing) for _ in range(2)]
        for worker in workers: worker.start()
        for worker in workers: worker.join(timeout=30)
        self.assertEqual(len(edits), 2)
        self.assertEqual(edits[0]["id"], edits[1]["id"], "Concurrent edits share one session.")
        existing = edits[0]
        self.assertEqual(existing["authoredPluginID"], "existing-editor")
        self.assertEqual(existing["id"], self.assert_success(self.call_cli("plugin", "edit", "--id", "existing-editor")[0])["task"]["id"])
        self.plugins_folder().chmod(0o500)
        try:
            self.assert_failure(self.call_cli("plugin", "delete", "--id", "existing-editor", expected_status=1)[0], "operation_failed")
        finally:
            self.plugins_folder().chmod(0o700)
        self.assertEqual(existing["id"], self.assert_success(self.call_cli("plugin", "edit", "--id", "existing-editor")[0])["task"]["id"], "A failed delete preserves the session.")
        self.assert_success(self.call_cli("plugin", "delete", "--id", "existing-editor")[0])
        self.assertNotIn("existing-editor", [entry["authoredPluginID"] for entry in self.assert_success(self.call_cli("plugin", "sessions")[0])["sessions"]])
        self.assert_failure(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Timer", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--presentation", "modal", expected_status=2)[0], "invalid_argument")
        configured_environment = self.install_claude_fixture("claude-fixture-plugin-preview")
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        for value in ("First preview", "Updated preview"):
            message = "plugin-preview-fixture " + json.dumps({"folder": str(self.plugins_folder() / ".drafts" / "plugins" / authored["authoredPluginID"]), "text": value})
            self.assert_success(self.call_cli("conversation", "send", authored["id"], "--message", message, extra_environment=configured_environment)[0])
            rendered = self.assert_success(self.call_cli("plugin", "render", "--file", self.plugins_folder() / ".drafts" / "plugins" / authored["authoredPluginID"] / "index.js")[0])
            self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "preview-content")), value)
        self.assert_success(self.call_cli("task", "draft", authored["id"], "--text", "Resume this draft")[0])
        reopened = self.assert_success(self.call_cli("plugin", "edit", "--id", authored["authoredPluginID"])[0])["task"]
        self.assertEqual(reopened["id"], authored["id"])
        self.assertEqual(reopened["savedPrompt"], "Resume this draft")
        texts, _ = self.history_texts(reopened["id"], configured_environment)
        self.assertTrue(any("Updated preview" in text for text in texts))
        self.assert_failure(self.call_cli("plugin", "edit", "--id", "../plugins", expected_status=2)[0], "invalid_argument")
        self.assert_success(self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")[0])
        composer_author = self.assert_success(self.call_cli("plugin", "author", "--placement", "composerActions", "--name", "Composer", "--presentation", "popover")[0])["task"]
        self.write_installed_plugin(composer_author["authoredPluginID"], self.PLUGIN_CONTEXT_SOURCE, placement="composerActions")
        composer_props = json.dumps({"composer": {"draft": "draft", "selection": {"location": 0, "length": 5, "text": "draft"}}})
        preview = self.assert_success(self.call_cli("plugin", "render", "--plugin", composer_author["authoredPluginID"], "--task", composer_author["id"], "--props", composer_props, "--event", "plugin-set-draft:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(preview["tree"], "plugin-draft")), "draft")
        self.assertTrue(any(call.get("name") == "composer.setDraft" for call in preview["hostCalls"]))
        self.assertEqual(self.plugin_text(self.plugin_node(preview["tree"], "plugin-selection")), "draft")
        for event, call_name in (("plugin-upper", "composer.replaceSelection"), ("plugin-insert", "composer.insertText"), ("plugin-focus", "composer.focus")):
            action = self.assert_success(self.call_cli("plugin", "render", "--plugin", composer_author["authoredPluginID"], "--task", composer_author["id"], "--props", composer_props, "--event", event + ":onPress")[0])
            self.assertTrue(any(call.get("name") == call_name for call in action["hostCalls"]))
        self.assertTrue(self.plugins_folder().is_dir(), "Authoring creates the plugins folder.")

        # Claude Code: the instructions ride --append-system-prompt and the skill a Playhouse wrapper.
        environment = self.install_claude_fixture("claude-fixture-plugin-author")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        task = self.assert_success(self.call_cli("plugin", "author", "--placement", "composerActions", "--name", "Context Claude", "--presentation", "modal", "--provider", "claude")[0])["task"]
        prompt = "Build a countdown timer."
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", prompt, extra_environment=environment)[0])
        turn = next(turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == prompt)
        arguments = turn["arguments"]
        instructions = arguments[arguments.index("--append-system-prompt") + 1]
        self.assertIn("Plugin authoring", instructions)
        self.assertIn(task["authoredPluginID"], instructions)
        self.assertIn("The chosen plugin name is Context Claude.", instructions)
        self.assertIn("The chosen presentation is modal.", instructions)
        self.assertIn(self.PLUGIN_CHANGE_RULE, instructions, "Every setup choice, even the name, can change on request.")
        self.assertIn("Chat input actions placement (`composerActions`)", instructions)
        self.assertIn("`composer` ({draft, selection", instructions, "The instructions describe the placement's context.")
        self.assertTrue(str(self.plugins_folder()) in instructions or os.path.realpath(self.plugins_folder()) in instructions)
        self.assertIn("persistent draft", instructions)
        self.assertIn("plugin render --file", instructions)
        directories = [arguments[index + 1] for index, value in enumerate(arguments) if value == "--add-dir"]
        wrappers = [Path(path) for path in directories if (Path(path) / ".claude" / "skills" / "playhouse-plugin").exists()]
        self.assertEqual(len(wrappers), 1, f"One wrapper carries the plugin skill: {directories}")
        self.assertSamePath(wrappers[0].parent, self.data_directory / "skill-bridge" / "claude")
        skill = wrappers[0] / ".claude" / "skills" / "playhouse-plugin" / "SKILL.md"
        self.assertTrue(os.path.realpath(skill).endswith("Contents/Resources/PluginRuntime/skills/playhouse-plugin/SKILL.md"),
                        "The wrapper links to the skill in the app bundle.")
        self.assertIn("name: playhouse-plugin", skill.read_text(encoding="utf-8"))
        self.assertIn("playhouse-plugin", turn["skills"], "Claude Code loads the bundled skill.")
        self.assertFalse((self.skills_home / ".claude" / "skills" / "playhouse-plugin").exists(), "Nothing is installed in the user's skills.")
        self.assertFalse((self.plugins_folder() / ".claude").exists(), "Nothing is written into the plugins folder.")

        # A follow-up turn of the plugin task keeps both.
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Make it blue.", extra_environment=environment)[0])
        resumed = next(turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == "Make it blue.")
        self.assertTrue(resumed["resumed"], "The follow-up resumes the plugin task's session.")
        resumed_instructions = resumed["arguments"][resumed["arguments"].index("--append-system-prompt") + 1]
        self.assertIn("Plugin authoring", resumed_instructions)
        self.assertIn("The chosen plugin name is Context Claude.", resumed_instructions)
        self.assertIn("The chosen presentation is modal.", resumed_instructions)
        self.assertIn(self.PLUGIN_CHANGE_RULE, resumed_instructions)
        self.assertIn(str(self.plugins_folder() / ".drafts" / "plugins"), resumed_instructions)
        resumed_directories = [resumed["arguments"][index + 1] for index, value in enumerate(resumed["arguments"]) if value == "--add-dir"]
        self.assertIn(os.path.realpath(wrappers[0]), [os.path.realpath(path) for path in resumed_directories], "The resumed turn keeps the skill wrapper.")
        bridge = self.assert_success(self.call_cli("skills", "bridge", "--task", task["id"])[0])
        self.assertIn(os.path.realpath(wrappers[0]), [os.path.realpath(path) for path in bridge["claudeAddDirectories"]],
                      "skills bridge reports the wrapper the launch passes.")

        # An ordinary Claude task gets neither the instructions nor the skill.
        ordinary = self.create_task("Ordinary task", roots=[], provider="claude")
        self.assert_success(self.call_cli("conversation", "send", ordinary["id"], "--message", "Hello.", extra_environment=environment)[0])
        plain = next(turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == "Hello.")
        self.assertNotIn("Plugin authoring", plain["arguments"][plain["arguments"].index("--append-system-prompt") + 1])
        self.assertNotIn("playhouse-plugin", plain["skills"])

        legacy = self.create_task("New plugin: Legacy", roots=[], provider="claude")
        self.assert_success(self.call_cli("conversation", "send", legacy["id"], "--message", "Remember the legacy conversation.", extra_environment=environment)[0])
        self.assert_success(self.call_cli("task", "draft", legacy["id"], "--text", "Legacy draft")[0])
        legacy_before = self.assert_success(self.call_cli("task", "get", legacy["id"])[0])
        self.write_installed_plugin("legacy-editor", self.PLUGIN_CONTEXT_SOURCE, placement="mainSidebar")
        self.seed_legacy_plugin_task(legacy["id"], "legacy-editor")
        migrated = self.assert_success(self.call_cli("plugin", "edit", "--id", "legacy-editor")[0])["task"]
        self.assertEqual(migrated["id"], legacy["id"])
        self.assertEqual(migrated["savedPrompt"], "Legacy draft")
        self.assertEqual(migrated["claudeSessionID"], legacy_before["claudeSessionID"])
        self.assert_success(self.call_cli("conversation", "send", migrated["id"], "--message", "Continue migrated editor.", extra_environment=environment)[0])
        migrated_turn = next(turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == "Continue migrated editor.")
        migrated_instructions = migrated_turn["arguments"][migrated_turn["arguments"].index("--append-system-prompt") + 1]
        self.assertIn(str(self.plugins_folder() / ".drafts" / "plugins"), migrated_instructions)
        self.assertNotIn(legacy["id"], [entry["id"] for entry in self.assert_success(self.call_cli("board", "list")[0])["tasks"]])
        texts, _ = self.history_texts(legacy["id"], environment)
        self.assertTrue(any("Remember the legacy conversation" in text for text in texts))
        legacy_delete = self.create_task("New plugin: Delete legacy", roots=[], provider="claude")
        self.write_installed_plugin("legacy-delete", self.PLUGIN_CONTEXT_SOURCE, placement="mainSidebar")
        self.seed_legacy_plugin_task(legacy_delete["id"], "legacy-delete")
        self.assert_success(self.call_cli("plugin", "delete", "--id", "legacy-delete")[0])
        self.assertNotIn(legacy_delete["id"], [entry["id"] for entry in self.assert_success(self.call_cli("board", "list")[0])["tasks"]])
        self.assertNotIn("legacy-delete", [entry["authoredPluginID"] for entry in self.assert_success(self.call_cli("plugin", "sessions")[0])["sessions"]])

    # case-contract: test_plugin_authoring_codex_instructions_resume | A Codex plugin editor sends the user’s description with the chosen name, presentation, placement, generated plugin identity and permission to change any of those choices in thread instructions, automatically supplies the bundled plugin skill, and restores the same setup when the thread resumes on a fresh app-server. The composer starts empty and no turn starts until the user sends.
    def test_plugin_authoring_codex_instructions_resume(self):
        # Codex: the instructions ride the thread and the skill an extra root plus a structured input.
        executable = self.install_provider_fixture("codex", "codex-fixture-plugin-author")
        configured = self.assert_success(self.call_cli("plugin", "author", "--placement", "conversationToolbar", "--name", "Context Codex", "--presentation", "popover", "--provider", "codex")[0])
        task = configured["task"]
        self.assertEqual(configured["prompt"], "")
        reopened = self.assert_success(self.call_cli("plugin", "edit", "--id", task["authoredPluginID"])[0])["task"]
        self.assertFalse(reopened.get("savedPrompt"))
        self.assertIsNone(reopened.get("pendingSubmittedPrompt"))
        self.assertFalse((self.data_directory / "codex-fixture-plugin-author.history").exists(), "No provider turn starts during setup.")
        prompt = "Build a countdown timer for Codex."
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", prompt, "--answer", "color=Blue", "--answer", "token=fixture-secret", extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)})[0])
        history = json.loads((self.data_directory / "codex-fixture-plugin-author.history").read_text(encoding="utf-8"))
        self.assertIn("Conversation sidebar toolbar placement (`conversationToolbar`)", history["threadStartDeveloperInstructions"])
        self.assertIn("plugin render", history["threadStartDeveloperInstructions"])
        self.assertIn("The chosen plugin name is Context Codex.", history["threadStartDeveloperInstructions"])
        self.assertIn("The chosen presentation is popover.", history["threadStartDeveloperInstructions"])
        self.assertIn(self.PLUGIN_CHANGE_RULE, history["threadStartDeveloperInstructions"], "Codex is told every setup choice can change on request.")
        self.assertIn(task["authoredPluginID"], history["threadStartDeveloperInstructions"])
        self.assertIn("persistent draft", history["threadStartDeveloperInstructions"])
        roots = [Path(root) for root in history["skillExtraRoots"] if (Path(root) / "playhouse-plugin" / "SKILL.md").exists()]
        self.assertEqual(len(roots), 1, f"One extra root carries the plugin skill: {history['skillExtraRoots']}")
        self.assertSamePath(roots[0].parent, self.data_directory / "skill-bridge" / "codex")
        first = next(turn for turn in history["turns"] if turn["userMessage"] == prompt)
        self.assertEqual([entry["name"] for entry in first["skillInputs"]], ["playhouse-plugin"])
        self.assertTrue(first["skillInputs"][0]["path"].endswith("skills/playhouse-plugin/SKILL.md"))
        disabled = {os.path.realpath(entry["path"]) for entry in (history.get("threadStartConfig") or {}).get("skills", {}).get("config", []) if entry["enabled"] is False}
        self.assertNotIn(os.path.realpath(roots[0] / "playhouse-plugin" / "SKILL.md"), disabled, "The plugin task's own skill stays on.")
        self.assertFalse((self.skills_codex_home / "config.toml").exists(), "Codex's config.toml is not written.")
        self.restart_provider(executable)
        reopened_codex = self.assert_success(self.call_cli("plugin", "edit", "--id", task["authoredPluginID"])[0])["task"]
        self.assertEqual(reopened_codex["id"], task["id"])
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Continue editing.", "--answer", "color=Blue", "--answer", "token=fixture-secret", extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)})[0])
        resumed_history = json.loads((self.data_directory / "codex-fixture-plugin-author.history").read_text(encoding="utf-8"))
        self.assertTrue(any(turn["userMessage"] == "Continue editing." for turn in resumed_history["turns"]))
        self.assertGreaterEqual(resumed_history.get("threadResumeCount", 0), 1)
        self.assertIn(task["authoredPluginID"], resumed_history["threadResumeDeveloperInstructions"][-1])
        self.assertIn("The chosen plugin name is Context Codex.", resumed_history["threadResumeDeveloperInstructions"][-1])
        self.assertIn("The chosen presentation is popover.", resumed_history["threadResumeDeveloperInstructions"][-1])
        self.assertIn(self.PLUGIN_CHANGE_RULE, resumed_history["threadResumeDeveloperInstructions"][-1], "Codex is told every setup choice can change on request.")
        self.assertIn(str(self.plugins_folder() / ".drafts" / "plugins"), resumed_history["threadResumeDeveloperInstructions"][-1])
        self.assertEqual(reopened_codex["codexThreadID"], self.assert_success(self.call_cli("plugin", "edit", "--id", task["authoredPluginID"])[0])["task"]["codexThreadID"])

        legacy_codex = self.create_task("New plugin: Codex legacy", roots=[], provider="codex")
        codex_env = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        self.assert_success(self.call_cli("conversation", "send", legacy_codex["id"], "--message", "Before migration.", "--answer", "color=Blue", "--answer", "token=fixture-secret", extra_environment=codex_env)[0])
        self.write_installed_plugin("legacy-codex", self.PLUGIN_CONTEXT_SOURCE, placement="mainSidebar")
        self.seed_legacy_plugin_task(legacy_codex["id"], "legacy-codex")
        migrated_codex = self.assert_success(self.call_cli("plugin", "edit", "--id", "legacy-codex")[0])["task"]
        self.restart_provider(executable)
        self.assert_success(self.call_cli("conversation", "send", migrated_codex["id"], "--message", "After migration.", "--answer", "color=Blue", "--answer", "token=fixture-secret", extra_environment=codex_env)[0])
        codex_history = json.loads((self.data_directory / "codex-fixture-plugin-author.history").read_text(encoding="utf-8"))
        self.assertIn(str(self.plugins_folder() / ".drafts" / "plugins"), codex_history["threadResumeDeveloperInstructions"][-1])
        self.assertIn("legacy-codex", codex_history["threadResumeDeveloperInstructions"][-1])

    # case-contract: test_plugin_editor_reattaches_after_daemon_restart | A plugin editor follows a running Claude turn after a daemon restart, restores its answer once alongside the preview, and settles without a task outcome nudge. Claude represents the shared reattachment settlement used by both providers.
    def test_plugin_editor_reattaches_after_daemon_restart(self):
        executable = self.install_provider_fixture("claude", "claude-fixture-reattach-plugin")
        environment = self.restart_service_environment("claude", executable)
        created = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Restart plugin", "--presentation", "modal", "--provider", "claude", extra_environment=environment)[0])["task"]
        self.assertTrue(Path(created["contextFolders"][0]).is_dir(), "The working folder exists before reopening the editor or sending.")
        marker = Path(str(executable) + ".reattach-hold-nudge")
        marker.touch()
        self.start_chat_turn_and_kill_daemon(executable, environment, created["id"], "Continue this plugin after restart.")
        Path(str(executable) + ".reattach-release-quiet").touch()
        self.wait_for(lambda: self.assert_success(self.call_cli("plugin", "edit", "--id", created["authoredPluginID"], extra_environment=environment)[0])["task"]["status"] == "Waiting Response", "The plugin turn settles without task outcome reporting.", timeout=40)
        texts, _ = self.history_texts(created["id"], environment)
        self.assertEqual(texts.count("After restart."), 1)
        self.assertTrue(marker.exists(), "No task outcome nudge was sent.")
    # case-contract: test_plugin_enable_disable_and_builtins | `plugin list` reports the built-in Changes plugin first (builtIn, valid and enabled, at the conversation sidebar with the inline presentation) before the installed plugins. A built-in can't be deleted, edited or rendered headlessly (invalid_argument), and an installed folder with a built-in's id is invalid. An inline plugin is valid only at the conversation sidebar. `plugin disable --id` and `plugin enable --id` work on built-in and installed plugins, bump the plugins revision and persist across fresh CLI reads. A disabled plugin is listed with enabled false, is not run when plugins are refreshed, and `plugin render` refuses it as unavailable until it is enabled again. An unknown id is not_found, a malformed or missing one invalid_argument, and a deleted plugin installed again starts enabled with no saved state. An inline conversation sidebar plugin receives `workspace` (its revision and the open diff) and `sidebar` (whether it is on the rail) props, and its Playhouse.ui.refreshWorkspace and openDiff calls are recorded headlessly, while the board's sidebar refuses them as unavailable. In the window, the Plugins menu has a Built-in Plugins section whose Changes submenu offers Disable but no Edit or Delete. Disabling Changes removes the task sidebar's Changes section and labels it Disabled, and enabling it brings the section back. An installed plugin's submenu offers Disable beside Edit and Delete, and disabling it removes its button until it is enabled again. An installed inline plugin renders in place in the task sidebar with no entry button: its refreshWorkspace raises the workspace revision, its openDiff opens the window's diff view for a real change and the open diff reaches its props, and on the hidden sidebar's rail it reads that it is on the rail. Each plugin keeps its own saved values: `plugin state --id` reads them and `plugin state --id --key --value <json>` stores one (null removes it) and bumps the plugins revision; `plugin list` reports each plugin's `state`, which an installed plugin gets as `props.state` and stores with Playhouse.setState (recorded headlessly), and the built-in Changes keeps its state the same way. An unknown id is not_found, and an empty key, a missing value or a value that is not JSON is invalid_argument without bumping the revision. A fresh daemon reads the disabled ids and saved states back from settings, and authoring an inline plugin outside the conversation sidebar is invalid_argument. In the window, the inline plugin's Playhouse.setState comes back as its props.state, and collapsing the Changes section saves its collapsed state as its plugin state. After a relaunch a disabled Changes stays hidden and labeled Disabled while the plugin keeps its saved state, and enabled again, Changes comes back collapsed. An open page plugin receives its newly saved state, and disabling a plugin closes its open surface.
    def test_plugin_enable_disable_and_builtins(self):
        def listed():
            return self.assert_success(self.call_cli("plugin", "list")[0])
        def by_id(response):
            return {plugin["id"]: plugin for plugin in response["plugins"]}

        initial = listed()
        changes = initial["plugins"][0]
        self.assertEqual((changes["id"], changes["name"], changes["placement"], changes["presentation"]), ("changes", "Changes", "conversationSidebar", "inline"))
        self.assertEqual((changes["builtIn"], changes["valid"], changes["enabled"], changes["errors"]), (True, True, True, []))
        self.assertEqual([plugin["id"] for plugin in initial["plugins"]], ["changes"], "Only the built-ins are listed before any plugin is installed.")

        hello = 'Playhouse.render(h(Text, { testID: "hello" }, "Hello"));'
        self.write_installed_plugin("hello-board", hello, placement="mainSidebar", presentation="page")
        self.write_installed_plugin("workspace-probe", self.PLUGIN_WORKSPACE_SOURCE, placement="conversationSidebar", presentation="inline")
        self.write_installed_plugin("board-probe", self.PLUGIN_WORKSPACE_SOURCE, placement="mainSidebar", presentation="page")
        self.write_installed_plugin("inline-composer", hello, placement="composerActions", presentation="inline")
        self.write_installed_plugin("changes", hello, placement="conversationSidebar", presentation="inline")
        refreshed = self.assert_success(self.call_cli("plugin", "refresh")[0])
        self.assertEqual([plugin["id"] for plugin in refreshed["plugins"]], ["changes", "board-probe", "changes", "hello-board", "inline-composer", "workspace-probe"],
                         "The built-ins come first, then the installed plugins by id.")
        self.assertTrue(refreshed["plugins"][0]["builtIn"])
        shadow = refreshed["plugins"][2]
        self.assertFalse(shadow["builtIn"])
        self.assertFalse(shadow["valid"])
        self.assertTrue(any("is a built-in plugin's id" in error for error in shadow["errors"]), shadow["errors"])
        plugins = {plugin["id"]: plugin for plugin in refreshed["plugins"][3:]}
        self.assertTrue(plugins["workspace-probe"]["valid"], plugins["workspace-probe"]["errors"])
        self.assertFalse(plugins["inline-composer"]["valid"])
        self.assertTrue(any("only in the conversation sidebar" in error for error in plugins["inline-composer"]["errors"]), plugins["inline-composer"]["errors"])
        self.assertTrue(all(plugin["enabled"] and not plugin["builtIn"] for plugin in plugins.values()))
        (self.plugins_folder() / "changes" / "plugin.json").unlink()
        (self.plugins_folder() / "changes" / "index.js").unlink()
        (self.plugins_folder() / "changes").rmdir()

        # A built-in is compiled in: it can only be disabled.
        for command in (("delete",), ("edit",)):
            refused = self.call_cli("plugin", *command, "--id", "changes", expected_status=2)[0]
            self.assert_failure(refused, "invalid_argument")
            self.assertIn("built-in", refused["error"]["message"])
        self.assert_failure(self.call_cli("plugin", "render", "--plugin", "changes", expected_status=2)[0], "invalid_argument")

        # An inline conversation sidebar plugin gets the workspace and the sidebar, and its calls are recorded.
        self.prepare_workspace_changes()
        task = self.create_task(title="Inline plugin task", roots=[self.changes])
        rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"])[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "probe-revision")), "revision 0")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "probe-open")), "no diff")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "probe-rail")), "expanded")
        opened_props = json.dumps({"workspace": {"revision": 3, "openDiff": {"repository": str(self.changes), "path": "shared.txt", "group": "unviewed"}}, "sidebar": {"collapsed": True}})
        railed = self.assert_success(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"], "--props", opened_props)[0])
        self.assertEqual(self.plugin_text(self.plugin_node(railed["tree"], "probe-revision")), "revision 3")
        self.assertEqual(self.plugin_text(self.plugin_node(railed["tree"], "probe-open")), "open shared.txt")
        self.assertEqual(self.plugin_text(self.plugin_node(railed["tree"], "probe-rail")), "rail")
        refreshed_call = self.assert_success(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"], "--event", "probe-refresh:onPress")[0])
        self.assertEqual(refreshed_call["hostCalls"], [{"kind": "ui", "name": "refreshWorkspace", "arguments": {}, "ok": True, "result": None}])
        self.assertEqual(self.plugin_text(self.plugin_node(refreshed_call["tree"], "probe-status")), "refresh: ok")
        diffed = self.assert_success(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"], "--event", "probe-open-diff:onPress")[0])
        self.assertEqual([(call["kind"], call["name"], call["ok"]) for call in diffed["hostCalls"]], [("bridge", "task.changes.list", True), ("ui", "openDiff", True)])
        inventory = self.assert_success(self.call_cli("task", "changes", "list", task["id"])[0])
        self.assertEqual(diffed["hostCalls"][1]["arguments"]["path"], inventory["unviewed"][0]["path"], "openDiff gets the listed entry.")
        self.assertEqual(self.plugin_text(self.plugin_node(diffed["tree"], "probe-status")), "openDiff: ok")

        # Each plugin keeps its own saved values, which come back as props.state.
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "probe-state")), "saved 0")
        self.assertEqual(by_id(listed())["workspace-probe"]["state"], {})
        saved = self.assert_success(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"], "--event", "probe-save:onPress")[0])
        self.assertEqual([(call["kind"], call["name"], call["ok"]) for call in saved["hostCalls"]], [("bridge", "plugin.state.set", True)])
        self.assertEqual(saved["hostCalls"][0]["arguments"], {"pluginID": "workspace-probe", "key": "clicks", "value": 1})
        self.assertEqual(self.plugin_text(self.plugin_node(saved["tree"], "probe-status")), "save: ok")
        self.assertEqual(self.assert_success(self.call_cli("plugin", "state", "--id", "workspace-probe")[0]), {"pluginID": "workspace-probe", "state": {"clicks": 1}})
        self.assertEqual(by_id(listed())["workspace-probe"]["state"], {"clicks": 1}, "plugin list reports each plugin's state.")
        reread = self.assert_success(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"])[0])
        self.assertEqual(self.plugin_text(self.plugin_node(reread["tree"], "probe-state")), "saved 1", "A new run of the plugin gets its saved state.")
        revision = listed()["revision"]
        stored = self.assert_success(self.call_cli("plugin", "state", "--id", "workspace-probe", "--key", "theme", "--value", '{"accent": "blue"}')[0])
        self.assertEqual(stored, {"pluginID": "workspace-probe", "state": {"clicks": 1, "theme": {"accent": "blue"}}, "revision": revision + 1},
                         "Saving bumps the plugins revision, so windows hand mounted plugins the new state.")
        removed = self.assert_success(self.call_cli("plugin", "state", "--id", "workspace-probe", "--key", "theme", "--value", "null")[0])
        self.assertEqual(removed["state"], {"clicks": 1}, "null removes a key.")
        collapsed = self.assert_success(self.call_cli("plugin", "state", "--id", "changes", "--key", "collapsed", "--value", "true")[0])
        self.assertEqual(collapsed["state"], {"collapsed": True}, "A built-in keeps its state the same way.")
        self.assertEqual(listed()["plugins"][0]["state"], {"collapsed": True})
        self.assert_success(self.call_cli("plugin", "state", "--id", "changes", "--key", "collapsed", "--value", "false")[0])
        before = listed()["revision"]
        self.assert_failure(self.call_cli("plugin", "state", "--id", "no-such-plugin", expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("plugin", "state", "--id", "no-such-plugin", "--key", "a", "--value", "1", expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("plugin", "state", "--id", "workspace-probe", "--key", " ", "--value", "1", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "state", "--id", "workspace-probe", "--key", "a", "--value", "{not json", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "state", "--id", "workspace-probe", "--key", "a", expected_status=2)[0], "invalid_argument")
        self.assertEqual(listed()["revision"], before, "A refused state change does not bump the revision.")
        self.assertEqual(by_id(listed())["workspace-probe"]["state"], {"clicks": 1})

        board = self.assert_success(self.call_cli("plugin", "render", "--plugin", "board-probe")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(board["tree"], "probe-revision")), "no workspace", "Only the conversation sidebar gets the workspace.")
        self.assertEqual(self.plugin_text(self.plugin_node(board["tree"], "probe-rail")), "no sidebar")
        for event, label in (("probe-refresh", "refresh"), ("probe-open-diff", "openDiff")):
            refused = self.assert_success(self.call_cli("plugin", "render", "--plugin", "board-probe", "--event", f"{event}:onPress")[0])
            self.assertEqual(self.plugin_text(self.plugin_node(refused["tree"], "probe-status")), f"{label}: unavailable")
            self.assertEqual(refused["hostCalls"][-1]["error"]["code"], "unavailable")

        # Disabling persists, hides nothing from the list, and stops the plugin from running.
        revision = listed()["revision"]
        disabled = self.assert_success(self.call_cli("plugin", "disable", "--id", "workspace-probe")[0])
        self.assertEqual(disabled, {"pluginID": "workspace-probe", "enabled": False, "revision": revision + 1})
        self.assertFalse(by_id(listed())["workspace-probe"]["enabled"], "A fresh CLI process reads the disabled state.")
        self.assert_failure(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"], expected_status=1)[0], "unavailable")
        self.assert_success(self.call_cli("plugin", "disable", "--id", "hello-board")[0])
        self.write_installed_plugin("hello-board", 'throw new Error("Disabled plugins never run");', placement="mainSidebar", presentation="page")
        quiet = by_id(self.assert_success(self.call_cli("plugin", "refresh")[0]))["hello-board"]
        self.assertEqual((quiet["valid"], quiet["enabled"], quiet["errors"]), (True, False, []), "A disabled plugin is not run when plugins are refreshed.")
        enabled = self.assert_success(self.call_cli("plugin", "enable", "--id", "hello-board")[0])
        self.assertEqual((enabled["pluginID"], enabled["enabled"]), ("hello-board", True))
        loud = by_id(self.assert_success(self.call_cli("plugin", "refresh")[0]))["hello-board"]
        self.assertFalse(loud["valid"], "Enabled again, it runs and its error shows.")
        self.assertTrue(any("Disabled plugins never run" in error for error in loud["errors"]), loud["errors"])
        self.assert_success(self.call_cli("plugin", "enable", "--id", "workspace-probe")[0])
        again = self.assert_success(self.call_cli("plugin", "render", "--plugin", "workspace-probe", "--task", task["id"])[0])
        self.assertEqual(self.plugin_text(self.plugin_node(again["tree"], "probe-revision")), "revision 0", "Enabling restores the plugin.")

        built_in = self.assert_success(self.call_cli("plugin", "disable", "--id", "changes")[0])
        self.assertEqual((built_in["pluginID"], built_in["enabled"]), ("changes", False))
        self.assertFalse(listed()["plugins"][0]["enabled"])
        # A fresh daemon (as after a relaunch) reads the disabled ids and states back from settings.
        environment = self.restart_service_environment("claude", "/usr/bin/false")
        try:
            fresh = by_id(self.assert_success(self.call_cli("plugin", "list", extra_environment=environment)[0]))
            self.assertFalse(fresh["changes"]["enabled"])
            self.assertEqual(fresh["workspace-probe"]["state"], {"clicks": 1})
            self.assertTrue(fresh["hello-board"]["enabled"])
        finally:
            self.kill_daemon(environment)
        self.assert_success(self.call_cli("plugin", "enable", "--id", "changes")[0])
        self.assertTrue(listed()["plugins"][0]["enabled"])

        # Authoring refuses an inline plugin where it can't sit.
        refused = self.call_cli("plugin", "author", "--placement", "composerActions", "--name", "Inline", "--presentation", "inline", expected_status=2)[0]
        self.assert_failure(refused, "invalid_argument")
        self.assertIn("only in the conversation sidebar", refused["error"]["message"])

        before = listed()["revision"]
        self.assert_failure(self.call_cli("plugin", "disable", "--id", "no-such-plugin", expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("plugin", "enable", "--id", "../plugins", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "disable", expected_status=2)[0], "invalid_argument")
        self.assertEqual(listed()["revision"], before, "A refused enable or disable does not bump the revision.")

        # A deleted plugin installed again starts enabled, with no saved state.
        self.assert_success(self.call_cli("plugin", "disable", "--id", "board-probe")[0])
        self.assert_success(self.call_cli("plugin", "state", "--id", "board-probe", "--key", "clicks", "--value", "4")[0])
        self.assert_success(self.call_cli("plugin", "delete", "--id", "board-probe")[0])
        self.write_installed_plugin("board-probe", self.PLUGIN_WORKSPACE_SOURCE, placement="mainSidebar", presentation="page")
        reinstalled = by_id(self.assert_success(self.call_cli("plugin", "refresh")[0]))["board-probe"]
        self.assertEqual((reinstalled["enabled"], reinstalled["state"]), (True, {}))
    # case-contract: test_plugin_install_refresh_and_delete | Each plugin is a folder in the data directory's plugins folder holding plugin.json (id, name, icon, placement, presentation) and its script. `plugin list` reports only the built-in plugins at first; after plugins are written, `plugin refresh` validates every folder, bumps the plugins revision, and reports the valid plugin beside invalid ones with their errors (an unknown placement or presentation, a manifest id that does not match its folder, a missing manifest or script, and a script that throws or uses an unknown atom when rendered once with sample context), which a fresh `plugin list` reports the same way without bumping the revision. The CLI reports each plugin's name, icon, placement, validity and first validation errors, and deleting through `plugin delete --id` removes only that plugin's folder. In the window, each plugin has its own submenu labeled with its placement, containing Edit, Delete and a disabled Settings placeholder; an invalid plugin's first error is inside its submenu. The Plugins menu visibly lists each plugin with a submenu indicator and opens a submenu with Edit, Delete and disabled Settings actions; an invalid plugin's first error is visible in its submenu. After a refresh the window shows the valid plugin's button at its placement. Deleting a plugin from its submenu after confirming, or with `plugin delete --id`, removes its folder, its button and its menu entry; an unknown id is not_found and an id that is not a plugin folder name is invalid_argument.
    def test_plugin_install_refresh_and_delete(self):
        empty = self.assert_success(self.call_cli("plugin", "list")[0])
        self.assertEqual([(plugin["id"], plugin["builtIn"]) for plugin in empty["plugins"]], [("changes", True)], "Only the built-ins are listed at first.")
        self.assertSamePath(empty["directory"], self.plugins_folder())
        self.assertEqual(empty["revision"], 0)

        hello = 'Playhouse.render(h(Text, { testID: "hello" }, "Hello from a plugin"));'
        self.write_installed_plugin("hello-board", hello, placement="mainSidebar", presentation="page", manifest={"name": "Hello Board", "icon": "hand.wave"})
        self.write_installed_plugin("bad-placement", hello, placement="titleBar")
        self.write_installed_plugin("bad-presentation", hello, presentation="toast")
        self.write_installed_plugin("wrong-id", hello, manifest={"id": "other-id"})
        self.write_installed_plugin("no-script", None)
        (self.plugins_folder() / "no-manifest").mkdir()
        (self.plugins_folder() / "no-manifest" / "index.js").write_text(hello, encoding="utf-8")
        self.write_installed_plugin("throws", 'throw new Error("Plugin exploded");')
        self.write_installed_plugin("unknown-atom", 'Playhouse.render(h("Blink", null));')
        (self.plugins_folder() / "notes.txt").write_text("Not a plugin.\n", encoding="utf-8")

        refreshed = self.assert_success(self.call_cli("plugin", "refresh")[0])
        self.assertEqual(refreshed["revision"], 1, "A refresh tells the window to reload.")
        plugins = {plugin["id"]: plugin for plugin in refreshed["plugins"] if not plugin["builtIn"]}
        self.assertEqual(sorted(plugins), ["bad-placement", "bad-presentation", "hello-board", "no-manifest", "no-script", "throws", "unknown-atom", "wrong-id"],
                         "Every plugin folder is listed, and a stray file is not.")
        board = plugins["hello-board"]
        self.assertTrue(board["valid"])
        self.assertEqual(board["errors"], [])
        self.assertEqual((board["name"], board["icon"], board["placement"], board["presentation"]), ("Hello Board", "hand.wave", "mainSidebar", "page"))
        self.assertSamePath(board["entryPath"], self.plugins_folder() / "hello-board" / "index.js")
        expected_errors = {
            "bad-placement": "Unknown placement \"titleBar\"",
            "bad-presentation": "Unknown presentation \"toast\"",
            "wrong-id": "does not match its folder",
            "no-script": "index.js is missing",
            "no-manifest": "plugin.json is missing",
            "throws": "Plugin exploded",
            "unknown-atom": "Unknown atom <Blink>",
        }
        for plugin_id, fragment in expected_errors.items():
            self.assertFalse(plugins[plugin_id]["valid"], f"{plugin_id} is invalid.")
            self.assertTrue(any(fragment in error for error in plugins[plugin_id]["errors"]), f"{plugin_id}: {plugins[plugin_id]['errors']}")
        self.assertEqual(plugins["throws"]["icon"], "puzzlepiece.extension", "A plugin without an icon gets the default.")

        listed = self.assert_success(self.call_cli("plugin", "list")[0])
        self.assertEqual(listed["plugins"], refreshed["plugins"], "A fresh CLI process reports the same plugins.")
        self.assertEqual(listed["revision"], 1, "Listing does not bump the revision.")

        deleted = self.assert_success(self.call_cli("plugin", "delete", "--id", "throws")[0])
        self.assertEqual(deleted, {"deleted": "throws", "revision": 2})
        self.assertFalse((self.plugins_folder() / "throws").exists(), "Deleting removes the plugin's folder.")
        self.assertTrue((self.plugins_folder() / "hello-board" / "index.js").exists(), "Other plugins stay.")
        self.assertNotIn("throws", [plugin["id"] for plugin in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]])
        self.assert_failure(self.call_cli("plugin", "delete", "--id", "throws", expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("plugin", "delete", "--id", "../plugins", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "delete", expected_status=2)[0], "invalid_argument")
        self.assertTrue(self.plugins_folder().is_dir(), "A refused delete leaves the plugins folder.")
        self.assertEqual(self.assert_success(self.call_cli("plugin", "list")[0])["revision"], 2, "A refused delete does not bump the revision.")
    # case-contract: test_plugin_surfaces_receive_context_and_host_access | An installed plugin receives its placement's context in Playhouse.props: the plugin and the appearance everywhere, the task with its repositories and context folders in the conversation placements, and the composer's draft and selected text in the composer placement, while the board's sidebar gets no task. `plugin render --plugin <id> --task <id>` renders it headlessly with that real context. Playhouse.bridge runs any bridge command but plugin render against the real store (a rename is seen by a fresh CLI process) and rejects a failing one with its code; Playhouse.ui close, openTask and the composer's setDraft, insertText, replaceSelection and focus are recorded headlessly; a composer call from the board's sidebar and a plugin render call are refused the same way in both hosts; and --task without --plugin or an unknown plugin is refused. In the window a page plugin from the board's sidebar covers the board, reads the real board, and its openTask opens that task without sending anything; a composer popover plugin opens anchored to its button showing the draft and the selected text, and its replaceSelection replaces the selected text in the composer; a sidebar plugin from the conversation sidebar slides in at the trailing edge showing the task's title and repository, inserts text after the selection, replaces the draft, renames the task, and closes with its close button; and a modal plugin beside the Terminal button opens as a sheet with the task's context and closes itself with Playhouse.ui.close. Every presentation starts with the app's standard modal header (the plugin's icon, its name and a close button) above the plugin's atoms, which bring no padding of their own yet sit inside the presentation's inset, as does the header: 24 points in a page or sheet, 20 in a sidebar, and 16 in a popover, whose header title is smaller than a sheet's.
    def test_plugin_surfaces_receive_context_and_host_access(self):
        self.write_installed_plugin("context-composer", self.PLUGIN_CONTEXT_SOURCE, placement="composerActions")
        self.write_installed_plugin("context-board", self.PLUGIN_CONTEXT_SOURCE, placement="mainSidebar", presentation="page")
        self.write_installed_plugin("props-dump", "Playhouse.render(h(Text, { testID: 'props' }, JSON.stringify(Playhouse.props)));", placement="conversationSidebar", presentation="sidebar")
        self.write_installed_plugin("context-toolbar", self.PLUGIN_CONTEXT_SOURCE, placement="conversationToolbar", presentation="modal")
        self.assertTrue(all(plugin["valid"] for plugin in self.assert_success(self.call_cli("plugin", "refresh")[0])["plugins"]))
        task = self.create_repo_task("Plugin context task", [self.primary])

        composer = json.dumps({"composer": {"draft": "make this loud", "selection": {"location": 10, "length": 4, "text": "loud"}}})
        rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "context-composer", "--task", task["id"], "--props", composer)[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "plugin-placement")), "composerActions")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "plugin-version")), "0")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "plugin-task")), "Plugin context task")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "plugin-repositories")), self.primary.name)
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "plugin-draft")), "make this loud")
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "plugin-selection")), "loud")
        self.assertEqual(rendered["hostCalls"], [])

        dumped = self.assert_success(self.call_cli("plugin", "render", "--plugin", "props-dump", "--task", task["id"])[0])
        props = json.loads(self.plugin_text(self.plugin_node(dumped["tree"], "props")))
        self.assertEqual(props["plugin"], {"id": "props-dump", "name": "Props Dump", "version": 0, "placement": "conversationSidebar", "presentation": "sidebar"})
        self.assertEqual(props["app"], {"appearance": "dark"})
        self.assertEqual(props["task"], {"id": task["id"], "title": "Plugin context task", "status": "Backlog", "provider": task["conversationProvider"], "isStandaloneChat": False})
        self.assertEqual(props["contextFolders"], [])
        self.assertEqual([os.path.realpath(repository["repositoryPath"]) for repository in props["repositories"]], [os.path.realpath(self.primary)])
        self.assertNotIn("composer", props, "Only the composer placement gets the draft.")

        board = self.assert_success(self.call_cli("plugin", "render", "--plugin", "context-board", "--task", task["id"])[0])
        self.assertEqual(self.plugin_text(self.plugin_node(board["tree"], "plugin-task")), "no task", "The board's sidebar is standalone.")
        self.assertEqual(self.plugin_text(self.plugin_node(board["tree"], "plugin-draft")), "no composer")
        counted = self.assert_success(self.call_cli("plugin", "render", "--plugin", "context-board", "--event", "plugin-count:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(counted["tree"], "plugin-status")), "tasks: 1", "A board plugin reads the real board.")

        renamed = self.assert_success(self.call_cli("plugin", "render", "--plugin", "context-composer", "--task", task["id"], "--event", "plugin-rename:onPress")[0])
        self.assertEqual(renamed["errors"], [])
        self.assertEqual(self.plugin_text(self.plugin_node(renamed["tree"], "plugin-status")), "renamed: Renamed by plugin")
        self.assertEqual([(call["kind"], call["name"], call["ok"]) for call in renamed["hostCalls"]], [("bridge", "task.rename", True)])
        self.assertEqual(renamed["hostCalls"][0]["arguments"], {"taskID": task["id"], "title": "Renamed by plugin"})
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["title"], "Renamed by plugin",
                         "A fresh CLI process sees the plugin's rename.")

        missing = self.assert_success(self.call_cli("plugin", "render", "--plugin", "context-composer", "--task", task["id"], "--event", "plugin-missing:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(missing["tree"], "plugin-status")), "error: not_found")
        self.assertEqual(missing["hostCalls"][0]["error"]["code"], "not_found")
        self.assertFalse(missing["hostCalls"][0]["ok"])

        upper = self.assert_success(self.call_cli("plugin", "render", "--plugin", "context-composer", "--task", task["id"], "--props", composer, "--event", "plugin-upper:onPress")[0])
        self.assertEqual(upper["hostCalls"], [{"kind": "ui", "name": "composer.replaceSelection", "arguments": {"text": "LOUD"}, "ok": True, "result": None}])

        def ui_call(plugin_id, event, *options):
            rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", plugin_id, *options, "--event", f"{event}:onPress")[0])
            self.assertEqual(rendered["errors"], [])
            return rendered
        recorded = {
            "plugin-set-draft": ("composer.setDraft", {"text": "fresh draft"}, "setDraft: ok"),
            "plugin-insert": ("composer.insertText", {"text": "!"}, "insert: ok"),
            "plugin-focus": ("composer.focus", {}, "focus: ok"),
        }
        for event, (name, arguments, status) in recorded.items():
            rendered = ui_call("context-composer", event, "--task", task["id"])
            self.assertEqual(rendered["hostCalls"], [{"kind": "ui", "name": name, "arguments": arguments, "ok": True, "result": None}])
            self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "plugin-status")), status)
        closed = ui_call("context-toolbar", "plugin-close", "--task", task["id"])
        self.assertEqual(closed["hostCalls"], [{"kind": "ui", "name": "close", "arguments": {}, "ok": True, "result": None}])
        toolbar = self.assert_success(self.call_cli("plugin", "render", "--plugin", "context-toolbar", "--task", task["id"])[0])
        self.assertEqual(self.plugin_text(self.plugin_node(toolbar["tree"], "plugin-task")), "Renamed by plugin", "The toolbar placement gets the task.")
        self.assertEqual(self.plugin_text(self.plugin_node(toolbar["tree"], "plugin-draft")), "no composer")

        opened = ui_call("context-board", "plugin-open")
        self.assertEqual([(call["kind"], call["name"], call["ok"]) for call in opened["hostCalls"]], [("bridge", "task.list", True), ("ui", "openTask", True)])
        self.assertEqual(opened["hostCalls"][1]["arguments"], {"taskID": task["id"]})
        # The board's sidebar has no composer, and no plugin renders plugins: refused as the window refuses them.
        unavailable = ui_call("context-board", "plugin-focus")
        self.assertEqual(self.plugin_text(self.plugin_node(unavailable["tree"], "plugin-status")), "focus: unavailable")
        self.assertEqual(unavailable["hostCalls"][0]["error"]["code"], "unavailable")
        recursive = ui_call("context-board", "plugin-recursive")
        self.assertEqual(self.plugin_text(self.plugin_node(recursive["tree"], "plugin-status")), "render: invalid_argument")
        self.assertEqual([(call["name"], call["ok"]) for call in recursive["hostCalls"]], [("plugin.render", False)])

        self.assert_failure(self.call_cli("plugin", "render", "--plugin", "no-such-plugin", expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("plugin", "render", "--file", self.plugins_folder() / "props-dump" / "index.js", "--task", task["id"], expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "render", "--plugin", "props-dump", "--page", "Text", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_fetch_reaches_the_network | Plugins have a fetch(url, options) global that makes HTTP and HTTPS requests from every placement, answered by the same core in the window and in `plugin render`; the cases reach a local fixture server instead of the internet. A fetch on mount shows the server's greeting; a GET resolves with its status, a response header read case-insensitively and a JSON body; a POST sends its method, headers and text body, which the server receives; a 404 resolves with ok false and its text body; a redirect is followed and reported as redirected with the final URL, while a URL with no path is not; a refused connection rejects with network_error; and a non-http URL such as file:// rejects with invalid_argument without any request. `plugin render` records each fetch in hostCalls as net.fetch with its arguments and result, and `plugin refresh` keeps a plugin that fetches on mount valid. In the window a page plugin from the board's sidebar shows the fetched greeting and each button's result.
    def test_plugin_fetch_reaches_the_network(self):
        base, closed = self.start_plugin_fetch_server()
        source = f'var BASE = "{base}";\nvar CLOSED = "{closed}";\n' + self.PLUGIN_FETCH_SOURCE
        self.write_installed_plugin("fetcher", source, placement="mainSidebar", presentation="page")
        plugins = [plugin for plugin in self.assert_success(self.call_cli("plugin", "refresh")[0])["plugins"] if not plugin["builtIn"]]
        self.assertEqual([(plugin["id"], plugin["valid"], plugin["errors"]) for plugin in plugins], [("fetcher", True, [])],
                         "A plugin that fetches on mount stays valid.")

        def press(event):
            rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "fetcher", "--event", f"{event}:onPress")[0])
            self.assertEqual(rendered["errors"], [])
            self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "fetch-greeting")), "hello from the fixture",
                             "The fetch on mount settles before the first render is reported.")
            return rendered

        got = press("fetch-get")
        self.assertEqual(self.plugin_text(self.plugin_node(got["tree"], "fetch-status")), "200 playhouse hello from the fixture")
        self.assertEqual([(call["kind"], call["name"], call["ok"]) for call in got["hostCalls"]], [("net", "fetch", True)] * 2)
        call = got["hostCalls"][1]
        self.assertEqual(call["arguments"], {"url": f"{base}/greeting", "method": "GET", "headers": {}})
        self.assertEqual(call["result"]["status"], 200)
        self.assertEqual(call["result"]["url"], f"{base}/greeting")
        self.assertFalse(call["result"]["redirected"])
        self.assertEqual(call["result"]["headers"]["x-fixture"], "playhouse", "Response headers arrive lowercased.")
        self.assertEqual(json.loads(call["result"]["body"]), {"message": "hello from the fixture"})

        posted = press("fetch-post")
        self.assertEqual(self.plugin_text(self.plugin_node(posted["tree"], "fetch-status")), 'POST secret {"n":1}')
        self.assertEqual(posted["hostCalls"][1]["arguments"], {
            "url": f"{base}/echo", "method": "POST", "body": '{"n":1}',
            "headers": {"X-Token": "secret", "Content-Type": "application/json"},
        })
        with urllib.request.urlopen(f"{base}/requests", timeout=10) as response:
            received = json.loads(response.read())
        self.assertIn({"method": "POST", "path": "/echo", "token": "secret", "body": '{"n":1}'}, received,
                      "The request reached the server with its header and body.")

        missing = press("fetch-missing")
        self.assertEqual(self.plugin_text(self.plugin_node(missing["tree"], "fetch-status")), "404 false nothing here",
                         "An HTTP error status resolves; only ok is false.")
        self.assertTrue(missing["hostCalls"][1]["ok"])

        redirected = press("fetch-redirect")
        self.assertEqual(self.plugin_text(self.plugin_node(redirected["tree"], "fetch-status")), "true greeting 200")
        self.assertTrue(redirected["hostCalls"][1]["result"]["redirected"])
        self.assertEqual(redirected["hostCalls"][1]["result"]["url"], f"{base}/greeting", "The response reports the URL after the redirect.")
        bare = press("fetch-bare")
        self.assertEqual(self.plugin_text(self.plugin_node(bare["tree"], "fetch-status")), "false 404",
                         "A URL the loader normalizes (a trailing slash) is not reported as redirected.")

        refused = press("fetch-refused")
        self.assertEqual(self.plugin_text(self.plugin_node(refused["tree"], "fetch-status")), "error: network_error")
        self.assertFalse(refused["hostCalls"][1]["ok"])
        self.assertEqual(refused["hostCalls"][1]["error"]["code"], "network_error")

        with urllib.request.urlopen(f"{base}/requests", timeout=10) as response:
            before = len(json.loads(response.read()))
        local = press("fetch-file")
        self.assertEqual(self.plugin_text(self.plugin_node(local["tree"], "fetch-status")), "error: invalid_argument")
        self.assertEqual(local["hostCalls"][1]["error"]["code"], "invalid_argument")
        with urllib.request.urlopen(f"{base}/requests", timeout=10) as response:
            self.assertEqual(len(json.loads(response.read())), before + 1, "Only the mount's greeting reached the server; file:// made no request.")
    # case-contract: test_debug_highlight_native_atoms_outlines_atoms | Debug ▸ Highlight Native Atoms outlines every atom view without moving it, so UI built from plugin atoms reads apart from plain SwiftUI. `plugin render` reports the container atoms (Stack, Panel, Card, Scroll, Disclosure, Overlay, Popover, Modal, Page, SidePanel), every one of them a known atom, and every other atom is a leaf. With the item off no atom carries an outline; turned on, the board's task card is outlined live, its Card as a container and its Text as a leaf, at the same frame as with it off, and the Plugin Catalog outlines each atom type it renders, including Spacer, Card and PillPicker, as a container or a leaf to match, the Card and the PillPicker keep the same frames as with it off, and hovering a Text atom shows a label naming its type that goes away when the pointer leaves. The setting persists: after a relaunch the reopened catalog is still outlined, and turning the item off removes every outline.
    def test_debug_highlight_native_atoms_outlines_atoms(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "Card")[0])
        self.assertEqual(rendered["errors"], [])
        containers = rendered["containerAtoms"]
        self.assertEqual(containers, [atom for atom in rendered["atoms"] if atom in containers], "Every container is a known atom.")
        self.assertEqual(set(containers), {"Stack", "Panel", "Card", "Scroll", "Disclosure", "Overlay", "Popover", "Modal", "Page", "SidePanel"},
                         "Only the atoms that lay out a composite's structure are containers.")
        leaves = [atom for atom in rendered["atoms"] if atom not in containers]
        self.assertEqual(leaves, ["Text", "Icon", "Label", "Button", "Link", "Spinner", "Spacer", "PillPicker", "Meter", "Divider", "ChoiceBar", "Toggle", "TextField", "Segmented", "Menu", "PressArea", "Editor", "StepSlider"],
                         "Every other atom, including a Button or Link that holds children, is a leaf.")
# case-contract: test_schedule_one_time_task_fires_when_due | A task whose conversation hasn't started is scheduled once (the composer's schedule hint, or schedule set --once); scheduling saves the prompt as the schedule's own payload without starting a turn, keeps the task in Backlog with a clock badge, and lists it in schedule list. A task with its own title keeps it, while an untitled task scheduled once (from the composer or schedule set) shows Generating title… and is then named from its prompt by the provider's title turn, as a first send would, without starting a conversation turn. Removing the schedule in the hint before Send turns the clock button off and returns Send to sending. A time in the past or a blank prompt is rejected with invalid_argument. A tick before the time does nothing; a tick 30 minutes after it, inside the one-hour grace period, sends the scheduled prompt to the provider, clears the schedule, and the task follows the ordinary board lifecycle. A second tick doesn't run it again. An existing conversation still shows scheduling, offers one-time messages only, preserves its lifecycle state, and sends the due message to that same task and conversation, preserving its Claude session or Codex thread identifier. The app bundle carries the scheduler LaunchAgent (<bundle-id>.scheduler.plist running playhouse-cli schedule tick every 60 seconds), and a plain tick on the real clock fires a schedule that has come due.
    def test_schedule_one_time_task_fires_when_due(self):
        environment = self.install_claude_fixture("claude-fixture-schedule-once")
        executable = environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]
        task_id = self.create_task("Scheduled once", provider="claude")["id"]
        now = datetime.datetime.now(datetime.timezone.utc)
        fire_at = (now + datetime.timedelta(hours=2)).replace(microsecond=0)

        past, _ = self.call_cli("schedule", "set", task_id, "--prompt", "Tell me a story.", "--once", self.schedule_iso(now - datetime.timedelta(minutes=5)), expected_status=2)
        self.assert_failure(past, "invalid_argument")
        blank, _ = self.call_cli("schedule", "set", task_id, "--prompt", "  ", "--once", self.schedule_iso(fire_at), expected_status=2)
        self.assert_failure(blank, "invalid_argument")
        self.assertIsNone(self.assert_success(self.call_cli("task", "get", task_id)[0]).get("schedule"), "A rejected schedule saves nothing.")

        scheduled = self.assert_success(self.call_cli(
            "schedule", "set", task_id, "--prompt", "Tell me a story.", "--once", self.schedule_iso(fire_at)
        )[0])
        self.assertEqual(scheduled["schedule"]["kind"], "once")
        self.assertEqual(scheduled["schedule"]["scheduledAt"], self.schedule_iso(fire_at))
        self.assertEqual(scheduled["schedule"]["prompt"], "Tell me a story.")
        self.assertEqual(scheduled["status"], "Backlog")
        fresh = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(fresh["schedule"]["scheduledAt"], self.schedule_iso(fire_at), "The schedule persists across fresh reads.")
        self.assertIn(task_id, [task["id"] for task in self.assert_success(self.call_cli("task", "list")[0])["tasks"]], "A one-time schedule stays on the board.")
        self.assertEqual([task["id"] for task in self.assert_success(self.call_cli("schedule", "list")[0])["tasks"]], [task_id])
        self.assertEqual(self.fixture_user_prompts(executable), [], "Scheduling starts no turn.")
        self.assertEqual(fresh["title"], "Scheduled once", "Scheduling keeps a task's own title.")

        untitled_id = self.create_task("Untitled task", provider="claude")["id"]
        reserved = self.assert_success(self.call_cli(
            "schedule", "set", untitled_id, "--prompt", "Summarize the release notes.", "--once", self.schedule_iso(fire_at),
            extra_environment=environment
        )[0])
        self.assertEqual(reserved["title"], "Generating title…", "Scheduling an untitled task reserves its title while it is named.")
        def settled_title():
            task = self.assert_success(self.call_cli("task", "get", untitled_id)[0])
            return task if task["title"] not in ("Untitled task", "Generating title…") else None
        named = self.wait_for(settled_title, "The scheduled task should get its generated title.")
        self.assertEqual(named["title"], "Generated Claude title", "A one-time scheduled task is named from its prompt as a first send would.")
        self.assertEqual(named["schedule"]["prompt"], "Summarize the release notes.")
        self.assertEqual(named["status"], "Backlog")
        self.assertEqual([prompt for prompt in self.fixture_user_prompts(executable) if not prompt.startswith("Write a concise task title")], [],
                         "Naming the task starts no conversation turn.")
        title_prompts = [prompt for prompt in self.fixture_user_prompts(executable) if prompt.startswith("Write a concise task title")]
        self.assertEqual(len(title_prompts), 1, "The task is named by exactly one title turn.")
        self.assertTrue(title_prompts[0].rstrip().endswith("Summarize the release notes."), "The title is generated from the scheduled prompt.")
        self.assertNotIn("Fixture task description.", title_prompts[0], "The title isn't generated from the task's description.")
        self.assert_success(self.call_cli("schedule", "clear", untitled_id)[0])

        early = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(fire_at - datetime.timedelta(minutes=10)), extra_environment=environment
        )[0])
        self.assertEqual((early["fired"], early["dropped"]), ([], []), "Nothing runs before its time.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["status"], "Backlog")

        due = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(fire_at + datetime.timedelta(minutes=30)), extra_environment=environment
        )[0])
        self.assertEqual([run["taskID"] for run in due["fired"]], [task_id], "A run 30 minutes late is inside the grace period.")
        self.assertEqual(due["dropped"], [])
        finished = self.wait_for_task_status(task_id, {"Review"})
        self.assertIsNone(finished.get("schedule"), "Firing clears the schedule.")
        self.assertIn("Tell me a story.", self.fixture_user_prompts(executable), "The scheduled prompt reaches the provider.")
        original_session_id = finished["claudeSessionID"]

        again = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(fire_at + datetime.timedelta(minutes=40)), extra_environment=environment
        )[0])
        self.assertEqual((again["fired"], again["dropped"]), ([], []), "A run happens once.")
        follow_up_at = fire_at + datetime.timedelta(days=1)
        follow_up = self.assert_success(self.call_cli(
            "schedule", "set", task_id, "--prompt", "Send a scheduled follow-up.", "--once", self.schedule_iso(follow_up_at)
        )[0])
        self.assertEqual(follow_up["status"], "Review", "Scheduling a follow-up keeps the existing conversation's lifecycle state.")
        self.assertEqual(follow_up["schedule"]["prompt"], "Send a scheduled follow-up.")
        recurring_follow_up, _ = self.call_cli(
            "schedule", "set", task_id, "--prompt", "Repeat this", "--repeat", "daily", "--title", "Repeated follow-up", expected_status=1
        )
        self.assert_failure(recurring_follow_up, "invalid_transition")
        follow_up_run = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(follow_up_at + datetime.timedelta(minutes=10)), extra_environment=environment
        )[0])
        self.assertEqual([run["taskID"] for run in follow_up_run["fired"]], [task_id], "The one-time message runs in the existing task.")
        self.wait_for(
            lambda: "Send a scheduled follow-up." in self.fixture_user_prompts(executable),
            "The scheduled follow-up should reach the existing conversation.",
        )
        after_follow_up = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(after_follow_up["claudeSessionID"], original_session_id, "The follow-up stays in the original Claude session.")

        contents = Path(self.cli).resolve().parent.parent
        bundle_identifier = plistlib.loads((contents / "Info.plist").read_bytes())["CFBundleIdentifier"]
        agent = plistlib.loads((contents / "Library" / "LaunchAgents" / f"{bundle_identifier}.scheduler.plist").read_bytes())
        self.assertEqual(agent["Label"], f"{bundle_identifier}.scheduler")
        self.assertEqual(agent["BundleProgram"], "Contents/MacOS/playhouse-cli")
        self.assertEqual(agent["ProgramArguments"], ["playhouse-cli", "schedule", "tick"])
        self.assertEqual(agent["StartInterval"], 60, "The agent ticks every minute while the app is closed.")

        soon_id = self.create_task("Due on the real clock", provider="claude")["id"]
        soon = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0) + datetime.timedelta(seconds=3)
        self.assert_success(self.call_cli("schedule", "set", soon_id, "--prompt", "Tell me a story.", "--once", self.schedule_iso(soon))[0])
        time.sleep(max(0, (soon - datetime.datetime.now(datetime.timezone.utc)).total_seconds()) + 0.5)
        real = self.assert_success(self.call_cli("schedule", "tick", extra_environment=environment)[0])
        self.assertEqual([run["taskID"] for run in real["fired"]], [soon_id], "A plain tick uses the real clock.")
        self.wait_for_task_status(soon_id, {"Review"})
    # case-contract: test_schedule_missed_beyond_grace_is_blocked | A scheduled run more than one hour late is not started. A one-time task lands in Blocked with a 'Missed scheduled run' message and its prompt kept as an unsent draft, and sending that draft starts it. A recurring schedule ticked a week late creates exactly one Blocked run task linked to its schedule, skips the older missed occurrences, and moves its next run into the future. A due run whose provider can't start lands in Blocked saying the scheduled run couldn't start, with its prompt kept as the draft.
    def test_schedule_missed_beyond_grace_is_blocked(self):
        environment = self.install_claude_fixture("claude-fixture-schedule-missed")
        executable = environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]
        task_id = self.create_task("Missed once", provider="claude")["id"]
        fire_at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).replace(microsecond=0)
        self.assert_success(self.call_cli("schedule", "set", task_id, "--prompt", "Tell me a story.", "--once", self.schedule_iso(fire_at))[0])
        late = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(fire_at + datetime.timedelta(hours=2)), extra_environment=environment
        )[0])
        self.assertEqual(late["fired"], [])
        self.assertEqual([run["taskID"] for run in late["dropped"]], [task_id])
        blocked = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(blocked["status"], "Blocked")
        self.assertTrue(blocked["statusMessage"].startswith("Missed scheduled run"), blocked["statusMessage"])
        self.assertEqual(blocked["savedPrompt"], "Tell me a story.")
        self.assertTrue(blocked["hasUnsentDraft"], "The missed prompt waits as the task's draft.")
        self.assertIsNone(blocked.get("schedule"))
        self.assertEqual(self.fixture_user_prompts(executable), [], "A missed run starts no turn.")
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Tell me a story.", extra_environment=environment)[0])
        self.assertEqual(self.wait_for_task_status(task_id, {"Review"})["status"], "Review", "Sending the draft runs the task.")

        template_id = self.create_task("Weekly template", provider="claude")["id"]
        template = self.assert_success(self.call_cli(
            "schedule", "set", template_id, "--prompt", "Tell me a story.", "--repeat", "weekly", "--weekday", "mon", "--time", "09:00", "--title", "Weekly report"
        )[0])
        next_run = self.parse_schedule_iso(template["schedule"]["scheduledAt"])
        week_late = next_run + datetime.timedelta(days=7, hours=2)
        missed = self.assert_success(self.call_cli("schedule", "tick", "--now", self.schedule_iso(week_late), extra_environment=environment)[0])
        self.assertEqual(missed["fired"], [])
        self.assertEqual(len(missed["dropped"]), 1, "Missed occurrences collapse into one run.")
        run_id = missed["dropped"][0]["taskID"]
        runs = [task for task in self.assert_success(self.call_cli("task", "list")[0])["tasks"] if task.get("scheduleSourceTaskID") == template_id]
        self.assertEqual([task["id"] for task in runs], [run_id])
        self.assertEqual(runs[0]["status"], "Blocked")
        self.assertEqual(runs[0]["title"], "Weekly report")
        missed_run = self.assert_success(self.call_cli("task", "get", run_id)[0])
        self.assertEqual(missed_run["savedPrompt"], "Tell me a story.", "The missed run keeps the prompt as its draft.")
        self.assertTrue(missed_run["hasUnsentDraft"])
        refreshed = self.assert_success(self.call_cli("task", "get", template_id)[0])
        self.assertGreater(self.parse_schedule_iso(refreshed["schedule"]["scheduledAt"]), week_late, "The next run moves into the future.")

        failing_id = self.create_task("Provider missing", provider="claude")["id"]
        failing_at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).replace(microsecond=0)
        self.assert_success(self.call_cli("schedule", "set", failing_id, "--prompt", "Tell me a story.", "--once", self.schedule_iso(failing_at))[0])
        unstarted = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(failing_at + datetime.timedelta(minutes=5)),
            extra_environment={"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": "none"}
        )[0])
        self.assertEqual([run["taskID"] for run in unstarted["fired"]], [failing_id])
        # The send's own failure handling can show Blocked first; the scheduler's message follows it.
        deadline = time.monotonic() + 30
        failed = self.wait_for_task_status(failing_id, {"Blocked"})
        while not (failed.get("statusMessage") or "").startswith("The scheduled run couldn't start") and time.monotonic() < deadline:
            time.sleep(0.25)
            failed = self.assert_success(self.call_cli("task", "get", failing_id)[0])
        self.assertEqual(failed["status"], "Blocked")
        self.assertTrue(failed["statusMessage"].startswith("The scheduled run couldn't start"), failed["statusMessage"])
        self.assertIn("Claude Code wasn't found", failed["statusMessage"], "The message names why the run couldn't start.")
        self.assertEqual(failed["savedPrompt"], "Tell me a story.")
        self.assertTrue(failed["hasUnsentDraft"], "The prompt waits as the draft for a retry.")
    # case-contract: test_schedule_recurring_template_hidden_and_spawns_runs | A recurring schedule needs a title, and a weekday when it repeats weekly; once confirmed, its template is absent from the board and task list but listed by schedule list and on the Scheduled Tasks page. A due tick creates a new board task with the schedule's title and context folders, linked by scheduleSourceTaskID, sends the prompt, records the run on the template and advances its next run by one day. A paused schedule doesn't fire, Run now starts a run immediately, and clearing the schedule turns the template into an ordinary Backlog task.
    def test_schedule_recurring_template_hidden_and_spawns_runs(self):
        environment = self.install_claude_fixture("claude-fixture-schedule-recurring")
        executable = environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]
        template_id = self.create_task("Recurring template", provider="claude")["id"]
        untitled, _ = self.call_cli("schedule", "set", template_id, "--prompt", "Tell me a story.", "--repeat", "daily", "--time", "09:00", "--title", " ", expected_status=2)
        self.assert_failure(untitled, "invalid_argument")
        no_day, _ = self.call_cli("schedule", "set", template_id, "--prompt", "Tell me a story.", "--repeat", "weekly", "--title", "Standup", expected_status=2)
        self.assert_failure(no_day, "invalid_argument")

        template = self.assert_success(self.call_cli(
            "schedule", "set", template_id, "--prompt", "Tell me a story.", "--repeat", "daily", "--time", "09:00", "--title", "Daily standup"
        )[0])
        self.assertEqual(template["title"], "Daily standup")
        self.assertEqual(template["schedule"]["kind"], "recurring")
        self.assertEqual(template["schedule"]["summary"], "Every day at 09:00")
        self.assertNotIn(template_id, [task["id"] for task in self.assert_success(self.call_cli("task", "list")[0])["tasks"]], "A recurring template isn't a board task.")
        self.assertEqual([task["id"] for task in self.assert_success(self.call_cli("schedule", "list")[0])["tasks"]], [template_id])

        first_run_at = self.parse_schedule_iso(template["schedule"]["scheduledAt"])
        fired = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(first_run_at + datetime.timedelta(minutes=10)), extra_environment=environment
        )[0])
        self.assertEqual(len(fired["fired"]), 1)
        run_id = fired["fired"][0]["taskID"]
        self.assertNotEqual(run_id, template_id, "Each run is a new task.")
        run = self.wait_for_task_status(run_id, {"Review"})
        self.assertEqual(run["title"], "Daily standup")
        self.assertEqual(run["scheduleSourceTaskID"], template_id)
        self.assertEqual(run["contextFolders"], template["contextFolders"], "A run takes the schedule's context folders.")
        self.assertTrue(run["contextFolders"])
        self.assertIsNone(run.get("schedule"))
        self.assertIn("Tell me a story.", self.fixture_user_prompts(executable))
        self.assertIn(run_id, [task["id"] for task in self.assert_success(self.call_cli("task", "list")[0])["tasks"]], "A run is followed on the board.")
        after = self.assert_success(self.call_cli("task", "get", template_id)[0])
        self.assertEqual(after["schedule"]["lastRunTaskID"], run_id)
        next_run_at = self.parse_schedule_iso(after["schedule"]["scheduledAt"])
        self.assertAlmostEqual((next_run_at - first_run_at).total_seconds(), 86400, delta=3600, msg="A daily schedule advances by one day.")

        paused = self.assert_success(self.call_cli("schedule", "pause", template_id)[0])
        self.assertTrue(paused["schedule"]["paused"])
        quiet = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(next_run_at + datetime.timedelta(minutes=10)), extra_environment=environment
        )[0])
        self.assertEqual((quiet["fired"], quiet["dropped"]), ([], []), "A paused schedule doesn't fire.")
        resumed = self.assert_success(self.call_cli("schedule", "resume", template_id)[0])
        self.assertFalse(resumed["schedule"]["paused"])

        now_run = self.assert_success(self.call_cli("schedule", "run-now", template_id, extra_environment=environment)[0])
        self.assertFalse(now_run["dropped"])
        self.assertNotIn(now_run["taskID"], {run_id, template_id})
        self.wait_for_task_status(now_run["taskID"], {"Review"})

        cleared = self.assert_success(self.call_cli("schedule", "clear", template_id)[0])
        self.assertIsNone(cleared.get("schedule"))
        self.assertIn(template_id, [task["id"] for task in self.assert_success(self.call_cli("task", "list")[0])["tasks"]], "Clearing the schedule puts the task on the board.")
        self.assertEqual(self.assert_success(self.call_cli("schedule", "list")[0])["tasks"], [])
    # case-contract: test_scheduled_task_edit_and_page_management | The Scheduled Tasks sidebar button opens the Scheduled Tasks page, whose New Task (header, or the button on the empty page) opens a task conversation with the schedule hint already open on Recurring. Opening a scheduled task shows its confirmed prompt with the schedule button on and Send in schedule mode, and its hint shows the saved repeat, day and time; changing its title and repeat in the hint and confirming with Send persists across fresh CLI reads, keeps the time, and starts no turn. Deleting a schedule removes it from schedule list and from the page. Sending a one-time scheduled task by hand ends its schedule, so a later tick sends nothing more; a recurring template rejects a send with invalid_transition; and clearing a schedule keeps its prompt as the task's draft.
    def test_scheduled_task_edit_and_page_management(self):
        environment = self.install_claude_fixture("claude-fixture-schedule-edit")
        executable = environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]
        task_id = self.create_task("Edited schedule", provider="claude")["id"]
        self.assert_success(self.call_cli(
            "schedule", "set", task_id, "--prompt", "Summarize the week.", "--repeat", "weekdays", "--time", "08:30", "--title", "Morning summary"
        )[0])
        edited = self.assert_success(self.call_cli(
            "schedule", "set", task_id, "--prompt", "Summarize the week in detail.", "--repeat", "weekly", "--weekday", "fri", "--time", "17:15", "--title", "Friday summary"
        )[0])
        self.assertEqual(edited["title"], "Friday summary")
        fresh = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(fresh["title"], "Friday summary")
        self.assertEqual(fresh["schedule"]["recurrence"], {"preset": "weekly", "hour": 17, "minute": 15, "weekday": 6})
        self.assertEqual(fresh["schedule"]["prompt"], "Summarize the week in detail.")
        self.assertEqual(fresh["savedPrompt"], "Summarize the week in detail.", "The composer reopens on the confirmed prompt.")
        self.assertTrue(fresh["hasUnsentDraft"], "The confirmed prompt is the composer's draft.")
        self.assertIsNone(fresh.get("claudeSessionID"))
        self.assertIsNone(fresh.get("codexThreadID"), "Editing a schedule starts no turn.")
        self.assertEqual(self.parse_schedule_iso(fresh["schedule"]["scheduledAt"]).astimezone().weekday(), 4, "The next run falls on a Friday.")
        rejected, _ = self.call_cli("conversation", "send", task_id, "--message", "Run the template.", expected_status=1, extra_environment=environment)
        self.assert_failure(rejected, "invalid_transition")
        self.assertEqual(self.fixture_user_prompts(executable), [], "A recurring template never runs itself.")
        cleared = self.assert_success(self.call_cli("schedule", "clear", task_id)[0])
        self.assertEqual(cleared["savedPrompt"], "Summarize the week in detail.", "Clearing a schedule keeps its prompt as the draft.")
        self.assertTrue(cleared["hasUnsentDraft"])
        self.assert_success(self.call_cli("schedule", "set", task_id, "--prompt", "Summarize the week.", "--repeat", "daily", "--title", "Friday summary")[0])
        self.assert_success(self.call_cli("task", "delete", task_id)[0])
        self.assertEqual(self.assert_success(self.call_cli("schedule", "list")[0])["tasks"], [])

        once_id = self.create_task("Sent by hand", provider="claude")["id"]
        fire_at = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).replace(microsecond=0)
        self.assert_success(self.call_cli("schedule", "set", once_id, "--prompt", "Tell me a story.", "--once", self.schedule_iso(fire_at))[0])
        self.assert_success(self.call_cli("conversation", "send", once_id, "--message", "Tell me a story.", extra_environment=environment)[0])
        self.assertIsNone(self.wait_for_task_status(once_id, {"Review"}).get("schedule"), "Sending by hand ends a one-time schedule.")
        sent = len(self.fixture_user_prompts(executable))
        later = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(fire_at + datetime.timedelta(minutes=5)), extra_environment=environment
        )[0])
        self.assertEqual((later["fired"], later["dropped"]), ([], []), "A started task's schedule sends nothing more.")
        self.assertEqual(len(self.fixture_user_prompts(executable)), sent)
    # case-contract: test_conversation_history_defers_earlier_images | A reader that asks history to defer images (--defer-images, as the app does) gets image data only for the newest turn the user started: earlier messages with images come back marked imagesDeferred with no image data, on the newest page, on an earlier --before page, where every image waits, and in the history a send returns, while plain history stays complete and never carries the mark, and the mark is never stored. conversation images returns the exact stored images of the named messages and nothing for a message without images; in a Codex conversation, whose user images live in the provider thread, an earlier image is deferred the same way and read back from the thread. Naming no message fails with invalid_argument and an unknown task fails with not_found. Reopening the conversation in the visible UI reads no image data until the reader scrolls up: each earlier image then loads when its message comes into view and is shown, and a turn sent afterwards from the composer keeps the loaded images without reading them again.
    def test_conversation_history_defers_earlier_images(self):
        claude = self.data_directory / "claude-fixture-deferred-images"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", claude)
        claude.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        codex = self.data_directory / "codex-fixture-image-serial-success"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", codex)
        codex.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        fixtures = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(claude), "PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(codex)}
        first_image = self.data_directory / "first-turn.png"
        first_image.write_bytes(bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000b49444154789c636000020000050001a5f645400000000049454e44ae426082"))
        second_image = self.data_directory / "second-turn.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", str(first_image), "--out", str(second_image)], check=True, capture_output=True)

        task_id = self.create_task("Claude deferred images", roots=[self.primary])["id"]
        self.assert_success(self.call_cli("conversation", "provider", task_id, "set", "claude")[0])
        key = task_id.upper()

        def reads(event):
            return [entry for entry in self.diagnostic_events() if entry.get("event") == event and entry.get("taskID") == key]

        def image_messages(history):
            return [message for message in history["messages"] if message["imageDataURLs"] or message.get("imagesDeferred")]

        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Say hello.", "--image", first_image, extra_environment=fixtures
        )[0])
        second = self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Long history turn 2.", "--image", second_image, "--defer-images",
            extra_environment=fixtures,
        )[0])
        full = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=fixtures)[0])
        first_message, second_message = image_messages(full)
        self.assertEqual((first_message["text"], second_message["text"]), ("Say hello.", "Long history turn 2."))
        self.assertTrue(first_message["imageDataURLs"][0].startswith("data:image/png;base64,"))
        self.assertTrue(second_message["imageDataURLs"][0].startswith("data:image/jpeg;base64,"))
        self.assertTrue(all("imagesDeferred" not in message for message in full["messages"]), "Plain history is complete and unmarked.")

        def assert_first_deferred(history, context):
            deferred, inline = image_messages(history)
            self.assertEqual((deferred["id"], deferred["imageDataURLs"], deferred.get("imagesDeferred")), (first_message["id"], [], True), context)
            self.assertEqual(inline, second_message, f"{context}: the newest turn keeps its image and is not marked.")

        assert_first_deferred(second, "The history a send returns defers the earlier turn's image")
        deferred = self.assert_success(self.call_cli("conversation", "history", task_id, "--defer-images", extra_environment=fixtures)[0])
        assert_first_deferred(deferred, "Complete history defers the earlier turn's image")
        self.assertEqual(
            [{**message, "imageDataURLs": [], "imagesDeferred": None} for message in deferred["messages"]],
            [{**message, "imageDataURLs": [], "imagesDeferred": None} for message in full["messages"]],
            "Deferring changes nothing but the image data.",
        )
        page = self.assert_success(self.call_cli(
            "conversation", "history", task_id, "--limit", "80", "--defer-images", extra_environment=fixtures
        )[0])
        assert_first_deferred(page, "The newest page defers the earlier turn's image")
        self.assertEqual(page["earlierMessageCount"], 0)
        newest_read = reads("conversation.history.read")[-1]
        self.assertEqual(
            (newest_read["source"], newest_read["deferredImageMessageCount"], newest_read["hydratedImageMessageCount"]), ("stored-page", "1", "1")
        )
        earlier = self.assert_success(self.call_cli(
            "conversation", "history", task_id, "--limit", "80", "--before", second_message["id"], "--defer-images", extra_environment=fixtures
        )[0])
        self.assertEqual([(message["id"], message["imageDataURLs"], message.get("imagesDeferred")) for message in image_messages(earlier)],
                         [(first_message["id"], [], True)], "An earlier page defers every image it holds.")
        earlier_read = reads("conversation.history.read")[-1]
        self.assertEqual((earlier_read["deferredImageMessageCount"], earlier_read["hydratedImageMessageCount"]), ("1", "0"))
        plain_read_count = len(reads("conversation.history.read"))
        self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "80", extra_environment=fixtures)[0])
        plain_read = reads("conversation.history.read")[plain_read_count]
        self.assertEqual((plain_read["deferredImageMessageCount"], plain_read["hydratedImageMessageCount"]), ("0", "2"))

        imageless = next(message for message in full["messages"] if message["role"] == "assistant")
        images = self.assert_success(self.call_cli(
            "conversation", "images", task_id, "--message", second_message["id"], "--message", imageless["id"], "--message", first_message["id"],
            extra_environment=fixtures,
        )[0])
        self.assertEqual({entry["id"]: entry["imageDataURLs"] for entry in images},
                         {first_message["id"]: first_message["imageDataURLs"], second_message["id"]: second_message["imageDataURLs"]},
                         "The named messages' exact images are returned, and nothing for a message without images.")
        self.assertEqual({entry["id"]: entry.get("turnID") for entry in images},
                         {first_message["id"]: first_message.get("turnID"), second_message["id"]: second_message.get("turnID")})
        images_read = reads("conversation.images.read")[-1]
        self.assertEqual((images_read["requestedMessageCount"], images_read["returnedMessageCount"], images_read["readProviderThread"]), ("3", "2", "false"))
        self.assertEqual(self.assert_success(self.call_cli(
            "conversation", "images", task_id, "--message", imageless["id"], "--message", "no-such-message", extra_environment=fixtures
        )[0]), [])
        self.assert_failure(self.call_cli("conversation", "images", task_id, expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli(
            "conversation", "images", str(uuid.uuid4()), "--message", first_message["id"], expected_status=3
        )[0], "not_found")

        third = self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Say hello.", "--defer-images", extra_environment=fixtures
        )[0])
        self.assertEqual([(message["id"], message["imageDataURLs"], message.get("imagesDeferred")) for message in image_messages(third)],
                         [(first_message["id"], [], True), (second_message["id"], [], True)],
                         "Once a later turn starts, both earlier images are deferred.")
        self.assertEqual(reads("conversation.history.read")[-1]["deferredImageMessageCount"], "2")
        with sqlite3.connect(self.conversation_database(), timeout=30) as connection:
            payloads = [row[0] for row in connection.execute("SELECT payload FROM conversation_messages WHERE task_id = ?", (key,))]
        self.assertTrue(payloads)
        self.assertFalse(any("imagesDeferred" in payload for payload in payloads), "The mark describes one read and is never stored.")
        resumed = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=fixtures)[0])
        self.assertEqual(image_messages(resumed), [first_message, second_message], "Plain history still carries every image after deferred reads.")

        # Codex keeps a user's images in its thread, so a deferred one is read back from there.
        codex_task = self.create_task("Codex deferred images", roots=[self.primary], provider="codex")["id"]
        self.assert_success(self.call_cli("conversation", "send", codex_task, "--image", first_image, extra_environment=fixtures)[0])
        self.assert_success(self.call_cli(
            "conversation", "send", codex_task, "--message", "Continue using the earlier image as context.", extra_environment=fixtures
        )[0])
        codex_full = self.assert_success(self.call_cli("conversation", "history", codex_task, extra_environment=fixtures)[0])
        codex_image_message, = image_messages(codex_full)
        self.assertEqual(codex_image_message["role"], "user")
        codex_key = codex_task.upper()

        def codex_image_read():
            images = self.assert_success(self.call_cli(
                "conversation", "images", codex_task, "--message", codex_image_message["id"], extra_environment=fixtures
            )[0])
            self.assertEqual([(entry["id"], entry["imageDataURLs"]) for entry in images],
                             [(codex_image_message["id"], codex_image_message["imageDataURLs"])])
            read = [entry for entry in self.diagnostic_events()
                    if entry.get("event") == "conversation.images.read" and entry.get("taskID") == codex_key][-1]
            return read["returnedMessageCount"], read["readProviderThread"]

        codex_deferred = self.assert_success(self.call_cli("conversation", "history", codex_task, "--defer-images", extra_environment=fixtures)[0])
        self.assertEqual([(message["id"], message["imageDataURLs"], message.get("imagesDeferred")) for message in image_messages(codex_deferred)],
                         [(codex_image_message["id"], [], True)], "A Codex thread's earlier image is deferred too.")
        self.assertEqual(codex_image_read(), ("1", "true"), "A Codex image is read from its thread.")

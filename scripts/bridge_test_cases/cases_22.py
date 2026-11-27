from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases22:
    # case-contract: test_plugin_add_mode_toggles_and_shows_placeholders | Add Plugin mode is off by default; the Plugins menu's Add Plugin Mode item and `plugin mode --on` turn it on, `plugin mode` reports the saved state to a fresh CLI process, `--off` turns it off, and any other option is refused as invalid_argument. While it is on, a bar across the top of the window explains the mode and its Close button turns it off; the board's sidebar shows a labeled Add here button below Scheduled Tasks and each task card's bottom row shows an Add here icon, which Close removes; an open task shows its sidebar expanded even when the sidebar was collapsed, with a labeled Add here button as the sidebar's first section, above Changes, an Add here icon before the sidebar's Skills and Terminal buttons and an Add here icon at the start of the composer's toolbar, which has no Skills button in a task; and the standalone chat shows only the composer's Add here icon. Turning the mode off from the CLI removes every placeholder live and returns the sidebar to its saved collapsed state.
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
    # case-contract: test_plugin_draft_versions_and_restore | Plugin edits persist as an isolated draft, saving publishes a new version and preserves history, discard restores the saved preview, and restoring an older version publishes it as a new revision. A draft with no unpublished changes can't be published: `plugin save` refuses it as invalid_argument and adds no version, and `plugin versions` reports `hasChanges`. In the editor, Publish is disabled and Discard changes is hidden until the draft differs from the published plugin, and both return to that state after publishing or discarding.
    def test_plugin_draft_versions_and_restore(self):
        source = self.PLUGIN_CONTEXT_SOURCE
        installed = self.write_installed_plugin("versioned", source, placement="mainSidebar")
        editor = self.assert_success(self.call_cli("plugin", "edit", "--id", "versioned")[0])["task"]
        draft = Path(editor["contextFolders"][0]) / "versioned"
        def versions():
            return self.assert_success(self.call_cli("plugin", "versions", "--id", "versioned")[0])
        # An unchanged draft has nothing to publish: saving it adds no version.
        self.assertEqual(versions(), {"versions": [], "hasChanges": False})
        manifest = (installed / "plugin.json").read_text()
        self.assert_failure(self.call_cli("plugin", "save", "--id", "versioned", expected_status=2)[0], "invalid_argument")
        self.assertEqual((installed / "plugin.json").read_text(), manifest, "The refused save leaves the installed plugin untouched.")
        self.assertFalse((self.plugins_folder() / ".versions" / "versioned").exists())
        changed = source.replace("props.plugin.placement", '"draft change"')
        (draft / "index.js").write_text(changed, encoding="utf-8")
        self.assertTrue(versions()["hasChanges"])
        self.assertEqual((installed / "index.js").read_text(), source)
        self.assertEqual(self.assert_success(self.call_cli("plugin", "edit", "--id", "versioned")[0])["task"]["id"], editor["id"])
        self.assertEqual((draft / "index.js").read_text(), changed)
        saved = self.assert_success(self.call_cli("plugin", "save", "--id", "versioned")[0])["plugin"]
        self.assertEqual(saved["version"], 1)
        self.assertEqual(json.loads((installed / "plugin.json").read_text())["version"], 1)
        self.assertEqual((installed / "index.js").read_text(), changed)
        self.assertEqual(versions(), {"versions": [0], "hasChanges": False}, "The published draft matches the plugin again.")
        self.assert_failure(self.call_cli("plugin", "save", "--id", "versioned", expected_status=2)[0], "invalid_argument")
        self.assertEqual(versions()["versions"], [0], "Saving again without changes adds no version.")
        self.assertEqual(json.loads((self.plugins_folder() / ".versions" / "versioned" / "0" / "plugin.json").read_text())["version"], 0)
        (draft / "index.js").write_text("invalid javascript !", encoding="utf-8")
        self.assertNotEqual(self.call_cli("plugin", "save", "--id", "versioned", expected_status=1)[0]["ok"], True)
        self.assertEqual((installed / "index.js").read_text(), changed)
        self.assert_success(self.call_cli("plugin", "discard", "--id", "versioned")[0])
        self.assertEqual((draft / "index.js").read_text(), changed)
        self.assertFalse(versions()["hasChanges"], "Discarding leaves no unpublished changes.")
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

    # case-contract: test_plugin_unsaved_discard_removes_plugin_and_menu_lists_it | A plugin that was never saved is discarded entirely: `plugin discard --id` on a new authoring session, before any prompt and after a turn wrote its draft, removes its draft folder and its editor conversation, so `plugin sessions` no longer lists it, `plugin edit --id` is not_found, and the plugins revision is bumped; `plugin delete --id` removes an unsaved plugin the same way. Discarding or deleting an unknown id is not_found, a saved plugin's discard still only resets its draft and keeps its editor, and when its draft can't be removed an unsaved plugin keeps its editor conversation for a retry. In the window, the Plugins menu lists each unsaved plugin as its own submenu labeled with its name, placement and (Unsaved), offering Edit and Delete, with no Edit item at the menu's root. Discard changes in an unsaved plugin's editor, shown even before it has a draft, asks to discard the plugin, then closes the editor and removes the plugin from the menu; Delete in its submenu, after confirming, removes another one the same way.
    def test_plugin_unsaved_discard_removes_plugin_and_menu_lists_it(self):
        def sessions():
            return [entry["authoredPluginID"] for entry in self.assert_success(self.call_cli("plugin", "sessions")[0])["sessions"]]
        def revision():
            return self.assert_success(self.call_cli("plugin", "list")[0])["revision"]
        drafts = self.plugins_folder() / ".drafts" / "plugins"

        # Discarded before the first prompt: nothing of it is kept.
        fresh = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Blamos", "--presentation", "popover", "--provider", "claude")[0])["task"]
        fresh_id = fresh["authoredPluginID"]
        self.assertIn(fresh_id, sessions())
        before = revision()
        discarded = self.assert_success(self.call_cli("plugin", "discard", "--id", fresh_id)[0])
        self.assertEqual(discarded["discarded"], fresh_id)
        self.assertTrue(discarded["deleted"], "An unsaved plugin has nothing to reset to, so discarding deletes it.")
        self.assertGreater(discarded["revision"], before, "The window reloads its Plugins menu.")
        self.assertNotIn(fresh_id, sessions())
        self.assertFalse((drafts / fresh_id).exists())
        self.assertFalse((self.plugins_folder() / fresh_id).exists())
        self.assert_failure(self.call_cli("plugin", "edit", "--id", fresh_id, expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("plugin", "discard", "--id", fresh_id, expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("plugin", "delete", "--id", "missing-plugin", expected_status=3)[0], "not_found")

        # Discarded after a turn wrote its draft: the draft and conversation go too.
        environment = self.install_claude_fixture("claude-fixture-plugin-preview")
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        sent = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Sent", "--presentation", "popover", "--provider", "claude")[0])["task"]
        sent_id = sent["authoredPluginID"]
        message = "plugin-preview-fixture " + json.dumps({"folder": str(drafts / sent_id), "text": "Sent preview"})
        self.assert_success(self.call_cli("conversation", "send", sent["id"], "--message", message, extra_environment=environment)[0])
        self.assertTrue((drafts / sent_id / "index.js").is_file(), "The turn wrote the plugin's draft.")
        self.assert_success(self.call_cli("plugin", "discard", "--id", sent_id)[0])
        self.assertNotIn(sent_id, sessions())
        self.assertFalse((drafts / sent_id).exists())
        self.assertFalse((self.plugins_folder() / sent_id).exists(), "Discarding never publishes the draft.")

        # A draft that can't be removed keeps the editor conversation for a retry.
        stuck = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "Stuck", "--presentation", "popover", "--provider", "claude")[0])["task"]
        stuck_id = stuck["authoredPluginID"]
        (drafts / stuck_id).mkdir(parents=True)
        (drafts / stuck_id / "index.js").write_text("draft", encoding="utf-8")
        drafts.chmod(0o500)
        try:
            self.assert_failure(self.call_cli("plugin", "discard", "--id", stuck_id, expected_status=1)[0], "operation_failed")
        finally:
            drafts.chmod(0o700)
        self.assertIn(stuck_id, sessions())
        self.assertEqual(self.assert_success(self.call_cli("plugin", "edit", "--id", stuck_id)[0])["task"]["id"], stuck["id"])
        # Deleting an unsaved plugin removes it the same way.
        self.assert_success(self.call_cli("plugin", "delete", "--id", stuck_id)[0])
        self.assertNotIn(stuck_id, sessions())
        self.assertFalse((drafts / stuck_id).exists())

        # A saved plugin's discard only resets its draft and keeps its editor.
        installed = self.write_installed_plugin("kept-editor", self.PLUGIN_CONTEXT_SOURCE, placement="mainSidebar")
        editor = self.assert_success(self.call_cli("plugin", "edit", "--id", "kept-editor")[0])["task"]
        (drafts / "kept-editor" / "index.js").write_text("changed", encoding="utf-8")
        reset = self.assert_success(self.call_cli("plugin", "discard", "--id", "kept-editor")[0])
        self.assertNotIn("deleted", reset)
        self.assertEqual((drafts / "kept-editor" / "index.js").read_text(), self.PLUGIN_CONTEXT_SOURCE)
        self.assertTrue(installed.is_dir())
        self.assertIn("kept-editor", sessions())
        self.assertEqual(self.assert_success(self.call_cli("plugin", "edit", "--id", "kept-editor")[0])["task"]["id"], editor["id"])

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
        self.assertEqual(renamed_session["pluginPlacement"], "conversationToolbar", "Its Plugins menu row shows the placement the agent moved it to.")
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

    # case-contract: test_plugin_authoring_codex_instructions_resume | A Codex plugin editor sends the user’s description with the chosen name, presentation, placement, generated plugin identity and permission to change any of those choices in thread instructions, points it at the CLI's plugin-editor help for its commands, automatically supplies the bundled plugin skill, and restores the same setup when the thread resumes on a fresh app-server. The composer starts empty and no turn starts until the user sends.
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
        self.assertIn(f"'{self.cli}' help --for plugin-editor", history["threadStartDeveloperInstructions"], "The editor finds its commands in its help.")
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
    # case-contract: test_plugin_edit_opens_editor_mid_turn | Edit on a plugin whose editor conversation has a turn running opens that conversation at once: while the editor's Claude turn has streamed its first answer and still holds its turn, the editor that sent it shows the turn running, `conversation runtime` lists the editor's task ID in activeTaskIDs (and drops it once the turn ends), and `plugin edit --id` returns within seconds with the same editor ID and the turn keeps running, and in the window the plugin submenu's Edit…, from the board and again with the editor already open, shows the editor with its preview and the running turn's pause button without closing it, the plugin submenu stays open under the pointer while the turn runs, and the output the turn streams next appears live in the reopened editor, as it does for `conversation watch` on the editor. Once the turn finishes its reply follows in the same conversation; `plugin sessions` lists the editor, `plugin discard --id` resets the saved plugin's draft and keeps its editor, and deleting the plugin removes its editor from `plugin sessions`. Opening an editor is Playhouse-owned and provider neutral, so Claude represents both providers.
    def test_plugin_edit_opens_editor_mid_turn(self):
        environment = self.install_claude_fixture("claude-fixture-plugin-editor-hold")
        executable = environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.write_installed_plugin("busy-editor", self.PLUGIN_CONTEXT_SOURCE, placement="mainSidebar")
        editor = self.assert_success(self.call_cli("plugin", "edit", "--id", "busy-editor")[0])["task"]
        self.assertEqual((editor["authoredPluginID"], editor["conversationProvider"]), ("busy-editor", "claude"))
        sent = {}
        sender = threading.Thread(target=lambda: sent.setdefault("turn", self.call_cli(
            "conversation", "send", editor["id"], "--message", "plugin-editor-hold-fixture", timeout=120,
            extra_environment=environment)), daemon=True)
        sender.start()
        self.wait_for(Path(executable + ".plugin-editor-turn-ready").is_file, "The editor turn streams and keeps running.")
        self.assertIn(editor["id"], self.assert_success(self.call_cli("conversation", "runtime")[0])["activeTaskIDs"],
                      "The runtime reports the editor's turn running by its task ID.")
        started = time.monotonic()
        reopened = self.assert_success(self.call_cli("plugin", "edit", "--id", "busy-editor", timeout=30)[0])["task"]
        elapsed = time.monotonic() - started
        self.assertEqual(reopened["id"], editor["id"], "Edit reopens the same editor conversation.")
        self.assertLess(elapsed, 10, "plugin edit does not wait for the editor's running turn.")
        self.assertTrue(sender.is_alive(), "The editor's turn is still running after plugin edit returned.")
        self.assertEqual(reopened["status"], "In Progress")
        # A window reopening the editor follows its running turn the way it follows a task's.
        watcher = self.start_cli("conversation", "watch", editor["id"])
        readable, _, _ = select.select([watcher.stdout], [], [], 20)
        self.assertTrue(readable, "The watcher subscribes to the editor's running turn.")
        self.assertEqual(json.loads(watcher.stdout.readline()).get("type"), "watching")
        Path(executable + ".plugin-editor-turn-continue").touch()
        self.wait_for(Path(executable + ".plugin-editor-turn-continued").is_file, "The held turn streams more after plugin edit.")
        self.assertTrue(sender.is_alive(), "The editor's turn keeps running while it streams.")
        Path(executable + ".plugin-editor-turn-release").touch()
        sender.join(timeout=60)
        self.assertFalse(sender.is_alive())
        self.assert_success(sent["turn"][0])
        self.assertNotIn(editor["id"], self.assert_success(self.call_cli("conversation", "runtime")[0])["activeTaskIDs"],
                         "The runtime drops the editor once its turn ends.")
        watched, watched_events = self.finish_cli(watcher, "conversation watch", timeout=30)
        # The standalone chat is followed through its history, which files turns under their pages.
        chat = self.assert_success(self.call_cli("chat", "open")[0])
        self.assert_failure(self.call_cli("conversation", "watch", chat["id"], expected_status=2)[0], "invalid_argument")
        self.assertTrue(self.assert_success(watched)["watched"])
        self.assertIn("Still building the busy plugin.", "".join(event["payload"].get("text") or "" for event in watched_events if event["type"] == "text_delta"),
                      "The watcher streams what the editor's turn writes after it subscribed.")
        streamed = "".join(event["payload"].get("text") or "" for event in sent["turn"][1] if event["type"] == "text_delta")
        self.assertIn("Working on the busy plugin. Still building the busy plugin.", streamed, "The turn streamed both parts of its answer.")
        texts, _ = self.history_texts(editor["id"], environment)
        self.assertEqual((texts.count("Working on the busy plugin. Still building the busy plugin."), texts.count("The busy plugin turn finished.")), (1, 1),
                         "The reply follows the streamed answer once each in the same conversation.")
        def sessions():
            return [entry["id"] for entry in self.assert_success(self.call_cli("plugin", "sessions")[0])["sessions"] if entry["authoredPluginID"] == "busy-editor"]
        self.assertEqual(sessions(), [editor["id"]], "plugin sessions lists the editor once.")
        draft_script = self.plugins_folder() / ".drafts" / "plugins" / "busy-editor" / "index.js"
        draft_script.write_text("Playhouse.render(h(Text, {}, 'Unsaved change'));", encoding="utf-8")
        self.assert_success(self.call_cli("plugin", "discard", "--id", "busy-editor")[0])
        self.assertEqual(draft_script.read_text(encoding="utf-8"), (self.plugins_folder() / "busy-editor" / "index.js").read_text(encoding="utf-8"),
                         "Discard resets the saved plugin's draft.")
        self.assertEqual(sessions(), [editor["id"]], "Discarding a saved plugin's draft keeps its editor.")
        self.assert_success(self.call_cli("plugin", "delete", "--id", "busy-editor")[0])
        self.assertEqual(sessions(), [], "Deleting the plugin removes its editor conversation.")
        self.assertFalse((self.plugins_folder() / "busy-editor").exists())

    # case-contract: test_plugin_editor_opens_long_conversation_with_loader | A plugin editor whose conversation is long opens at once and shows that it is loading until its history arrives: the editor's sixty settled turns, held in Playhouse's own store, are read as the newest page of 80 messages with the 40 before them counted, ending on the newest question and answer, and `plugin edit --id` returns the same editor. While the editor's operation lock is held, as a Save, Discard or starting turn holds it, that history read waits and returns the same page once the lock is released. In the window, the plugin submenu's Edit… opens the editor with its preview while that read waits, and its transcript shows Loading conversation… in place of the empty plugin prompt; once the lock is released the loader goes away and the newest question and answer show. Opening an editor and its loader are Playhouse-owned and provider neutral, so Claude represents both providers.
    def test_plugin_editor_opens_long_conversation_with_loader(self):
        environment = self.install_claude_fixture("claude-fixture-plugin-long-editor")
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.write_installed_plugin("long-editor", self.PLUGIN_CONTEXT_SOURCE, placement="mainSidebar")
        editor = self.assert_success(self.call_cli("plugin", "edit", "--id", "long-editor")[0])["task"]
        self.assert_success(self.call_cli("conversation", "send", editor["id"], "--message", "Start the long plugin.",
                                          extra_environment=environment)[0])
        # Earlier sessions' turns are already in Playhouse's own store; the provider holds none of them.
        self.seed_long_history(editor["id"])
        self.assertEqual(self.assert_success(self.call_cli("plugin", "edit", "--id", "long-editor")[0])["task"]["id"], editor["id"],
                         "Edit reopens the same editor conversation.")
        def assert_newest_page(page):
            texts = [message["text"] for message in page["messages"]]
            self.assertEqual((len(texts), page.get("earlierMessageCount")), (80, 40), "The editor reads only its newest page.")
            self.assertEqual(texts[-2:], ["Long history user 60.", "Long history assistant 60."])
        assert_newest_page(self.assert_success(self.call_cli("conversation", "history", editor["id"], "--limit", "80",
                                                             extra_environment=environment)[0]))
        # Opening the editor reads that page behind its operation lock, which a Save, Discard or
        # starting turn holds; the read waits for it rather than failing.
        barrier = TaskOperationLockBarrier(self.data_directory, editor["id"])
        try:
            read = self.start_cli("conversation", "history", editor["id"], "--limit", "80", extra_environment=environment)
            time.sleep(1.5)
            self.assertIsNone(read.poll(), "The history read waits while the editor's operation lock is held.")
        finally:
            barrier.release()
        waited, _ = self.finish_cli(read, "conversation history", timeout=30)
        assert_newest_page(self.assert_success(waited))

    # case-contract: test_plugin_enable_disable_and_builtins | `plugin list` reports the built-in Changes plugin first (builtIn, valid and enabled, at the conversation sidebar with the inline presentation), then the task card's built-in Pull request mode and Pull requests plugins (inline at the taskItem placement), the board sidebar's built-in Agents info (a section at the mainSidebarBottom placement) and its built-in Scheduled Tasks (a popover at the mainSidebar placement), and the composer's built-in Built-in Commands (headless at the composerActions placement, with its / commands), before the installed plugins. A built-in can't be deleted, edited or rendered headlessly (invalid_argument), and an installed folder with a built-in's id is invalid. An inline plugin is valid only at the conversation sidebar or on the task card. `plugin disable --id` and `plugin enable --id` work on built-in and installed plugins, bump the plugins revision and persist across fresh CLI reads. A `plugin refresh` with nothing changed still bumps the revision and lists identical plugins, and in the window it leaves an open plugin submenu open. A disabled plugin is listed with enabled false, is not run when plugins are refreshed, and `plugin render` refuses it as unavailable until it is enabled again. An unknown id is not_found, a malformed or missing one invalid_argument, and a deleted plugin installed again starts enabled with no saved state. An inline conversation sidebar plugin receives `workspace` (its revision and the open diff) and `sidebar` (whether it is on the rail) props, and its Playhouse.ui.refreshWorkspace and openDiff calls are recorded headlessly, while the board's sidebar refuses them as unavailable. In the window, the Plugins menu has a Built-in Plugins section whose Changes submenu offers Disable but no Edit or Delete, and which labels Built-in Commands Headless (slash commands only), its submenu also offering Disable but no Edit or Delete. Disabling Changes removes the task sidebar's Changes section and labels it Disabled, and enabling it brings the section back. An installed plugin's submenu offers Disable beside Edit and Delete, and disabling it removes its button until it is enabled again. An installed inline plugin renders in place in the task sidebar with no entry button: its refreshWorkspace raises the workspace revision, its openDiff opens the window's diff view for a real change and the open diff reaches its props, and on the hidden sidebar's rail it reads that it is on the rail. Each plugin keeps its own saved values: `plugin state --id` reads them and `plugin state --id --key --value <json>` stores one (null removes it) and bumps the plugins revision; `plugin list` reports each plugin's `state`, which an installed plugin gets as `props.state` and stores with Playhouse.setState (recorded headlessly), and the built-in Changes keeps its state the same way. An unknown id is not_found, and an empty key, a missing value or a value that is not JSON is invalid_argument without bumping the revision. A fresh daemon reads the disabled ids and saved states back from settings, and authoring an inline plugin outside the conversation sidebar or the task card is invalid_argument. In the window, the inline plugin's Playhouse.setState comes back as its props.state, and collapsing the Changes section saves its collapsed state as its plugin state. After a relaunch a disabled Changes stays hidden and labeled Disabled while the plugin keeps its saved state, and enabled again, Changes comes back collapsed. An open page plugin receives its newly saved state, and disabling a plugin closes its open surface.
    def test_plugin_enable_disable_and_builtins(self):
        def listed():
            return self.assert_success(self.call_cli("plugin", "list")[0])
        def by_id(response):
            return {plugin["id"]: plugin for plugin in response["plugins"]}

        initial = listed()
        changes = initial["plugins"][0]
        self.assertEqual((changes["id"], changes["name"], changes["placement"], changes["presentation"]), ("changes", "Changes", "conversationSidebar", "inline"))
        self.assertEqual((changes["builtIn"], changes["valid"], changes["enabled"], changes["errors"]), (True, True, True, []))
        self.assertEqual([plugin["id"] for plugin in initial["plugins"]], ["changes", "pull-request-mode", "pull-requests", "agents-info", "scheduled-tasks", "built-in-commands"], "Only the built-ins are listed before any plugin is installed.")
        # The task card's built-ins: the mode pill and the pull request controls.
        for card_plugin in initial["plugins"][1:3]:
            self.assertEqual((card_plugin["placement"], card_plugin["presentation"], card_plugin["builtIn"], card_plugin["valid"], card_plugin["enabled"]),
                             ("taskItem", "inline", True, True, True), card_plugin)
        # The board sidebar's built-in: Agents info, a section at its bottom.
        agents_info = initial["plugins"][3]
        self.assertEqual((agents_info["name"], agents_info["placement"], agents_info["presentation"], agents_info["builtIn"], agents_info["valid"], agents_info["enabled"]),
                         ("Agents info", "mainSidebarBottom", "section", True, True, True), agents_info)
        # The board sidebar's Scheduled Tasks popover.
        scheduled = initial["plugins"][4]
        self.assertEqual((scheduled["name"], scheduled["icon"], scheduled["placement"], scheduled["presentation"], scheduled["builtIn"], scheduled["valid"], scheduled["enabled"]),
                         ("Scheduled Tasks", "clock", "mainSidebar", "popover", True, True, True), scheduled)
        # The composer's `/` commands: a headless plugin, with commands and no surface.
        commands = initial["plugins"][5]
        self.assertEqual((commands["name"], commands["placement"], commands["presentation"], commands["builtIn"], commands["valid"], commands["enabled"]),
                         ("Built-in Commands", "composerActions", "headless", True, True, True), commands)
        self.assertEqual([command["name"] for command in commands["commands"]], ["mcp", "plan", "goal", "skill", "login", "plugin"])

        hello = 'Playhouse.render(h(Text, { testID: "hello" }, "Hello"));'
        self.write_installed_plugin("hello-board", hello, placement="mainSidebar", presentation="page")
        self.write_installed_plugin("workspace-probe", self.PLUGIN_WORKSPACE_SOURCE, placement="conversationSidebar", presentation="inline")
        self.write_installed_plugin("board-probe", self.PLUGIN_WORKSPACE_SOURCE, placement="mainSidebar", presentation="page")
        self.write_installed_plugin("inline-composer", hello, placement="composerActions", presentation="inline")
        self.write_installed_plugin("changes", hello, placement="conversationSidebar", presentation="inline")
        self.write_installed_plugin("card-badge", hello, placement="taskItem", presentation="inline")
        refreshed = self.assert_success(self.call_cli("plugin", "refresh")[0])
        self.assertEqual([plugin["id"] for plugin in refreshed["plugins"]],
                         ["changes", "pull-request-mode", "pull-requests", "agents-info", "scheduled-tasks", "built-in-commands", "board-probe", "card-badge", "changes", "hello-board", "inline-composer", "workspace-probe"],
                         "The built-ins come first, then the installed plugins by id.")
        self.assertTrue(all(plugin["builtIn"] for plugin in refreshed["plugins"][:6]))
        shadow = refreshed["plugins"][8]
        self.assertFalse(shadow["builtIn"])
        self.assertFalse(shadow["valid"])
        self.assertTrue(any("is a built-in plugin's id" in error for error in shadow["errors"]), shadow["errors"])
        plugins = {plugin["id"]: plugin for plugin in refreshed["plugins"][6:] if plugin is not shadow}
        self.assertTrue(plugins["workspace-probe"]["valid"], plugins["workspace-probe"]["errors"])
        self.assertTrue(plugins["card-badge"]["valid"], "An inline plugin is valid on the task card too.")
        self.assertFalse(plugins["inline-composer"]["valid"])
        self.assertTrue(any("only in the conversation sidebar" in error for error in plugins["inline-composer"]["errors"]), plugins["inline-composer"]["errors"])
        self.assertTrue(all(plugin["enabled"] and not plugin["builtIn"] for plugin in plugins.values()))
        (self.plugins_folder() / "changes" / "plugin.json").unlink()
        (self.plugins_folder() / "changes" / "index.js").unlink()
        (self.plugins_folder() / "changes").rmdir()
        # A refresh with nothing changed still bumps the revision, and lists the same plugins.
        before = self.assert_success(self.call_cli("plugin", "refresh")[0])
        unchanged = self.assert_success(self.call_cli("plugin", "refresh")[0])
        self.assertEqual(unchanged["revision"], before["revision"] + 1)
        self.assertEqual(unchanged["plugins"], before["plugins"], "An unchanged refresh lists identical plugins.")

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
        self.assertEqual(self.assert_success(self.call_cli("plugin", "state", "--id", "workspace-probe")[0]), {"pluginID": "workspace-probe", "state": {"clicks": 1}, "enabled": True})
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
        self.assertEqual([(plugin["id"], plugin["builtIn"]) for plugin in empty["plugins"]], [("changes", True), ("pull-request-mode", True), ("pull-requests", True), ("agents-info", True), ("scheduled-tasks", True), ("built-in-commands", True)], "Only the built-ins are listed at first.")
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
    # case-contract: test_plugin_surfaces_receive_context_and_host_access | An installed plugin receives its placement's context in Playhouse.props: the plugin and the appearance everywhere, the task with its repositories and context folders in the conversation placements, and the composer's draft and selected text in the composer placement, while the board's sidebar gets no task. `plugin render --plugin <id> --task <id>` renders it headlessly with that real context. Playhouse.bridge runs any bridge command but plugin render against the real store (a rename is seen by a fresh CLI process) and rejects a failing one with its code; Playhouse.ui close, openTask and the composer's setDraft, insertText, replaceSelection and focus are recorded headlessly; a composer call from the board's sidebar and a plugin render call are refused the same way in both hosts; and --task without --plugin or an unknown plugin is refused. In the window a page plugin from the board's sidebar covers the board, reads the real board, and its openTask opens that task without sending anything, keeping the page open behind it, so going back from the task returns to the page; a composer popover plugin opens anchored to its button showing the draft and the selected text, and its replaceSelection replaces the selected text in the composer; a sidebar plugin from the conversation sidebar slides in at the trailing edge showing the task's title and repository, inserts text after the selection, replaces the draft, renames the task, and closes with its close button; and a modal plugin beside the Terminal button opens as a sheet with the task's context and closes itself with Playhouse.ui.close. Every presentation starts with the app's standard modal header (the plugin's icon, its name and a close button) above the plugin's atoms, which bring no padding of their own yet sit inside the presentation's inset, as does the header: 24 points in a page or sheet, 20 in a sidebar, and 16 in a popover, whose header title is smaller than a sheet's.
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
        self.assertEqual(props["task"], {"id": task["id"], "title": "Plugin context task", "status": "Backlog", "provider": task["conversationProvider"], "isStandaloneChat": False,
                                         "scheduleSourceTaskID": None})
        self.assertEqual(props["contextFolders"], [])
        self.assertEqual(props["pastPullRequests"], [])
        self.assertEqual([os.path.realpath(repository["repositoryPath"]) for repository in props["repositories"]], [os.path.realpath(self.primary)])
        self.assertEqual([repository["pullRequest"] for repository in props["repositories"]], [None], "A task not started yet has no pull request.")
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
    # case-contract: test_plugin_image_atom_loads_caches_and_falls_back | An Image atom shows a picture its window loads natively from its url. An installed page plugin's circular 48-point Image of a PNG served over http from 127.0.0.1 draws the picture's red and blue halves clipped to a circle and is one accessibility element with its label, a 64 by 32 file:// Image draws the same PNG from the plugin's folder with its corners rounded, an unlabeled Image of the same URL is decorative (hidden from accessibility), and an Image whose URL answers with something that isn't a picture, or whose server refuses the connection, draws its placeholder symbol instead, with no plugin error. The window loads the served picture once: the copies mounted together share one request, and a second copy mounted by a re-render (the readout reads Copies: 2) and the page closed and opened again draw it with no further request to the server, which marks it no-store; the failed URL isn't asked for again at once either. The Plugin Catalog's Image page draws a data:image picture filled (covering its 64-point square, cropped), fitted (letterboxed inside it), clipped to a circle and with rounded corners, shows the failing URL's placeholder symbol, and keeps its unlabeled Image out of accessibility. `plugin render` reports the plugin's Image nodes and their props (url, size, width and height, circle, cornerRadius, contentMode, placeholder, label) without loading any picture, the added copy is one commit that creates one Image and changes the readout, and the catalog page renders without errors. An Image url that isn't an absolute https, http, file or data:image URL (ftp, a relative path, a data URL of text, an https URL with no host), a missing url, a mistyped size, circle or contentMode, a child, or an event is reported in errors with exit 1, naming the prop and what is wrong.
    def test_plugin_image_atom_loads_caches_and_falls_back(self):
        base, closed = self.start_plugin_fetch_server()
        folder = self.write_installed_plugin("avatars", None, placement="mainSidebar", presentation="page")
        picture = folder / "avatar.png"
        picture.write_bytes(base64.b64decode(self.IMAGE_ATOM_PNG))
        source = f'var BASE = "{base}";\nvar CLOSED = "{closed}";\nvar FILE = "{picture.as_uri()}";\n' + self.PLUGIN_IMAGE_SOURCE
        (folder / "index.js").write_text(source, encoding="utf-8")
        plugins = [plugin for plugin in self.assert_success(self.call_cli("plugin", "refresh")[0])["plugins"] if not plugin["builtIn"]]
        self.assertEqual([(plugin["id"], plugin["valid"], plugin["errors"]) for plugin in plugins], [("avatars", True, [])], "A plugin of Images is valid.")

        rendered = self.assert_success(self.call_cli("plugin", "render", "--plugin", "avatars", "--event", "image-add-copy:onPress")[0])
        self.assertEqual(rendered["errors"], [])
        self.assertEqual(rendered["hostCalls"], [], "Images are the window's to load; the plugin makes no host call for them.")
        first = self.plugin_node(rendered["tree"], "image-remote-1")
        self.assertEqual((first["type"], first.get("events", []), first.get("children", [])), ("Image", [], []))
        self.assertEqual(first["props"], {"url": f"{base}/avatar.png", "size": 48, "circle": True, "label": "Avatar 1", "testID": "image-remote-1"})
        self.assertEqual(self.plugin_node(rendered["tree"], "image-remote-2")["props"]["url"], f"{base}/avatar.png", "The added copy shows the same URL.")
        self.assertEqual(self.plugin_text(self.plugin_node(rendered["tree"], "image-copies")), "Copies: 2")
        added = rendered["commits"][-1]
        self.assertEqual((added["step"], added["ops"].count("create"), "text" in added["ops"]), ("image-add-copy:onPress", 1, True),
                         "Adding a copy creates one Image and changes the readout.")
        on_disk = self.plugin_node(rendered["tree"], "image-file")["props"]
        self.assertEqual((on_disk["url"], on_disk["width"], on_disk["height"], on_disk["cornerRadius"]), (picture.as_uri(), 64, 32, 8))
        broken = self.plugin_node(rendered["tree"], "image-broken")["props"]
        self.assertEqual((broken["url"], broken["placeholder"]), (f"{base}/not-an-image.png", "person.crop.circle"))
        self.assertEqual(self.plugin_node(rendered["tree"], "image-refused")["props"]["url"], f"{closed}/avatar.png")
        decorative = self.plugin_node(rendered["tree"], "image-decorative")["props"]
        self.assertEqual((decorative["url"], decorative["size"], "label" in decorative), (f"{base}/avatar.png", 24, False), "An Image without a label is decorative.")
        with urllib.request.urlopen(f"{base}/requests", timeout=10) as response:
            self.assertEqual(json.loads(response.read()), [], "Rendering and validating the plugin loaded no picture.")

        page = self.assert_success(self.call_cli("plugin", "render", "--page", "Image")[0])
        self.assertEqual(page["errors"], [])
        filled = self.plugin_node(page["tree"], "image-fill")["props"]
        self.assertTrue(filled["url"].startswith("data:image/png;base64,"), "The catalog page draws a data URL, so it needs no network.")
        self.assertEqual((filled["size"], "contentMode" in filled), (64, False), "fill is the default contentMode.")
        self.assertEqual(self.plugin_node(page["tree"], "image-fit")["props"]["contentMode"], "fit")
        self.assertTrue(self.plugin_node(page["tree"], "image-circle")["props"]["circle"])
        self.assertEqual(self.plugin_node(page["tree"], "image-rounded")["props"]["cornerRadius"], 12)
        self.assertEqual(self.plugin_node(page["tree"], "image-failed")["props"]["placeholder"], "person.crop.circle")
        self.assertNotIn("label", self.plugin_node(page["tree"], "image-decorative-catalog")["props"], "The page shows a decorative Image too.")

        for source, message in [
            ('Playhouse.render(h(Image, { url: "https://example.com/a.png", size: 48 }));', None),
            ('Playhouse.render(h(Image, { url: "http://localhost:8080/a.png", contentMode: "fit" }));', None),
            ('Playhouse.render(h(Image, { url: "file:///tmp/a.png" }));', None),
            ('Playhouse.render(h(Image, { url: "data:image/gif;base64,R0lGODlhAQABAAAAACw=" }));', None),
            ('Playhouse.render(h(Image, { url: "ftp://example.com/a.png" }));', '<Image> has an invalid prop: url: expected an absolute https, http, file or data:image URL, found "ftp://example.com/a.png"'),
            ('Playhouse.render(h(Image, { url: "avatar.png" }));', '<Image> has an invalid prop: url: expected an absolute https, http, file or data:image URL, found "avatar.png"'),
            ('Playhouse.render(h(Image, { url: "data:text/plain,hi" }));', "<Image> has an invalid prop: url: expected an absolute"),
            ('Playhouse.render(h(Image, { url: "https:///a.png" }));', "<Image> has an invalid prop: url: expected an absolute"),
            ('Playhouse.render(h(Image, { size: 48 }));', "<Image> has an invalid prop: url: missing"),
            ('Playhouse.render(h(Image, { url: "https://example.com/a.png", size: "big" }));', "<Image> has an invalid prop: size: expected a number, found a string"),
            ('Playhouse.render(h(Image, { url: "https://example.com/a.png", circle: "yes" }));', "<Image> has an invalid prop: circle: expected a boolean, found a string"),
            ('Playhouse.render(h(Image, { url: "https://example.com/a.png", contentMode: 1 }));', "<Image> has an invalid prop: contentMode: expected a string, found 1"),
            ('Playhouse.render(h(Image, { url: "https://example.com/a.png" }, h(Text, null, "x")));', "<Image> can't hold <Text>"),
            ('Playhouse.render(h(Image, { url: "https://example.com/a.png", onPress: function () {} }));', '<Image> has no event "onPress"'),
        ]:
            if message is None:
                accepted = self.assert_success(self.render_plugin(source))
                self.assertEqual(accepted["errors"], [], f"{source} is a URL an Image may load.")
                continue
            failed = self.render_plugin(source, expected_status=1)
            self.assertTrue(any(message in error for error in failed["result"]["errors"]), f"{source} reports {message}: {failed['result']['errors']}")
    # case-contract: test_debug_highlight_native_atoms_outlines_atoms | Debug ▸ Highlight Native Atoms outlines every atom view without moving it, so UI built from plugin atoms reads apart from plain SwiftUI. `plugin render` reports the container atoms (Stack, Panel, Card, Scroll, Disclosure, Overlay, Popover, Modal, Page, SidePanel), every one of them a known atom, and every other atom is a leaf. With the item off no atom carries an outline; turned on, the board's task card is outlined live, its Card as a container and its Text as a leaf, at the same frame as with it off, and the Plugin Catalog outlines each atom type it renders, including Spacer, Card and PillPicker, as a container or a leaf to match, the Card and the PillPicker keep the same frames as with it off, and hovering a Text atom shows a label naming its type that goes away when the pointer leaves. The setting persists: after a relaunch the reopened catalog is still outlined, and turning the item off removes every outline.
    def test_debug_highlight_native_atoms_outlines_atoms(self):
        rendered = self.assert_success(self.call_cli("plugin", "render", "--page", "Card")[0])
        self.assertEqual(rendered["errors"], [])
        containers = rendered["containerAtoms"]
        self.assertEqual(containers, [atom for atom in rendered["atoms"] if atom in containers], "Every container is a known atom.")
        self.assertEqual(set(containers), {"Stack", "Panel", "Card", "Scroll", "Disclosure", "Overlay", "Popover", "Modal", "Page", "SidePanel"},
                         "Only the atoms that lay out a composite's structure are containers.")
        leaves = [atom for atom in rendered["atoms"] if atom not in containers]
        self.assertEqual(leaves, ["Text", "Markdown", "Icon", "Image", "Label", "Button", "Link", "Spinner", "Spacer", "PillPicker", "Meter", "Divider", "ChoiceBar", "Toggle", "TextField", "Segmented", "Menu", "PressArea", "Editor", "StepSlider", "ResizeHandle", "DatePicker"],
                         "Every other atom, including a Button or Link that holds children, is a leaf.")
# case-contract: test_schedule_one_time_task_fires_when_due | A task whose conversation hasn't started is scheduled once (the composer's schedule hint, or schedule set --once); scheduling saves the prompt as the schedule's own payload without starting a turn, keeps the task in Backlog with a clock badge, and lists it in schedule list. A task with its own title keeps it, while an untitled task scheduled once (from the composer or schedule set) shows Generating title… and is then named from its prompt by the provider's title turn, as a first send would, without starting a conversation turn. Removing the schedule in the hint before Send turns the clock button off and returns Send to sending. A time in the past or a blank prompt is rejected with invalid_argument. A tick before the time does nothing; a tick 30 minutes after it, inside the one-hour grace period, sends the scheduled prompt to the provider, clears the schedule, and the task follows the ordinary board lifecycle. A second tick doesn't run it again. An existing conversation still shows scheduling, offers one-time messages only, preserves its lifecycle state, keeps the scheduled message in the composer as its unsent draft while Send returns to sending, and sends the due message, including edits made to that draft since it was scheduled, to that same task and conversation, preserving its Claude session or Codex thread identifier; once it is sent, the draft is cleared from storage and from the open composer. The app bundle carries the scheduler LaunchAgent (<bundle-id>.scheduler.plist running playhouse-cli schedule tick every 60 seconds), and a plain tick on the real clock fires a schedule that has come due.
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
        waiting = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(waiting["savedPrompt"], "Send a scheduled follow-up.", "The scheduled message waits in the composer as its draft.")
        self.assertTrue(waiting["hasUnsentDraft"], "The scheduled message is an unsent draft until it is sent.")
        recurring_follow_up, _ = self.call_cli(
            "schedule", "set", task_id, "--prompt", "Repeat this", "--repeat", "daily", "--title", "Repeated follow-up", expected_status=1
        )
        self.assert_failure(recurring_follow_up, "invalid_transition")
        # The message waits in the composer, so an edit made there is what gets sent.
        self.assert_success(self.call_cli("task", "draft", task_id, "--text", "Send an edited scheduled follow-up.")[0])
        follow_up_run = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(follow_up_at + datetime.timedelta(minutes=10)), extra_environment=environment
        )[0])
        self.assertEqual([run["taskID"] for run in follow_up_run["fired"]], [task_id], "The one-time message runs in the existing task.")
        self.wait_for(
            lambda: "Send an edited scheduled follow-up." in self.fixture_user_prompts(executable),
            "The edited scheduled follow-up should reach the existing conversation.",
        )
        self.assertNotIn("Send a scheduled follow-up.", self.fixture_user_prompts(executable), "The text from before the edit isn't sent.")
        after_follow_up = self.assert_success(self.call_cli("task", "get", task_id)[0])
        self.assertEqual(after_follow_up["claudeSessionID"], original_session_id, "The follow-up stays in the original Claude session.")
        def draft_cleared():
            task = self.assert_success(self.call_cli("task", "get", task_id)[0])
            return task if not task["hasUnsentDraft"] else None
        self.wait_for(draft_cleared, "Once the scheduled message is sent, it is no longer the composer's draft.")

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
    # case-contract: test_schedule_recurring_template_hidden_and_spawns_runs | A recurring schedule needs a title, and a weekday when it repeats weekly; once confirmed, its template is absent from the board and task list but listed by schedule list and in the Scheduled Tasks popover. A due tick creates a new board task with the schedule's title and context folders, linked by scheduleSourceTaskID, sends the prompt, records the run on the template and advances its next run by one day. A paused schedule doesn't fire, Run now starts a run immediately, and clearing the schedule turns the template into an ordinary Backlog task. A run saves no pull request mode of its own: it takes the one the pull-request-mode plugin keeps for its schedule (a Manual schedule's run reaches Review in Manual mode), and once that is changed to PR a later run reaches Review in PR mode. Saving PR for the tasks saved while PR was the default (once, at a first launch since Manual became the default) leaves such a run with no mode of its own, still inheriting its schedule's, while a run whose schedule was deleted gets PR saved as its own. The template's last run is the latest run, and the Scheduled Tasks popover's Open Last Run closes the popover and opens that run, so going back from it returns to the board.
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

        # A run has no mode of its own: the pull-request-mode plugin gives it the one its schedule was given.
        self.set_pull_request_mode(template_id, "manual")
        def review_modes(task_id):
            return [event.get("mode") for event in self.diagnostic_events()
                    if event.get("event") == "plugin.pull_request_mode.review" and event.get("taskID") == task_id]
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
        self.assertIsNone(self.pull_request_mode(run_id), "A run saves no mode of its own.")
        self.wait_for(lambda: review_modes(run_id) == ["manual"], "The run reached Review in its schedule's Manual mode.")
        # Saving PR for the tasks saved while PR was the default leaves a run whose schedule exists
        # inheriting its schedule's mode.
        subprocess.run(["/usr/bin/defaults", "delete", self.defaults_suite, "existingTaskPullRequestModesPinned"], check=False, capture_output=True)
        self.assertFalse(self.default_exists("existingTaskPullRequestModesPinned"))
        self.assertIsNone(self.pull_request_mode(run_id), "A run whose schedule exists keeps no mode of its own.")
        self.assertEqual(self.pull_request_mode(template_id), "manual", "A schedule's chosen mode is kept.")
        self.assertTrue(self.default_exists("existingTaskPullRequestModesPinned"))
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

        self.set_pull_request_mode(template_id, "pr")
        now_run = self.assert_success(self.call_cli("schedule", "run-now", template_id, extra_environment=environment)[0])
        self.assertFalse(now_run["dropped"])
        self.assertNotIn(now_run["taskID"], {run_id, template_id})
        self.wait_for_task_status(now_run["taskID"], {"Review"})
        self.wait_for(lambda: review_modes(now_run["taskID"]) == ["pr"], "With the schedule set to PR, a run is in PR mode.")
        last_run = [task for task in self.assert_success(self.call_cli("schedule", "list")[0])["tasks"] if task["id"] == template_id][0]
        self.assertEqual(last_run["schedule"]["lastRunTaskID"], now_run["taskID"], "The template's last run is the latest one, which the page opens.")

        cleared = self.assert_success(self.call_cli("schedule", "clear", template_id)[0])
        self.assertIsNone(cleared.get("schedule"))
        self.assertIn(template_id, [task["id"] for task in self.assert_success(self.call_cli("task", "list")[0])["tasks"]], "Clearing the schedule puts the task on the board.")
        self.assertEqual(self.assert_success(self.call_cli("schedule", "list")[0])["tasks"], [])
        # A run whose schedule is gone was in PR mode while PR was the default, so it gets PR saved as its own.
        self.assertTrue(self.assert_success(self.call_cli("task", "delete", template_id)[0])["deleted"])
        subprocess.run(["/usr/bin/defaults", "delete", self.defaults_suite, "existingTaskPullRequestModesPinned"], check=False, capture_output=True)
        self.assertFalse(self.default_exists("existingTaskPullRequestModesPinned"))
        self.assertEqual(self.pull_request_mode(run_id), "pr", "A run whose schedule was deleted gets PR saved as its own.")
        self.assertTrue(self.default_exists("existingTaskPullRequestModesPinned"))
    # case-contract: test_scheduled_task_edit_and_page_management | The Scheduled Tasks sidebar button opens the Scheduled Tasks popover beside it, over the board, whose New Task (header, or the button in the empty popover) closes the popover and opens a task conversation with the schedule hint already open on Recurring; opening a scheduled task from it closes it too, so going back returns to the bare board. Opening a scheduled task shows its confirmed prompt with the schedule button on and Send in schedule mode, and its hint shows the saved repeat, day and time; changing its title and repeat in the hint and confirming with Send persists across fresh CLI reads, keeps the time, and starts no turn. Deleting a schedule removes it from schedule list and from the popover. Done in the hint of a task that is already scheduled once saves the moved time at once, without Send, keeping its prompt, Backlog state and Send's schedule mode, starting no turn, and the hint reopens on that time; schedule set without --prompt likewise moves a scheduled task while keeping its prompt and mode, and still rejects a task with no schedule with invalid_argument. Remove in the hint clears a saved schedule as well, turning the clock off and keeping the prompt in the composer, and schedule set rejects --mode, --model or --image without --prompt with invalid_argument. An existing conversation's scheduled message is moved the same way, keeping its prompt, the composer draft and the task's Review state; after it is scheduled, and after the conversation is reopened, the message stays in the composer as its draft and Send sends again while the clock stays on and the hint shows the saved time. Clearing an existing conversation's scheduled message sends nothing; in the hint, Remove leaves the message in the composer, and a composer draft already there is kept. Sending a one-time scheduled task by hand ends its schedule, so a later tick sends nothing more; a recurring template rejects a send with invalid_transition; and clearing a schedule keeps its prompt as the task's draft.
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
        # Without a prompt, a scheduled task is only moved: its saved prompt and mode stay.
        moved_at = fire_at + datetime.timedelta(hours=2)
        payload_flag, _ = self.call_cli("schedule", "set", once_id, "--once", self.schedule_iso(moved_at), "--mode", "plan", expected_status=2)
        self.assert_failure(payload_flag, "invalid_argument")
        blank, _ = self.call_cli("schedule", "set", once_id, "--prompt", "  ", "--once", self.schedule_iso(moved_at), expected_status=2)
        self.assert_failure(blank, "invalid_argument")
        self.assert_success(self.call_cli("schedule", "set", once_id, "--once", self.schedule_iso(moved_at))[0])
        moved = self.assert_success(self.call_cli("task", "get", once_id)[0])
        self.assertEqual(moved["schedule"]["scheduledAt"], self.schedule_iso(moved_at), "Rescheduling persists the new time across fresh reads.")
        self.assertEqual(moved["schedule"]["prompt"], "Tell me a story.", "Rescheduling keeps the scheduled prompt.")
        self.assertEqual(moved["schedule"]["mode"], "default", "Rescheduling keeps the scheduled mode.")
        self.assertEqual(moved["savedPrompt"], "Tell me a story.")
        self.assertEqual(moved["status"], "Backlog")
        self.assertEqual(self.fixture_user_prompts(executable), [], "Rescheduling starts no turn.")
        unscheduled_id = self.create_task("Never scheduled", provider="claude")["id"]
        no_prompt, _ = self.call_cli("schedule", "set", unscheduled_id, "--once", self.schedule_iso(moved_at), expected_status=2)
        self.assert_failure(no_prompt, "invalid_argument")
        self.assertIsNone(self.assert_success(self.call_cli("task", "get", unscheduled_id)[0]).get("schedule"), "A task with no schedule still needs a prompt.")
        self.assert_success(self.call_cli("conversation", "send", once_id, "--message", "Tell me a story.", extra_environment=environment)[0])
        self.assertIsNone(self.wait_for_task_status(once_id, {"Review"}).get("schedule"), "Sending by hand ends a one-time schedule.")
        sent = len(self.fixture_user_prompts(executable))
        later = self.assert_success(self.call_cli(
            "schedule", "tick", "--now", self.schedule_iso(fire_at + datetime.timedelta(minutes=5)), extra_environment=environment
        )[0])
        self.assertEqual((later["fired"], later["dropped"]), ([], []), "A started task's schedule sends nothing more.")
        self.assertEqual(len(self.fixture_user_prompts(executable)), sent)

        # An existing conversation's scheduled message can be moved without restating it.
        follow_up_at = fire_at + datetime.timedelta(hours=4)
        scheduled_follow_up = self.assert_success(self.call_cli("schedule", "set", once_id, "--prompt", "Send a scheduled follow-up.", "--once", self.schedule_iso(follow_up_at))[0])
        self.assertEqual(scheduled_follow_up["savedPrompt"], "Send a scheduled follow-up.", "A scheduled message stays in the composer as its draft.")
        self.assertTrue(scheduled_follow_up["hasUnsentDraft"])
        self.assert_success(self.call_cli("task", "draft", once_id, "--text", "An unrelated draft.")[0])
        moved_follow_up_at = follow_up_at + datetime.timedelta(hours=1)
        self.assert_success(self.call_cli("schedule", "set", once_id, "--once", self.schedule_iso(moved_follow_up_at))[0])
        moved_follow_up = self.assert_success(self.call_cli("task", "get", once_id)[0])
        self.assertEqual(moved_follow_up["schedule"]["scheduledAt"], self.schedule_iso(moved_follow_up_at))
        self.assertEqual(moved_follow_up["schedule"]["prompt"], "Send a scheduled follow-up.", "Moving a scheduled message keeps its prompt.")
        self.assertEqual(moved_follow_up["savedPrompt"], "An unrelated draft.", "Moving a scheduled message leaves the composer draft alone.")
        self.assertEqual(moved_follow_up["status"], "Review")
        self.assertEqual(len(self.fixture_user_prompts(executable)), sent, "Moving a scheduled message sends nothing.")
        cancelled = self.assert_success(self.call_cli("schedule", "clear", once_id)[0])
        self.assertIsNone(cancelled.get("schedule"))
        self.assertEqual(cancelled["savedPrompt"], "An unrelated draft.", "Clearing a scheduled message keeps the composer draft already there.")
        self.assertEqual(len(self.fixture_user_prompts(executable)), sent, "Clearing a scheduled message sends nothing.")

    # case-contract: test_conversation_history_defers_earlier_images | A reader that asks history to defer images (--defer-images, as the app does) gets image data only for the newest turn the user started: earlier messages with images come back marked imagesDeferred with no image data, on the newest page, on an earlier --before page, where every image waits, and in the history a send returns, while plain history stays complete and never carries the mark, and the mark is never stored. conversation images returns the exact stored images of the named messages and nothing for a message without images; in a Codex conversation, whose user images Playhouse stores the same way, an earlier image is deferred the same way and read back from the store. Naming no message fails with invalid_argument and an unknown task fails with not_found. Reopening the conversation in the visible UI reads no image data until the reader scrolls up: each earlier image then loads when its message comes into view and is shown, and a turn sent afterwards from the composer keeps the loaded images without reading them again.
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
        self.assertEqual((images_read["requestedMessageCount"], images_read["returnedMessageCount"]), ("3", "2"))
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

        # A Codex user's images are stored by Playhouse too, so a deferred one is read back from the store.
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
            return read["returnedMessageCount"]

        codex_deferred = self.assert_success(self.call_cli("conversation", "history", codex_task, "--defer-images", extra_environment=fixtures)[0])
        self.assertEqual([(message["id"], message["imageDataURLs"], message.get("imagesDeferred")) for message in image_messages(codex_deferred)],
                         [(codex_image_message["id"], [], True)], "A Codex thread's earlier image is deferred too.")
        self.assertEqual(codex_image_read(), "1", "A Codex image is read from Playhouse's store.")
        with sqlite3.connect(self.conversation_database(), timeout=30) as connection:
            stored = connection.execute("SELECT image_data_urls FROM conversation_messages WHERE task_id = ? AND id = ?",
                                        (codex_key, codex_image_message["id"])).fetchone()
        self.assertEqual(json.loads(stored[0]), codex_image_message["imageDataURLs"], "A Codex user image is stored with its message.")

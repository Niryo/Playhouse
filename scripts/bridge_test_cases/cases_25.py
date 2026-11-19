from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases25:
    # case-contract: test_slash_commands_menu_lists_commands_and_items | The composer's / commands come from the built-in Built-in Commands headless plugin, which reads everything it shows through bridge commands and acts through ui calls. Typing / where a word starts anywhere in the composer opens a command menu listing /mcp, /plan, /goal, /skill, /login and /plugin in that order, narrowed to the commands whose name starts with what follows the /. On a Claude task /goal can't be chosen and says goal mode isn't supported by Claude, while on a Codex task it can. Choosing /plan turns plan mode on and choosing /goal on a Codex task opens the goal entry, each removing the typed command from the draft. The command menu shares the mention menu's look: the same floating panel, as wide as the mention menu, with the same section headers and highlighted-row surface. Typing a command with its own list in full lists its items, narrowed by text after a space: /mcp lists the MCP servers the composer can mention, and asked with sign-in status marks each server with the agents that need a sign-in to it (shown as a Sign in button per agent on its row); /skill lists the mentionable skills, editable ones with a working gear and built-in ones with a disabled gear; choosing either mentions it as @handle in place of the command. /login lists both agents, the task's own first, and choosing one starts that agent's sign-in, opening the link Codex's sign-in returns. /plugin lists Create Plugin first, which turns on Add Plugin mode, then the user's own plugins (never built-in ones), disabled ones marked so, each with edit, which opens the plugin's editor conversation, delete, which asks first, and a settings gear that stays disabled until plugins have settings. In the window an MCP server's gear opens the MCP page with that server's editor, its Sign in button opens the MCP page filtered to it and starts that agent's sign-in, and every choice removes the typed command. slash-commands run runs a command, chooses one of its items or presses an item's button the same way the window does and reports the plugin's host calls. Disabling the Built-in Commands plugin removes its commands from the menu and from slash-commands, and enabling it restores them. Listing without a task is a usage error and for an unknown task is not_found; running without a command, with an item for a command without a list, without an item for a command with a list, or with a button but no item is a usage error, and an unknown command, item or button is not_found.
    def test_slash_commands_menu_lists_commands_and_items(self):
        repository = self.make_skill_repository("slash-repo", {
            ".agents/skills/slash-skill/SKILL.md": self.skill_manifest("slash-skill", "A skill the slash menu lists"),
            ".mcp.json": json.dumps({"mcpServers": {"slash-docs": {"type": "stdio", "command": "node", "args": ["docs.js"]}}}),
        })
        self.write_skill(self.skills_codex_home / "skills" / ".system", "slash-system-skill", "Bundled with Codex")
        self.write_json(self.mcp_claude_state, {"mcpServers": {"slash-remote": {"type": "http", "url": "https://remote.example.com/mcp"}}})
        claude = self.install_claude_fixture("claude-fixture-slash")
        codex = self.install_codex_fixture("codex-fixture-slash")
        self.write_json(claude["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".mcp-status", [{"name": "slash-remote", "status": "needs-auth"}])
        self.write_json(codex["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".mcp-status", [
            {"name": "slash-remote", "authStatus": "notLoggedIn", "tools": {}},
        ])
        environment = {**claude, **codex}
        task = self.create_skills_task("Slash task", [repository], provider="claude")
        codex_task = self.create_skills_task("Slash Codex task", [repository], provider="codex")

        def menu(query, task_id=task["id"], *flags):
            query_flags = ["--query", query] if query else []
            return self.assert_success(self.call_cli("slash-commands", "list", "--task", task_id, *query_flags, *flags,
                                                     extra_environment=environment)[0])

        def run(command, *options, task_id=task["id"], expected_status=0):
            response = self.call_cli("slash-commands", "run", "--task", task_id, "--command", command, *options,
                                     extra_environment=environment, expected_status=expected_status)[0]
            return self.assert_success(response) if expected_status == 0 else response

        def ui_calls(result):
            return [(call["name"], call["arguments"]) for call in result["hostCalls"] if call["kind"] == "ui"]

        # Every command is the Built-in Commands plugin's.
        everything = menu("")
        self.assertIsNone(everything.get("command"))
        self.assertEqual([entry["name"] for entry in everything["commands"]], ["mcp", "plan", "goal", "skill", "login", "plugin"])
        self.assertEqual({entry["pluginID"] for entry in everything["commands"]}, {"built-in-commands"})
        self.assertEqual([entry["name"] for entry in everything["commands"] if entry["list"]], ["mcp", "skill", "login", "plugin"])
        self.assertIsNone(everything.get("list"))
        goal = next(entry for entry in everything["commands"] if entry["name"] == "goal")
        self.assertFalse(goal["enabled"], "Claude can't run goal mode.")
        self.assertIn("isn't supported by Claude", goal["disabledReason"])
        self.assertTrue(all(entry["enabled"] for entry in everything["commands"] if entry["name"] != "goal"))
        codex_goal = next(entry for entry in menu("", codex_task["id"])["commands"] if entry["name"] == "goal")
        self.assertTrue(codex_goal["enabled"], "Codex runs goal mode.")
        self.assertIsNone(codex_goal.get("disabledReason"))
        self.assertEqual([entry["name"] for entry in menu("p")["commands"]], ["plan", "plugin"], "Commands are narrowed by prefix.")
        self.assertEqual([entry["name"] for entry in menu("PL")["commands"]], ["plan", "plugin"], "Matching ignores case.")
        self.assertEqual(menu("zzz")["commands"], [])
        self.assertEqual(menu("plan ")["commands"], [], "A space after a command without a list ends it.")

        # /plan and /goal are actions without the agent: the plugin turns the composer's mode on.
        self.assertEqual(ui_calls(run("plan")), [("composer.setMode", {"mode": "plan"})])
        self.assertEqual(run("/plan")["outcome"], {}, "The outcome removes the typed command and inserts nothing.")
        self.assertEqual(ui_calls(run("goal", task_id=codex_task["id"])), [("composer.setMode", {"mode": "goal"})])
        self.assert_failure(run("goal", expected_status=1), "unavailable")

        mcp = menu("mcp")
        self.assertEqual(mcp["command"], "mcp")
        self.assertEqual(mcp["commands"], [])
        self.assertEqual(mcp["list"]["title"], "MCP servers")
        self.assertEqual(mcp["list"]["pending"], "Checking sign-in…", "The quick list says the sign-ins are still being asked.")
        servers = {item["title"]: item for item in mcp["list"]["items"]}
        self.assertIn("@slash-docs", servers)
        self.assertIn("@slash-remote", servers)
        self.assertEqual(servers["@slash-docs"]["id"], "mcp-slash-docs")
        self.assertEqual(servers["@slash-docs"]["data"]["handle"], "slash-docs")
        self.assertEqual([button["id"] for button in servers["@slash-docs"]["buttons"]], ["gear"], "Every listed server has a gear.")
        self.assertEqual([button["id"] for button in servers["@slash-remote"]["buttons"]], ["gear"], "Without status no sign-in is reported.")
        complete = menu("mcp", task["id"], "--complete")
        self.assertIsNone(complete["list"].get("pending"))
        self.assertEqual(complete["list"]["empty"], "No MCP servers", "Neither agent reported an error.")
        signed = {item["title"]: item for item in complete["list"]["items"]}
        self.assertEqual([button["id"] for button in signed["@slash-remote"]["buttons"]], ["signin-claude", "signin-codex", "gear"],
                         "Each agent that needs a sign-in has a Sign in button.")
        self.assertEqual(signed["@slash-remote"]["buttons"][0]["text"], "Claude")
        self.assertEqual([button["id"] for button in signed["@slash-docs"]["buttons"]], ["gear"])
        filtered = menu("mcp rem")
        self.assertEqual(filtered["filter"], "rem")
        self.assertEqual([item["title"] for item in filtered["list"]["items"]], ["@slash-remote"], "Text after a space narrows the items.")
        self.assertEqual(menu("mcp zzz")["list"]["items"], [])
        self.assertEqual(run("mcp", "--item", "mcp-slash-docs")["outcome"], {"text": "@slash-docs "}, "Choosing a server mentions it.")
        gear = run("mcp", "--item", "mcp-slash-docs", "--button", "gear")
        self.assertEqual(gear["outcome"], {})
        self.assertEqual(ui_calls(gear), [("openSkills", {"mcpServerID": servers["@slash-docs"]["data"]["serverID"]})])
        sign_in = run("mcp", "--item", "mcp-slash-remote", "--button", "signin-codex")
        self.assertEqual(ui_calls(sign_in), [("openSkills", {"signIn": {"name": "slash-remote", "provider": "codex"}})])
        self.assertEqual([call["name"] for call in sign_in["hostCalls"] if call["kind"] == "bridge"], ["mentions.list", "mcp.status"],
                         "The plugin reads the servers and their sign-ins through bridge commands.")

        skills = {item["title"]: item for item in menu("skill")["list"]["items"]}
        self.assertEqual(skills["@slash-skill"]["id"], "skill-slash-skill")
        self.assertFalse(skills["@slash-skill"]["buttons"][0].get("disabled", False), "A repository skill's gear opens its editor.")
        self.assertTrue(all(item["icon"] == "sparkles" for item in skills.values()), "/skill lists only skills.")
        codex_skills = {item["title"]: item for item in menu("skill", codex_task["id"])["list"]["items"]}
        self.assertTrue(codex_skills["@slash-system-skill"]["buttons"][0]["disabled"], "A built-in skill can't be edited.")
        self.assertEqual(run("skill", "--item", "skill-slash-skill")["outcome"], {"text": "@slash-skill "})
        self.assertEqual(ui_calls(run("skill", "--item", "skill-slash-skill", "--button", "gear")),
                         [("openSkills", {"skillID": skills["@slash-skill"]["data"]["skillID"]})])
        self.assert_failure(run("skill", "--item", "skill-slash-system-skill", "--button", "gear", task_id=codex_task["id"], expected_status=1), "unavailable")

        logins = menu("login")["list"]["items"]
        self.assertEqual([item["id"] for item in logins], ["login-claude", "login-codex"], "The task's own agent comes first.")
        self.assertEqual((logins[0]["title"], logins[0]["detail"]), ("Sign in to Claude", "This task's agent"))
        self.assertEqual([item["id"] for item in menu("login", codex_task["id"])["list"]["items"]], ["login-codex", "login-claude"])
        # Choosing an agent runs the same sign-in as `usage login`.
        claude_auth = Path(claude["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".auth-state")
        claude_auth.write_text(json.dumps({"loggedIn": False}), encoding="utf-8")
        login = run("login", "--item", "login-claude")
        self.assertEqual([(call["name"], call["arguments"]) for call in login["hostCalls"] if call["kind"] == "bridge"][-1],
                         ("usage.login", {"provider": "claude"}))
        # The sign-in runs in the background after the call returns.
        self.wait_for(lambda: "claude-second@example.com" in claude_auth.read_text(encoding="utf-8"), "Claude Code's sign-in ran.")
        # Codex's sign-in returns a link, which the plugin opens.
        codex_account = Path(codex["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".account")
        codex_account.write_text(json.dumps({"loggedIn": False, "email": None, "used": [0, 0]}), encoding="utf-8")
        codex_login = run("login", "--item", "login-codex", task_id=codex_task["id"])
        self.assertEqual(codex_login["outcome"], {})
        self.assertEqual([(call["kind"], call["name"], call["arguments"]) for call in codex_login["hostCalls"]][-2:], [
            ("bridge", "usage.login", {"provider": "codex"}), ("ui", "openURL", {"url": "https://example.invalid/codex-login"}),
        ], "Choosing Codex starts its sign-in and opens the link it returns.")
        self.wait_for(lambda: "codex-second@example.com" in codex_account.read_text(encoding="utf-8"), "Codex's sign-in ran.")

        self.write_installed_plugin("slash-panel", "function Panel() { return h(Text, null, 'hi'); }")
        self.write_installed_plugin("slash-off", "function Panel() { return h(Text, null, 'off'); }")
        self.assert_success(self.call_cli("plugin", "disable", "--id", "slash-off")[0])
        plugins = menu("plugin")["list"]["items"]
        self.assertEqual((plugins[0]["id"], plugins[0]["title"]), ("create-plugin", "Create Plugin"), "Create Plugin comes first.")
        own = {item["id"]: item for item in plugins[1:]}
        self.assertEqual(sorted(own), ["plugin-slash-off", "plugin-slash-panel"], "Only the user's own plugins are listed, never built-in ones.")
        self.assertTrue(all([button["id"] for button in item["buttons"]] == ["edit", "delete", "gear"] for item in own.values()))
        self.assertTrue(own["plugin-slash-panel"]["buttons"][2]["disabled"], "The settings gear waits for plugin settings.")
        self.assertTrue(own["plugin-slash-off"]["detail"].endswith("(Disabled)"))
        self.assertFalse(own["plugin-slash-panel"]["detail"].endswith("(Disabled)"))
        self.assertEqual([item["id"] for item in menu("plugin create")["list"]["items"]], ["create-plugin"])
        run("plugin", "--item", "create-plugin")
        self.assertEqual(self.assert_success(self.call_cli("plugin", "mode")[0]), {"enabled": True}, "Create Plugin turns on Add Plugin mode.")
        self.assertEqual(ui_calls(run("plugin", "--item", "plugin-slash-panel")), [("editPlugin", {"pluginID": "slash-panel"})])
        self.assertEqual(ui_calls(run("plugin", "--item", "plugin-slash-panel", "--button", "edit")), [("editPlugin", {"pluginID": "slash-panel"})])
        self.assert_failure(run("plugin", "--item", "plugin-slash-panel", "--button", "gear", expected_status=1), "unavailable")
        # Delete asks first: unconfirmed, nothing is deleted; confirmed, the folder is.
        declined = run("plugin", "--item", "plugin-slash-off", "--button", "delete")
        self.assertEqual([call["name"] for call in declined["hostCalls"]][-1], "confirm")
        self.assertTrue((self.plugins_folder() / "slash-off").is_dir())
        deleted = run("plugin", "--item", "plugin-slash-off", "--button", "delete", "--confirm")
        self.assertEqual([(call["kind"], call["name"]) for call in deleted["hostCalls"]][-2:], [("ui", "confirm"), ("bridge", "plugin.delete")])
        self.assertFalse((self.plugins_folder() / "slash-off").exists(), "The confirmed delete removes the plugin's folder.")
        listed = [plugin["id"] for plugin in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]]
        self.assertNotIn("slash-off", listed)

        # Disabling the Built-in Commands plugin removes its commands.
        self.assert_success(self.call_cli("plugin", "disable", "--id", "built-in-commands")[0])
        self.assertEqual(menu("")["commands"], [])
        self.assert_failure(run("plan", expected_status=3), "not_found")
        self.assert_success(self.call_cli("plugin", "enable", "--id", "built-in-commands")[0])
        self.assertEqual(len(menu("")["commands"]), 6)

        self.assert_failure(self.call_cli("slash-commands", "list", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("slash-commands", "list", "--task", str(uuid.uuid4()), expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("slash-commands", "run", "--task", task["id"], expected_status=2)[0], "invalid_argument")
        self.assert_failure(run("nope", expected_status=3), "not_found")
        self.assert_failure(run("plan", "--item", "x", expected_status=2), "invalid_argument")
        self.assert_failure(run("mcp", expected_status=2), "invalid_argument")
        self.assert_failure(run("mcp", "--button", "gear", expected_status=2), "invalid_argument")
        self.assert_failure(run("mcp", "--item", "mcp-nope", expected_status=3), "not_found")
        self.assert_failure(run("mcp", "--item", "mcp-slash-docs", "--button", "nope", expected_status=3), "not_found")

    # case-contract: test_headless_plugin_exposes_slash_commands | An installed plugin whose presentation is headless and whose placement is composerActions has no button or surface, only the / commands its manifest's commands declare and its script registers with Playhouse.commands.register. They are listed after the built-in commands with the plugin's id, its icon for a command without one, and the composer and slash-commands run them alike with the composer's context: a command without a list runs at once and the text it returns replaces the typed command; a command with a list shows the items its list handler builds from bridge commands, narrowed by the typed filter, which also matches an item's keywords, choosing an item inserts the text its choose handler returns, and an item's button calls the press handler, whose host calls are reported; a command whose available handler says it can't run is listed disabled with its reason and can't be run. A command whose handler throws fails with its message, which the window shows under the composer after removing the typed command, and a plugin whose available handler fails lists its commands disabled with the error as the reason. A disabled plugin's commands aren't offered. A headless plugin without commands or at another placement, a command named like a built-in one, and a declared command its script never registers each make the plugin invalid, and an invalid plugin offers no commands.
    def test_headless_plugin_exposes_slash_commands(self):
        task = self.create_task("Headless task", provider="claude")
        commands = [
            {"name": "greet", "detail": "Greets the task", "icon": "hand.wave"},
            {"name": "notes", "detail": "Lists the task's notes", "list": True},
            {"name": "later", "detail": "Not ready"},
            {"name": "broken", "detail": "Always fails"},
        ]
        self.write_installed_plugin("note-commands", HEADLESS_NOTES_SOURCE, presentation="headless", manifest={"commands": commands})

        def menu(query):
            query_flags = ["--query", query] if query else []
            return self.assert_success(self.call_cli("slash-commands", "list", "--task", task["id"], *query_flags)[0])

        def run(command, *options, expected_status=0):
            response = self.call_cli("slash-commands", "run", "--task", task["id"], "--command", command, *options,
                                     expected_status=expected_status)[0]
            return self.assert_success(response) if expected_status == 0 else response

        listed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]}
        record = listed["note-commands"]
        self.assertEqual((record["placement"], record["presentation"], record["valid"], record["errors"]),
                         ("composerActions", "headless", True, []))
        self.assertEqual([command["name"] for command in record["commands"]], ["greet", "notes", "later", "broken"])

        # Its commands follow the built-in ones, each with the plugin's id.
        entries = menu("")["commands"]
        self.assertEqual([entry["name"] for entry in entries], ["mcp", "plan", "goal", "skill", "login", "plugin", "greet", "notes", "later", "broken"])
        own = {entry["name"]: entry for entry in entries[6:]}
        self.assertEqual({entry["pluginID"] for entry in own.values()}, {"note-commands"})
        self.assertEqual((own["greet"]["icon"], own["greet"]["detail"], own["greet"]["list"]), ("hand.wave", "Greets the task", False))
        self.assertEqual(own["notes"]["icon"], "puzzlepiece.extension", "A command without an icon has its plugin's.")
        self.assertTrue(own["notes"]["list"])
        self.assertTrue(own["greet"]["enabled"] and own["notes"]["enabled"])
        self.assertEqual((own["later"]["enabled"], own["later"]["disabledReason"]), (False, "Not yet"),
                         "The available handler disables a command with its reason.")
        self.assertEqual([entry["name"] for entry in menu("g")["commands"]], ["goal", "greet"])

        # A command without a list runs at once with the composer's context.
        greet = run("greet")
        self.assertEqual(greet["outcome"], {"text": "Hello from Headless task "})
        self.assertEqual(greet["hostCalls"], [])
        self.assert_failure(run("later", expected_status=1), "unavailable")
        # A handler that throws fails the command with its message.
        broken = run("broken", expected_status=1)
        self.assert_failure(broken, "script_error")
        self.assertIn("Broken on purpose", broken["error"]["message"])

        # A command with a list builds its items through bridge commands.
        notes = menu("notes")
        self.assertEqual(notes["command"], "notes")
        self.assertEqual((notes["list"]["title"], notes["list"]["empty"], notes["list"]["noMatch"]), ("Notes", "No notes", "No note matches"))
        items = notes["list"]["items"]
        self.assertEqual([item["id"] for item in items], ["note-title", "note-plain"])
        self.assertEqual(items[0]["detail"], "Headless task", "The list read the task through task.get.")
        self.assertEqual([button["id"] for button in items[0]["buttons"]], ["plan"])
        self.assertEqual([item["id"] for item in menu("notes heading")["list"]["items"]], ["note-title"], "The filter matches keywords.")
        self.assertEqual(menu("notes zzz")["list"]["items"], [])
        chosen = run("notes", "--item", "note-title")
        self.assertEqual(chosen["outcome"], {"text": "Note: Headless task "})
        self.assertEqual([(call["kind"], call["name"], call["arguments"]) for call in chosen["hostCalls"]],
                         [("bridge", "task.get", {"taskID": task["id"]})])
        pressed = run("notes", "--item", "note-title", "--button", "plan")
        self.assertEqual(pressed["outcome"], {})
        self.assertEqual([(call["kind"], call["name"], call["arguments"]) for call in pressed["hostCalls"]][-1],
                         ("ui", "composer.setMode", {"mode": "plan"}))
        self.assert_failure(run("notes", "--item", "note-plain", "--button", "plan", expected_status=3), "not_found")

        # A disabled plugin's commands aren't offered.
        self.assert_success(self.call_cli("plugin", "disable", "--id", "note-commands")[0])
        self.assertEqual([entry["name"] for entry in menu("")["commands"]], ["mcp", "plan", "goal", "skill", "login", "plugin"])
        self.assert_failure(run("greet", expected_status=3), "not_found")
        self.assert_success(self.call_cli("plugin", "enable", "--id", "note-commands")[0])
        self.assertEqual(run("greet")["outcome"], {"text": "Hello from Headless task "})

        # Invalid headless plugins and commands.
        self.write_installed_plugin("no-commands", "var x = 1;", presentation="headless")
        self.write_installed_plugin("headless-board", HEADLESS_NOTES_SOURCE, placement="mainSidebar", presentation="headless",
                                    manifest={"commands": commands})
        self.write_installed_plugin("plan-again", "Playhouse.commands.register('plan', { run: function () { return {}; } });",
                                    presentation="headless", manifest={"commands": [{"name": "plan", "detail": "Another plan"}]})
        self.write_installed_plugin("never-registered", "var x = 1;", presentation="headless",
                                    manifest={"commands": [{"name": "ghost", "detail": "Never registered"}]})
        # A plugin whose available handler fails lists its commands disabled with the error.
        self.write_installed_plugin("flaky-commands", HEADLESS_FLAKY_SOURCE, presentation="headless",
                                    manifest={"commands": [{"name": "flaky", "detail": "Can't tell"}]})
        listed = {plugin["id"]: plugin for plugin in self.assert_success(self.call_cli("plugin", "list")[0])["plugins"]}
        expected_errors = {
            "no-commands": "needs at least one command",
            "headless-board": "its placement must be \"composerActions\"",
            "plan-again": "/plan is a built-in command.",
            "never-registered": "never calls Playhouse.commands.register(\"ghost\"",
        }
        for plugin_id, error in expected_errors.items():
            self.assertFalse(listed[plugin_id]["valid"], plugin_id)
            self.assertTrue(any(error in each for each in listed[plugin_id]["errors"]), (plugin_id, listed[plugin_id]["errors"]))
        self.assertTrue(listed["flaky-commands"]["valid"])
        entries = menu("")["commands"]
        self.assertEqual([entry["name"] for entry in entries],
                         ["mcp", "plan", "goal", "skill", "login", "plugin", "flaky", "greet", "notes", "later", "broken"],
                         "Invalid plugins offer no commands.")
        self.assertEqual(entries[1]["pluginID"], "built-in-commands")
        flaky = entries[6]
        self.assertEqual((flaky["pluginID"], flaky["enabled"]), ("flaky-commands", False))
        self.assertIn("Can't tell yet", flaky["disabledReason"], "The available handler's error is the reason.")
        self.assert_failure(run("flaky", expected_status=1), "unavailable")


    # case-contract: test_cli_help_lists_commands_by_group_and_audience | The CLI's help is printed from its single command catalog, which the parser also requires: help, help <group> and <group> --help print that group's declared commands with their usage and a one-line description, and --for <audience> narrows them to one agent. The standalone chat's help lists the board commands, task create and every schedule command but no internal command (schedule tick) and no task-only command (task outcome, task progress publish, task pr autopilot, task move to Done --discard-changes); the task agent's help lists those task commands and still no internal one; the side chat's help lists only the read-only board commands its hook lets it run, the same list it is refused with, and never the option that starts a task; the plugin editor's help lists plugin render and no task or schedule command. The full help lists everything, internal commands marked. An unknown group or audience and an undeclared command or operation are refused as invalid_argument, pointing at help. Following the chat's help, a new task is created and scheduled once for tomorrow at 09:00 with schedule set, and it is in schedule list and in the Scheduled Tasks popover with that run time. The help reads only the CLI's own catalog and the schedule goes through the shared board manager, so provider selection cannot change either; no provider runs.
    def test_cli_help_lists_commands_by_group_and_audience(self):
        environment = {**os.environ, "PLAYHOUSE_DATA_DIRECTORY": str(self.data_directory), "PLAYHOUSE_BRIDGE_SERVICE_NAME": arguments.service_name}
        def help_text(*command):
            completed = subprocess.run([str(self.cli), *command], capture_output=True, text=True, timeout=30, env=environment)
            self.assertEqual(completed.returncode, 0, f"{command}: {completed.stdout} {completed.stderr}")
            return completed.stdout
        def commands(text):
            return [line.strip() for line in text.splitlines() if line.startswith("  playhouse ")]
        def refused(*command):
            response = self.call_cli(*command, expected_status=2)[0]
            self.assert_failure(response, "invalid_argument")
            message = response["error"]["message"]
            self.assertIn("help", message, f"{command} should point at help: {response}")
            return message

        full = help_text("help")
        self.assertIn(f"`playhouse` stands for this CLI: {self.cli}", full)
        self.assertEqual(help_text(), full, "Running the CLI with no arguments prints the full help.")
        self.assertIn("  playhouse schedule tick [--now <ISO8601>]", full)
        self.assertIn("each minute. (internal)", full, "The full help marks internal commands.")
        self.assertIn("  playhouse task outcome <task-id> <completed|waiting-response|blocked> [--reason <text>]", full)

        # One group, asked either way, lists only its own commands, each with a description.
        schedule = help_text("help", "schedule")
        self.assertEqual(help_text("schedule", "--help"), schedule)
        self.assertTrue(commands(schedule) and all(line.startswith("playhouse schedule ") for line in commands(schedule)), schedule)
        self.assertIn("playhouse schedule set <task-id> --prompt <text> --once <ISO8601> [--title <title>] [--image <path>...] [--mode default|plan] [--model <id>]", commands(schedule))
        self.assertIn("      Schedule a task to start once with this prompt", schedule)
        self.assertIn("playhouse task create --title <title> --prompt <text> [--root <path>...] [--provider <codex|claude>]", commands(help_text("task", "--help")))
        self.assertEqual(help_text("task", "pr", "--help"), help_text("help", "task", "pr"))
        self.assertTrue(all(line.startswith("playhouse task pr ") for line in commands(help_text("help", "task", "pr"))))

        chat = help_text("help", "--for", "chat")
        for line in ["playhouse task create --title <title> --prompt <text> [--root <path>...] [--provider <codex|claude>]",
                     "playhouse schedule list", "playhouse schedule clear|pause|resume|run-now <task-id>",
                     "playhouse workspace repos list", "playhouse plugin mode [--on|--off]"]:
            self.assertIn(line, commands(chat))
        self.assertTrue(any(line.startswith("playhouse schedule set <task-id> --prompt <text> --once ") for line in commands(chat)))
        for hidden in ["schedule tick", "task outcome", "task progress publish", "task pr autopilot", "--discard-changes", "(internal)", "chat page new"]:
            self.assertNotIn(hidden, chat, f"The chat's help must not list {hidden}.")
        self.assertEqual(help_text("schedule", "--help", "--for", "chat"), help_text("help", "schedule", "--for", "chat"))
        self.assertNotIn("schedule tick", help_text("help", "schedule", "--for", "chat"))

        task = help_text("help", "--for", "task")
        for line in ["playhouse task outcome <task-id> <completed|waiting-response|blocked> [--reason <text>]",
                     "playhouse task move <task-id> Done --discard-changes", "playhouse task repository add <task-id> --repo <path>",
                     "playhouse task repository add-worktree <task-id> --repo <path> [--branch <name>] [--branch-from <ref>]",
                     "playhouse task pr link <task-id> (--worktree <path>|--repo <path>) --url <pr-url>"]:
            self.assertIn(line, commands(task))
        self.assertTrue(any(line.startswith("playhouse task progress publish ") for line in commands(task)))
        self.assertTrue(any(line.startswith("playhouse task pr autopilot ") for line in commands(task)))
        self.assertNotIn("schedule tick", task)
        self.assertNotIn("(internal)", task)

        side = commands(help_text("help", "--for", "side-chat"))
        self.assertEqual(sorted({line.split(" <")[0].split(" --")[0].split(" [")[0] for line in side}), [
            "playhouse help", "playhouse task create", "playhouse task get|show", "playhouse task list", "playhouse task prompt",
            "playhouse task rename", "playhouse version", "playhouse workspace repos list"])

        self.assertNotIn("--submitted", help_text("help", "--for", "side-chat"), "A read-only side chat can't start a task.")
        editor = commands(help_text("help", "--for", "plugin-editor"))
        self.assertTrue(any(line.startswith("playhouse plugin render ") for line in editor), editor)
        self.assertFalse(any(line.startswith(("playhouse task ", "playhouse schedule ")) for line in editor), editor)

        self.assertIn("Groups: help, status", refused("help", "nosuch"))
        self.assertIn("chat, side-chat, task, plugin-editor", refused("help", "--for", "nobody"))
        self.assertIn("playhouse help task", refused("task", "bogus"))
        self.assertIn("playhouse help", refused("frobnicate"))

        # An agent that follows the chat's help can schedule a task for tomorrow at 09:00.
        once = next(line for line in commands(chat) if line.startswith("playhouse schedule set <task-id> --prompt <text> --once "))
        self.assertIn("--once <ISO8601>", once)
        created = self.assert_success(self.call_cli("task", "create", "--title", "Write the release notes",
                                                    "--prompt", "Write the release notes for the next version.")[0])
        tomorrow = (datetime.datetime.now().astimezone() + datetime.timedelta(days=1)).replace(hour=9, minute=0, second=0, microsecond=0)
        self.assert_success(self.call_cli("schedule", "set", created["id"], "--prompt", "Write the release notes.",
                                          "--once", tomorrow.isoformat(timespec="seconds"))[0])
        listed = self.assert_success(self.call_cli("schedule", "list")[0])["tasks"]
        self.assertEqual([task["id"] for task in listed], [created["id"]])
        self.assertEqual(self.parse_schedule_iso(listed[0]["schedule"]["scheduledAt"]), tomorrow.astimezone(datetime.timezone.utc))

HEADLESS_NOTES_SOURCE = """
Playhouse.commands.register("greet", {
  run: function () { return { text: "Hello from " + Playhouse.props.task.title + " " }; }
});
Playhouse.commands.register("notes", {
  list: function () {
    return Playhouse.bridge("task.get", { taskID: Playhouse.props.task.id }).then(function (task) {
      return {
        title: "Notes", empty: "No notes", noMatch: "No note matches",
        items: [
          { id: "note-title", title: "Task title", detail: task.title, icon: "note.text", keywords: ["heading"],
            buttons: [{ id: "plan", label: "Plan it", help: "Plan from this note", icon: "list.bullet" }], data: { text: task.title } },
          { id: "note-plain", title: "Plain note", detail: "No buttons", data: { text: "plain" } }
        ]
      };
    });
  },
  choose: function (request) { return { text: "Note: " + request.item.data.text + " " }; },
  press: function () { return Playhouse.ui.composer.setMode("plan").then(function () { return {}; }); }
});
Playhouse.commands.register("later", {
  available: function () { return { enabled: false, reason: "Not yet" }; },
  run: function () { return { text: "never" }; }
});
Playhouse.commands.register("broken", {
  run: function () { throw new Error("Broken on purpose"); }
});
"""

HEADLESS_FLAKY_SOURCE = """
Playhouse.commands.register("flaky", {
  available: function () { throw new Error("Can't tell yet"); },
  run: function () { return { text: "never" }; }
});
"""

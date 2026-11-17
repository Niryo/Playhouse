from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases25:
    # case-contract: test_slash_commands_menu_lists_commands_and_items | Typing / where a word starts anywhere in the composer opens a command menu listing /mcp, /plan, /goal, /skill, /login and /plugin in that order, narrowed to the commands whose name starts with what follows the /. On a Claude task /goal can't be chosen and says goal mode isn't supported by Claude, while on a Codex task it can. Choosing /plan turns plan mode on and choosing /goal on a Codex task opens the goal entry, each removing the typed command from the draft. Typing a command with its own list in full lists its items, narrowed by text after a space: /mcp lists the MCP servers the composer can mention, and asked with sign-in status marks each server with the agents that need a sign-in to it (shown as a Sign in button per agent on its row); /skill lists the mentionable skills, editable ones with a working gear and built-in ones with a disabled gear; choosing either mentions it as @handle in place of the command. /login lists both agents, the task's own first, and choosing one starts that agent's sign-in. /plugin lists Create Plugin first, which turns on Add Plugin mode, then the user's own plugins (never built-in ones), disabled ones marked so, each with edit, which opens the plugin's editor conversation, delete, which asks first, and a settings gear that stays disabled until plugins have settings. In the window an MCP server's gear opens the MCP page with that server's editor, its Sign in button opens the MCP page filtered to it and starts that agent's sign-in, and every choice removes the typed command. Listing without a task is a usage error and for an unknown task is not_found.
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

        everything = menu("")
        self.assertIsNone(everything.get("command"))
        self.assertEqual([entry["command"] for entry in everything["commands"]], ["mcp", "plan", "goal", "skill", "login", "plugin"])
        self.assertEqual(everything["items"], [])
        goal = next(entry for entry in everything["commands"] if entry["command"] == "goal")
        self.assertFalse(goal["enabled"], "Claude can't run goal mode.")
        self.assertIn("isn't supported by Claude", goal["disabledReason"])
        self.assertTrue(all(entry["enabled"] for entry in everything["commands"] if entry["command"] != "goal"))
        codex_goal = next(entry for entry in menu("", codex_task["id"])["commands"] if entry["command"] == "goal")
        self.assertTrue(codex_goal["enabled"], "Codex runs goal mode.")
        self.assertIsNone(codex_goal.get("disabledReason"))
        self.assertEqual([entry["command"] for entry in menu("p")["commands"]], ["plan", "plugin"], "Commands are narrowed by prefix.")
        self.assertEqual([entry["command"] for entry in menu("PL")["commands"]], ["plan", "plugin"], "Matching ignores case.")
        self.assertEqual(menu("zzz")["commands"], [])
        self.assertEqual(menu("plan ")["commands"], [], "A space after a command without a list ends it.")

        mcp = menu("mcp")
        self.assertEqual(mcp["command"], "mcp")
        self.assertEqual(mcp["commands"], [])
        servers = {item["title"]: item for item in mcp["items"]}
        self.assertIn("slash-docs", servers)
        self.assertIn("slash-remote", servers)
        self.assertEqual(servers["slash-docs"]["kind"], "mcp")
        self.assertEqual(servers["slash-docs"]["handle"], "slash-docs", "Choosing a server mentions it with its handle.")
        self.assertTrue(servers["slash-docs"]["editable"], "Every listed server has a gear.")
        self.assertEqual(servers["slash-remote"].get("needsSignIn", []), [], "Without status no sign-in is reported.")
        status = menu("mcp", task["id"], "--status")
        self.assertEqual(status["statusErrors"], {})
        signed = {item["title"]: item for item in status["items"]}
        self.assertEqual(signed["slash-remote"]["needsSignIn"], ["claude", "codex"], "Each agent that needs a sign-in is named.")
        self.assertEqual(signed["slash-docs"].get("needsSignIn", []), [])
        filtered = menu("mcp rem")
        self.assertEqual(filtered["filter"], "rem")
        self.assertEqual([item["title"] for item in filtered["items"]], ["slash-remote"], "Text after a space narrows the items.")
        self.assertEqual(menu("mcp zzz")["items"], [])

        skills = {item["title"]: item for item in menu("skill")["items"]}
        self.assertEqual(skills["slash-skill"]["kind"], "skill")
        self.assertEqual(skills["slash-skill"]["handle"], "slash-skill")
        self.assertTrue(skills["slash-skill"]["editable"], "A repository skill's gear opens its editor.")
        self.assertTrue(all(item["kind"] == "skill" for item in skills.values()), "/skill lists only skills.")
        codex_skills = {item["title"]: item for item in menu("skill", codex_task["id"])["items"]}
        self.assertFalse(codex_skills["slash-system-skill"]["editable"], "A built-in skill can't be edited.")

        logins = menu("login")["items"]
        self.assertEqual([item["targetID"] for item in logins], ["claude", "codex"], "The task's own agent comes first.")
        self.assertEqual(logins[0]["title"], "Sign in to Claude")
        self.assertEqual([item["targetID"] for item in menu("login", codex_task["id"])["items"]], ["codex", "claude"])
        # Choosing an agent runs the same sign-in as `usage login`, named by the item's targetID.
        claude_auth = Path(claude["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".auth-state")
        claude_auth.write_text(json.dumps({"loggedIn": False}), encoding="utf-8")
        self.assert_success(self.call_cli("usage", "login", logins[0]["targetID"], extra_environment=environment)[0])
        # The sign-in runs in the background after the call returns.
        self.wait_for(lambda: "claude-second@example.com" in claude_auth.read_text(encoding="utf-8"), "Claude Code's sign-in ran.")

        self.write_installed_plugin("slash-panel", "function Panel() { return h(Text, null, 'hi'); }")
        self.write_installed_plugin("slash-off", "function Panel() { return h(Text, null, 'off'); }")
        self.assert_success(self.call_cli("plugin", "disable", "--id", "slash-off")[0])
        plugins = menu("plugin")["items"]
        self.assertEqual(plugins[0]["kind"], "create-plugin", "Create Plugin comes first.")
        self.assertEqual(plugins[0]["title"], "Create Plugin")
        own = {item["targetID"]: item for item in plugins[1:]}
        self.assertEqual(sorted(own), ["slash-off", "slash-panel"], "Only the user's own plugins are listed, never built-in ones.")
        self.assertTrue(all(item["kind"] == "plugin" and item["editable"] for item in own.values()))
        self.assertTrue(own["slash-off"]["detail"].endswith("(Disabled)"))
        self.assertFalse(own["slash-panel"]["detail"].endswith("(Disabled)"))
        self.assertEqual([item["kind"] for item in menu("plugin create")["items"]], ["create-plugin"])
        # Edit opens the plugin's editor conversation, as `plugin edit` does.
        self.assert_success(self.call_cli("plugin", "edit", "--id", own["slash-panel"]["targetID"])[0])
        sessions = self.assert_success(self.call_cli("plugin", "sessions")[0])["sessions"]
        self.assertTrue(any(session.get("authoredPluginID") == "slash-panel" for session in sessions), "The plugin's editor exists.")

        self.assert_failure(self.call_cli("slash-commands", "list", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("slash-commands", "list", "--task", str(uuid.uuid4()), expected_status=3)[0], "not_found")

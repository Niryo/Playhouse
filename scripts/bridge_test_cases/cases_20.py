from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases20:
    # case-contract: test_mcp_fix_with_agent_starts_task_for_conflicting_servers | A server whose definitions conflict offers a Fix button on its row, which creates a task on the source task's provider whose saved prompt explains how both agents configure MCP servers and lists each server with its problem: repository servers by repository-relative file, to be fixed in the new task's own worktree and committed and pushed, and global servers by absolute file path, to be fixed in place with their folders opened as context folders. The view switches to the new task's conversation, which sends that prompt once and leaves no unsent draft. A server with no problem, a managed server, an unknown server, and a request without a task are rejected without opening a task.
    def test_mcp_fix_with_agent_starts_task_for_conflicting_servers(self):
        repository = self.make_skill_repository("mcp-fix-repo", {
            ".mcp.json": json.dumps({"mcpServers": {
                "repo-clash": {"type": "stdio", "command": "clash-json", "args": [], "env": {}},
                "fine": {"type": "stdio", "command": "fine", "args": [], "env": {}},
            }}),
            ".codex/config.toml": '[mcp_servers.repo-clash]\ncommand = "clash-toml"\n',
        })
        self.write_json(self.mcp_claude_state, {"mcpServers": {"clash": {"type": "stdio", "command": "clash-a", "args": [], "env": {}}}})
        self.write_file(self.mcp_codex_config, '[mcp_servers.clash]\ncommand = "clash-b"\n')
        self.write_json(self.mcp_managed, {"mcpServers": {"company": {"type": "http", "url": "https://mcp.company.example/mcp"}}})
        environment = self.install_claude_fixture("claude-fixture-mcp-fix")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        source = self.create_skills_task("MCP fix source", [repository], provider="claude")
        source_worktree = Path(source["repositoryWorktrees"][0]["worktreePath"])
        tasks_before = len(self.assert_success(self.call_cli("board", "list")[0])["tasks"])

        def fix(*servers, expected_status=0):
            arguments = [argument for server in servers for argument in ("--server", server)]
            return self.call_cli("mcp", "fix", "--task", source["id"], *arguments, expected_status=expected_status)[0]

        self.assert_failure(fix(f"repo:{repository}#fine", expected_status=2), "invalid_argument")
        self.assert_failure(fix("managed:company", expected_status=2), "invalid_argument")
        self.assert_failure(fix("global:no-such-server", expected_status=3), "not_found")
        self.assert_failure(self.call_cli("mcp", "fix", "--server", "global:clash", expected_status=2)[0], "invalid_argument")
        self.assertEqual(len(self.assert_success(self.call_cli("board", "list")[0])["tasks"]), tasks_before, "A rejected fix opens no task.")

        created = self.assert_success(fix(f"repo:{repository}#repo-clash", "global:clash"))
        task, prompt = created["task"], created["prompt"]
        self.assertEqual(task["title"], "Fix 2 MCP servers")
        self.assertEqual(task["conversationProvider"], "claude", "The fixing task uses the source task's provider.")
        self.assertEqual([record["repositoryPath"] for record in task["repositoryWorktrees"]], [str(repository)])
        self.assertEqual(sorted(os.path.realpath(folder) for folder in task["contextFolders"]),
                         sorted([os.path.realpath(self.skills_home), os.path.realpath(self.skills_codex_home)]),
                         "The folders of the global files are opened to the agent.")
        self.assertEqual(task["savedPrompt"], prompt)
        self.assertIn("Claude Code reads `mcpServers`", prompt)
        self.assertIn("[mcp_servers.<name>]", prompt)
        self.assertIn("commit and push", prompt)
        self.assertIn("`repo-clash` in mcp-fix-repo: `.mcp.json`, `.codex/config.toml`", prompt)
        self.assertNotIn(str(source_worktree), prompt, "Repository files are relative, so they point into the fixing task's worktree.")
        self.assertTrue(str(self.mcp_claude_state) in prompt or os.path.realpath(self.mcp_claude_state) in prompt,
                        "A global server is named by its absolute file path.")
        self.assertIn("not tracked by Git", prompt)
        self.assertNotIn("`fine`", prompt)

        global_only = self.assert_success(fix("global:clash"))["task"]
        self.assertEqual(global_only["title"], "Fix MCP server clash")
        self.assertEqual(global_only["repositoryWorktrees"], [], "Fixing only global servers needs no repository.")

        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", prompt, extra_environment=environment)[0])
        turns = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == prompt]
        self.assertEqual(len(turns), 1, "The fixing prompt is sent once.")
        started = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertFalse(started["hasUnsentDraft"])
        self.assertSamePath(turns[0]["cwd"], started["repositoryWorktrees"][0]["worktreePath"])
    # case-contract: test_mcp_bridge_claude_launch_passes_shared_servers | A Claude turn starts the servers Claude Code does not read itself: its --mcp-config carries Codex's own global servers (with env_vars passed as ${NAME}), the working repository's .codex/config.toml servers, and the other task repository's .mcp.json servers, but not the servers Claude Code already reads or ones turned off on the page. Its --settings starts the working repository's .mcp.json servers that are on with enabledMcpjsonServers and skips turned-off ones with disabledMcpjsonServers, without writing to the repository or either provider's configuration. The resumed second turn carries the same servers, and turning a server back on adds it.
    def test_mcp_bridge_claude_launch_passes_shared_servers(self):
        repository = self.make_skill_repository("mcp-claude-repo", {
            ".mcp.json": json.dumps({"mcpServers": {
                "repo-tool": {"type": "stdio", "command": "repo-tool", "args": [], "env": {}},
                "repo-off": {"type": "stdio", "command": "repo-off", "args": [], "env": {}},
            }}),
            ".codex/config.toml": '[mcp_servers.repo-codex]\ncommand = "repo-codex"\nargs = ["--serve"]\n',
        })
        extra = self.make_skill_repository("mcp-claude-extra", {
            ".mcp.json": json.dumps({"mcpServers": {"extra-api": {"type": "http", "url": "https://extra.example.com/mcp"}}}),
        })
        self.write_json(self.mcp_claude_state, {"mcpServers": {"claude-tool": {"type": "stdio", "command": "claude-tool", "args": [], "env": {}}}})
        self.write_file(self.mcp_codex_config, '[mcp_servers.codex-tool]\ncommand = "codex-tool"\nenv_vars = ["CODEX_KEY"]\n\n[mcp_servers.codex-off]\ncommand = "codex-off"\n')
        environment = self.install_claude_fixture("claude-fixture-mcp-bridge")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        task = self.create_skills_task("Claude MCP", [repository, extra], provider="claude")
        worktree = Path(next(record["worktreePath"] for record in task["repositoryWorktrees"] if record["repositoryPath"] == str(repository)))
        for server_id in [f"repo:{repository}#repo-off", "global:codex-off"]:
            self.assert_success(self.call_cli("mcp", "disable", "--task", task["id"], "--server", server_id)[0])
        before_claude = self.mcp_claude_state.read_text(encoding="utf-8")
        before_codex = self.mcp_codex_config.read_text(encoding="utf-8")

        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Use the tools.", extra_environment=environment)[0])
        turns = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText")]
        arguments = turns[0]["arguments"]
        servers = json.loads(arguments[arguments.index("--mcp-config") + 1])["mcpServers"]
        self.assertEqual(sorted(servers), ["codex-tool", "extra-api", "repo-codex"],
                         "Claude gets the servers it does not read itself, without the ones it reads or ones turned off.")
        self.assertEqual(servers["codex-tool"], {"type": "stdio", "command": "codex-tool", "args": [], "env": {"CODEX_KEY": "${CODEX_KEY}"}})
        self.assertEqual(servers["repo-codex"], {"type": "stdio", "command": "repo-codex", "args": ["--serve"], "env": {}})
        self.assertEqual(servers["extra-api"], {"type": "http", "url": "https://extra.example.com/mcp"})
        settings = json.loads(arguments[arguments.index("--settings") + 1])
        self.assertEqual(settings["enabledMcpjsonServers"], ["repo-tool"], "The working repository's .mcp.json server that is on starts.")
        self.assertEqual(settings["disabledMcpjsonServers"], ["repo-off"], "A turned-off .mcp.json server is skipped for this run.")
        self.assertEqual(self.mcp_claude_state.read_text(encoding="utf-8"), before_claude, "Claude Code's configuration is not written.")
        self.assertEqual(self.mcp_codex_config.read_text(encoding="utf-8"), before_codex, "Codex's configuration is not written.")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "The worktree is not written to.")
        self.assertFalse((self.rules_claude_config / "settings.json").exists())

        bridge = self.assert_success(self.call_cli("mcp", "bridge", "--task", task["id"])[0])
        self.assertEqual(sorted(server["id"] for server in bridge["claudeShared"]),
                         sorted(["global:codex-tool", f"repo:{repository}#repo-codex", f"repo:{extra}#extra-api"]))

        self.assert_success(self.call_cli("mcp", "enable", "--task", task["id"], "--server", "global:codex-off")[0])
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Use them again.", extra_environment=environment)[0])
        second = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == "Use them again."][-1]
        self.assertTrue(second["resumed"], "The second turn resumes the Claude session.")
        resumed = second["arguments"]
        self.assertEqual(sorted(json.loads(resumed[resumed.index("--mcp-config") + 1])["mcpServers"]),
                         ["codex-off", "codex-tool", "extra-api", "repo-codex"], "Turning a server back on adds it.")
    # case-contract: test_mcp_bridge_codex_thread_gets_shared_servers | A Codex turn starts the servers Codex does not read itself: the thread's mcp_servers config carries the working repository's .mcp.json servers and Claude Code's own global servers, translated so ${NAME} environment references become env_vars and an Authorization bearer token becomes bearer_token_env_var, leaves out an SSE server Codex can't run and the servers Codex already reads, and turns off a server Codex may read itself (from its config.toml or the working repository's .codex/config.toml) that is turned off on the page with enabled = false, without writing Codex's config.toml. Turning servers on or off on the page resumes the thread on its next turn with the new mcp_servers config.
    def test_mcp_bridge_codex_thread_gets_shared_servers(self):
        repository = self.make_skill_repository("mcp-codex-repo", {
            ".mcp.json": json.dumps({"mcpServers": {
                "repo-tool": {"type": "stdio", "command": "repo-tool", "args": ["--serve"], "env": {"REPO_TOKEN": "${REPO_TOKEN}", "MODE": "fast"}},
                "repo-sse": {"type": "sse", "url": "https://sse.example.com/mcp"},
            }}),
            ".codex/config.toml": '[mcp_servers.repo-codex-off]\ncommand = "repo-codex-off"\n',
        })
        self.write_json(self.mcp_claude_state, {"mcpServers": {
            "claude-remote": {"type": "http", "url": "https://remote.example.com/mcp",
                              "headers": {"Authorization": "Bearer ${REMOTE_TOKEN}", "X-Team": "core"}},
        }})
        self.write_file(self.mcp_codex_config, '[mcp_servers.codex-tool]\ncommand = "codex-tool"\n\n[mcp_servers.codex-off]\ncommand = "codex-off"\n')
        before_codex = self.mcp_codex_config.read_text(encoding="utf-8")
        task = self.create_skills_task("Codex MCP", [repository])
        self.assert_success(self.call_cli("mcp", "disable", "--task", task["id"], "--server", "global:codex-off")[0])
        self.assert_success(self.call_cli("mcp", "disable", "--task", task["id"], "--server", f"repo:{repository}#repo-codex-off")[0])

        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-mcp", message="Use the tools.")
        history = json.loads((self.data_directory / "codex-fixture-mcp.history").read_text(encoding="utf-8"))
        servers = history["threadStartConfig"]["mcp_servers"]
        self.assertEqual(servers, {
            "repo-tool": {"command": "repo-tool", "args": ["--serve"], "env": {"MODE": "fast"}, "env_vars": ["REPO_TOKEN"]},
            "claude-remote": {"url": "https://remote.example.com/mcp", "bearer_token_env_var": "REMOTE_TOKEN", "http_headers": {"X-Team": "core"}},
            "codex-off": {"command": "codex-off", "enabled": False},
            "repo-codex-off": {"command": "repo-codex-off", "enabled": False},
        }, "Codex gets the servers it does not read itself, translated, and a turned-off server it may read itself is turned off.")
        self.assertEqual(self.mcp_codex_config.read_text(encoding="utf-8"), before_codex, "Codex's config.toml is not written.")
        bridge = self.assert_success(self.call_cli("mcp", "bridge", "--task", task["id"])[0])
        self.assertEqual(sorted(server["name"] for server in bridge["codexShared"]), ["claude-remote", "repo-tool"])
        self.assertEqual(sorted(bridge["codexDisabled"]), ["codex-off", "repo-codex-off"])

        self.assert_success(self.call_cli("mcp", "enable", "--task", task["id"], "--server", "global:codex-off")[0])
        self.assert_success(self.call_cli("mcp", "disable", "--task", task["id"], "--server", f"repo:{repository}#repo-tool")[0])
        resumes_before = history.get("threadResumeCount", 0)
        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-mcp", message="Use them again.")
        history = json.loads((self.data_directory / "codex-fixture-mcp.history").read_text(encoding="utf-8"))
        self.assertGreater(history.get("threadResumeCount", 0), resumes_before, "Changing the servers resumes the thread.")
        self.assertEqual(history["threadResumeConfig"]["mcp_servers"], {
            "claude-remote": {"url": "https://remote.example.com/mcp", "bearer_token_env_var": "REMOTE_TOKEN", "http_headers": {"X-Team": "core"}},
            "repo-codex-off": {"command": "repo-codex-off", "enabled": False},
        }, "The resumed thread gets the new servers.")
    # case-contract: test_mcp_status_reports_sign_in_per_provider | Opening the MCP page asks both agents on its own, with no button to press, which servers they start and which need a sign-in, showing Checking sign-in… while they answer and asking again whenever the page is opened: Claude Code, asked with the task's own MCP bridge, reports each server including the ones Playhouse passes it, and Codex reports its own; a server that needs a sign-in shows a Sign in badge with the Claude or Codex logo on its row (labelled Sign in for Claude or Sign in for Codex), and the claude.ai connectors and plugin servers Claude Code starts that no file defines are listed under Also started by Claude Code in the Managed section, a connector that needs a sign-in with the same badge. Asking for one provider only asks that provider. An agent that can't be asked is reported by name on the page while the other agent's answer is still shown.
    def test_mcp_status_reports_sign_in_per_provider(self):
        repository = self.make_skill_repository("mcp-status-repo", {})
        self.write_json(self.mcp_claude_state, {"mcpServers": {"claude-remote": {"type": "http", "url": "https://remote.example.com/mcp"}}})
        self.write_file(self.mcp_codex_config, '[mcp_servers.codex-remote]\nurl = "https://codex.example.com/mcp"\n\n[mcp_servers.codex-tool]\ncommand = "codex-tool"\n')
        claude = self.install_claude_fixture("claude-fixture-mcp-status")
        codex = self.install_codex_fixture("codex-fixture-mcp-status")
        self.write_json(claude["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".mcp-status", [
            {"name": "claude-remote", "status": "needs-auth"},
            {"name": "claude.ai Notes", "status": "needs-auth"},
            {"name": "plugin:kit:helper", "status": "connected"},
        ])
        self.write_json(codex["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".mcp-status", [
            {"name": "codex-remote", "authStatus": "notLoggedIn", "tools": {}},
            {"name": "codex-tool", "authStatus": "unsupported", "tools": {}},
        ])
        task = self.create_skills_task("MCP status", [repository], provider="claude")

        report = self.assert_success(self.call_cli("mcp", "status", "--task", task["id"], extra_environment={**claude, **codex})[0])
        self.assertEqual(report["errors"], {})
        claude_status = {server["name"]: server for server in report["claude"]}
        self.assertTrue(claude_status["claude-remote"]["needsSignIn"], "A server Claude can't start without a sign-in is reported.")
        self.assertTrue(claude_status["claude.ai Notes"]["needsSignIn"])
        self.assertFalse(claude_status["plugin:kit:helper"]["needsSignIn"])
        self.assertEqual(claude_status["codex-tool"]["status"], "connected", "Claude is asked with the servers Playhouse passes it.")
        codex_status = {server["name"]: server for server in report["codex"]}
        self.assertTrue(codex_status["codex-remote"]["needsSignIn"])
        self.assertEqual(codex_status["codex-remote"]["status"], "notLoggedIn")
        self.assertFalse(codex_status["codex-tool"]["needsSignIn"])

        Path(codex["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".mcp-status-fail").write_text("Fail the status request.\n", encoding="utf-8")
        failing = self.assert_success(self.call_cli("mcp", "status", "--task", task["id"], extra_environment={**claude, **codex})[0])
        self.assertIn("codex", failing["errors"], "An agent that can't be asked is reported by name.")
        self.assertEqual(failing["codex"], [])
        self.assertNotIn("claude", failing["errors"])
        self.assertTrue(any(server["name"] == "claude-remote" and server["needsSignIn"] for server in failing["claude"]),
                        "The other agent's answer is still shown.")
        only_claude = self.assert_success(self.call_cli("mcp", "status", "--task", task["id"], extra_environment=claude)[0])
        self.assertIn("codex", only_claude["errors"], "An agent that isn't installed is reported by name.")
        self.assertTrue(any(server["name"] == "claude-remote" for server in only_claude["claude"]))

        Path(codex["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] + ".mcp-status-fail").unlink()
        codex_only = self.assert_success(self.call_cli("mcp", "status", "--task", task["id"], "--provider", "codex", extra_environment={**claude, **codex})[0])
        self.assertEqual(codex_only["claude"], [], "Asking for Codex alone doesn't ask Claude Code.")
        self.assertEqual(codex_only["errors"], {})
        self.assertTrue(any(server["name"] == "codex-remote" and server["needsSignIn"] for server in codex_only["codex"]))
        claude_only = self.assert_success(self.call_cli("mcp", "status", "--task", task["id"], "--provider", "claude", extra_environment={**claude, **codex})[0])
        self.assertEqual(claude_only["codex"], [], "Asking for Claude alone doesn't ask Codex.")
        self.assertTrue(any(server["name"] == "claude-remote" and server["needsSignIn"] for server in claude_only["claude"]))
        self.assert_failure(self.call_cli("mcp", "status", "--provider", "gemini", expected_status=2)[0], "invalid_argument")
    # case-contract: test_mcp_authenticate_signs_in_each_provider | The Sign in badge with the Claude or Codex logo on a server (labelled Sign in for Claude or Sign in for Codex) is the button that signs in: it asks that agent to start the OAuth sign-in of that one server (Claude Code's mcp_authenticate, Codex's mcpServer/oauth/login) and returns the authorization link, which the page opens in the browser (a test build only records it, and never opens one) while the badge reads Waiting… (labelled Waiting for sign-in…). A server both agents have shows one Sign in button per agent on the same row, each just that agent's logo so the name keeps room in the narrow card (labelled the same way): each starts only its own agent's sign-in, waiting on one leaves the other clickable, and each badge clears on its own once that agent is signed in. The agent finishes the sign-in when the browser redirects back to it, and the page then checks again by itself and the badge goes away; waiting for it through the CLI keeps the bridge running and returns signed in. Starting one agent's sign-in never asks the other agent, a sign-in nobody finishes times out with a message that names the server, and waiting for a sign-in that was never started or was already reported with either agent, an unknown provider, and a blank server name are rejected or reported without starting anything.
    def test_mcp_authenticate_signs_in_each_provider(self):
        repository = self.make_skill_repository("mcp-auth-repo", {})
        self.write_json(self.mcp_claude_state, {"mcpServers": {
            "shared-remote": {"type": "http", "url": "https://remote.example.com/mcp"},
            "claude-other": {"type": "http", "url": "https://other.example.com/mcp"},
        }})
        self.write_file(self.mcp_codex_config, '[mcp_servers.shared-remote]\nurl = "https://remote.example.com/mcp"\n\n[mcp_servers.codex-remote]\nurl = "https://codex.example.com/mcp"\n\n[mcp_servers.codex-other]\nurl = "https://codex-other.example.com/mcp"\n')
        claude = self.install_claude_fixture("claude-fixture-mcp-auth")
        codex = self.install_codex_fixture("codex-fixture-mcp-auth")
        claude_executable = claude["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"]
        codex_executable = codex["PLAYHOUSE_E2E_CODEX_EXECUTABLE"]
        self.write_json(claude_executable + ".mcp-status", [
            {"name": "shared-remote", "status": "needs-auth"}, {"name": "claude-other", "status": "needs-auth"},
        ])
        self.write_json(codex_executable + ".mcp-status", [
            {"name": "shared-remote", "authStatus": "notLoggedIn", "tools": {}},
            {"name": "codex-remote", "authStatus": "notLoggedIn", "tools": {}}, {"name": "codex-other", "authStatus": "notLoggedIn", "tools": {}},
        ])
        environment = {**claude, **codex}
        task = self.create_skills_task("MCP authenticate", [repository], provider="claude")

        def call(*command, extra=None, expected_status=0):
            return self.call_cli("mcp", *command, "--task", task["id"], extra_environment={**environment, **(extra or {})}, expected_status=expected_status)[0]

        def logged(path):
            return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines()] if Path(path).exists() else []

        def finish(provider, name, callback_path, extra=None):
            """Waits for a started sign-in through the CLI while the "browser" redirects back."""
            command = ["mcp", "authenticate-wait", "--provider", provider, "--name", name, "--task", task["id"]]
            process = self.start_cli(*command, extra_environment={**environment, **(extra or {})})
            time.sleep(1.5)
            self.assertIsNone(process.poll(), "Waiting for the sign-in keeps the request, and so the bridge, running.")
            with open(callback_path, "a", encoding="utf-8") as callback:
                callback.write(name + "\n")
            response, _ = self.finish_cli(process, command)
            return self.assert_success(response)

        started = self.assert_success(call("authenticate", "--provider", "claude", "--name", "shared-remote"))
        self.assertEqual(started, {"provider": "claude", "name": "shared-remote",
                                   "authorizationUrl": "https://auth.example.test/claude/authorize?server=shared-remote"})
        self.assertEqual(logged(claude_executable + ".mcp-authenticate"), [{"serverName": "shared-remote"}], "Claude Code is asked for that server only.")
        self.assertEqual(logged(codex_executable + ".mcp-login"), [], "Starting Claude's sign-in doesn't ask Codex.")
        before = {server["name"]: server for server in self.assert_success(call("status", "--provider", "claude"))["claude"]}
        self.assertTrue(before["shared-remote"]["needsSignIn"], "The server needs its sign-in until the browser redirects back.")
        codex_before = {server["name"]: server for server in self.assert_success(call("status", "--provider", "codex"))["codex"]}
        self.assertTrue(codex_before["shared-remote"]["needsSignIn"], "A server both agents have needs a sign-in for each of them.")
        finished = finish("claude", "shared-remote", claude_executable + ".mcp-callback")
        self.assertEqual(finished, {"provider": "claude", "name": "shared-remote", "signedIn": True})
        after = {server["name"]: server for server in self.assert_success(call("status", "--provider", "claude"))["claude"]}
        self.assertFalse(after["shared-remote"]["needsSignIn"], "The finished sign-in no longer needs one.")
        codex_during = {server["name"]: server for server in self.assert_success(call("status", "--provider", "codex"))["codex"]}
        self.assertTrue(codex_during["shared-remote"]["needsSignIn"], "Signing in for Claude doesn't sign the same server in for Codex.")
        self.assertTrue(after["claude-other"]["needsSignIn"], "Other servers still need theirs.")

        started = self.assert_success(call("authenticate", "--provider", "codex", "--name", "codex-remote"))
        self.assertEqual(started, {"provider": "codex", "name": "codex-remote",
                                   "authorizationUrl": "https://auth.example.test/codex/authorize?server=codex-remote"})
        self.assertEqual(logged(codex_executable + ".mcp-login"), [{"name": "codex-remote"}], "Codex is asked for that server only.")
        self.assertEqual(logged(claude_executable + ".mcp-authenticate"), [{"serverName": "shared-remote"}], "Starting Codex's sign-in doesn't ask Claude Code.")
        finished = finish("codex", "codex-remote", codex_executable + ".mcp-callback")
        self.assertEqual(finished, {"provider": "codex", "name": "codex-remote", "signedIn": True})
        codex_after = {server["name"]: server for server in self.assert_success(call("status", "--provider", "codex"))["codex"]}
        self.assertFalse(codex_after["codex-remote"]["needsSignIn"])
        self.assertTrue(codex_after["codex-other"]["needsSignIn"])

        quick = {"PLAYHOUSE_E2E_MCP_LOGIN_TIMEOUT_SECONDS": "2"}
        self.assert_success(call("authenticate", "--provider", "claude", "--name", "claude-other", extra=quick))
        timed_out = self.assert_success(call("authenticate-wait", "--provider", "claude", "--name", "claude-other", extra=quick))
        self.assertFalse(timed_out["signedIn"], "A sign-in nobody finishes doesn't sign in.")
        self.assertIn("claude-other", timed_out["error"])
        self.assertIn("in time", timed_out["error"])
        self.assert_success(call("authenticate", "--provider", "codex", "--name", "codex-other", extra=quick))
        codex_timed_out = self.assert_success(call("authenticate-wait", "--provider", "codex", "--name", "codex-other", extra=quick))
        self.assertFalse(codex_timed_out["signedIn"])
        self.assertIn("codex-other", codex_timed_out["error"])

        # A pending sign-in is background work for either agent: the daemon, which would
        # idle-exit after 3 seconds here, stays up while the agent waits for the browser.
        # (The window's own watchers keep a daemon up, so only this suite can show it.)
        for provider, name, callback_path in [("claude", "claude-other", claude_executable + ".mcp-callback"),
                                              ("codex", "codex-other", codex_executable + ".mcp-callback")]:
            lifecycle = {"PLAYHOUSE_BRIDGE_SERVICE_NAME": f"{arguments.service_name}.mcp-login-{uuid.uuid4().hex[:8]}",
                         "PLAYHOUSE_BRIDGE_IDLE_GRACE_SECONDS": "3"}
            daemon_pid = self.assert_success(self.call_cli("status", extra_environment={**environment, **lifecycle})[0])["processID"]
            self.assert_success(call("authenticate", "--provider", provider, "--name", name, extra=lifecycle))
            time.sleep(5.5)
            self.assertTrue(self.process_is_running(daemon_pid), f"The bridge stays up while a {provider} sign-in waits for the browser.")
            with open(callback_path, "a", encoding="utf-8") as callback:
                callback.write(name + "\n")
            finished = self.assert_success(call("authenticate-wait", "--provider", provider, "--name", name, extra=lifecycle))
            self.assertTrue(finished["signedIn"], "The sign-in finishes on the daemon that waited for it.")
            deadline = time.monotonic() + 10
            while self.process_is_running(daemon_pid) and time.monotonic() < deadline:
                time.sleep(0.25)
            self.assertFalse(self.process_is_running(daemon_pid), "Once the sign-in is over, the idle bridge exits again.")

        never = self.assert_success(call("authenticate-wait", "--provider", "claude", "--name", "never-started"))
        self.assertFalse(never["signedIn"], "Waiting for a sign-in that was never started reports it.")
        self.assertIn("No sign-in", never["error"])
        for provider, name in [("claude", "shared-remote"), ("codex", "codex-remote")]:
            reported = self.assert_success(call("authenticate-wait", "--provider", provider, "--name", name))
            self.assertFalse(reported["signedIn"], "A finished sign-in is reported once; waiting again finds none in progress.")
            self.assertIn("No sign-in", reported["error"])
        self.assert_failure(call("authenticate", "--provider", "gemini", "--name", "shared-remote", expected_status=2), "invalid_argument")
        self.assert_failure(call("authenticate", "--provider", "claude", "--name", "", expected_status=2), "invalid_argument")
        self.assertEqual(logged(claude_executable + ".mcp-authenticate")[-1], {"serverName": "claude-other"}, "A rejected request starts nothing.")
    # case-contract: test_plugin_renderer_commits_minimal_ops_and_runs_handlers | The Plugins menu opens the Plugin Catalog, whose sidebar lists every atom (Stack, Text, Icon, Label, Button, Link, Spinner, Spacer, PillPicker, Card, Disclosure, Panel, Meter, Scroll, Divider, ChoiceBar, Toggle, TextField, Segmented, Menu, PressArea, Overlay, Editor, Popover, StepSlider, Modal, Page, SidePanel) and the Task Item, Agents Info, Token Stats, Skills Page, Repository Chips, Composer and Done Archive examples; each atom page renders its JavaScript page through the React renderer into native SwiftUI with no plugin error and lists the atom's props. Clicking a Button atom runs its JavaScript onPress handler, whose state change commits a single text op on that Text's string node, and clicking a Disclosure's title runs its onToggle handler, which collapses it (its children hide while staying in the tree: one commit updating only the Disclosure's props and the state readout) and expands it again, and clicking a ChoiceBar's option runs its onChange handler with that option's value, which selects it (one commit updating only the ChoiceBar's props and the readout), while clicking the option already selected commits nothing, and the Scroll page's scroll view shrinks to its four rows, then, once added rows pass its 120-point maxHeight, stays 120 points tall and scrolls to reach the last row. On the Skills page's controls' pages, clicking the Toggle runs its onToggle handler, which flips it (one commit updating only the Toggle's props and the readout), typing in the TextField runs onChange with the new text, Return in it runs onSubmit and an arrow key runs onArrow with its direction, choosing a Segmented segment runs onChange with its value, choosing a Menu item runs onMenu with that item's id, and the PressArea tells a click (onPress) from a press and hold (onLongPress). On the Overlay page, the badge drawn over the chip's top trailing corner leaves the chip its own size and runs its own onPress. `plugin render` runs a plugin headlessly through the same runtime and node tree: the first render is one commit, each event sent by testID runs its handler and commits only the ops for the nodes that changed (a toggled label is one text op on one node), an interval advanced with --advance updates only its own node, and every bundled catalog page renders without errors. An unknown atom, an unknown or mistyped prop, a missing required prop, an event the atom doesn't raise, a child the atom can't hold, a string outside a Text, or a handler that throws is reported in errors with exit 1 (a mistyped or missing prop, decoded straight from the plugin's values, names its path and what is wrong, such as size: expected a number, found a string or options.0.label: missing), and an event for a missing testID, an event the atom has no handler for, or an unknown catalog page is refused as invalid_argument. Commits, the plugin's props and event values cross between JavaScript and Swift as JavaScript values with JSON.stringify's rules: props keep their types and nesting, NaN becomes null, a Date becomes its ISO string, undefined, function and inherited fields are left out of nested values, toJSON is called once per value (one that returns itself gives an empty object), an event value arrives as a string, and a circular prop or an op whose node id is out of range is reported in errors. The Button page also shows a link-style Button and a large one (taller than a regular Button), each running onPress, the Menu page's disabled Run Now item is shown but can't be chosen, and the Icon page draws the app logo asset in its own colors (original) in a 50-point frame with its accessibility label; a mistyped original or Menu item disabled is reported with its path. The Scroll page's lazy paged list raises onEndReached each time its end scrolls into view: it starts at 1 pages loaded, and scrolling to its end appends a page and then, scrolled to the new end, another (2, then 3 pages loaded); in `plugin render` each onEndReached is one commit that adds the page's rows and changes the readout. The TextField page's plain field (style plain) draws no border on its rounded Stack, so it is shorter than the rounded field, and typing in it runs its onChange.
    def test_plugin_renderer_commits_minimal_ops_and_runs_handlers(self):
        plugin = """
function App() {
  var on = React.useState(false);
  var ticks = React.useState(0);
  React.useEffect(function () {
    var timer = setInterval(function () { ticks[1](function (count) { return count + 1; }); }, 1000);
    return function () { clearInterval(timer); };
  }, []);
  return h(Stack, { axis: "v", spacing: 4, testID: "root" },
    h(Text, { size: 13, testID: "label" }, on[0] ? "On" : "Off"),
    h(Text, { size: 10, testID: "ticks" }, "Ticks: ", String(ticks[0])),
    h(Button, { testID: "toggle", onPress: function () { on[1](!on[0]); } }, h(Text, null, "Toggle")),
    h(Button, { testID: "explode", onPress: function () { throw new Error("Kaboom"); } }, h(Text, null, "Explode")));
}
Playhouse.render(h(App));
"""
        rendered = self.assert_success(self.render_plugin(plugin))
        self.assertEqual(rendered["atoms"], ["Stack", "Text", "Icon", "Label", "Button", "Link", "Spinner", "Spacer", "PillPicker", "Card", "Disclosure", "Panel", "Meter",
                                             "Scroll", "Divider", "ChoiceBar", "Toggle", "TextField", "Segmented", "Menu", "PressArea", "Overlay", "Editor", "Popover", "StepSlider",
                                             "Modal", "Page", "SidePanel"],
                         "Plugins compose exactly the native composites' atoms.")
        self.assertEqual(rendered["errors"], [])
        self.assertEqual(len(rendered["commits"]), 1, "The first render is one commit.")
        first = rendered["commits"][0]
        self.assertIn("create", first["ops"])
        self.assertIn("createText", first["ops"])
        self.assertEqual(first["ops"][-1], "append", "The commit ends by appending the root atom to the container.")
        tree = rendered["tree"]
        label = self.plugin_node(tree, "label")
        self.assertEqual(self.plugin_text(label), "Off")
        self.assertEqual(self.plugin_node(tree, "toggle")["events"], ["onPress"], "Handlers stay in JavaScript; only their names reach Swift.")
        self.assertNotIn("onPress", self.plugin_node(tree, "toggle").get("props", {}))

        toggled = self.assert_success(self.render_plugin(plugin, "--event", "toggle:onPress", "--event", "toggle:onPress", "--event", "toggle:onPress"))
        self.assertEqual(toggled["errors"], [])
        label = self.plugin_node(toggled["tree"], "label")
        label_text = label["children"][0]
        self.assertEqual(self.plugin_text(label), "On", "Three presses ran the JavaScript handler three times.")
        for commit in toggled["commits"][1:]:
            self.assertEqual(commit["step"], "toggle:onPress")
            self.assertEqual(commit["ops"], ["text"], "A toggled label commits one text op.")
            self.assertEqual(commit["touchedNodes"], [label_text["id"]], "Only the label's string node changes.")
        self.assertEqual(label_text["updates"], 3)
        self.assertEqual(label["updates"], 0, "The Text atom's props never changed.")
        self.assertEqual(self.plugin_node(toggled["tree"], "root")["updates"], 0, "Nothing else was updated.")

        advanced = self.assert_success(self.render_plugin(plugin, "--advance", "3"))
        ticks = self.plugin_node(advanced["tree"], "ticks")
        self.assertEqual(self.plugin_text(ticks), "Ticks: 3", "Three seconds of the interval ran.")
        tick_commits = [commit for commit in advanced["commits"] if commit["step"] == "advance"]
        self.assertEqual(len(tick_commits), 1)
        self.assertEqual(set(tick_commits[0]["touchedNodes"]), {ticks["children"][1]["id"]}, "Each tick changes only its own string node.")
        self.assertEqual(self.plugin_node(advanced["tree"], "label")["children"][0]["updates"], 0)

        # Commits, props and event values cross as JavaScript values, not JSON
        # strings, but keep JSON.stringify's rules.
        values_plugin = """
function App() {
  var picked = React.useState("none");
  return h(Stack, { testID: "values" },
    h(Text, { testID: "props-echo" }, JSON.stringify(Playhouse.props)),
    h(Text, { testID: "nan", size: NaN, label: new Date(0) }, "x"),
    h(PillPicker, { testID: "pill", selected: "a", onChange: function (value) { picked[1](typeof value + " " + value); },
      options: [{ value: "a", label: "A", help: undefined, extra: function () {}, gone: { toJSON: function () { return undefined; } }, selfish: { toJSON: function () { return this; } } }, inherits] }),
    h(Text, { testID: "picked" }, picked[0]));
}
var inherits = Object.create({ inherited: "x" });
inherits.value = "b";
inherits.label = "B";
Playhouse.render(h(App));
"""
        props = {"nested": {"list": [1, 2.5, "two", True, None], "flag": False}, "title": "Hi"}
        values = self.assert_success(self.render_plugin(values_plugin, "--props", json.dumps(props), "--event", "pill:onChange:b"))
        self.assertEqual(values["errors"], [])
        self.assertEqual(json.loads(self.plugin_text(self.plugin_node(values["tree"], "props-echo"))), props,
                         "The plugin's props reach JavaScript with their types and nesting intact.")
        nan = self.plugin_node(values["tree"], "nan")["props"]
        self.assertIn("size", nan)
        self.assertIsNone(nan["size"], "NaN crosses as null, as JSON.stringify sends it.")
        self.assertEqual(nan["label"], "1970-01-01T00:00:00.000Z", "A Date crosses as its toJSON() string.")
        options = self.plugin_node(values["tree"], "pill")["props"]["options"]
        self.assertEqual(options, [{"value": "a", "label": "A", "selfish": {}}, {"value": "b", "label": "B"}],
                         "Undefined, function, undefined-toJSON and inherited fields are left out of nested values, and toJSON runs once (a self-returning one gives {}).")
        self.assertEqual(self.plugin_node(values["tree"], "pill")["props"]["selected"], "a")
        self.assertEqual(self.plugin_text(self.plugin_node(values["tree"], "picked")), "string b", "An event value arrives as a JavaScript string.")
        circular = self.render_plugin("""
var loop = {}; loop.self = loop;
Playhouse.render(h(PillPicker, { selected: "a", options: [{ value: "a", label: "A", extra: loop }] }));
""", expected_status=1)
        self.assertTrue(any("circular" in error for error in circular["result"]["errors"]), f"A circular prop is reported: {circular['result']['errors']}")
        out_of_range = self.render_plugin('__native.commit([{ op: "createText", id: 1e300, text: "x" }]);', expected_status=1)
        self.assertTrue(any("Invalid commit" in error and "integer" in error for error in out_of_range["result"]["errors"]),
                        f"An op whose node id is out of range is reported, not a crash: {out_of_range['result']['errors']}")

        for page in ["AgentsInfo", "Button", "Card", "ChoiceBar", "Composer", "Disclosure", "Divider", "DoneArchive", "Editor", "Icon", "Label", "Link", "Menu", "Meter", "Modal", "Overlay",
                     "KanbanColumn", "Page", "Panel", "PillPicker", "Popover", "PressArea", "RepositoryChips", "Scroll", "Segmented", "SidePanel", "SkillsPage", "Spacer", "Spinner", "Stack", "StepSlider",
                     "TaskItem", "Text", "TextField", "Toggle", "TokenStats"]:
            page_render = self.assert_success(self.call_cli("plugin", "render", "--page", page)[0])
            self.assertEqual(page_render["errors"], [], f"The {page} catalog page renders without errors.")
            used = {node["type"] for node in self.plugin_nodes(page_render["tree"])}
            if page not in ("TaskItem", "AgentsInfo", "TokenStats", "SkillsPage", "RepositoryChips", "Composer", "KanbanColumn", "DoneArchive"):
                self.assertIn(page, used, f"The {page} page shows its atom.")
        disclosure = self.assert_success(self.call_cli("plugin", "render", "--page", "Disclosure", "--event", "disclosure-demo:onToggle")[0])
        section = self.plugin_node(disclosure["tree"], "disclosure-demo")
        state = self.plugin_node(disclosure["tree"], "disclosure-state")
        self.assertTrue(section["props"]["collapsed"], "The Disclosure page's onToggle collapsed it.")
        self.assertEqual(self.plugin_text(state), "Collapsed")
        self.plugin_node(disclosure["tree"], "disclosure-first")
        self.assertEqual(sorted(disclosure["commits"][-1]["ops"]), ["text", "update"], "Collapsing keeps the children in the tree: the Disclosure's props and the readout change.")
        self.assertEqual(set(disclosure["commits"][-1]["touchedNodes"]), {section["id"], state["children"][0]["id"]})
        chosen = self.assert_success(self.call_cli("plugin", "render", "--page", "ChoiceBar", "--event", "choice-bar:onChange:wasters")[0])
        bar = self.plugin_node(chosen["tree"], "choice-bar")
        selected = self.plugin_node(chosen["tree"], "choice-selected")
        self.assertEqual(bar["events"], ["onChange"])
        self.assertEqual(bar["props"]["selected"], "wasters", "The ChoiceBar page's onChange selected the chosen value.")
        self.assertEqual([option["testID"] for option in bar["props"]["options"]], ["choice-overview", "choice-wasters", "choice-tools"])
        self.assertEqual(self.plugin_text(selected), "Selected: wasters")
        self.assertEqual(sorted(chosen["commits"][-1]["ops"]), ["text", "update"], "Choosing updates only the ChoiceBar's props and the readout.")
        self.assertEqual(set(chosen["commits"][-1]["touchedNodes"]), {bar["id"], selected["children"][1]["id"]})
        same = self.assert_success(self.call_cli("plugin", "render", "--page", "ChoiceBar", "--event", "choice-bar:onChange:overview")[0])
        self.assertEqual(len(same["commits"]), 1, "Choosing the option already selected commits nothing.")
        scrolled = self.assert_success(self.call_cli("plugin", "render", "--page", "Scroll", "--event", "scroll-add:onPress")[0])
        scroll = self.plugin_node(scrolled["tree"], "scroll-demo")
        self.assertEqual((scroll["type"], scroll["props"]["maxHeight"]), ("Scroll", 120))
        self.assertEqual(len([child for child in scroll["children"] if child["type"] == "Text"]), 8, "Adding rows puts them inside the Scroll.")
        self.assertEqual(self.plugin_text(self.plugin_node(scrolled["tree"], "scroll-count")), "8 rows")
        paged = self.assert_success(self.call_cli("plugin", "render", "--page", "Scroll", "--event", "scroll-paged:onEndReached", "--event", "scroll-paged:onEndReached")[0])
        self.assertEqual(paged["errors"], [])
        paged_scroll = self.plugin_node(paged["tree"], "scroll-paged")
        self.assertEqual((paged_scroll["props"]["lazy"], paged_scroll["events"]), (True, ["onEndReached"]))
        self.assertEqual(len(paged_scroll["children"]), 60, "Each onEndReached appends a 20-row page.")
        self.assertEqual(self.plugin_text(self.plugin_node(paged["tree"], "scroll-pages")), "3 pages loaded")
        for step in [entry for entry in paged["commits"] if entry["step"] == "scroll-paged:onEndReached"]:
            self.assertIn("text", step["ops"], "Each page changes the readout.")
            self.assertEqual(step["ops"].count("create"), 20, "Each page creates its 20 rows.")
        toggled = self.assert_success(self.call_cli("plugin", "render", "--page", "Toggle", "--event", "toggle-demo:onToggle")[0])
        switch = self.plugin_node(toggled["tree"], "toggle-demo")
        state = self.plugin_node(toggled["tree"], "toggle-state")
        self.assertEqual((switch["events"], switch["props"]["isOn"], switch["props"]["size"]), (["onToggle"], False, "mini"), "onToggle flipped the switch off.")
        self.assertEqual(self.plugin_text(state), "Off")
        self.assertEqual(sorted(toggled["commits"][-1]["ops"]), ["text", "update"], "Toggling updates only the Toggle's props and the readout.")
        self.assertEqual(set(toggled["commits"][-1]["touchedNodes"]), {switch["id"], state["children"][0]["id"]})
        typed = self.assert_success(self.call_cli("plugin", "render", "--page", "TextField", "--event", "text-field-demo:onChange:release")[0])
        field = self.plugin_node(typed["tree"], "text-field-demo")
        self.assertEqual((sorted(field["events"]), field["props"]["text"], field["props"]["placeholder"]), (["onArrow", "onChange", "onSubmit"], "release", "Search skills"))
        self.assertEqual(self.plugin_text(self.plugin_node(typed["tree"], "text-field-value")), "Text: release", "onChange received the new text.")
        plain = self.assert_success(self.call_cli("plugin", "render", "--page", "TextField", "--event", "text-field-plain:onChange:quiet")[0])
        plain_field = self.plugin_node(plain["tree"], "text-field-plain")
        self.assertEqual((plain_field["props"]["style"], plain_field["props"]["text"], plain_field["events"]), ("plain", "quiet", ["onChange"]))
        self.assertEqual(self.plugin_node(plain["tree"], "text-field-plain-box")["props"]["cornerRadius"], 9, "The plain field sits on a rounded Stack.")
        self.assertEqual(self.plugin_text(self.plugin_node(plain["tree"], "text-field-plain-value")), "Plain: quiet", "The plain field's onChange ran its handler.")
        keyed = self.assert_success(self.call_cli("plugin", "render", "--page", "TextField", "--event", "text-field-demo:onArrow:down")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(keyed["tree"], "text-field-key")), "Key: down", "onArrow received the arrow's direction.")
        submitted = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "TextField", "--event", "text-field-demo:onArrow:up", "--event", "text-field-demo:onSubmit")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(submitted["tree"], "text-field-key")), "Key: return", "Return ran onSubmit.")
        overlay = self.assert_success(self.call_cli("plugin", "render", "--page", "Overlay", "--event", "overlay-badge:onPress")[0])
        stacked = self.plugin_node(overlay["tree"], "overlay-demo")
        self.assertEqual((stacked["props"]["align"], stacked["props"]["offsetX"], stacked["props"]["offsetY"]), ("topTrailing", 6, -6))
        self.assertEqual([child["props"].get("testID") for child in stacked["children"]], ["overlay-base", "overlay-badge"], "The base first, then what sits over it.")
        self.assertEqual(self.plugin_text(self.plugin_node(overlay["tree"], "overlay-count")), "Pressed the badge 1 times", "The badge runs its own onPress.")
        self.assertEqual(overlay["commits"][-1]["ops"], ["text"], "Pressing the badge changes only the readout.")
        segmented = self.assert_success(self.call_cli("plugin", "render", "--page", "Segmented", "--event", "segmented-demo:onChange:global")[0])
        picker = self.plugin_node(segmented["tree"], "segmented-demo")
        self.assertEqual((picker["events"], picker["props"]["selected"]), (["onChange"], "global"))
        self.assertEqual([option["label"] for option in picker["props"]["options"]], ["Repo", "Global", "Built-in"])
        self.assertEqual(self.plugin_text(self.plugin_node(segmented["tree"], "segmented-selected")), "Selected: global")
        menu = self.assert_success(self.call_cli("plugin", "render", "--page", "Menu", "--event", "menu-demo:onMenu:delete")[0])
        demo_menu = self.plugin_node(menu["tree"], "menu-demo")
        self.assertEqual((demo_menu["events"], demo_menu["props"]["icon"]), (["onMenu"], "ellipsis"))
        self.assertEqual([[item["id"] for item in group] for group in demo_menu["props"]["items"]], [["edit", "reveal", "busy"], [], ["delete"]])
        busy = demo_menu["props"]["items"][0][2]
        self.assertEqual((busy["title"], busy["disabled"], busy["testID"]), ("Run Now", True, "menu-disabled"), "A Menu item can be disabled.")
        self.assertEqual(self.plugin_text(self.plugin_node(menu["tree"], "menu-chosen")), "Chosen: delete", "onMenu received the item's id.")
        pressed_area = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "PressArea", "--event", "press-area-demo:onPress", "--event", "press-area-demo:onLongPress", "--event", "press-area-demo:onLongPress")[0])
        area = self.plugin_node(pressed_area["tree"], "press-area-demo")
        self.assertEqual((sorted(area["events"]), area["props"]["pointer"]), (["onLongPress", "onPress"], True))
        self.assertEqual(self.plugin_text(self.plugin_node(pressed_area["tree"], "press-area-count")), "Clicked 1 · held 2",
                         "A click and a press and hold reach different handlers.")
        pressed = self.assert_success(self.call_cli("plugin", "render", "--page", "Button", "--event", "button-plain:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(pressed["tree"], "button-press-count")), "Pressed 1 times")
        self.assertEqual(pressed["commits"][-1]["ops"], ["text"], "The Button page's press is one text op.")
        link_button = self.plugin_node(pressed["tree"], "button-link")
        self.assertEqual((link_button["type"], link_button["props"]["style"], link_button["events"]), ("Button", "link", ["onPress"]), "A Button can look like a link.")
        large_button = self.plugin_node(pressed["tree"], "button-large")
        self.assertEqual((large_button["props"]["controlSize"], large_button["children"][0]["type"]), ("large", "Label"), "A Button can be a large control.")
        icons = self.assert_success(self.call_cli("plugin", "render", "--page", "Icon")[0])
        self.assertEqual(icons["errors"], [])
        logo = self.plugin_node(icons["tree"], "icon-asset-original")
        self.assertEqual((logo["props"]["asset"], logo["props"]["original"], logo["props"]["width"]), ("PlayhouseLogo", True, 50), "An Icon can draw an asset in its own colors.")
        self.assertNotIn("original", self.plugin_node(icons["tree"], "icon-asset")["props"], "A template asset leaves original unset.")

        exploded = self.render_plugin(plugin, "--event", "explode:onPress", expected_status=1)
        self.assertTrue(any("Kaboom" in error for error in exploded["result"]["errors"]), "A handler that throws is reported.")
        for source, message in [
            ('Playhouse.render(h("Div"));', "Unknown atom <Div>"),
            ('Playhouse.render(h(Stack, { bogus: 1 }));', '<Stack> has no prop "bogus"'),
            ('Playhouse.render(h(Text, { size: "large" }, "x"));', "<Text> has an invalid prop: size: expected a number, found a string"),
            ('Playhouse.render(h(Text, { lineLimit: 1.5 }, "x"));', "<Text> has an invalid prop: lineLimit: expected a whole number, found 1.5"),
            ('Playhouse.render(h(PillPicker, { selected: "a", options: [{ value: "a" }] }));', "<PillPicker> has an invalid prop: options.0.label: missing"),
            ('Playhouse.render(h(Stack, null, "loose"));', "must be inside a <Text> atom"),
            ('Playhouse.render(h(Label, { icon: "clock" }));', "<Label> has an invalid prop: text: missing"),
            ('Playhouse.render(h(Meter, { color: "red" }));', "<Meter> has an invalid prop: fraction: missing"),
            ('Playhouse.render(h(Disclosure, { title: "x", collapsed: "no" }));', "<Disclosure> has an invalid prop: collapsed: expected a boolean, found a string"),
            ('Playhouse.render(h(ChoiceBar, { options: [{ value: "a", label: "A" }] }));', "<ChoiceBar> has an invalid prop: selected: missing"),
            ('Playhouse.render(h(Scroll, { maxHeight: "tall" }));', "<Scroll> has an invalid prop: maxHeight: expected a number, found a string"),
            ('Playhouse.render(h(Divider, { axis: "v" }));', '<Divider> has no prop "axis"'),
            ('Playhouse.render(h(Icon, { asset: "PlayhouseLogo", original: "yes" }));', "<Icon> has an invalid prop: original: expected a boolean, found a string"),
            ('Playhouse.render(h(Menu, { items: [[{ id: "a", title: "A", disabled: 1 }]] }));', "<Menu> has an invalid prop: items.0.0.disabled: expected a boolean, found 1"),
            ('Playhouse.render(h(Divider, null, h(Text, null, "x")));', "<Divider> can't hold <Text>"),
            ('Playhouse.render(h(Toggle, { size: "mini" }));', "<Toggle> has an invalid prop: isOn: missing"),
            ('Playhouse.render(h(TextField, { text: 3 }));', "<TextField> has an invalid prop: text: expected a string, found 3"),
            ('Playhouse.render(h(Segmented, { options: [{ value: "a", label: "A" }], selected: "a", onToggle: function () {} }));', '<Segmented> has no event "onToggle"'),
            ('Playhouse.render(h(Menu, { icon: "ellipsis", items: [{ id: "a", title: "A" }] }));', "<Menu> has an invalid prop: items.0"),
            ('Playhouse.render(h(Toggle, { isOn: true }, h(Text, null, "x")));', "<Toggle> can't hold <Text>"),
            ('Playhouse.render(h(Stack, { onTap: function () {} }));', '<Stack> has no event "onTap"'),
            ('Playhouse.render(h(Icon, { name: "clock" }, h(Text, null, "x")));', "<Icon> can't hold <Text>"),
        ]:
            failed = self.render_plugin(source, expected_status=1)
            self.assertTrue(failed["ok"], "A plugin that fails still reports its render.")
            self.assertTrue(any(message in error for error in failed["result"]["errors"]), f"{source} reports {message}: {failed['result']['errors']}")
        self.assert_failure(self.render_plugin(plugin, "--event", "missing:onPress", expected_status=2), "invalid_argument")
        self.assert_failure(self.render_plugin(plugin, "--event", "label:onPress", expected_status=2), "invalid_argument")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "NoSuchPage", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_stack_surface_composes_panel_and_choice_bar | The Plugin Catalog's Stack page draws a surface on a Stack in both axes, while its Stacks without surface props draw nothing: a column filled accent at 0.18 with an accent border and an 8-point radius keeps its children at its top leading corner, inside its padding, when its 220-point minWidth and 90-point minHeight are larger than they are; a capsule row filled #2E7D32 with a dashed border lays its icon and text out side by side on that green; and a border-only Stack with align unset (a Stack's default, center) and fillWidth stretches across the page, draws its border and no fill with rounded corners, and keeps its text centered both ways in its 60-point minHeight. The Panel page shows each Panel beside the Stack it is shorthand for (a column Stack with group, fill primary at 0.05, radius 8 and padding 12 unless set), and each pair is the same size, including a Panel with no padding prop beside a Stack padded 12, including the accent Log in Panel and the single decorated row Stack that replaces its nested row. `plugin render` reports the surface props on those nodes with no errors and none on the plain Stacks, and a mistyped surface prop on a Stack (fill, fillOpacity, cornerRadius, capsule, strokeWidth or dash) or an unknown one (shadow, or axis on a Panel) is reported in errors with exit 1, naming the prop and what is wrong. The ChoiceBar page also composes the bar from atoms, a decorated row Stack of Buttons each marked selected (the Button's selected prop) around a decorated Stack with a Text: it is the same size as the ChoiceBar atom beside it, its Overview button carries the selected trait, and clicking Wasters runs its onPress, which moves the selected trait to it (Composed: wasters) while the ChoiceBar atom stays on Overview; a mistyped selected on a Button is reported with its path.
    def test_plugin_stack_surface_composes_panel_and_choice_bar(self):
        surface_keys = {"fill", "fillOpacity", "cornerRadius", "capsule", "stroke", "strokeOpacity", "strokeWidth", "dash"}
        stacks = self.assert_success(self.call_cli("plugin", "render", "--page", "Stack")[0])
        self.assertEqual(stacks["errors"], [])
        tree = stacks["tree"]
        for plain in ["stack-column", "stack-row", "stack-group", "stack-fill"]:
            self.assertEqual(set(self.plugin_node(tree, plain)["props"]) & surface_keys, set(), f"{plain} draws nothing.")
        column = self.plugin_node(tree, "stack-surface-column")
        self.assertEqual((column["type"], column["props"]["axis"], column["props"]["align"], column["props"]["fill"], column["props"]["fillOpacity"],
                          column["props"]["cornerRadius"], column["props"]["stroke"], column["props"]["minWidth"], column["props"]["minHeight"], column["props"]["padding"]),
                         ("Stack", "v", "leading", "accent", 0.18, 8, "accent", 220, 90, 8), "A column Stack can be filled, rounded and bordered.")
        self.assertEqual(column["children"][0]["props"]["testID"], "stack-surface-column-first")
        row = self.plugin_node(tree, "stack-surface-row")
        self.assertEqual((row["type"], row["props"]["axis"], row["props"]["fill"], row["props"]["capsule"], row["props"]["dash"], row["props"]["strokeOpacity"]),
                         ("Stack", "h", "#2E7D32", True, [4, 3], 0.3), "A row Stack can be a filled capsule with a dashed border.")
        self.assertEqual([child["type"] for child in row["children"]], ["Icon", "Text"], "The row lays its children out itself, with no nested Stack.")
        center = self.plugin_node(tree, "stack-surface-center")
        self.assertEqual((center["props"]["strokeWidth"], center["props"]["fillWidth"], center["props"]["minHeight"]), (2, True, 60))
        self.assertNotIn("align", center["props"], "The border-only Stack leaves align at its default, center.")
        self.assertNotIn("fill", center["props"], "A border alone draws no fill.")

        panels = self.assert_success(self.call_cli("plugin", "render", "--page", "Panel")[0])
        self.assertEqual(panels["errors"], [])
        tree = panels["tree"]
        panel_defaults = {"fill": "primary", "fillOpacity": 0.05, "cornerRadius": 8, "padding": 12}
        self.assertNotIn("padding", self.plugin_node(tree, "panel-padded")["props"], "The padded Panel sets no padding: 12 is its default.")
        for name in ["panel-padded", "panel-default", "panel-capsule"]:
            panel = self.plugin_node(tree, name)
            stack = self.plugin_node(tree, f"{name}-stack")
            self.assertEqual((panel["type"], stack["type"], stack["props"]["axis"], stack["props"]["align"], stack["props"]["group"]), ("Panel", "Stack", "v", "leading", True))
            expected = {**panel_defaults, **{key: value for key, value in panel["props"].items() if key != "testID"}}
            if expected.get("capsule"):
                expected.pop("cornerRadius")
            actual = {key: value for key, value in stack["props"].items() if key not in ("testID", "axis", "align", "group")}
            self.assertEqual(actual, expected, f"{name} is the column Stack with the Panel's defaults.")
            self.assertEqual([self.plugin_text(child) for child in stack["children"]], [self.plugin_text(child) for child in panel["children"]])
        accent = self.plugin_node(tree, "panel-accent")
        accent_row = self.plugin_node(tree, "panel-accent-stack")
        self.assertEqual([child["type"] for child in accent["children"]], ["Stack"], "The Panel needs a nested row.")
        self.assertEqual((accent_row["props"]["axis"], [child["type"] for child in accent_row["children"]]), ("h", ["Spacer", "Text", "Spacer"]),
                         "A decorated row Stack lays the Log in row out with no nesting.")
        self.assertEqual({key: accent_row["props"][key] for key in ("fill", "fillOpacity", "cornerRadius", "width", "padding")},
                         {key: accent["props"][key] for key in ("fill", "fillOpacity", "cornerRadius", "width", "padding")})

        # The ChoiceBar composite, composed from a decorated row Stack of Buttons marked selected.
        composed = self.assert_success(self.call_cli("plugin", "render", "--page", "ChoiceBar", "--event", "choice-composed-wasters:onPress")[0])
        self.assertEqual(composed["errors"], [])
        bar = self.plugin_node(composed["tree"], "choice-bar-composed")
        self.assertEqual((bar["type"], bar["props"]["axis"], bar["props"]["fill"], bar["props"]["fillOpacity"], bar["props"]["cornerRadius"], bar["props"]["group"]),
                         ("Stack", "h", "primary", 0.06, 7, True))
        buttons = [self.plugin_node(composed["tree"], f"choice-composed-{value}") for value in ("overview", "wasters", "tools")]
        self.assertEqual([(button["type"], button["props"]["selected"]) for button in buttons], [("Button", False), ("Button", True), ("Button", False)],
                         "Pressing Wasters marks its Button selected.")
        self.assertEqual([(button["children"][0]["type"], button["children"][0]["props"]["fillOpacity"]) for button in buttons],
                         [("Stack", 0), ("Stack", 0.2), ("Stack", 0)], "Each option is drawn on a decorated Stack, highlighted when selected.")
        self.assertEqual(self.plugin_text(self.plugin_node(composed["tree"], "choice-composed-selected")), "Composed: wasters")
        self.assertEqual(self.plugin_node(composed["tree"], "choice-bar")["props"]["selected"], "overview", "The ChoiceBar atom keeps its own choice.")

        for source, message in [
            ('Playhouse.render(h(Stack, { fill: 3 }));', "<Stack> has an invalid prop: fill: expected a string, found 3"),
            ('Playhouse.render(h(Stack, { axis: "h", fillOpacity: "high" }));', "<Stack> has an invalid prop: fillOpacity: expected a number, found a string"),
            ('Playhouse.render(h(Stack, { cornerRadius: true }));', "<Stack> has an invalid prop: cornerRadius: expected a number, found a boolean"),
            ('Playhouse.render(h(Stack, { capsule: "yes" }));', "<Stack> has an invalid prop: capsule: expected a boolean, found a string"),
            ('Playhouse.render(h(Stack, { strokeWidth: "2" }));', "<Stack> has an invalid prop: strokeWidth: expected a number, found a string"),
            ('Playhouse.render(h(Stack, { dash: "4" }));', "<Stack> has an invalid prop: dash: expected an array, found a string"),
            ('Playhouse.render(h(Stack, { dash: [4, "3"] }));', "<Stack> has an invalid prop: dash.1: expected a number, found a string"),
            ('Playhouse.render(h(Stack, { shadow: 4 }));', '<Stack> has no prop "shadow"'),
            ('Playhouse.render(h(Panel, { axis: "h" }));', '<Panel> has no prop "axis"'),
            ('Playhouse.render(h(Button, { selected: "yes" }));', "<Button> has an invalid prop: selected: expected a boolean, found a string"),
        ]:
            failed = self.render_plugin(source, expected_status=1)
            self.assertTrue(any(message in error for error in failed["result"]["errors"]), f"{source} reports {message}: {failed['result']['errors']}")
    # case-contract: test_plugin_task_item_renders_from_atoms_like_native | The Plugin Catalog's Task Item page shows the task item composed in JavaScript from atoms beside the native SwiftUI task item built from the same atoms and sample data: both show the same title, progress report, status message and token counter with the same sizes, and the JavaScript tree uses only atoms with the native card's identifiers and context menu; neither shows a pull-request mode pill, pull-request link, create button or conflicts button, which are task card plugins and not part of the task item. Blocking the JavaScript item changes only its status message and the toggle's label (one commit: text, update, text on three nodes) while the native item keeps its own state, clicking the JavaScript card runs its onPress handler (Opened 1 times, one text op) without re-rendering the title or the card, and right-clicking the JavaScript card offers the native card's menu, whose Move to Done runs onMenu with its id (Last: menu done). The time row is one flat row: the clock, the created time and the token counter are siblings in one stack, so the time shows in full (Nov 8, 2026), as wide in the JavaScript item as in the native one and left of the counter.
    def test_plugin_task_item_renders_from_atoms_like_native(self):
        task = self.TASK_ITEM_ID
        rendered = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "TaskItem",
            "--event", "js-toggle-blocked:onPress",
            "--event", f"task-card-{task}:onPress")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        # The same identifiers the board's native TaskItemView gives its card.
        for test_id in [f"task-card-{task}", f"task-title-{task}", f"task-progress-report-{task}", f"task-progress-icon-{task}",
                        f"task-progress-label-{task}", f"task-progress-detail-{task}", f"task-status-message-{task}",
                        f"task-token-usage-counter-{task}"]:
            self.plugin_node(tree, test_id)
        self.assertFalse(any(str(node.get("props", {}).get("testID", "")).startswith(("task-pr-mode-", "task-pr-link-", "task-resolve-pr-conflicts-", "task-create-pr-"))
                             for node in self.plugin_nodes(tree)),
                         "The pull request controls are task card plugins, not part of the task item.")
        card = self.plugin_node(tree, f"task-card-{task}")
        self.assertEqual(card["type"], "Card")
        self.assertEqual(card["props"]["meterTestID"], f"task-cpu-usage-bar-{task}")
        self.assertEqual([item["testID"] for item in card["props"]["menu"]],
                         ["move-task-to-done-menu-item", "rename-task-menu-item", "token-stats-task-menu-item", "delete-task-menu-item"])
        self.assertEqual(self.plugin_text(self.plugin_node(tree, f"task-progress-label-{task}")), "Building")
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"Card", "Stack", "Text", "Icon", "Button"}, "The task item is atoms only.")
        # The clock, time and counter share one row, as TaskItemView builds it.
        created = self.plugin_node(tree, f"task-created-time-{task}")
        self.assertEqual(self.plugin_text(created), "Nov 8, 2026")
        counter = self.plugin_node(tree, f"task-token-usage-counter-{task}")
        time_row = next(node for node in self.plugin_nodes(tree) if any(child["id"] == counter["id"] for child in node.get("children", [])))
        self.assertEqual(time_row["type"], "Stack")
        self.assertEqual([(child["type"], child.get("props", {}).get("testID")) for child in time_row["children"]],
                         [("Icon", None), ("Text", f"task-created-time-{task}"), ("Button", f"task-token-usage-counter-{task}")],
                         "The clock, the time and the counter are siblings in one flat row.")

        status = self.plugin_node(tree, f"task-status-message-{task}")
        self.assertEqual(self.plugin_text(status), "Blocked: 2 checks failing")
        self.assertEqual(status["props"]["color"], "red")
        toggle_label = self.plugin_node(tree, "js-toggle-blocked")["children"][0]
        self.assertEqual(self.plugin_text(toggle_label), "Unblock")
        commits = {commit["step"]: commit for commit in rendered["commits"]}
        blocked = commits["js-toggle-blocked:onPress"]
        self.assertEqual(sorted(blocked["ops"]), ["text", "text", "update"], "Blocking re-renders only the status message and the toggle's label.")
        self.assertEqual(set(blocked["touchedNodes"]), {status["id"], status["children"][0]["id"], toggle_label["children"][0]["id"]})

        opened = commits[f"task-card-{task}:onPress"]
        opened_count = self.plugin_node(tree, "js-opened-count")
        self.assertEqual(self.plugin_text(opened_count), "Opened 1 times", "The card's onPress ran in JavaScript.")
        self.assertEqual(opened["ops"], ["text"])
        self.assertEqual(opened["touchedNodes"], [opened_count["children"][1]["id"]])

        self.assertEqual(self.plugin_node(tree, f"task-title-{task}")["updates"], 0, "The title never re-rendered.")
        self.assertEqual(card["updates"], 0, "The card's own props never changed.")

        menu = self.assert_success(self.call_cli("plugin", "render", "--page", "TaskItem", "--event", f"task-card-{task}:onMenu:done")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(menu["tree"], "js-last-action")), "Last: menu done", "A menu item runs onMenu with its id.")
        self.assertEqual(menu["commits"][-1]["ops"], ["text"])
        self.assert_failure(self.call_cli("plugin", "render", "--page", "TaskItem", "--event", f"task-title-{task}:onPress", expected_status=2)[0], "invalid_argument")
    # case-contract: test_plugin_agents_info_renders_from_atoms_like_native | The Plugin Catalog's Agents Info page shows the Agents info section composed in JavaScript from atoms beside the native SwiftUI section the board uses, built from the same atoms and sample data: both show the Agents info title button (Expanded), a Claude block above a Codex block with the same account and plan rows, window rows (label, percent, usage bar and reset time), Codex's credits, its Near limit status and the updated hints, each at the same size in both, and the JavaScript tree uses only atoms (Disclosure, Panel, Meter, Stack, Text, Icon, Button, Spacer) with the board section's identifiers. Collapsing is the Disclosure atom's own: clicking the JavaScript title runs onToggle, whose state change is one commit that updates only the Disclosure's props and the readout (Last: collapse) while the blocks stay in the tree, the JavaScript blocks go away and its title reads Collapsed while the native section stays open, the native title collapses its own section to the same size, and expanding brings the blocks back (Last: expand). Signing Claude out in the JavaScript example replaces its window rows with a Log in button the same size as the native one, whose onPress runs in JavaScript (Last: login claude) and brings the rows back, and Codex's switch-account button runs its JavaScript handler with its provider (Last: switch codex) without re-rendering any block.
    def test_plugin_agents_info_renders_from_atoms_like_native(self):
        rendered = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "AgentsInfo",
            "--event", "agents-info:onToggle",
            "--event", "agents-info-switch-codex:onPress")[0])
        self.assertEqual(rendered["errors"], [])
        tree = rendered["tree"]
        # The same identifiers the board's native AgentsInfoSection gives its section.
        for test_id in ["agents-info", "agents-info-claude", "agents-info-claude-account", "agents-info-switch-claude",
                        "agents-info-claude-window-five_hour", "agents-info-claude-window-seven_day", "agents-info-claude-updated",
                        "agents-info-codex", "agents-info-codex-account", "agents-info-switch-codex", "agents-info-codex-window-overage",
                        "agents-info-codex-credits", "agents-info-codex-status", "agents-info-codex-updated"]:
            self.plugin_node(tree, test_id)
        types = {node["type"] for node in self.plugin_nodes(tree)} - {"#root", "#text"}
        self.assertEqual(types, {"Disclosure", "Panel", "Meter", "Stack", "Text", "Icon", "Button", "Spacer"}, "The Agents info section is atoms only.")
        section = self.plugin_node(tree, "agents-info")
        self.assertEqual(section["type"], "Disclosure")
        self.assertEqual(section["events"], ["onToggle"])
        self.assertEqual((section["props"]["title"], section["props"]["toggleTestID"]), ("Agents info", "agents-info-toggle"))
        self.assertTrue(section["props"]["collapsed"], "onToggle collapsed the section.")
        blocks = [child for child in section["children"] if child["type"] == "Panel"]
        self.assertEqual([block["props"]["testID"] for block in blocks], ["agents-info-claude", "agents-info-codex"],
                         "Collapsed, the blocks stay in the tree; the Disclosure atom hides them.")
        claude = self.plugin_node(tree, "agents-info-claude")
        self.assertEqual((claude["props"]["spacing"], claude["props"]["padding"], claude["props"]["fillWidth"]), (4, 8, True))
        account = self.plugin_node(tree, "agents-info-claude-account")
        self.assertEqual(self.plugin_text(account), "claude@example.com Team")
        self.assertEqual((account["props"]["truncation"], account["props"]["help"]), ("middle", "claude@example.com · Team"))
        window = self.plugin_node(tree, "agents-info-claude-window-five_hour")
        self.assertEqual(window["type"], "Stack")
        self.assertTrue(window["props"]["combine"], "A window row is one accessibility element, as on the board.")
        self.assertEqual([child["type"] for child in window["children"]], ["Stack", "Meter", "Text"], "Label and percent, the bar, then the reset time.")
        label_row, meter, reset = window["children"]
        self.assertEqual([self.plugin_text(child) for child in label_row["children"] if child["type"] == "Text"], ["5h", "5%"])
        self.assertEqual((meter["props"]["fraction"], meter["props"]["color"]), (0.05, "accent"))
        self.assertEqual(self.plugin_text(reset), "Resets in 3h 24m")
        spend = self.plugin_node(tree, "agents-info-codex-window-overage")
        self.assertEqual(spend["children"][1]["props"]["color"], "orange", "A window near its limit has an orange bar.")
        status = self.plugin_node(tree, "agents-info-codex-status")
        self.assertEqual((self.plugin_text(status), status["props"]["color"]), ("Near limit", "orange"))
        self.assertEqual(self.plugin_text(self.plugin_node(tree, "agents-info-codex-credits")), "Credits available")

        commits = {commit["step"]: commit for commit in rendered["commits"]}
        last_action = self.plugin_node(tree, "js-last-action")
        toggled = commits["agents-info:onToggle"]
        self.assertEqual(sorted(toggled["ops"]), ["text", "update"], "Collapsing updates only the Disclosure's props and the readout.")
        self.assertEqual(set(toggled["touchedNodes"]), {section["id"], last_action["children"][1]["id"]})
        switched = commits["agents-info-switch-codex:onPress"]
        self.assertEqual(self.plugin_text(last_action), "Last: switch codex", "The switch-account button ran its JavaScript handler with its provider.")
        self.assertEqual(switched["ops"], ["text"])
        self.assertEqual(switched["touchedNodes"], [last_action["children"][1]["id"]])
        for block in blocks:
            self.assertEqual(block["updates"], 0, "No block re-rendered.")

        expanded = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "AgentsInfo", "--event", "agents-info:onToggle", "--event", "agents-info:onToggle")[0])
        self.assertFalse(self.plugin_node(expanded["tree"], "agents-info")["props"]["collapsed"], "A second toggle expands it again.")
        self.assertEqual(self.plugin_text(self.plugin_node(expanded["tree"], "js-last-action")), "Last: expand")

        signed_out = self.assert_success(self.call_cli("plugin", "render", "--page", "AgentsInfo", "--event", "js-toggle-signed-out:onPress")[0])
        test_ids = {node.get("props", {}).get("testID") for node in self.plugin_nodes(signed_out["tree"])}
        self.assertIn("agents-info-login-claude", test_ids, "A signed-out Claude shows Log in.")
        self.assertNotIn("agents-info-claude-window-five_hour", test_ids, "A signed-out agent shows no usage.")
        login = self.plugin_node(signed_out["tree"], "agents-info-login-claude")
        self.assertEqual((login["type"], login["props"]["label"]), ("Button", "Log in to Claude"))
        self.assertEqual(login["children"][0]["type"], "Panel")
        logged_in = self.assert_success(self.call_cli(
            "plugin", "render", "--page", "AgentsInfo", "--event", "js-toggle-signed-out:onPress", "--event", "agents-info-login-claude:onPress")[0])
        self.assertEqual(self.plugin_text(self.plugin_node(logged_in["tree"], "js-last-action")), "Last: login claude", "Log in ran its JavaScript handler.")
        self.plugin_node(logged_in["tree"], "agents-info-claude-window-five_hour")
        self.assert_failure(self.call_cli("plugin", "render", "--page", "AgentsInfo", "--event", "agents-info:onPress", expected_status=2)[0], "invalid_argument")

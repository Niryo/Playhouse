"""OpenCode provider cases: Playhouse drives the OpenCode server fixture through the real daemon."""
from test_bridge_support import *
from test_bridge_support import __file__


class BridgeTestCases31:
    OPENCODE_AGENT_LISTENER = r"""
Playhouse.service.on("agent.finished", function (e) { return Playhouse.setState("finished", { status: e.status, result: e.result, error: e.error }); });
"""

    # Files each run on the board: the structured result's title, or why the run failed.
    OPENCODE_SCHEMA_LISTENER = r"""
Playhouse.service.on("agent.finished", async function (e) {
  var title = e.status === "done" ? e.result.title : "Schema run " + e.status + ": " + e.error;
  await Playhouse.bridge("task.create", { title: title, prompt: "Filed by the OpenCode agent.", roots: [], repositories: [] });
  return Playhouse.setState("finished", { status: e.status, result: e.result, error: e.error });
});
"""

    def opencode_fixture(self, name):
        executable = self.install_provider_fixture("opencode", name)
        return executable, {"PLAYHOUSE_E2E_OPENCODE_EXECUTABLE": str(executable)}

    def opencode_records(self, executable, kind):
        return self.jsonl(f"{executable}.{kind}")

    def opencode_sessions(self, executable):
        path = Path(f"{executable}.sessions.json")
        return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}

    def opencode_requests(self, executable, method, path_suffix):
        return [r for r in self.opencode_records(executable, "methods") if r["method"] == method and r["path"].endswith(path_suffix)]

    def opencode_servers(self):
        return [m for kind, _, m in self.agent_manifests() if kind == "opencode"]

    # case-contract: test_opencode_turn_runs_tools_and_resumes_session | An OpenCode task lists the models OpenCode's server offers the task's folder once its list settles, never the built-in models OpenCode lists briefly while it loads, after the picker's own Default, without creating a session, and its selected model and effort reach the session, with Extra High asking for the model's strongest variant, high. A turn runs on the one `opencode serve` every task shares, started on a loopback port behind a password with OpenCode's self-update turned off and no skill, rule or MCP configuration of Playhouse's (no inline config, no config file, its Claude Code compatibility left on): the session works in the task's working folder, the task's other roots are allowed to it as external directories, and Playhouse's task instructions reach OpenCode as a session instruction entry, writing nothing into the repository, while code mode adds no permission rules over the user's own. The turn's commentary, shell and edit tool rows, real file edit and final answer are recorded, and the tokens of every step are added to the task's usage. The task keeps the OpenCode session ID, a second turn prompts that same session on the same server without handoff context or a new session, and a plan-mode turn runs OpenCode's plan agent. With automatic compaction on, switching a large session's model compacts it first through OpenCode's own compaction, recorded as an automatic compaction row and as the compaction in the task's token map. Playhouse passes OpenCode none of the gallery: a global rule OpenCode doesn't read itself isn't added to the session's instructions, and a skill turned off in Playhouse or a repository's .mcp.json server adds no permission rule or server, while the skills and `opencode.json` MCP servers of the task's working folder are what OpenCode finds itself. The @ mention menu lists an agent from .opencode/agents as an OpenCode agent. In the window the composer offers OpenCode, its model picker lists OpenCode's models with its default shown and saves the one picked, the conversation shows the commentary, the shell and edit rows labelled with their command or file and Completed, and the final answer, the second and plan answers appear after them, and a turn sent from the window carries only Playhouse's task instructions.
    def test_opencode_turn_runs_tools_and_resumes_session(self):
        executable, environment = self.opencode_fixture("opencode-fixture-turns")
        task = self.create_task("OpenCode tools", roots=[self.primary, self.secondary], provider="opencode")
        self.assertEqual(task["conversationProvider"], "opencode")

        # The models come from OpenCode's server, with no session created for them, once its list
        # settles: a list it answers while it loads isn't taken.
        transient = Path(f"{executable}.transient-models")
        transient.touch()
        models = self.assert_success(self.call_cli("conversation", "models", task["id"], extra_environment=environment)[0])
        self.assertFalse(transient.exists(), "OpenCode answered once with only its built-in models.")
        model_ids = [model["id"] for model in models["models"]] if isinstance(models, dict) else [model["id"] for model in models]
        self.assertEqual(model_ids, ["fixture/fast", "fixture/deep"], "The picker adds its own Default.")
        self.assertEqual(self.opencode_sessions(executable), {}, "Reading models creates no OpenCode session.")
        self.assert_success(self.call_cli("conversation", "model", task["id"], "set", "fixture/deep", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "effort", task["id"], "set", "xhigh", extra_environment=environment)[0])

        target = self.primary / "opencode-fixture.txt"
        target.unlink(missing_ok=True)
        try:
            self.assert_success(self.call_cli(
                "conversation", "send", task["id"], "--message", "[[tools]] Update the fixture file.", extra_environment=environment,
            )[0])
            self.assertEqual(target.read_text(encoding="utf-8"), "Written by the OpenCode fixture.\n",
                             "The OpenCode turn's edit tool writes into the task's working folder.")
            after_first = self.task_for(task["id"], environment)
            session_id = after_first["openCodeSessionID"]
            self.assertTrue(session_id and session_id.startswith("ses_fixture"), after_first)
            self.assertIsNone(after_first.get("claudeSessionID"))
            self.assertIsNone(after_first.get("codexThreadID"))

            history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
            assistant = [m for m in history["messages"] if m["role"] == "assistant"]
            self.assertEqual(assistant[-1]["text"], "OpenCode fixture edited opencode-fixture.txt.")
            self.assertIn("Looking at the repository first.", [m["text"] for m in assistant[:-1]],
                          "Text OpenCode wrote before its tool calls is kept as commentary.")
            titles = [activity["title"] for activity in history["activities"]]
            self.assertIn("Running echo fixture-shell", titles)
            self.assertIn("Editing 1 file", titles)
            self.assertTrue(all(activity["status"] == "completed" for activity in history["activities"]
                                if activity["title"] in ("Running echo fixture-shell", "Editing 1 file")), history["activities"])

            first = self.opencode_records(executable, "history")[-1]
            self.assertEqual(first["sessionId"], session_id)
            self.assertEqual(first["mode"], "build")
            self.assertEqual(first["model"], "fixture/deep")
            self.assertEqual(first["effort"], "high", "The fixture's models stop at high, so Extra High asks for high.")
            self.assertEqual(Path(first["cwd"]).resolve(), self.primary.resolve())
            self.assertEqual({Path(p).resolve() for p in first["additionalDirectories"]}, {self.secondary.resolve()},
                             "The task's other roots are allowed to the session as external directories.")
            self.assertEqual(first["instructionKeys"], ["playhouse"])
            self.assertIn(task["id"], first["instructions"], "Playhouse's task instructions reach OpenCode as a session instruction entry.")
            self.assertEqual([r for r in first["permissions"] if r["action"] != "external_directory"], [],
                             "Code mode keeps the user's own OpenCode permission rules.")
            launches = self.opencode_records(executable, "launches")
            launch = launches[-1]
            self.assertEqual(launch["arguments"], ["serve", "--hostname", "127.0.0.1", "--port", "0"])
            self.assertTrue(launch["hasPassword"], "The server is started behind a password.")
            self.assertIsNone(launch["disableClaudeCode"], "OpenCode reads .claude skills and CLAUDE.md itself.")
            self.assertIsNone(launch["disableClaudeCodePrompt"], "OpenCode reads CLAUDE.md itself.")
            self.assertEqual(launch["disableAutoupdate"], "1")
            self.assertIsNone(launch["configFile"], "Playhouse gives the server no config file of its own.")
            self.assertIsNone(launch["inlineConfig"], "Playhouse gives the server no inline config.")
            self.assertFalse((self.primary / "opencode.json").exists())
            self.assertFalse((self.primary / ".opencode").exists())
            servers = self.opencode_servers()
            self.assertTrue(servers and all(server["port"] and server["process"] for server in servers), servers)
            self.assertFalse(any(session_id in server["turns"] for server in servers), "A finished turn leaves no turn on its server.")

            # The second turn prompts the same session on the same server.
            self.assert_success(self.call_cli(
                "conversation", "send", task["id"], "--message", "Anything else?", extra_environment=environment,
            )[0])
            second = self.opencode_records(executable, "history")[-1]
            self.assertEqual(second["sessionId"], session_id)
            self.assertEqual(second["priorTurnCount"], 1)
            self.assertNotIn("<playhouse-handoff-context>", second["prompt"], "A resumed OpenCode session needs no transcript context.")
            self.assertEqual(len(self.opencode_records(executable, "launches")), len(launches), "The second turn reuses the running server.")
            created = len(self.opencode_requests(executable, "POST", "/api/session"))
            deleted = len([r for r in self.opencode_records(executable, "methods") if r["method"] == "DELETE" and r["path"].startswith("/api/session/")])
            self.assertEqual(created - deleted, 1, "Only the task's own session stays in OpenCode's list.")
            history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
            self.assertEqual(history["messages"][-1]["text"], "OpenCode fixture answered in build mode with fixture/deep.")
            reread = self.task_for(task["id"], environment)
            self.assertEqual(reread["openCodeSessionID"], session_id)
            usage = self.assert_success(self.call_cli("task", "token-usage", task["id"], extra_environment=environment)[0])
            opencode_turns = [turn for turn in usage["turns"] if turn["provider"] == "opencode"]
            self.assertEqual([turn["totalTokens"] for turn in opencode_turns], [24000, 12000],
                             "Each OpenCode turn's usage adds up its steps (two in the tools turn) and is recorded once.")

            # Plan mode runs the turn with OpenCode's plan agent.
            self.assert_success(self.call_cli(
                "conversation", "send", task["id"], "--message", "Plan the next change.", "--mode", "plan", extra_environment=environment,
            )[0])
            planned = self.opencode_records(executable, "history")[-1]
            self.assertEqual(planned["mode"], "plan")
            history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
            self.assertEqual(history["messages"][-1]["text"], "OpenCode fixture answered in plan mode with fixture/deep.")

            # Switching the model of a large session compacts it with OpenCode's own summary first.
            self.assert_success(self.call_cli("settings", "set-auto-compaction", "--enabled", "true", "--minimum", "10000", extra_environment=environment)[0])
            self.assert_success(self.call_cli("conversation", "model", task["id"], "set", "fixture/fast", extra_environment=environment)[0])
            self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "After the model switch.", extra_environment=environment)[0])
            self.assertEqual([entry["sessionId"] for entry in self.opencode_records(executable, "compactions")], [session_id])
            history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
            self.assertIn("Context compacted automatically", [activity["title"] for activity in history["activities"]])
            self.assertEqual(history["messages"][-1]["text"], "OpenCode fixture answered in build mode with fixture/fast.")
            waste = self.assert_success(self.call_cli("task", "token-waste", task["id"], extra_environment=environment)[0])
            self.assertEqual([agent["compactions"] for agent in waste["agents"] if agent["id"] == "opencode"], [1],
                             "The token map shows OpenCode's compaction.")
        finally:
            target.unlink(missing_ok=True)
        self.assert_opencode_launch_shares_gallery(environment, executable)

    def assert_opencode_launch_shares_gallery(self, environment, executable):
        """Playhouse passes OpenCode none of the gallery: OpenCode uses what it finds in the
        task's working folder itself."""
        root = self.data_directory / "opencode-shared"
        root.mkdir()
        (root / ".mcp.json").write_text(json.dumps({"mcpServers": {
            "oc-stdio": {"type": "stdio", "command": "node", "args": ["server.js"]},
        }}), encoding="utf-8")
        (root / "opencode.json").write_text(json.dumps({"mcp": {"oc-own": {"type": "local", "command": ["node", "own.js"]}}}), encoding="utf-8")
        (self.skills_home / ".agents").mkdir(parents=True, exist_ok=True)
        (self.skills_home / ".agents" / "AGENTS.md").write_text("Shared OpenCode rule marker.\n", encoding="utf-8")
        self.write_skill(self.skills_codex_home / "skills", "oc-codex-own", "A Codex skill OpenCode doesn't read")
        self.write_skill(root / ".agents" / "skills", "oc-native", "A skill OpenCode reads itself")
        self.write_skill(root / ".claude" / "skills", "oc-off", "A skill turned off in Playhouse")
        (root / ".opencode" / "agents").mkdir(parents=True)
        (root / ".opencode" / "agents" / "oc-planner.md").write_text("---\nname: oc-planner\ndescription: Plans with OpenCode\n---\n\nPlan.\n", encoding="utf-8")
        task = self.create_task("OpenCode shared gallery", roots=[root], provider="opencode")
        mentions = self.assert_success(self.call_cli("mentions", "list", "--task", task["id"], "--query", "oc-planner")[0])
        planner = next(item for item in mentions["items"] if item["id"] == "agent:oc-planner")
        self.assertIn("the OpenCode agent `oc-planner`", planner["reference"])
        self.assertIn(".opencode/agents/oc-planner.md", planner["reference"])
        off_id = self.skills_by_name(self.skill_catalog(task_id=task["id"])["repositories"][0]["skills"])["oc-off"]["id"]
        self.assert_success(self.call_cli("skills", "disable", "--task", task["id"], "--skill", off_id)[0])
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Use the gallery.", extra_environment=environment)[0])
        turn = self.opencode_records(executable, "history")[-1]
        self.assertNotIn("Shared OpenCode rule marker.", turn["instructions"], "A rule OpenCode doesn't read itself isn't added.")
        self.assertEqual(turn["permissions"], [], "A skill turned off in Playhouse adds no rule: OpenCode uses what it finds.")
        self.assertEqual(turn["skills"], ["oc-native", "oc-off"], "OpenCode finds the working folder's skills itself.")
        self.assertEqual(turn["mcp"], {"oc-own": {"type": "local", "command": ["node", "own.js"]}},
                         "OpenCode runs the folder's own opencode.json servers, and none from .mcp.json.")
        self.assertFalse(list(self.data_directory.glob("opencode-runs/shared-config")), "Playhouse writes no OpenCode config.")

    # case-contract: test_opencode_answers_questions_and_side_chat_stays_read_only | A question OpenCode's question tool asks through its form is shown as a structured question and answered through the form with the chosen option or with the user's own text, and OpenCode answers with what it received. In code mode every permission OpenCode asks for is allowed once. A side chat forks the task's OpenCode session into its own session and runs read-only: its session denies edits and asks before every command, so an edit is refused by the rule and shell commands are rejected except the Playhouse CLI's board commands, and the task's own session, status and prompt are left unchanged. In the window the question appears with its choices, the chosen answer and OpenCode's reply show in the conversation, and the side chat's reply reports the read-only decisions.
    def test_opencode_answers_questions_and_side_chat_stays_read_only(self):
        executable, environment = self.opencode_fixture("opencode-fixture-questions")
        task = self.create_task("OpenCode questions", roots=[self.primary], provider="opencode")
        # A question OpenCode's question tool asks takes the user's answer through its form.
        asked_response, asked_events = self.call_cli(
            "conversation", "send", task["id"], "--message", "[[question]] Pick a color.",
            "--answer", "question-1=Blue", extra_environment=environment,
        )
        self.assert_success(asked_response)
        self.assertFalse([e for e in asked_events if e.get("type") == "action_notice"],
                         "A question is not an approval Playhouse denied, so no approval notice streams.")
        asked = self.opencode_records(executable, "history")[-1]
        self.assertEqual(asked["formReply"], {"q0": "Blue"})
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        self.assertEqual(history["messages"][-1]["text"], "OpenCode fixture got the color Blue.")
        self.assert_success(self.call_cli(
            "conversation", "send", task["id"], "--message", "[[question]] Pick another.",
            "--answer", "question-1=Teal", extra_environment=environment,
        )[0])
        custom = self.opencode_records(executable, "history")[-1]
        self.assertEqual(custom["formReply"], {"q0": "Teal"}, "A field that takes the user's own answer gets their text.")

        # Code mode allows what OpenCode asks about, as with the other providers.
        self.assert_success(self.call_cli(
            "conversation", "send", task["id"], "--message", "[[permissions]] Check permissions.", extra_environment=environment,
        )[0])
        self.assertEqual(self.opencode_records(executable, "history")[-1]["permissionDecisions"],
                         {"shell": "once", "cli": "once", "edit": "once"})

        # A side chat forks the session and stays read-only: no edits, and only board commands.
        before = self.task_for(task["id"], environment)
        reply = self.assert_success(self.call_cli(
            "conversation", "side-chat", task["id"], "--selection", "color", "--message", "[[permissions]] Can you edit?",
            extra_environment=environment,
        )[0])
        side = self.opencode_records(executable, "history")[-1]
        self.assertNotEqual(side["sessionId"], before["openCodeSessionID"], "A side chat runs in its own forked OpenCode session.")
        self.assertEqual(side["permissionDecisions"], {"shell": "reject", "cli": "once", "edit": "reject"})
        self.assertIn({"action": "edit", "resource": "*", "effect": "deny"}, side["permissions"])
        self.assertIn({"action": "shell", "resource": "*", "effect": "ask"}, side["permissions"])
        self.assertIn("Permissions: shell=reject, cli=once, edit=reject.", reply["reply"])
        forked = self.opencode_sessions(executable)[side["sessionId"]]
        self.assertEqual(forked["forkedFrom"], before["openCodeSessionID"])
        self.assert_side_chat_leaves_task_alone(task, before, environment)
        self.assertEqual(self.task_for(task["id"], environment)["openCodeSessionID"], before["openCodeSessionID"])
        own = self.opencode_sessions(executable)[before["openCodeSessionID"]]
        self.assertFalse([r for r in own["permissions"] if r["action"] in ("edit", "shell")],
                         "The side chat's read-only rules stay on its own session.")

    # case-contract: test_opencode_steer_and_stop_running_turn | While an OpenCode turn runs, the runtime lists its session, and a steer reaches the running execution through the session's inbox: the steer shows in the conversation below what OpenCode wrote before it, and OpenCode's answer to it ends the turn. Stopping a later running turn interrupts the session, settles the task in Waiting Response with no failure reason, and leaves the shared server running with no turn recorded for the session. While a turn holds a background job OpenCode started, Stop asks for confirmation and declining keeps the turn and its job running; confirming cancels the job through OpenCode's API, settles the task in Waiting Response, and keeps the shared server running. In the window the steered message and its answer appear in order, and Stop ends the held turn with the composer ready again; with a background job running Stop asks first, Keep Running leaves the turn going and Stop All ends it.
    def test_opencode_steer_and_stop_running_turn(self):
        executable, environment = self.opencode_fixture("opencode-fixture-hold")
        task = self.create_task("OpenCode steering", roots=[self.primary], provider="opencode")
        ready = Path(f"{executable}.hold-ready")

        # A steer reaches the running execution through the session's inbox.
        sender = self.start_cli("conversation", "send", task["id"], "--message", "[[hold]] Work for a while.", extra_environment=environment)
        self.wait_for(ready.is_file, "The OpenCode turn holds.")
        session_id = self.task_for(task["id"], environment)["openCodeSessionID"]
        runtime = self.assert_success(self.call_cli("conversation", "runtime", extra_environment=environment)[0])
        self.assertIn(session_id, json.dumps(runtime))
        self.assertTrue(any(session_id in server["turns"] for server in self.opencode_servers()),
                        "The running turn is recorded on its server, for a later daemon.")
        self.assert_success(self.call_cli("conversation", "steer", task["id"], "--message", "Also check the tests.", extra_environment=environment)[0])
        self.assert_success(self.finish_cli(sender, "conversation send", timeout=60)[0])
        steered = self.opencode_records(executable, "history")[-1]
        self.assertEqual(steered["steer"], "Also check the tests.")
        steer_request = self.opencode_requests(executable, "POST", f"/api/session/{session_id}/prompt")[-1]
        self.assertEqual(steer_request["body"].get("delivery"), "steer")
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        texts = [m["text"] for m in history["messages"]]
        self.assertIn("Also check the tests.", texts)
        self.assertEqual(texts[-1], "OpenCode fixture took the steer: Also check the tests.")
        self.assertIn("Holding the OpenCode turn.", texts, "What OpenCode wrote before the steer stays above it.")

        # Stop interrupts the running execution; the task waits for the user without a failure.
        ready.unlink()
        sender = self.start_cli("conversation", "send", task["id"], "--message", "[[hold]] Keep going.", extra_environment=environment)
        self.wait_for(ready.is_file, "The second OpenCode turn holds.")
        self.assert_success(self.call_cli("conversation", "stop", task["id"], extra_environment=environment)[0])
        sender.communicate(timeout=60)
        self.assertTrue(self.opencode_requests(executable, "POST", f"/api/session/{session_id}/interrupt"))
        self.assertEqual(self.opencode_records(executable, "history")[-1]["result"], "interrupted")
        stopped = self.task_for(task["id"], environment)
        self.assertEqual(stopped["status"], "Waiting Response")
        self.assertFalse(stopped.get("statusMessage"), stopped)
        self.wait_for(lambda: not any(session_id in server["turns"] for server in self.opencode_servers()),
                      "The stopped turn is no longer recorded on its server.")
        self.assertTrue(all(self.agent_process_alive(server["process"]) for server in self.opencode_servers()),
                        "The shared server keeps running for the task's next turn.")

        # A turn holding a background job OpenCode started asks before Stop ends that job too.
        ready.unlink()
        sender = self.start_cli("conversation", "send", task["id"], "--message", "[[background-hold]] Start a background job.", extra_environment=environment)
        self.wait_for(ready.is_file, "The OpenCode turn holds with its background job.")
        unconfirmed = self.assert_success(self.call_cli("conversation", "stop", task["id"], extra_environment=environment)[0])
        self.assertFalse(unconfirmed["interrupted"])
        self.assertTrue(unconfirmed["confirmationID"])
        self.assertEqual(self.task_for(task["id"], environment)["status"], "In Progress", "Declining keeps the turn running.")
        self.assertFalse(self.opencode_records(executable, "job-cancels"), "Declining leaves the background job running.")
        confirmed = self.assert_success(self.call_cli(
            "conversation", "stop", task["id"], "--confirm-background-work", unconfirmed["confirmationID"], extra_environment=environment,
        )[0])
        self.assertTrue(confirmed["interrupted"])
        sender.communicate(timeout=60)
        job = self.opencode_records(executable, "history")[-1]["job"]
        self.assertEqual([entry["id"] for entry in self.opencode_records(executable, "job-cancels")], [job],
                         "Confirming cancels the session's background job through OpenCode's API.")
        self.wait_for(lambda: self.task_for(task["id"], environment)["status"] == "Waiting Response", "The stopped turn waits for the user.")
        self.assertTrue(all(self.agent_process_alive(server["process"]) for server in self.opencode_servers()),
                        "The shared server keeps running after its background job is stopped.")

    # case-contract: test_opencode_missing_session_and_unavailable_provider | When OpenCode no longer has a task's session after a daemon restart, the next turn starts a new OpenCode session seeded with Playhouse's own transcript of the conversation and the task keeps the new session ID. A prompt OpenCode can't run for want of a model provider fails with a message naming `opencode auth login`, an OpenCode release older than the minimum (OpenCode 1) is reported as too old, and a missing CLI reports OpenCode wasn't found. Providers list reports OpenCode with its product name, installed state and official OpenCode 2 curl installer. MCP status for OpenCode lists the servers OpenCode's server runs for the task from the folder's own opencode.json, with the one that needs a sign-in marked, and status for every provider includes them; signing in to that server starts OpenCode's own OAuth for its integration, returns its link, and waits for OpenCode to finish it, after which the server needs no sign-in. An out-of-turn MCP tool call is refused because OpenCode has no API for it. A plugin's background agent runs on OpenCode in a read-only session of its own that is removed when it ends, and its plugin hears its answer. An OpenCode subagent shows as a completed agent row whose history opens from its own child session. Usage reports OpenCode installed and signed out with no connected model provider, and once one is connected (as `opencode auth login`, which runs in Terminal, leaves it) a refresh shows it as OpenCode's account, with no plan. In the window the recovered answer appears after the earlier conversation, the failed turn shows its sign-in error, the MCP page marks the server that needs a sign-in with an OpenCode badge that is gone once it is signed in, the subagent row shows and opens its history, and the Agents info section shows an OpenCode block offering Log in until a model provider is connected, which then shows as its account.
    def test_opencode_missing_session_and_unavailable_provider(self):
        executable, environment = self.opencode_fixture("opencode-fixture-recovery")
        task = self.create_task("OpenCode recovery", roots=[self.primary], provider="opencode")
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Remember the word lantern.", extra_environment=environment)[0])
        lost = self.task_for(task["id"], environment)["openCodeSessionID"]
        # OpenCode lost the session (deleted outside Playhouse, say), and the daemon restarted.
        sessions = self.opencode_sessions(executable)
        sessions.pop(lost)
        Path(f"{executable}.sessions.json").write_text(json.dumps(sessions), encoding="utf-8")
        restarted = self.restart_service_environment("opencode", executable)
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "What word?", extra_environment=restarted)[0])
        recovered = self.opencode_records(executable, "history")[-1]
        replaced = self.task_for(task["id"], restarted)["openCodeSessionID"]
        self.assertNotEqual(replaced, lost, "A lost OpenCode session is replaced by a new one.")
        self.assertEqual(recovered["sessionId"], replaced)
        self.assertIn("Remember the word lantern.", recovered["prompt"],
                      "The new session starts with Playhouse's own transcript of the conversation.")
        self.assertIn("What word?", recovered["prompt"])

        # A prompt OpenCode can't run for want of a model provider says how to fix it.
        failed = self.call_cli("conversation", "send", task["id"], "--message", "[[auth]] Try.", expected_status=1, extra_environment=environment)[0]
        self.assertFalse(failed.get("ok"), failed)
        self.assertIn("opencode auth login", json.dumps(failed))

        # An OpenCode release too old for Playhouse is reported, and a missing CLI is unavailable.
        old, old_environment = self.opencode_fixture("opencode-fixture-old")
        old_task = self.create_task("OpenCode too old", roots=[self.primary], provider="opencode")
        too_old = self.call_cli("conversation", "send", old_task["id"], "--message", "Hello?", expected_status=1, extra_environment=old_environment)[0]
        self.assertIn("too old for Playhouse", json.dumps(too_old))
        self.assertIn("2.4.0", json.dumps(too_old))
        self.assertTrue(old.exists())
        self.assertFalse(self.opencode_records(old, "launches"), "A release too old is never started.")
        missing = self.call_cli("conversation", "send", old_task["id"], "--message", "Hello?", expected_status=1,
                                extra_environment={"PLAYHOUSE_E2E_OPENCODE_EXECUTABLE": "none"})[0]
        self.assertIn("OpenCode wasn't found", json.dumps(missing))
        self.assert_opencode_server_features(task["id"], environment, executable)
        providers = self.assert_success(self.call_cli("providers", "list", extra_environment=environment)[0])
        opencode = next(p for p in providers if p["provider"] == "opencode")
        self.assertEqual(opencode["productName"], "OpenCode")
        self.assertTrue(opencode["isInstalled"])
        self.assertEqual(opencode["installCommand"], "curl -fsSL https://opencode.ai/v2/install | bash")

    def assert_opencode_server_features(self, task_id, environment, executable):
        """What OpenCode's server reports reaches Playhouse: MCP status and subagent sessions.
        What it has no API for is refused with the reason, and Agents info shows the model
        providers OpenCode is connected to as its account."""
        root = self.data_directory / "opencode-mcp"
        root.mkdir()
        # The servers are in the folder's own opencode.json, which OpenCode reads itself.
        (root / "opencode.json").write_text(json.dumps({"mcp": {
            "oc-local": {"type": "local", "command": ["node", "server.js"]},
            "oc-remote": {"type": "remote", "url": "https://example.test/mcp"},
        }}), encoding="utf-8")
        mcp_task = self.create_task("OpenCode MCP", roots=[root], provider="opencode")
        status = self.assert_success(self.call_cli("mcp", "status", "--task", mcp_task["id"], "--provider", "opencode", extra_environment=environment)[0])
        servers = {entry["name"]: entry for entry in status["opencode"]}
        self.assertEqual(servers["oc-local"]["status"], "connected")
        self.assertFalse(servers["oc-local"]["needsSignIn"])
        self.assertTrue(servers["oc-remote"]["needsSignIn"], status)
        self.assertNotIn("opencode", status["errors"])
        unscoped = self.assert_success(self.call_cli("mcp", "status", "--task", mcp_task["id"], extra_environment=environment)[0])
        self.assertEqual({entry["name"] for entry in unscoped["opencode"]}, {"oc-local", "oc-remote"},
                         "Status for every provider includes OpenCode's servers.")
        # The server that needs a sign-in starts OpenCode's own OAuth for its integration.
        started = self.assert_success(self.call_cli("mcp", "authenticate", "--provider", "opencode", "--name", "oc-remote", "--task", mcp_task["id"],
                                                    extra_environment=environment)[0])
        self.assertTrue(started["authorizationUrl"].startswith("https://example.test/oauth/mcp-oc-remote?attempt="), started)
        self.assertEqual([entry["methodID"] for entry in self.opencode_records(executable, "oauth")], ["oauth"])
        waiting = self.start_cli("mcp", "authenticate-wait", "--provider", "opencode", "--name", "oc-remote", "--task", mcp_task["id"],
                                 extra_environment=environment)
        time.sleep(1.5)
        self.assertIsNone(waiting.poll(), "Waiting for the sign-in keeps the request running until OpenCode finishes it.")
        Path(f"{executable}.oauth-complete").touch()
        finished = self.assert_success(self.finish_cli(waiting, "mcp authenticate-wait")[0])
        self.assertEqual(finished, {"provider": "opencode", "name": "oc-remote", "signedIn": True})
        after = {entry["name"]: entry for entry in self.assert_success(self.call_cli(
            "mcp", "status", "--task", mcp_task["id"], "--provider", "opencode", extra_environment=environment)[0])["opencode"]}
        self.assertFalse(after["oc-remote"]["needsSignIn"], "The finished sign-in no longer needs one.")
        self.assert_failure(self.call_cli("mcp", "call", "--tool", "mcp__docs__search", "--provider", "opencode",
                                          expected_status=1, extra_environment=environment)[0], "unavailable")
        # A plugin's background agent runs on OpenCode in a read-only session of its own.
        self.write_installed_plugin("oc-agent", self.OPENCODE_AGENT_LISTENER, placement="composerActions", presentation="headless",
                                    manifest={"events": ["agent.finished"]})
        self.assert_success(self.call_cli("agent", "run", "--plugin", "oc-agent", "--provider", "opencode", "--prompt", "Summarize the board.",
                                          extra_environment=environment)[0])
        self.wait_for(lambda: self.plugin_state("oc-agent", environment).get("finished"), "The plugin hears its OpenCode agent finish.", timeout=30)
        agent_finished = self.plugin_state("oc-agent", environment)["finished"]
        self.assertEqual(agent_finished["status"], "done", agent_finished)
        self.assertEqual(agent_finished["result"], "OpenCode fixture answered in build mode with fixture/fast.")
        agent_turn = self.opencode_records(executable, "history")[-1]
        self.assertEqual(agent_turn["prompt"], "Summarize the board.")
        self.assertIn({"action": "edit", "resource": "*", "effect": "deny"}, agent_turn["permissions"], "The agent's session is read-only.")
        self.assertNotIn(agent_turn["sessionId"], self.opencode_sessions(executable), "The agent's session is removed once it ends.")
        sent = self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "[[subagent]] Look around.", extra_environment=environment)[0])
        agent = next((activity for activity in sent["activities"] if activity.get("agentPath") == "explore"), None)
        self.assertIsNotNone(agent, f"OpenCode's subagent call is a subagent row: {sent['activities']}")
        self.assertEqual((agent["title"], agent["status"]), ("Explore", "completed"))
        child = agent["childThreadID"]
        self.assertEqual(self.opencode_sessions(executable)[child]["parentID"], self.task_for(task_id, environment)["openCodeSessionID"],
                         "The row opens the subagent's own child session.")
        subagent = self.assert_success(self.call_cli("conversation", "subagent-history", task_id, "--activity", json.dumps(agent),
                                                     extra_environment=environment)[0])
        self.assertEqual(subagent["messages"][-1]["text"], "The README is at the repository root.")
        self.assertIn("Reading README.md", [activity["title"] for activity in subagent["activities"]])
        usage = {p["provider"]: p for p in self.assert_success(self.call_cli("usage", "get", "--refresh", extra_environment=environment)[0])["providers"]}
        self.assertTrue(usage["opencode"]["installed"])
        self.assertFalse(usage["opencode"]["loggedIn"], "OpenCode with no connected model provider reads as signed out.")
        # The model providers OpenCode is connected to are its account; it reports no plan. Logging
        # in opens `opencode auth login` in Terminal, which a headless test can't drive, so the
        # test connects one the way that login would leave it.
        Path(f"{executable}.auth.json").write_text(json.dumps([{"integrationID": "anthropic", "type": "api"}]), encoding="utf-8")
        signed_in = {p["provider"]: p for p in self.assert_success(self.call_cli("usage", "get", "--refresh", extra_environment=environment)[0])["providers"]}["opencode"]
        self.assertTrue(signed_in["loggedIn"])
        self.assertEqual(signed_in["account"], "anthropic")
        self.assertIsNone(signed_in.get("plan"))

    # case-contract: test_opencode_turn_survives_daemon_restart | An OpenCode turn runs on a shared server that outlives a daemon killed mid-turn and records the running turn in its manifest; the next daemon reconnects to the same server, rebuilds the turn from the session's messages and follows it live, and records the answer OpenCode gives after the restart exactly once, without repeating what was recorded before. The session's messages reach the token map's log while the turn runs, once a model request ends, and the reattached turn writes the rest when it finishes, so the map holds both of its requests. The finished turn leaves its server with no turn recorded, and the adopted server stops once it has been idle for the idle timeout, removing its manifest. In the window the answer given after the restart appears once in the conversation and the task leaves In Progress.
    def test_opencode_turn_survives_daemon_restart(self):
        executable, _ = self.opencode_fixture("opencode-fixture-reattach")
        environment = self.restart_service_environment("opencode", executable, PLAYHOUSE_E2E_OPENCODE_SERVER_IDLE_SECONDS="3")
        task = self.create_task("OpenCode restart", roots=[self.primary], provider="opencode")
        ready = Path(f"{executable}.hold-ready")
        sent = {}
        sender = threading.Thread(target=lambda: sent.setdefault("turn", self.call_cli(
            "conversation", "send", task["id"], "--message", "[[hold]] [[step]] Survive a restart.",
            expected_status=69, timeout=60, extra_environment=environment)), daemon=True)
        sender.start()
        self.wait_for(ready.is_file, "The OpenCode turn holds before the daemon dies.")
        session_id = self.task_for(task["id"], environment)["openCodeSessionID"]
        servers = [m for m in self.opencode_servers() if m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]]
        self.assertEqual([session_id in m["turns"] for m in servers].count(True), 1, servers)
        server = next(m for m in servers if session_id in m["turns"])["process"]
        request_log = self.data_directory / "opencode-request-logs" / f"{session_id}.jsonl"
        self.wait_for(lambda: request_log.is_file() and "Holding the OpenCode turn." in request_log.read_text(encoding="utf-8"),
                      "The running turn's finished model request reaches the token map's log.")
        launches_before = len(self.opencode_records(executable, "launches"))
        self.kill_daemon(environment)
        sender.join(timeout=30)
        self.assertTrue(self.process_is_running(server["pid"]), "The OpenCode server outlives the daemon that started it.")
        # The next daemon carries the turn on: the released answer lands in the task's history.
        self.assert_success(self.call_cli("task", "get", task["id"], extra_environment=environment)[0])
        Path(f"{executable}.hold-release").touch()
        self.wait_for(lambda: "Released the OpenCode turn." in [
            m["text"] for m in self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])["messages"]
        ], "The reattached OpenCode turn records its answer.", timeout=40)
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        texts = [m["text"] for m in history["messages"]]
        self.assertEqual(texts.count("Released the OpenCode turn."), 1, texts)
        self.assertEqual(texts.count("Holding the OpenCode turn."), 1, texts)
        self.assertNotIn("Holding the OpenCode turn.", texts[texts.index("Released the OpenCode turn.") + 1:])
        self.wait_for(lambda: "Released the OpenCode turn." in request_log.read_text(encoding="utf-8"),
                      "The reattached turn writes the rest of its messages when it finishes.")
        waste = self.assert_success(self.call_cli("task", "token-waste", task["id"], extra_environment=environment)[0])
        self.assertEqual([agent["requests"] for agent in waste["agents"] if agent["id"] == "opencode"], [2],
                         "The map holds the request before the restart and the one after it.")
        self.assertEqual(len(self.opencode_records(executable, "launches")), launches_before,
                         "The next daemon reconnects to the same server instead of starting one.")
        self.wait_for(lambda: not any(session_id in m["turns"] for m in self.opencode_servers()),
                      "The finished turn is no longer recorded on its server.")
        self.wait_for(lambda: self.task_for(task["id"], environment)["status"] != "In Progress", "The task leaves In Progress.")
        # With nothing left to run, the adopted server stops once it has been idle, and its files go.
        self.wait_for(lambda: not self.process_is_running(server["pid"]), "The idle OpenCode server stops.", timeout=30)
        self.wait_for(lambda: not [m for m in self.opencode_servers() if m["process"] and m["process"]["pid"] == server["pid"]],
                      "The stopped server's manifest is removed.", timeout=10)

    # case-contract: test_opencode_tasks_share_one_server_with_native_discovery | Tasks on different repositories run on the one `opencode serve` every task shares, which Playhouse starts once with no skill, rule or MCP configuration of its own. Each task's turn sees only what OpenCode finds in its own working folder: that folder's committed .agents and .claude skills and the MCP servers of its own `opencode.json`, never the other task's, and OpenCode's MCP status for each task lists only its folder's servers. A global MCP server added in Playhouse writes no OpenCode configuration and starts no server. When the server process stops, the next turn starts one new server and continues the task's session, and the folder's skills and servers are there again with nothing for Playhouse to restore. In the window, the answers to the turns sent from the composer of each task, and after the server stopped, show in the conversation.
    def test_opencode_tasks_share_one_server_with_native_discovery(self):
        executable, environment = self.opencode_fixture("opencode-fixture-shared")
        first = self.make_skill_repository("oc-shared-first", {
            ".agents/skills/oc-first-skill/SKILL.md": self.skill_manifest("oc-first-skill", "The first repository's skill"),
            "opencode.json": json.dumps({"mcp": {"oc-first-mcp": {"type": "local", "command": ["node", "first.js"]}}}),
        })
        second = self.make_skill_repository("oc-shared-second", {
            ".claude/skills/oc-second-skill/SKILL.md": self.skill_manifest("oc-second-skill", "The second repository's skill"),
            "opencode.json": json.dumps({"mcp": {"oc-second-mcp": {"type": "remote", "url": "https://example.test/mcp"}}}),
        })
        first_task = self.create_skills_task("OpenCode shared first", [first], provider="opencode")
        second_task = self.create_skills_task("OpenCode shared second", [second], provider="opencode")
        self.assert_success(self.call_cli("conversation", "send", first_task["id"], "--message", "First repository.", extra_environment=environment)[0])
        first_turn = self.opencode_records(executable, "history")[-1]
        self.assert_success(self.call_cli("conversation", "send", second_task["id"], "--message", "Second repository.", extra_environment=environment)[0])
        second_turn = self.opencode_records(executable, "history")[-1]
        self.assertNotEqual(first_turn["cwd"], second_turn["cwd"], "Each session works in its own task's folder.")
        self.assertEqual(first_turn["skills"], ["oc-first-skill"])
        self.assertEqual(first_turn["mcp"], {"oc-first-mcp": {"type": "local", "command": ["node", "first.js"]}})
        self.assertEqual(second_turn["skills"], ["oc-second-skill"], "The second task sees its own folder's skills, not the first's.")
        self.assertEqual(second_turn["mcp"], {"oc-second-mcp": {"type": "remote", "url": "https://example.test/mcp"}})
        launches = self.opencode_records(executable, "launches")
        self.assertEqual(len(launches), 1, "Both tasks run on one server.")
        self.assertIsNone(launches[0]["configFile"])
        self.assertIsNone(launches[0]["inlineConfig"])
        self.assertEqual(len(self.opencode_servers()), 1, self.opencode_servers())
        for task, name in [(first_task, "oc-first-mcp"), (second_task, "oc-second-mcp")]:
            report = self.assert_success(self.call_cli("mcp", "status", "--task", task["id"], "--provider", "opencode", extra_environment=environment)[0])
            self.assertEqual([server["name"] for server in report["opencode"]], [name], "OpenCode reports the task's own folder's servers.")

        # A global server added in Playhouse changes nothing on OpenCode.
        self.assert_success(self.call_cli("mcp", "create", "--scope", "global", "--name", "oc-global-tool", "--command", "node", "--arg", "global.js")[0])
        self.assertFalse(list((self.data_directory / "opencode-runs").glob("shared-config")), "Playhouse writes no OpenCode config.")
        self.assert_success(self.call_cli("conversation", "send", first_task["id"], "--message", "After the global change.", extra_environment=environment)[0])
        self.assertNotIn("oc-global-tool", self.opencode_records(executable, "history")[-1]["mcp"])
        self.assertEqual(len(self.opencode_records(executable, "launches")), 1, "The change starts no server.")

        # The server process stops: the next turn starts one new server, with nothing to restore.
        session_id = self.task_for(first_task["id"], environment)["openCodeSessionID"]
        pid = self.opencode_servers()[0]["process"]["pid"]
        os.kill(pid, signal.SIGKILL)
        self.wait_for(lambda: not self.process_is_running(pid), "The OpenCode server process is gone.")
        self.assert_success(self.call_cli("conversation", "send", first_task["id"], "--message", "After the server stopped.", extra_environment=environment)[0])
        after = self.opencode_records(executable, "history")[-1]
        self.assertEqual(len(self.opencode_records(executable, "launches")), 2, "The next turn starts one new server.")
        self.assertEqual(after["sessionId"], session_id, "The task continues its OpenCode session on the new server.")
        self.assertEqual(after["skills"], ["oc-first-skill"])
        self.assertEqual(after["mcp"], first_turn["mcp"], "The folder's servers are there again with nothing restored.")
        history = self.assert_success(self.call_cli("conversation", "history", first_task["id"], extra_environment=environment)[0])
        self.assertTrue(history["messages"][-1]["text"].startswith("OpenCode fixture answered"), history["messages"][-1])

    # case-contract: test_opencode_catalog_marks_what_opencode_cannot_use | The Skills, Rules and MCP pages mark OpenCode only on what it finds itself, since Playhouse passes its one shared server nothing. For a task on two repositories: the working repository's committed skill is every agent's; a skill committed in the second repository is Claude's and Codex's only, noting that OpenCode reads skills only from the task's working folder; a private skill is Claude's and Codex's only, noting that OpenCode reads only the repository's and the home folder's skills; a Codex-only global skill is Claude's and Codex's only, while global .agents and .claude skills are every agent's; and a working-folder skill turned off in Playhouse still lists OpenCode, noting that OpenCode still uses it. The repositories' .mcp.json servers are Claude's and Codex's only. The working repository's AGENTS.md reaches OpenCode, which still reads it when it is turned off, while ~/.agents/AGENTS.md, which Playhouse shares with Claude and Codex, doesn't; a CLAUDE.md reaches OpenCode only in the working folder with no AGENTS.md beside it, and the global CLAUDE.md only until OpenCode's own global AGENTS.md exists. A plugin editor can't run on OpenCode: one authored with OpenCode as its provider starts on Codex, and switching it to OpenCode is refused, saying plugin editors need Claude or Codex. In the window, the Skills page shows the two-agent mark and the note in each skill's hint and every agent's mark on the global .agents and .claude skills, the MCP page shows the two-agent mark, and a plugin editor's provider menu, once it lists the installed providers, doesn't offer OpenCode or its install.
    def test_opencode_catalog_marks_what_opencode_cannot_use(self):
        first = self.make_skill_repository("oc-catalog-first", {
            ".agents/skills/oc-first-skill/SKILL.md": self.skill_manifest("oc-first-skill", "Committed in the working repository"),
            ".claude/skills/oc-first-off/SKILL.md": self.skill_manifest("oc-first-off", "Turned off in Playhouse"),
            "AGENTS.md": "Working repository rules.\n",
            "CLAUDE.md": "Claude rules beside AGENTS.md.\n",
            ".mcp.json": json.dumps({"mcpServers": {"oc-first-server": {"type": "stdio", "command": "first"}}}),
        })
        second = self.make_skill_repository("oc-catalog-second", {
            ".claude/skills/oc-second-skill/SKILL.md": self.skill_manifest("oc-second-skill", "Committed in the second repository"),
            "CLAUDE.md": "The second repository's rules.\n",
            ".mcp.json": json.dumps({"mcpServers": {"oc-second-server": {"type": "stdio", "command": "second"}}}),
        })
        self.write_skill(self.skills_codex_home / "skills", "oc-codex-only", "A Codex-only global skill")
        self.write_skill(self.skills_home / ".agents" / "skills", "oc-global-agents", "A global .agents skill")
        self.write_skill(self.skills_home / ".claude" / "skills", "oc-global-claude", "A global .claude skill")
        self.write_file(self.rules_claude_config / "CLAUDE.md", "Global Claude rules.\n")
        self.write_file(self.skills_home / ".agents" / "AGENTS.md", "Shared global rules.\n")
        task = self.create_task("OpenCode catalog", roots=[first, second], provider="opencode")
        self.assert_success(self.call_cli("skills", "create", "--task", task["id"], "--scope", "private", "--root", str(first),
                                          "--name", "oc-private", "--description", "Private to the first repository")[0])
        catalog = self.skill_catalog(task_id=task["id"])
        first_skills = self.skills_by_name(catalog["repositories"][0]["skills"])
        second_skills = self.skills_by_name(catalog["repositories"][1]["skills"])
        self.assertEqual(first_skills["oc-first-skill"]["providers"], ["claude", "codex", "opencode"])
        self.assertIsNone(first_skills["oc-first-skill"].get("providerNote"))
        self.assertEqual(second_skills["oc-second-skill"]["providers"], ["claude", "codex"])
        self.assertIn("reads skills only from the task's working folder", second_skills["oc-second-skill"]["providerNote"])
        self.assertEqual(first_skills["oc-private"]["providers"], ["claude", "codex"])
        self.assertIn("reads only skills in the repository and your home folder", first_skills["oc-private"]["providerNote"])
        global_skills = self.skills_by_name(catalog["global"])
        self.assertEqual(global_skills["oc-codex-only"]["providers"], ["claude", "codex"])
        self.assertIn("doesn't read Codex's skill folder", global_skills["oc-codex-only"]["providerNote"])
        for name in ("oc-global-agents", "oc-global-claude"):
            self.assertEqual(global_skills[name]["providers"], ["claude", "codex", "opencode"], f"OpenCode reads {name} from the home folder itself.")
            self.assertIsNone(global_skills[name].get("providerNote"))
        self.assert_success(self.call_cli("skills", "disable", "--task", task["id"], "--skill", first_skills["oc-first-off"]["id"])[0])
        off = self.skills_by_name(self.skill_catalog(task_id=task["id"])["repositories"][0]["skills"])["oc-first-off"]
        self.assertFalse(off["enabled"])
        self.assertIn("opencode", off["providers"], "OpenCode still uses a skill it finds itself.")
        self.assertIn("OpenCode still uses it", off["providerNote"])

        servers = self.mcp_by_name([server for section in self.mcp_catalog(task["id"])["repositories"] for server in section["servers"]])
        self.assertEqual(servers["oc-first-server"]["providers"], ["claude", "codex"], "OpenCode doesn't read .mcp.json.")
        self.assertEqual(servers["oc-second-server"]["providers"], ["claude", "codex"])

        rules = self.rule_catalog(task_id=task["id"])
        working_rules = self.rule_section(rules, catalog["repositories"][0]["name"])
        self.assertIn("opencode", working_rules["AGENTS.md"]["providers"])
        self.assertNotIn("opencode", working_rules["AGENTS.md"]["sharedWith"], "OpenCode reads AGENTS.md itself.")
        shared = next(rule for rule in rules["global"] if rule["name"].endswith(".agents/AGENTS.md"))
        self.assertEqual(shared["providers"], ["claude", "codex"], "Playhouse shares ~/.agents/AGENTS.md with Claude and Codex only.")
        self.assertNotIn("opencode", working_rules["CLAUDE.md"]["providers"], "OpenCode reads AGENTS.md, not a CLAUDE.md beside it.")
        second_rules = self.rule_section(rules, catalog["repositories"][1]["name"])
        self.assertNotIn("opencode", second_rules["CLAUDE.md"]["providers"], "OpenCode reads rules only from the working folder.")
        alone = self.create_task("OpenCode catalog second alone", roots=[second], provider="opencode")
        alone_rules = self.rule_section(self.rule_catalog(task_id=alone["id"]), "oc-catalog-second")
        self.assertIn("opencode", alone_rules["CLAUDE.md"]["providers"], "OpenCode reads the working folder's CLAUDE.md when it has no AGENTS.md.")
        global_claude = next(rule for rule in rules["global"] if rule["name"].endswith(".claude/CLAUDE.md"))
        self.assertIn("opencode", global_claude["providers"], "OpenCode reads Claude Code's global CLAUDE.md.")
        self.write_file(self.skills_home / ".config" / "opencode" / "AGENTS.md", "OpenCode's own global rules.\n")
        global_claude = next(rule for rule in self.rule_catalog(task_id=task["id"])["global"] if rule["name"].endswith(".claude/CLAUDE.md"))
        self.assertNotIn("opencode", global_claude["providers"], "OpenCode's own global AGENTS.md replaces CLAUDE.md for it.")
        self.assert_success(self.call_cli("rules", "disable", "--task", task["id"], "--rule", working_rules["AGENTS.md"]["id"])[0])
        working_rules = self.rule_section(self.rule_catalog(task_id=task["id"]), catalog["repositories"][0]["name"])
        self.assertIn("opencode", working_rules["AGENTS.md"]["alwaysOnFor"], "OpenCode still reads a turned-off AGENTS.md.")

        editor = self.assert_success(self.call_cli("plugin", "author", "--placement", "mainSidebar", "--name", "OC Plugin",
                                                   "--presentation", "popover", "--provider", "opencode")[0])["task"]
        self.assertEqual(editor["conversationProvider"], "codex", "A plugin editor asked for on OpenCode starts on Codex.")
        refused, _ = self.call_cli("conversation", "provider", editor["id"], "set", "opencode", expected_status=2)
        self.assertIn("Plugin editors can't use OpenCode", refused["error"]["message"])
        session = next(entry for entry in self.assert_success(self.call_cli("plugin", "sessions")[0])["sessions"] if entry["id"] == editor["id"])
        self.assertEqual(session["conversationProvider"], "codex", "The refused switch leaves the editor on Codex.")

    # case-contract: test_opencode_token_map_reads_session_messages | An OpenCode task with no turn has no token map. After an OpenCode turn that reads a long build log and runs an explore subagent, the token map reads the messages OpenCode's server lists for the task's session and the subagent's child session, which the turn wrote beside the store before it finished: each assistant message is a request that was sent every message before it, the build log the read tool returned is the largest item, OpenCode's system prompt and tool definitions, which its server doesn't return, are one hidden-overhead item sent with every request and measured at about the 2,000 tokens the fixture bills for them, the final transcript's tokens equal the last request's reported input, and the subagent's child session is its own agent. With --turn, the turn's map holds its three main requests and the subagent's one, and its summary lists 4 model calls. The raw input's single-request scope labels each request reconstructed, its items add up to the input OpenCode reported with the earlier request's share as cache read, the log's full text reads back exactly as OpenCode returned it, and the JSON export holds the messages the request was sent. The map still reads after the daemon restarts with OpenCode gone, and deleting the task removes the messages it saved. The Token Stats modal shows the build log as the largest waster and opens its full text, lists the hidden overhead and the subagent, and the raw input's latest request reads as reconstructed.
    def test_opencode_token_map_reads_session_messages(self):
        executable, _ = self.opencode_fixture("opencode-fixture-token-map")
        environment = self.restart_service_environment("opencode", executable)
        task = self.create_task("OpenCode token map", roots=[self.primary], provider="opencode")
        empty = self.assert_success(self.call_cli("task", "token-waste", task["id"], extra_environment=environment)[0])
        self.assertEqual((empty["available"], empty["agents"], empty["wasters"]), (False, [], []), "A task with no OpenCode turn has no token map.")

        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "[[token-map]] Map the tokens.", extra_environment=environment)[0])
        turn = self.opencode_records(executable, "history")[-1]
        session_id = self.task_for(task["id"], environment)["openCodeSessionID"]
        child = turn["child"]
        logs = self.data_directory / "opencode-request-logs"
        self.assertTrue((logs / f"{session_id}.jsonl").is_file(), "The turn wrote its session's messages beside the store.")
        self.assertTrue((logs / f"{session_id}.subagent.{child}.jsonl").is_file(), "It wrote the subagent's child session too.")
        billed = [m["tokens"] for m in self.opencode_sessions(executable)[session_id]["messages"] if m["type"] == "assistant"]
        contexts = [t["input"] + t["cache"]["read"] + t["cache"]["write"] for t in billed]
        self.assertEqual(len(contexts), 3, "The fixture made three model requests in the session.")

        def check_map(environment):
            waste = self.assert_success(self.call_cli("task", "token-waste", task["id"], extra_environment=environment)[0])
            self.assertTrue(waste["available"])
            agents = {agent["id"]: agent for agent in waste["agents"]}
            self.assertEqual(list(agents), ["opencode", f"opencode/{child}"], waste["agents"])
            self.assertEqual((agents["opencode"]["label"], agents["opencode"]["isMain"], agents["opencode"]["requests"]), ("OpenCode main agent", True, 3))
            self.assertEqual(agents["opencode"]["sentTokens"], sum(contexts))
            self.assertEqual(agents["opencode"]["finalTranscriptTokens"], contexts[-1], "The final transcript adds up to the last request's input.")
            self.assertEqual((agents[f"opencode/{child}"]["isMain"], agents[f"opencode/{child}"]["requests"], agents[f"opencode/{child}"]["sentTokens"]), (False, 1, 900))
            top = waste["wasters"][0]
            self.assertEqual((top["agent"], top["kind"], top["label"]), ("opencode", "toolResult", "read"), waste["wasters"][:3])
            self.assertGreater(top["tokens"], 1_500, "The build log the read tool returned is the largest item.")
            hidden = [row for row in waste["overhead"] if row["kind"] == "hiddenOverhead" and row["agent"] == "opencode"]
            self.assertEqual(len(hidden), 1, waste["overhead"])
            self.assertTrue(hidden[0]["everyRequest"])
            self.assertEqual(hidden[0]["label"], "System prompt, tool definitions and other context OpenCode does not return")
            self.assertTrue(1_900 <= hidden[0]["tokens"] <= 2_100, f"The hidden overhead is measured at about what the fixture bills: {hidden[0]}")
            return waste, top
        waste, top = check_map(environment)

        # One turn's map places the session's requests in it by OpenCode's own timestamps.
        history = self.assert_success(self.call_cli("conversation", "history", task["id"], extra_environment=environment)[0])
        turn_id = next(m["turnID"] for m in history["messages"] if m["role"] == "user" and m["text"] == "[[token-map]] Map the tokens.")
        scoped = self.assert_success(self.call_cli("task", "token-waste", task["id"], "--turn", turn_id, extra_environment=environment)[0])
        self.assertEqual([agent["requests"] for agent in scoped["agents"]], [3, 1], "The turn's three main requests and its subagent's one.")
        summary = self.assert_success(self.call_cli("task", "token-usage", task["id"], "--turn", turn_id, extra_environment=environment)[0])
        self.assertEqual(summary["callUsage"]["totalCalls"], 4)

        # Each request is rebuilt from the messages before its answer.
        page = self.assert_success(self.call_cli("task", "raw-input", task["id"], "--scope", "request", "--limit", "1000", extra_environment=environment)[0])
        request = page["request"]
        self.assertEqual((request["number"], request["count"], request["latest"], request["exact"]), (3, 3, 3, False))
        self.assertTrue(request["note"].startswith("Reconstructed: OpenCode resends the session's messages"), request["note"])
        self.assertEqual(request["contextTokens"], contexts[-1])
        self.assertEqual(request["itemTokens"], request["contextTokens"], request["tokenNote"])
        self.assertEqual((request["cacheReadTokens"], request["cacheWriteTokens"]), (contexts[1], 0), "The earlier request's share was read from cache.")
        kinds = [row["kind"] for row in page["rows"]]
        self.assertEqual(kinds[:2], ["hiddenOverhead", "userText"], "A request starts with the hidden overhead and the prompt.")
        self.assertEqual(kinds.count("toolCall"), 2, "The read and the subagent call.")
        first = self.assert_success(self.call_cli("task", "raw-input", task["id"], "--scope", "request", "--request", "1", extra_environment=environment)[0])
        self.assertEqual([row["kind"] for row in first["rows"]], ["hiddenOverhead", "userText"], "The first request was sent only the prompt.")
        text = self.assert_success(self.call_cli("task", "raw-input-text", task["id"], "--item", str(top["item"]), "--length", "100000",
                                                 extra_environment=environment)[0])
        self.assertEqual(text["text"], turn["log"], "The log reads back exactly as OpenCode returned it.")
        self.assertEqual(text["label"], "read")
        exported = self.assert_success(self.call_cli("task", "raw-input-export", task["id"], "--request", "1", "--format", "json",
                                                     extra_environment=environment)[0])
        self.assertEqual(json.loads(exported["text"]), {"messages": ["[[token-map]] Map the tokens."]})

        # The written messages outlive the daemon and OpenCode's server.
        servers = [m["process"]["pid"] for m in self.opencode_servers() if m.get("process")]
        self.kill_daemon(environment)
        for pid in servers:
            os.kill(pid, signal.SIGKILL)
        check_map({**environment, "PLAYHOUSE_E2E_OPENCODE_EXECUTABLE": "none"})
        self.assert_success(self.call_cli("task", "delete", task["id"], extra_environment=environment)[0])
        self.assertFalse((logs / f"{session_id}.jsonl").exists() or (logs / f"{session_id}.subagent.{child}.jsonl").exists(),
                         "Deleting the task removes the messages it saved.")

    # case-contract: test_plugin_agent_run_opencode_json_schema | agent.run with provider opencode and a JSON schema (CLI agent run --provider opencode --json-schema, Playhouse.agent.run from the popover with the plugin's provider) sends the plugin's prompt with the schema and an instruction to answer with only matching JSON to a read-only OpenCode session of its own. An answer whose JSON matches the schema, inside a Markdown code block or not, is the run's structured result, which the plugin's handler uses to create a board task. An answer that isn't JSON or doesn't match is asked for once more in the same session, naming what was wrong, and a matching second answer is the result; a second mismatch fails the run with an error saying OpenCode's answer didn't match the JSON schema and why, which the plugin files on the board. Each run's session is removed when it ends. In the window the popover's run on OpenCode creates the task from the corrected answer and shows its result, and a run that never matched shows on the board as a failed task.
    def test_plugin_agent_run_opencode_json_schema(self):
        executable, environment = self.opencode_fixture("opencode-fixture-json")
        answers = Path(f"{executable}.json-answers")
        self.write_installed_plugin("oc-schema", self.OPENCODE_SCHEMA_LISTENER, placement="composerActions", presentation="headless",
                                    manifest={"events": ["agent.finished"]})
        schema = {"type": "object", "properties": {"title": {"type": "string"}, "priority": {"type": "integer"}},
                  "required": ["title", "priority"], "additionalProperties": False}

        def run(prompt, replies):
            answers.write_text(json.dumps(replies), encoding="utf-8")
            before = len(self.opencode_records(executable, "history"))
            self.assert_success(self.call_cli("plugin", "state", "--id", "oc-schema", "--key", "finished", "--value", "null", extra_environment=environment)[0])
            self.assert_success(self.call_cli("agent", "run", "--plugin", "oc-schema", "--provider", "opencode", "--prompt", prompt,
                                              "--json-schema", json.dumps(schema), extra_environment=environment)[0])
            finished = self.wait_for(lambda: self.plugin_state("oc-schema", environment).get("finished"), "The plugin hears its OpenCode agent finish.", timeout=30)
            turns = self.opencode_records(executable, "history")[before:]
            self.assertEqual({t["sessionId"] for t in turns} & set(self.opencode_sessions(executable)), set(), "The run's session is removed when it ends.")
            return finished, turns

        def board_titles():
            return [task["title"] for task in self.assert_success(self.call_cli("task", "list", extra_environment=environment)[0])["tasks"]]

        # A matching answer in a code block is the structured result.
        finished, turns = run("File a task for Omri.", ["Here it is:\n```json\n{\"title\": \"Reply to Omri\", \"priority\": 2}\n```"])
        self.assertEqual((finished["status"], finished["result"]), ("done", {"title": "Reply to Omri", "priority": 2}), finished)
        self.assertEqual(len(turns), 1)
        prompt = turns[0]["prompt"]
        self.assertTrue(prompt.startswith("File a task for Omri.\n\nAnswer with only a JSON value that matches this JSON Schema"), prompt)
        self.assertEqual(json.loads(prompt[prompt.index("{"):]), schema, "The prompt carries the plugin's schema.")
        self.assertIn({"action": "edit", "resource": "*", "effect": "deny"}, turns[0]["permissions"], "The run's session is read-only.")
        self.wait_for(lambda: "Reply to Omri" in board_titles(), "The plugin's handler creates a board task from the structured result.")

        # An answer that isn't JSON is asked for again in the same session, naming what was wrong.
        finished, turns = run("File a task for Dana.", ["Sure, I'll file it for Dana.", '{"title": "Reply to Dana", "priority": 1}'])
        self.assertEqual((finished["status"], finished["result"]), ("done", {"title": "Reply to Dana", "priority": 1}), finished)
        self.assertEqual(len(turns), 2)
        self.assertEqual(turns[0]["sessionId"], turns[1]["sessionId"], "The correction goes to the same session.")
        self.assertTrue(turns[1]["prompt"].startswith("Your answer didn't match the JSON Schema: the answer isn't JSON."), turns[1]["prompt"])

        # Two mismatches fail the run with what was wrong the second time.
        finished, turns = run("File a task for Lee.", ['{"title": "Reply to Lee"}', '{"title": "Reply to Lee", "priority": "high"}'])
        self.assertEqual(finished["status"], "failed")
        self.assertEqual(finished["error"], "OpenCode's answer didn't match the JSON schema: $.priority must be an integer, not a string.")
        self.assertEqual(len(turns), 2)
        self.assertIn('$ is missing the required property "priority".', turns[1]["prompt"])
        self.wait_for(lambda: f"Schema run failed: {finished['error']}" in board_titles(), "The plugin files the failed run on the board.")
        finished, _ = run("File a task for Kim.", ['{"title": "Reply to Kim", "priority": 3, "owner": "Kim"}', '{"title": "Reply to Kim", "priority": 3}'])
        self.assertEqual(finished["result"], {"title": "Reply to Kim", "priority": 3}, "A property the schema doesn't allow is corrected too.")

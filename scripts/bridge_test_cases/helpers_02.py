from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestHelpers02:
    def assert_turn_progress_reaches_followers_mid_turn(self, provider, fixture_name, environment_name, thread_key, activity_id, send_arguments=()):
        """A window that isn't reading a turn's stream follows it through the
        runtime snapshot's conversation revision and a history reload."""
        display = "Claude" if provider == "claude" else "Codex"
        progress_text = f"{display} is partway through the followed turn."
        final_text = f"{display} finished the followed turn."
        source_name = "claude-code-fixture.py" if provider == "claude" else "codex-app-server-fixture.py"
        executable = self.data_directory / fixture_name
        copy_file(Path(__file__).resolve().parent / "fixtures" / source_name, executable)
        executable.chmod(0o755)
        (self.data_directory / f".playhouse-{provider}-fixture-owner").write_text(
            f"Playhouse test owns this {'Claude Code' if provider == 'claude' else 'Codex'} protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {environment_name: str(executable)}
        task_id = self.create_task(f"{display} followed turn", provider=provider)["id"]
        started = Path(str(executable) + ".follow-turn-started")
        resume = Path(str(executable) + ".follow-turn-continue")
        ready = Path(str(executable) + ".follow-turn-ready")
        release = Path(str(executable) + ".follow-turn-release")

        def revision(snapshot):
            return snapshot.get("conversationRevisions", {}).get(task_id, 0)

        def history_messages():
            return self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])

        def snapshots_within(seconds):
            seen = []
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if not select.select([watcher.stdout], [], [], 0.1)[0]:
                    continue
                line = watcher.stdout.readline()
                event = json.loads(line.decode("utf-8")) if line.strip() else {}
                if event.get("type") == "runtime_state":
                    seen.append(event["payload"])
            return seen

        watcher = self.start_cli("conversation", "runtime", "--watch", extra_environment=environment, binary_output=True)
        prompt = "Please follow-active-turn."
        send = self.start_cli("conversation", "send", task_id, "--message", prompt, *send_arguments, extra_environment=environment)
        progressed = None
        fixture_history = Path(str(executable) + ".history")

        def provider_resume_count():
            if not fixture_history.is_file():
                return 0
            return json.loads(fixture_history.read_text(encoding="utf-8")).get("threadResumeCount", 0)
        try:
            self.wait_for_marker(started, True, f"The {display} fixture should hold its turn before any output.", timeout=20)
            if "--model" in send_arguments:
                turns = json.loads(fixture_history.read_text(encoding="utf-8")).get("turns", [])
                self.assertEqual(
                    turns[-1].get("modelID"), send_arguments[send_arguments.index("--model") + 1],
                    "The turn should run with the selected model, so history's default differs from it.",
                )
            thread_id = None
            deadline = time.monotonic() + 10
            while not thread_id and time.monotonic() < deadline:
                thread_id = self.assert_success(self.call_cli("task", "get", task_id)[0]).get(thread_key)
                time.sleep(0.05)
            self.assertTrue(thread_id, f"The running {display} turn should record its {thread_key}.")
            quiet = self.read_watcher_snapshot(watcher, lambda snapshot: thread_id in snapshot["activeThreadIDs"])
            # Let snapshots taken before the hold drain, then the held turn stays silent.
            quiet = ([quiet] + snapshots_within(0.5))[-1]
            later = snapshots_within(1.5)
            self.assertEqual(
                [revision(snapshot) for snapshot in later if revision(snapshot) != revision(quiet)], [],
                "A turn with no visible output yet should not ask windows to reload history.",
            )

            resumes_before_progress = provider_resume_count()
            resume.write_text("Show progress.\n", encoding="utf-8")
            self.wait_for_marker(ready, True, f"The {display} fixture should hold its turn while progress is visible.", timeout=20)
            progressed = self.read_watcher_snapshot(
                watcher, lambda snapshot: thread_id in snapshot["activeThreadIDs"] and revision(snapshot) > revision(quiet)
            )
            self.assertIn(thread_id, progressed["activeThreadIDs"], "The revision must rise while the turn is still running.")
            history = None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                history = history_messages()
                if any(message["text"] == progress_text for message in history["messages"]) and any(
                    activity["id"] == activity_id for activity in history["activities"]
                ):
                    break
                time.sleep(0.1)
            texts = [message["text"] for message in history["messages"]]
            self.assertIn(prompt, texts, "Mid-turn history should hold the running turn's prompt.")
            self.assertIn(progress_text, texts, "Mid-turn history should hold the running turn's commentary.")
            self.assertNotIn(final_text, texts, "The final answer must not exist before the turn finishes.")
            running = next((activity for activity in history["activities"] if activity["id"] == activity_id), None)
            self.assertIsNotNone(running, f"Mid-turn history should hold the running {display} tool activity.")
            self.assertEqual(running["status"], "inProgress", "The tool is still running while the turn holds.")
            self.assertEqual(
                provider_resume_count(), resumes_before_progress,
                "Mid-turn history must read the running thread as loaded, not resume it with history's default model.",
            )
        finally:
            resume.write_text("Show progress.\n", encoding="utf-8")
            release.write_text("Finish the turn.\n", encoding="utf-8")
        try:
            self.finish_cli(send, ("conversation", "send", task_id, "--message", prompt), timeout=60)
            settled = self.read_watcher_snapshot(
                watcher, lambda snapshot: thread_id not in snapshot["activeThreadIDs"] and revision(snapshot) > revision(progressed)
            )
            self.assertGreater(revision(settled), revision(progressed))
        finally:
            watcher.terminate()
            watcher.wait(timeout=10)
        history = history_messages()
        texts = [message["text"] for message in history["messages"]]
        self.assertIn(final_text, texts, "The settled turn's final answer should be in history.")
        finished = next(activity for activity in history["activities"] if activity["id"] == activity_id)
        self.assertNotEqual(finished["status"], "inProgress", "The tool activity should settle with its turn.")
    def assert_earlier_turn_tool_calls_in_history(self, provider, environment, call_ids, summaries):
        """Runs a tool-call turn and a later turn, then checks the earlier turn's calls in history."""
        task_id = self.create_task(f"{provider} timeline tools", provider=provider)["id"]
        answer = ("Here is what ran:\n1. `git status --short` was clean.\n2. The check exited with code `3`.\n\n"
                  "- Bullets read at text size\n- Inline `code` is tinted")
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Please show-tool-calls-inline.", extra_environment=environment)[0])
        latest = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        self.assertIn(call_ids[0], {activity["id"] for activity in latest["activities"]},
                      "While its turn is the latest, the call belongs to that turn's Worked for activities.")
        self.assertIn(answer, [message["text"] for message in latest["messages"]],
                      "History should keep the answer's Markdown source exactly, inline code and list markers included.")
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Please reply simply.", extra_environment=environment)[0])
        history = self.assert_success(self.call_cli("conversation", "history", task_id, extra_environment=environment)[0])
        message_ids = {message["text"]: message["id"] for message in history["messages"]}
        intro = message_ids.get("I'll check the repository status first.")
        middle = message_ids.get("The status is clean. Next I'll list the files and run the check.")
        self.assertTrue(intro and middle, f"The commentary on either side of a call should stay separate messages: {list(message_ids)}")
        timeline = [activity for activity in history.get("timelineActivities", []) if activity["id"] in call_ids]
        self.assertEqual([activity["id"] for activity in timeline], list(call_ids),
                         "History should return the earlier turn's calls in the order they ran.")
        status, listing, failing, mcp = timeline
        self.assertEqual(status["afterMessageID"], intro, "A call should follow the message written before it.")
        for activity in (listing, failing, mcp):
            self.assertEqual(activity["afterMessageID"], middle, "Calls after the second message should follow it.")
        self.assertEqual(status["input"], "git status --short && echo fixture-status-done")
        self.assertEqual(status["output"].strip(), "fixture-status-done")
        self.assertEqual(status["summary"], summaries[0])
        self.assertEqual(status["status"], "completed")
        self.assertEqual(listing["input"], "ls -1 -- . # lists every fixture file so the collapsed row can show how a long command is cut to a single line with an ellipsis instead of wrapping across the transcript\necho fixture-listing-done")
        self.assertEqual(listing["output"].strip().splitlines()[-1], "fixture-four.txt")
        self.assertEqual(listing["summary"], summaries[1])
        self.assertEqual(failing["input"], "exit 3")
        self.assertEqual(failing["status"], "failed", "A failing command should report failed.")
        self.assertIsNone(mcp.get("input"), "An MCP call's arguments must stay private.")
        self.assertIsNone(mcp.get("output"), "An MCP call's raw result must stay private.")
        raw = json.dumps(history)
        self.assertNotIn("timeline-private-argument", raw)
        self.assertNotIn("timeline-private-result", raw)
        latest_turn_id = history["messages"][-1].get("turnID")
        self.assertTrue(latest_turn_id, "The later turn's messages should carry their turn ID.")
        for activity in timeline:
            self.assertNotEqual(activity.get("turnID"), latest_turn_id, "Each call belongs to the earlier turn, not the latest one.")
        latest_ids = {activity["id"] for activity in history["activities"]}
        self.assertFalse(latest_ids & set(call_ids[:3]), "The earlier turn's shell calls are timeline activities, not the latest turn's.")

        newest = self.assert_success(self.call_cli("conversation", "history", task_id, "--limit", "2", extra_environment=environment)[0])
        self.assertGreater(newest["earlierMessageCount"], 0)
        self.assertFalse({activity["id"] for activity in newest.get("timelineActivities", [])} & set(call_ids),
                         "The newest page holds none of the earlier turn's messages, so none of its calls.")
        earlier = self.assert_success(self.call_cli(
            "conversation", "history", task_id, "--limit", "80", "--before", newest["messages"][0]["id"], extra_environment=environment,
        )[0])
        self.assertEqual([activity["id"] for activity in earlier.get("timelineActivities", []) if activity["id"] in call_ids], list(call_ids),
                         "The page holding the earlier turn should carry all of its calls.")
    def recorded_codex_app_servers(self, launches):
        """The app-servers a `-single-server` fixture recorded: socket servers, and stdio launches
        that are not a socket server's own stdio child."""
        records = [json.loads(line) for line in launches.read_text(encoding="utf-8").splitlines() if line.strip()] \
            if launches.is_file() else []
        socket_servers = {record["pid"] for record in records if record["listen"].startswith("unix://")}
        return [record for record in records
                if record["listen"].startswith("unix://") or record["parentPID"] not in socket_servers]
    def rewrite_codex_manifest_as_legacy(self, manifest_path, manifest, codex_home):
        """Renames a live server's manifest to the key a server started before one app-server
        served every caller would have had: it also held the goal-feature and goal-runtime flags."""
        parts = manifest["keyParts"]
        legacy_parts = [parts[0], codex_home, "false", "false", parts[2]]
        key_hash = hashlib.sha256("\x01".join(legacy_parts + [manifest["serviceName"]]).encode()).digest()[:12].hex()
        runs = manifest_path.parent
        (runs / f"{manifest['keyHash']}.log").rename(runs / f"{key_hash}.log")
        (runs / f"{manifest['keyHash']}.owner.lock").unlink(missing_ok=True)
        manifest_path.unlink()
        legacy = {**manifest, "keyHash": key_hash, "keyParts": legacy_parts}
        legacy_path = runs / f"{key_hash}.json"
        legacy_path.write_text(json.dumps(legacy), encoding="utf-8")
        return legacy_path
    def write_default(self, key, value):
        subprocess.run(["/usr/bin/defaults", "write", self.defaults_suite, key, value], check=True, capture_output=True)
    def default_exists(self, key):
        return subprocess.run(["/usr/bin/defaults", "read", self.defaults_suite, key], capture_output=True).returncode == 0
    def read_default(self, key):
        completed = subprocess.run(
            ["/usr/bin/defaults", "read", self.defaults_suite, key],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, f"Could not read isolated preference {key}: {completed.stderr}")
        return completed.stdout.strip(), completed.stderr
    def install_codex_fixture(self, name):
        """Installs the Codex app-server protocol fixture and returns its environment."""
        executable = self.data_directory / name
        copy_file(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        return {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
    def install_claude_fixture(self, name):
        """Installs the Claude Code protocol fixture and returns its turn environment."""
        source = Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py"
        executable = self.data_directory / name
        copy_file(source, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        return {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
    def run_claude_token_waste_turn(self, title):
        """One Claude fixture turn whose session file logs every request; see
        write_waste_session in scripts/fixtures/claude-code-fixture.py."""
        environment = self.install_claude_fixture("claude-fixture-token-waste")
        environment["CLAUDE_CONFIG_DIR"] = str(self.data_directory / "claude-config")
        task_id = self.create_task(title=title, provider="claude")["id"]
        self.assert_success(self.call_cli(
            "conversation", "send", task_id, "--message", "Show token waste.", extra_environment=environment,
        )[0])
        return task_id, environment
    def cpu_attribution_child(self, executable, kind):
        """The {pid, parentPID, workingDirectory} a running CPU-attribution fixture child recorded for itself."""
        record = Path(f"{executable}.cpu-child-{kind}.json")
        return json.loads(record.read_text(encoding="utf-8")) if record.is_file() else None
    @property
    def skills_home(self):
        """The isolated home a test data directory's skill gallery reads."""
        return self.data_directory / "skills-home"
    @property
    def skills_codex_home(self):
        return self.data_directory / "codex-home"
    @staticmethod
    def skill_manifest(name, description, body="Follow these steps."):
        return f"---\nname: {name}\ndescription: {description}\n---\n\n{body}\n"
    def write_skill(self, folder, name, description, body="Follow these steps."):
        (Path(folder) / name).mkdir(parents=True, exist_ok=True)
        (Path(folder) / name / "SKILL.md").write_text(self.skill_manifest(name, description, body), encoding="utf-8")
    def make_skill_repository(self, name, skills, links=None):
        """A committed Git repository in this case's data directory, so a task
        worktree checks its skills out without touching the shared fixture."""
        repository = self.data_directory / name
        repository.mkdir()
        self.run_git(repository, "init", "-q", "-b", "main")
        (repository / "README.md").write_text(f"# {name}\n", encoding="utf-8")
        for relative, text in skills.items():
            path = repository / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        for relative, target in (links or {}).items():
            path = repository / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(target)
        self.run_git(repository, "add", "-A")
        self.run_git(repository, "-c", "user.name=Playhouse Test", "-c", "user.email=playhouse@example.com",
                     "commit", "-q", "-m", "Skills fixture")
        return repository
    @staticmethod
    def skills_by_name(skills):
        return {skill["name"]: skill for skill in skills}
    def assertSamePath(self, actual, expected, message=None):
        self.assertEqual(os.path.realpath(actual), os.path.realpath(expected), message)
    @property
    def rules_claude_config(self):
        return self.skills_home / ".claude"
    @property
    def rules_managed(self):
        return self.skills_home / "managed" / "ClaudeCode"
    def write_file(self, path, text):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    def rule_catalog(self, task_id=None):
        command = ["rules", "list"]
        if task_id:
            command += ["--task", task_id]
        return self.assert_success(self.call_cli(*command)[0])
    @staticmethod
    def rules_by_name(rules):
        return {rule["name"]: rule for rule in rules}
    def rule_section(self, catalog, name):
        return self.rules_by_name(next(section for section in catalog["repositories"] if section["name"] == name)["rules"])
    @property
    def mcp_claude_state(self):
        """Claude Code's state file in the isolated home: its user MCP servers."""
        return self.skills_home / ".claude.json"
    @property
    def mcp_codex_config(self):
        return self.skills_codex_home / "config.toml"
    @property
    def mcp_managed(self):
        return self.rules_managed / "managed-mcp.json"
    def write_json(self, path, value):
        self.write_file(path, json.dumps(value, indent=2) + "\n")
    def read_json(self, path):
        return json.loads(Path(path).read_text(encoding="utf-8"))
    def read_toml(self, path):
        import tomllib
        return tomllib.loads(Path(path).read_text(encoding="utf-8"))
    def mcp_catalog(self, task_id=None):
        command = ["mcp", "list"]
        if task_id:
            command += ["--task", task_id]
        return self.assert_success(self.call_cli(*command)[0])
    @staticmethod
    def mcp_by_name(servers):
        return {server["name"]: server for server in servers}
    def mcp_section(self, catalog, name):
        return self.mcp_by_name(next(section for section in catalog["repositories"] if section["name"] == name)["servers"])
    def mcp_server(self, task_id, server_id):
        return next(server for server in self.all_mcp_servers(self.mcp_catalog(task_id)) if server["id"] == server_id)
    @staticmethod
    def all_mcp_servers(catalog):
        return [server for section in catalog["repositories"] for server in section["servers"]] + catalog["global"] + catalog["managed"]
    def install_codex_fixture(self, name):
        """Installs the Codex app-server fixture without running a turn, and returns its environment."""
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / name
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        copy_file(fixture, executable)
        executable.chmod(0o755)
        return {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
    @staticmethod
    def plugin_nodes(tree):
        nodes = [tree]
        for child in tree.get("children", []):
            nodes += BridgeTestHelpers02.plugin_nodes(child)
        return nodes
    def plugin_node(self, tree, test_id):
        for node in self.plugin_nodes(tree):
            if node.get("props", {}).get("testID") == test_id:
                return node
        self.fail(f"No atom has testID {test_id}.")
    @staticmethod
    def plugin_text(node):
        return "".join(child["text"] for child in node.get("children", []) if child["type"] == "#text")
    def render_plugin(self, source, *options, expected_status=0):
        path = self.data_directory / f"plugin-{uuid.uuid4().hex[:8]}.js"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        return self.call_cli("plugin", "render", "--file", path, *options, expected_status=expected_status)[0]
    @staticmethod
    def schedule_iso(moment):
        return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    @staticmethod
    def parse_schedule_iso(text):
        return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    def wait_for_task_status(self, task_id, statuses, timeout=60):
        deadline = time.monotonic() + timeout
        task = None
        while time.monotonic() < deadline:
            task = self.assert_success(self.call_cli("task", "get", task_id)[0])
            if task["status"] in statuses:
                return task
            time.sleep(0.25)
        self.fail(f"Task {task_id} never reached {statuses}; last state: {task}")
    def fixture_user_prompts(self, executable):
        history = Path(str(executable) + ".history")
        if not history.is_file():
            return []
        return [turn.get("userText") or "" for turn in json.loads(history.read_text(encoding="utf-8")).get("turns", [])]
    def codex_turn_start_prompts(self, executable):
        """Every prompt the Codex fixture's turn/start received, helper turns (titles, PR descriptions) included."""
        starts = Path(str(executable) + ".turn-starts")
        if not starts.is_file():
            return []
        return [json.loads(line)["text"] for line in starts.read_text(encoding="utf-8").splitlines() if line.strip()]
    def plugins_folder(self):
        return self.data_directory / "plugins"
    def set_pull_request_mode(self, task_id, mode, extra_environment=None):
        """Chooses a task's pull request mode as its card's pill does: the `pull-request-mode` plugin's state.
        The plugin acts on the change at once (a Green or Merge task in Review is followed), with this call's environment."""
        value = "null" if mode is None else json.dumps(mode)
        return self.assert_success(self.call_cli(
            "plugin", "state", "--id", "pull-request-mode", "--key", task_id, "--value", value, extra_environment=extra_environment,
        )[0])
    def pull_request_mode(self, task_id):
        """The mode the `pull-request-mode` plugin keeps for a task, or None for the default (Manual)."""
        state = self.assert_success(self.call_cli("plugin", "state", "--id", "pull-request-mode")[0])
        return state["state"].get(task_id)
    def write_installed_plugin(self, plugin_id, source, placement="composerActions", presentation="popover", manifest=None):
        """Writes a plugin folder as an authoring agent would: plugin.json and index.js."""
        folder = self.plugins_folder() / plugin_id
        folder.mkdir(parents=True, exist_ok=True)
        fields = {"id": plugin_id, "name": plugin_id.replace("-", " ").title(), "icon": "puzzlepiece.extension",
                  "placement": placement, "presentation": presentation}
        fields.update(manifest or {})
        (folder / "plugin.json").write_text(json.dumps(fields), encoding="utf-8")
        if source is not None:
            (folder / "index.js").write_text(source, encoding="utf-8")
        return folder
    def start_plugin_fetch_server(self):
        """The local server the fetch plugin reaches; it stops when its stdin closes."""
        server = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve().parent / "fixtures" / "plugin-fetch-server.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        def stop():
            server.stdin.close()
            server.wait(timeout=10)
        self.addCleanup(stop)
        ports = json.loads(server.stdout.readline())
        return f"http://127.0.0.1:{ports['port']}", f"http://127.0.0.1:{ports['closedPort']}"
    def assert_delete_stops_live_turns(self, provider):
        """Deletes a task whose turn waits on a question and one whose turn ignores its interrupt.
        Each delete finishes within seconds, with no wait for the agent, and leaves nothing of
        the task running or stored."""
        display = "Claude" if provider == "claude" else "Codex"
        fixture_source = Path(__file__).resolve().parent / "fixtures" / (
            "claude-code-fixture.py" if provider == "claude" else "codex-app-server-fixture.py"
        )
        environment_name = "PLAYHOUSE_E2E_CLAUDE_EXECUTABLE" if provider == "claude" else "PLAYHOUSE_E2E_CODEX_EXECUTABLE"
        thread_key = "claudeSessionID" if provider == "claude" else "codexThreadID"
        if provider == "claude":
            (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
                "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
            )
        else:
            (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
                "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
            )
        for scenario, message in [("question", "Ask a structured question."), ("hold-interrupt", "Hold until stopped.")]:
            executable = self.data_directory / f"{provider}-fixture-delete-{scenario}"
            copy_file(fixture_source, executable)
            executable.chmod(0o755)
            # The Codex question fixture asks once this marker exists.
            Path(str(executable) + ".turn-release").write_text("Ask at once.\n", encoding="utf-8")
            environment = {environment_name: str(executable)}
            created, _ = self.call_cli(
                "task", "create", "--title", f"{display} delete during {scenario}", "--prompt", "Fixture task description.",
                "--repo", self.primary, "--provider", provider,
            )
            task_id = self.assert_success(created)["id"]
            sender = self.start_cli("conversation", "send", task_id, "--message", message, extra_environment=environment)
            waiting_send = None
            try:
                if scenario == "question":
                    self.wait_for(
                        lambda: self.assert_success(self.call_cli("task", "get", task_id)[0])["status"] == "Waiting Response",
                        f"The {display} turn should wait on its question before the delete.",
                    )
                else:
                    self.wait_for(lambda: Path(str(executable) + ".interrupt-ready").is_file(),
                                  f"The {display} turn should be running before the delete.")
                live = self.assert_success(self.call_cli("task", "get", task_id)[0])
                thread_id = live[thread_key]
                worktree = Path(live["repositoryWorktrees"][0]["worktreePath"])
                self.assertTrue(worktree.is_dir(), "The turn should run in the task's own worktree.")
                runtime = self.assert_success(self.call_cli("conversation", "runtime")[0])
                self.assertIn(thread_id, runtime["activeThreadIDs"], f"The {display} turn should be live when the delete starts.")
                with self.assertRaises(OSError, msg="A live turn holds the task's turn reservation."):
                    ConversationTurnLockBarrier(self.data_directory, task_id)

                waiting_send = None
                if scenario == "hold-interrupt":
                    # A follow-up queued behind the turn and a send waiting for it are stopped with it.
                    self.assert_success(self.call_cli("conversation", "queue", task_id, "--message", "Queued before the delete.")[0])
                    waiting_send = self.start_cli("conversation", "send", task_id, "--message", "Sent while the turn runs.", extra_environment=environment)
                    self.wait_for(lambda: sum(
                        event.get("event") == "conversation.send.accepted" and event.get("taskID") == task_id
                        for event in self.diagnostic_events()
                    ) == 2, "The second send should be waiting for the running turn before the delete.")
                started = time.monotonic()
                first = self.start_cli("task", "delete", task_id, extra_environment=environment)
                second = self.start_cli("task", "delete", task_id, extra_environment=environment)
                response, _ = self.finish_cli(first, ["task", "delete", task_id], timeout=30)
                elapsed = time.monotonic() - started
                self.assertTrue(self.assert_success(response)["deleted"])
                self.assertLess(elapsed, 15, f"Deleting a task with a live {display} turn must not wait for the agent.")
                # A delete sent while the first one runs shares its result; one sent after it finds no task.
                stdout, _ = second.communicate(timeout=30)
                repeated = json.loads([line for line in stdout.splitlines() if line.strip()][-1])
                if repeated.get("ok"):
                    self.assertTrue(repeated["result"]["deleted"])
                else:
                    self.assert_failure(repeated, "not_found")
                self.assert_failure(self.call_cli("task", "delete", task_id, expected_status=3)[0], "not_found")
                self.assert_failure(self.call_cli("task", "get", task_id, expected_status=3)[0], "not_found")

                sender.communicate(timeout=20)
                self.assertNotEqual(sender.returncode, 0, "The stopped turn's send ends without a result.")
                self.assertFalse(worktree.exists(), "Deleting the task removes the worktree its turn ran in.")
                ConversationTurnLockBarrier(self.data_directory, task_id).release()
                settled = self.assert_success(self.call_cli("conversation", "runtime")[0])
                self.assertNotIn(thread_id, settled["activeThreadIDs"], "The deleted task's turn is no longer live.")
                if provider == "claude":
                    self.wait_for(
                        lambda: subprocess.run(["pgrep", "-f", str(executable)], capture_output=True).returncode != 0,
                        "Deleting the task stops its Claude Code process.", timeout=10,
                    )
                if waiting_send is not None:
                    stdout, _ = waiting_send.communicate(timeout=20)
                    self.assert_failure(json.loads([line for line in stdout.splitlines() if line.strip()][-1]), "task_deleting")
                    queue_file = self.data_directory / "queued-conversation-messages.json"
                    queued = json.loads(queue_file.read_text(encoding="utf-8")) if queue_file.is_file() else {}
                    self.assertNotIn(task_id.upper(), queued, "Deleting the task removes its queued follow-ups.")
                    if provider == "codex":
                        held_turns = Path(str(executable) + ".held-turns").read_text(encoding="utf-8").split()
                        self.assertEqual(len(held_turns), 1, "Neither the queued follow-up nor the waiting send starts a turn.")
                        # Let the app-server finish the turn it was told to stop, so its late events
                        # reach the daemon before the transcript is checked.
                        release = Path(str(executable) + ".interrupt-release")
                        release.write_text("release\n", encoding="utf-8")
                        self.wait_for(lambda: not release.exists(), "The Codex fixture should end the stopped turn after the delete.")
                # The stopped turn's last events must not bring the deleted task's transcript back.
                time.sleep(0.5)
                self.assertEqual(self.conversation_row_counts(task_id), {"turns": 0, "messages": 0, "activities": 0})
                self.assert_failure(self.call_cli("task", "get", task_id, expected_status=3)[0], "not_found")
                events = [event for event in self.diagnostic_events() if event.get("taskID") == task_id]
                names = [event.get("event") for event in events]
                self.assertIn("task.delete.stopping_turn", names)
                stopped = next(event for event in events if event.get("event") == "task.delete.turn_stopped")
                if scenario == "question":
                    self.assertEqual(stopped.get("declinedQuestion"), "true", "The delete declines the question the turn waits on.")
                    self.assertEqual(stopped["method"], "interrupt", "A declined question ends the turn without force.")
                    self.assertNotIn("task.delete.turn_force_killed", names)
                if scenario == "hold-interrupt":
                    self.assertTrue(Path(str(executable) + ".interrupt-received").is_file(),
                                    f"The delete first asks {display} to interrupt the turn.")
                    self.assertIn("task.delete.turn_force_killed", names,
                                  "A turn that ignores its interrupt is force-stopped.")
                    self.assertEqual(stopped["method"], "force")
                self.assertIn("task.delete.succeeded", names)
                self.assertNotIn("task.delete.failed", names)
            finally:
                Path(str(executable) + ".interrupt-release").write_text("release\n", encoding="utf-8")
                if waiting_send is not None and waiting_send.poll() is None:
                    waiting_send.kill()
                    waiting_send.communicate()
                if sender.poll() is None:
                    sender.kill()
                    sender.communicate()

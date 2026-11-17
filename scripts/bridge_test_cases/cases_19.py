from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases19:
    # case-contract: test_mentions_menu_lists_expands_and_remembers_recent | Typing @ in the composer opens a mention menu that lists, in order, the task's enabled skills, MCP servers, agents (Claude Code's .claude/agents and Codex's .codex/agents, an agent both define being one item that names both files, the running provider's first), repositories (the task's own and those under the repository root), then other board tasks, and never rule files; before anything was mentioned, an empty query shows that whole list, grouped under a header per kind. Typing after the @ filters it, items whose handle starts with the query first, and a query nothing matches shows an empty state. The arrow keys move the highlight, Return or Tab inserts the highlighted item, and a click inserts the clicked one, as @handle drawn in the accent color; Escape closes the menu while keeping the typed text. Sending appends a <playhouse-mentions> block naming each mentioned item with its full path or details (for the task's repository, also its worktree), only for known handles that start a word, and the provider receives it while the transcript shows only the typed message, once, with its mentions drawn in the accent color, and the task's saved prompt keeps the typed text. Steering an active Codex turn expands its mentions the same way, exactly once, and shows the steer once, while a steer that misses its turn is queued as typed. The sent mentions become the recent mentions, most recent first and ten at most, which an empty query then shows instead, and they persist across fresh CLI processes. Listing mentions without a task is a usage error, and for an unknown task is not_found.
    def test_mentions_menu_lists_expands_and_remembers_recent(self):
        repository = self.make_skill_repository("mention-repo", {
            "AGENTS.md": "# Mention repo rules\nKeep it tidy.\n",
            ".agents/skills/mention-skill/SKILL.md": self.skill_manifest("mention-skill", "A skill to mention"),
            **{f".agents/skills/mention-extra-{n}/SKILL.md": self.skill_manifest(f"mention-extra-{n}", "Another skill to mention") for n in range(1, 5)},
            ".mcp.json": json.dumps({"mcpServers": {"docs-server": {"type": "stdio", "command": "node", "args": ["docs.js"]}}}),
            ".claude/agents/reviewer.md": "---\nname: reviewer\ndescription: Reviews changes\n---\n\nReview the diff.\n",
            ".codex/agents/reviewer.toml": 'name = "reviewer"\ndescription = "Reviews changes"\ndeveloper_instructions = """Review."""\n',
            ".codex/agents/helper.toml": 'name = "helper"\ndescription = "Codex-only helper"\n',
        })
        environment = self.install_claude_fixture("claude-fixture-mentions")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        other = self.create_task("Other mention task", roots=[])
        task = self.create_skills_task("Mention task", [repository], provider="claude")
        task_id = task["id"]
        worktree = task["repositoryWorktrees"][0]["worktreePath"]

        listed = self.assert_success(self.call_cli("mentions", "list", "--task", task_id)[0])
        items = listed["items"]
        by_handle = {item["handle"]: item for item in items}
        order = ["skill", "mcp", "agent", "repository", "task"]
        kinds = [item["kind"] for item in items]
        self.assertEqual(kinds, sorted(kinds, key=order.index), "Skills come first, then MCP servers, agents, repositories and tasks.")
        self.assertEqual(kinds[0], "skill")
        self.assertEqual(len(by_handle), len(items), "Every handle is unique.")
        self.assertNotIn("mention-repo/AGENTS.md", by_handle, "The repository's rule file is not mentionable.")
        self.assertFalse(any(item["id"].startswith("rule:") or "AGENTS.md" in item["reference"] for item in items), "No rule is listed.")
        self.assertEqual(by_handle["mention-skill"]["kind"], "skill")
        self.assertIn("mention-skill/SKILL.md", by_handle["mention-skill"]["reference"])
        self.assertEqual(by_handle["docs-server"]["kind"], "mcp")
        reviewer = by_handle["reviewer"]
        self.assertEqual(reviewer["kind"], "agent")
        self.assertEqual(reviewer["detail"], "Reviews changes")
        self.assertIn(".claude/agents/reviewer.md", reviewer["reference"], "An agent both providers define names Claude's subagent file.")
        self.assertIn(".codex/agents/reviewer.toml", reviewer["reference"], "and Codex's agent file, in one item.")
        self.assertLess(reviewer["reference"].index("Claude Code subagent"), reviewer["reference"].index("Codex agent"),
                        "The running provider's definition comes first.")
        self.assertEqual(by_handle["helper"]["kind"], "agent")
        own = by_handle["mention-repo"]
        self.assertEqual(own["kind"], "repository")
        self.assertEqual(own["id"], f"repository:{repository}")
        self.assertIn(worktree, own["reference"], "The task's own repository names its worktree.")
        self.assertEqual(by_handle["primary"]["kind"], "repository", "Repositories under the repository root are listed too.")
        self.assertEqual(by_handle["Other-mention-task"]["id"], f"task:{other['id']}")
        self.assertNotIn("Mention-task", by_handle, "The task never mentions itself.")
        self.assertEqual(listed["recentIDs"], [])
        self.assertEqual([item["id"] for item in listed["suggestions"]], [item["id"] for item in items],
                         "Before anything was mentioned, an empty query shows the whole list.")
        searched = self.assert_success(self.call_cli("mentions", "list", "--task", task_id, "--query", "rev")[0])["suggestions"]
        self.assertEqual(searched[0]["handle"], "reviewer", "A handle that starts with the query comes first.")
        self.assertTrue(all("rev" in (item["handle"] + item["title"] + item["detail"]).lower() for item in searched))
        self.assertEqual(self.assert_success(self.call_cli("mentions", "list", "--task", task_id, "--query", "zzz-nothing")[0])["suggestions"], [])

        message = "Ask @reviewer to check @mention-repo, then mail me@example.com about @unknown."
        # Without an unsent draft to keep, the send becomes the task's saved prompt.
        self.assert_success(self.call_cli("task", "prompt", task_id, "--text", "")[0])
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", message, extra_environment=environment)[0])
        turn = next(turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if (turn.get("userText") or "").startswith("Ask @reviewer"))
        sent = turn["userText"]
        self.assertTrue(sent.startswith(message + "\n\n<playhouse-mentions>\n"), sent)
        self.assertTrue(sent.endswith("</playhouse-mentions>"), sent)
        lines = [line for line in sent.splitlines() if line.startswith("- @")]
        self.assertEqual(len(lines), 2, f"Only the known handles that start a word are expanded: {lines}")
        self.assertEqual(lines[0], f"- @reviewer (agent): {reviewer['reference']}")
        self.assertEqual(lines[1], f"- @mention-repo (repository): {own['reference']}", "Trailing punctuation still ends the mention.")
        history = self.assert_success(self.call_cli("conversation", "history", task_id)[0])
        stored = next(entry for entry in history["messages"] if entry["role"] == "user" and entry["text"].startswith(message))
        self.assertIn("<playhouse-mentions>", stored["text"], "The transcript keeps the block, which the conversation view hides.")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task_id)[0])["savedPrompt"], message,
                         "The task's saved prompt keeps the typed text.")

        after = self.assert_success(self.call_cli("mentions", "list", "--task", task_id)[0])
        self.assertEqual(after["recentIDs"], ["agent:reviewer", f"repository:{repository}"], "Sent mentions become recent, in order.")
        self.assertEqual([item["handle"] for item in after["suggestions"]], ["reviewer", "mention-repo"],
                         "An empty query now shows the recent mentions instead of the whole list.")

        many = [item["handle"] for item in items if item["handle"] not in ("reviewer", "mention-repo")][:11]
        self.assertEqual(len(many), 11)
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", " ".join("@" + handle for handle in many),
                                          extra_environment=environment)[0])
        recent = self.assert_success(self.call_cli("mentions", "list", "--task", task_id)[0])["recentIDs"]
        self.assertEqual(recent, [by_handle[handle]["id"] for handle in many[:10]], "At most ten recent mentions are kept, newest first.")

        # Steering a Codex turn expands its mentions too, the running provider's agent file first;
        # a steer that misses its turn is queued as typed and expanded once when it is sent.
        steer_task = self.create_skills_task("Mention steer task", [repository], provider="codex")["id"]
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        codex = self.data_directory / "codex-fixture-mention-steer-serial-success-wait"
        copy_file(fixture, codex)
        codex.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        codex_environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(codex)}
        send_command = ["conversation", "send", steer_task, "--message", "Hold this turn for a steer."]
        process = self.start_cli(*send_command, extra_environment=codex_environment)
        ready = Path(str(codex) + ".resolve-ready")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not ready.exists() and process.poll() is None:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "The fixture holds the turn active for steering.")
            Path(str(codex) + ".reject-next-steer").write_text("The expected turn ID is stale.\n", encoding="utf-8")
            missed = self.assert_success(self.call_cli("conversation", "steer", steer_task, "--message", "@helper later",
                                                       extra_environment=codex_environment)[0])
            self.assertTrue(missed["queued"])
            queued = self.assert_success(self.call_cli("conversation", "queue-list", steer_task)[0])
            self.assertEqual([item["text"] for item in queued], ["@helper later"], "A missed steer is queued as typed, not expanded.")
            self.assert_success(self.call_cli("conversation", "queue-remove", steer_task, queued[0]["id"])[0])
            steered = self.assert_success(self.call_cli("conversation", "steer", steer_task, "--message", "Hurry, @reviewer.",
                                                        extra_environment=codex_environment)[0])
            self.assertTrue(steered["accepted"])
        finally:
            Path(str(codex) + ".resolve-continue").write_text("Release the active turn.\n", encoding="utf-8")
        self.finish_cli(process, send_command)
        steer_history = json.loads(Path(str(codex) + ".history").read_text(encoding="utf-8"))
        steer_text = "".join(item.get("text", "") for request in steer_history["steerRequests"] for item in request.get("input", []))
        self.assertTrue(steer_text.startswith("Hurry, @reviewer.\n\n<playhouse-mentions>\n"), steer_text)
        self.assertEqual(steer_text.count("<playhouse-mentions>"), 1)
        agent_line = next(line for line in steer_text.splitlines() if line.startswith("- @reviewer (agent): "))
        self.assertLess(agent_line.index("Codex agent `reviewer`"), agent_line.index("Claude Code subagent"),
                        "A Codex task names Codex's agent file first.")

        self.assert_failure(self.call_cli("mentions", "list", "--task", str(uuid.uuid4()), expected_status=3)[0], "not_found")
        self.assert_failure(self.call_cli("mentions", "list", expected_status=2)[0], "invalid_argument")
    # case-contract: test_rules_catalog_lists_repo_global_and_managed_rules | The Skills page, titled Skills, Rules & MCP, switches to its Rules list with a Skills | Rules | MCP picker. Rules lists, in one sectioned list whose Repo, Global and Managed anchors scroll it to their sections, each task repository's instruction files from its worktree (AGENTS.override.md, AGENTS.md, CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md, and every .md file under .claude/rules, keyed by the source repository and the file's path), the user's global rules (~/.agents/AGENTS.md, Codex's AGENTS.md, and Claude's CLAUDE.md and rules folder), and the organization's managed CLAUDE.md. Each rule row shows only its name and Claude and Codex badges for the agents that follow it, without hovering, and its other details show in a hint while the pointer rests on it, which carries no provider badge: each rule names the agents that follow it in Playhouse sessions and the ones that read it natively: a repository AGENTS.md beside a CLAUDE.md is followed by both but read natively only by Codex, ~/.agents/AGENTS.md is read natively by neither yet shared with both, a CLAUDE.md symlinked to AGENTS.md is one Linked rule read natively by both, AGENTS.override.md is Codex's own and leaves the AGENTS.md beside it to Claude, a .claude/rules file shows its paths globs, the managed CLAUDE.md is Claude's only and read-only, and an @import of a missing file is flagged as a problem. A repository without rules shows an empty state. Reading a rule returns its file exactly, and an unknown rule is not_found.
    def test_rules_catalog_lists_repo_global_and_managed_rules(self):
        working = self.make_skill_repository("rules-catalog-repo", {
            "AGENTS.md": "# Repository conventions\nUse tabs.\n",
            "CLAUDE.md": "# Claude notes\n@docs/missing.md\n",
            ".claude/CLAUDE.md": "Claude folder notes.\n",
            "CLAUDE.local.md": "My sandbox URL.\n",
            ".claude/rules/api.md": "---\npaths:\n  - \"src/api/**\"\n---\n\n# API rules\nValidate input.\n",
            ".claude/rules/style/naming.md": "Name things plainly.\n",
        })
        linked = self.make_skill_repository("rules-linked-repo", {"AGENTS.md": "# Linked rules\nShared by both.\n"},
                                            links={"CLAUDE.md": "AGENTS.md"})
        override = self.make_skill_repository("rules-override-repo", {
            "AGENTS.md": "# Team rules\n", "AGENTS.override.md": "# Codex override\n",
        })
        empty = self.make_skill_repository("rules-empty-repo", {})
        self.write_file(self.skills_home / ".agents" / "AGENTS.md", "# Personal rules\nBe brief.\n")
        self.write_file(self.skills_codex_home / "AGENTS.md", "# Codex home rules\n")
        self.write_file(self.rules_claude_config / "CLAUDE.md", "# Claude home rules\n")
        self.write_file(self.rules_claude_config / "rules" / "global-style.md", "Prefer small functions.\n")
        self.write_file(self.rules_managed / "CLAUDE.md", "# Company policy\n")

        task = self.create_skills_task("Rules catalog", [working, linked, override, empty])
        worktrees = {record["repositoryPath"]: record["worktreePath"] for record in task["repositoryWorktrees"]}
        catalog = self.rule_catalog(task["id"])
        self.assertEqual([section["name"] for section in catalog["repositories"]],
                         ["rules-catalog-repo", "rules-linked-repo", "rules-override-repo", "rules-empty-repo"])
        self.assertEqual(catalog["repositories"][0]["repositoryPath"], str(working), "Rules are keyed by the source repository.")
        self.assertSamePath(catalog["repositories"][0]["rootPath"], worktrees[str(working)])
        self.assertEqual(catalog["repositories"][3]["rules"], [], "A repository without rules has an empty section.")

        repo = self.rule_section(catalog, "rules-catalog-repo")
        self.assertEqual(list(repo), ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md", ".claude/rules/api.md", ".claude/rules/style/naming.md"],
                         "Every rule file is listed, including nested .claude/rules files.")
        agents = repo["AGENTS.md"]
        self.assertEqual(agents["id"], f"repo:{working}#AGENTS.md")
        self.assertEqual(agents["providers"], ["claude", "codex"], "Playhouse has both agents follow AGENTS.md.")
        self.assertEqual(agents["nativeProviders"], ["codex"], "Claude Code skips AGENTS.md beside a CLAUDE.md on its own.")
        self.assertEqual(agents["sharedWith"], ["claude"], "Playhouse has Claude read it alongside CLAUDE.md.")
        self.assertFalse(agents["availableOutsidePlayhouse"])
        self.assertEqual(agents["summary"], "Repository conventions")
        self.assertSamePath(agents["filePath"], Path(worktrees[str(working)]) / "AGENTS.md")
        claude = repo["CLAUDE.md"]
        self.assertEqual(claude["nativeProviders"], ["claude"])
        self.assertEqual(claude["providers"], ["claude", "codex"])
        self.assertIn("@docs/missing.md", claude["issue"], "An import of a missing file is a problem.")
        self.assertIsNone(agents.get("issue"))
        self.assertEqual(repo[".claude/rules/api.md"]["paths"], ["src/api/**"])
        self.assertEqual(repo[".claude/rules/style/naming.md"]["paths"], [])
        self.assertEqual(repo["CLAUDE.local.md"]["locations"][0]["layout"], "claudeLocal")
        self.assertEqual(repo[".claude/CLAUDE.md"]["locations"][0]["layout"], "claude")
        self.assertEqual(repo[".claude/CLAUDE.md"]["nativeProviders"], ["claude"])
        self.assertFalse(agents["linkable"], "Claude Code reads CLAUDE.md instead, so AGENTS.md has no link to offer.")
        self.assertFalse(repo[".claude/rules/style/naming.md"]["linkable"], "Codex has no place for a separate rule file.")

        linked_rules = self.rule_section(catalog, "rules-linked-repo")
        self.assertEqual(list(linked_rules), ["AGENTS.md"], "A CLAUDE.md symlinked to AGENTS.md is one rule.")
        self.assertEqual(sorted(location["layout"] for location in linked_rules["AGENTS.md"]["locations"]), ["agents", "claude"])
        self.assertTrue(linked_rules["AGENTS.md"]["availableOutsidePlayhouse"])
        self.assertEqual(linked_rules["AGENTS.md"]["nativeProviders"], ["claude", "codex"])

        override_rules = self.rule_section(catalog, "rules-override-repo")
        self.assertEqual(override_rules["AGENTS.override.md"]["providers"], ["codex"], "AGENTS.override.md is Codex's own.")
        self.assertEqual(override_rules["AGENTS.md"]["providers"], ["claude"], "Codex reads the override instead of AGENTS.md.")

        self.assertEqual([rule["id"] for rule in catalog["global"]],
                         ["global:agents/AGENTS.md", "global:codex/AGENTS.md", "global:claude/CLAUDE.md", "global:claude/rules/global-style.md"])
        global_rules = self.rules_by_name(catalog["global"])
        codex_name = catalog["global"][1]["name"]
        self.assertSamePath(codex_name, self.skills_codex_home / "AGENTS.md")
        self.assertEqual(list(global_rules), ["~/.agents/AGENTS.md", codex_name, "~/.claude/CLAUDE.md", "~/.claude/rules/global-style.md"])
        shared = global_rules["~/.agents/AGENTS.md"]
        self.assertEqual(shared["id"], "global:agents/AGENTS.md")
        self.assertEqual(shared["nativeProviders"], [], "Neither CLI reads ~/.agents/AGENTS.md on its own.")
        self.assertEqual(shared["providers"], ["claude", "codex"], "Playhouse shares it with both.")
        self.assertEqual(shared["sharedWith"], ["claude", "codex"])
        self.assertTrue(shared["linkable"])
        self.assertEqual(global_rules[codex_name]["nativeProviders"], ["codex"])
        self.assertEqual(global_rules["~/.claude/CLAUDE.md"]["nativeProviders"], ["claude"])
        self.assertEqual(global_rules["~/.claude/rules/global-style.md"]["id"], "global:claude/rules/global-style.md")
        self.assertTrue(all(rule["providers"] == ["claude", "codex"] for rule in global_rules.values()))

        managed = catalog["managed"]
        self.assertEqual([rule["id"] for rule in managed], ["managed:claude/CLAUDE.md"])
        self.assertEqual(managed[0]["providers"], ["claude"], "The managed CLAUDE.md is Claude's only.")
        self.assertFalse(managed[0]["editable"])

        detail = self.assert_success(self.call_cli("rules", "get", "--task", task["id"], "--rule", agents["id"])[0])
        self.assertEqual(detail["content"], "# Repository conventions\nUse tabs.\n")
        self.assertEqual(detail["rule"]["id"], agents["id"])
        self.assert_failure(self.call_cli("rules", "get", "--task", task["id"], "--rule", "global:no-such-rule", expected_status=3)[0], "not_found")
        without_task = self.rule_catalog()
        self.assertEqual(without_task["repositories"], [])
        self.assertEqual([rule["name"] for rule in without_task["global"]], list(global_rules))
    # case-contract: test_rules_create_update_and_delete_on_disk | New Rule writes the shared AGENTS.md (the chosen task worktree's, or ~/.agents/AGENTS.md for a global rule) or, given a name, a topic file in .claude/rules (the worktree's, or Claude's global rules folder) whose paths frontmatter lists the globs given; empty instructions, an invalid name, globs without a name, the managed scope, and an existing file are rejected with nothing written, and the source checkout is left alone. Clicking a rule opens its editor on the whole file with a Markdown preview, and saving writes the file exactly as typed; empty instructions and a rules-folder file whose frontmatter never closes are rejected while keeping the file. The managed CLAUDE.md opens read-only without Save and can be neither edited nor deleted. Deleting a rule removes its file from disk, and every change is visible to a fresh CLI process and on the page.
    def test_rules_create_update_and_delete_on_disk(self):
        repository = self.make_skill_repository("rules-manage-repo", {})
        task = self.create_skills_task("Rules manage", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.write_file(self.rules_managed / "CLAUDE.md", "# Company policy\n")

        def create(*arguments, expected_status=0):
            return self.call_cli("rules", "create", "--task", task["id"], *arguments, expected_status=expected_status)[0]

        for arguments in [
            ["--scope", "repo", "--root", str(repository), "--body", "   "],
            ["--scope", "repo", "--root", str(repository), "--name", "Bad Name", "--body", "Text."],
            ["--scope", "repo", "--root", str(repository), "--path", "src/**", "--body", "Scoped without a name."],
            ["--scope", "managed", "--body", "Not allowed."],
        ]:
            self.assert_failure(create(*arguments, expected_status=2), "invalid_argument")
        self.assertFalse((worktree / "AGENTS.md").exists() or (worktree / ".claude").exists(), "A rejected rule writes nothing.")

        repo_rule = self.assert_success(create("--scope", "repo", "--root", str(repository), "--body", "# Repository rules\nRun the linter."))
        self.assertEqual(repo_rule["id"], f"repo:{repository}#AGENTS.md")
        self.assertEqual((worktree / "AGENTS.md").read_text(encoding="utf-8"), "# Repository rules\nRun the linter.\n")
        self.assertFalse((repository / "AGENTS.md").exists(), "The source checkout is left alone.")
        self.assert_failure(create("--scope", "repo", "--root", str(repository), "--body", "Again.", expected_status=1), "already_exists")
        self.assertEqual((worktree / "AGENTS.md").read_text(encoding="utf-8"), "# Repository rules\nRun the linter.\n")

        global_rule = self.assert_success(create("--scope", "global", "--body", "Answer briefly."))
        self.assertEqual(global_rule["id"], "global:agents/AGENTS.md")
        self.assertEqual((self.skills_home / ".agents" / "AGENTS.md").read_text(encoding="utf-8"), "Answer briefly.\n")
        topic = self.assert_success(create("--scope", "repo", "--root", str(repository), "--name", "api-style",
                                           "--path", "src/**/*.ts", "--path", "lib/**", "--body", "Validate every input."))
        self.assertEqual(topic["id"], f"repo:{repository}#.claude/rules/api-style.md")
        self.assertEqual(topic["paths"], ["src/**/*.ts", "lib/**"])
        self.assertEqual((worktree / ".claude" / "rules" / "api-style.md").read_text(encoding="utf-8"),
                         '---\npaths:\n  - "src/**/*.ts"\n  - "lib/**"\n---\n\nValidate every input.\n')
        global_topic = self.assert_success(create("--scope", "global", "--name", "global-topic", "--body", "Global topic."))
        self.assertEqual(global_topic["id"], "global:claude/rules/global-topic.md")
        self.assertTrue((self.rules_claude_config / "rules" / "global-topic.md").is_file())

        def update(rule_id, content, expected_status=0):
            path = self.data_directory / f"rule-edit-{uuid.uuid4().hex}.md"
            path.write_text(content, encoding="utf-8")
            return self.call_cli("rules", "update", "--task", task["id"], "--rule", rule_id, "--content-file", path, expected_status=expected_status)[0]

        edited = "# Repository rules\n\n- Run the linter.\n- Keep commits small.\n"
        self.assertEqual(self.assert_success(update(repo_rule["id"], edited))["summary"], "Repository rules")
        self.assertEqual((worktree / "AGENTS.md").read_text(encoding="utf-8"), edited, "An edit is saved exactly as written.")
        self.assert_failure(update(repo_rule["id"], "  \n", expected_status=2), "invalid_argument")
        self.assert_failure(update(topic["id"], "---\npaths:\n  - src/**\nNo closing line.\n", expected_status=2), "invalid_argument")
        self.assertEqual((worktree / "AGENTS.md").read_text(encoding="utf-8"), edited, "A rejected edit keeps the file.")
        self.assertIn("Validate every input.", (worktree / ".claude" / "rules" / "api-style.md").read_text(encoding="utf-8"))
        self.assertEqual(self.assert_success(self.call_cli("rules", "get", "--task", task["id"], "--rule", repo_rule["id"])[0])["content"], edited)

        self.assert_failure(update("managed:claude/CLAUDE.md", "Rewritten.\n", expected_status=2), "invalid_argument")
        self.assert_failure(self.call_cli("rules", "delete", "--task", task["id"], "--rule", "managed:claude/CLAUDE.md", expected_status=2)[0], "invalid_argument")
        self.assertEqual((self.rules_managed / "CLAUDE.md").read_text(encoding="utf-8"), "# Company policy\n", "The managed CLAUDE.md is read-only.")

        self.assertEqual(self.assert_success(self.call_cli("rules", "delete", "--task", task["id"], "--rule", topic["id"])[0]), {"deleted": True})
        self.assertFalse((worktree / ".claude" / "rules" / "api-style.md").exists(), "Deleting removes the rule file from disk.")
        self.assert_failure(self.call_cli("rules", "get", "--task", task["id"], "--rule", topic["id"], expected_status=3)[0], "not_found")
        fresh = self.rule_catalog(task["id"])
        self.assertEqual([rule["name"] for rule in fresh["repositories"][0]["rules"]], ["AGENTS.md"])
        self.assertEqual([rule["name"] for rule in fresh["global"]], ["~/.agents/AGENTS.md", "~/.claude/rules/global-topic.md"])
    # case-contract: test_rules_enable_state_and_outside_links_persist | A lone AGENTS.md that both CLIs already read on their own shows Both CLIs rather than Linked, since nothing links to it. Turning a rule off is stored by Playhouse rather than in either provider's settings, survives fresh CLI processes and reopening the page, and can be turned back on; the managed CLAUDE.md can't be turned off. A turned-off rule Codex reads itself, such as the working repository's AGENTS.md, still lists Codex and the page says Codex still reads it, while a rule only Playhouse shares, such as ~/.agents/AGENTS.md, reaches neither agent. Making ~/.agents/AGENTS.md available outside Playhouse writes absolute symlinks as Codex's AGENTS.md and Claude's CLAUDE.md, after which it is one Linked rule read natively by both; a repository CLAUDE.md gets a relative AGENTS.md symlink beside it. An existing file at a link path is left untouched and the request fails with already_exists without writing any link, a rule Codex has no place for can't be linked, and removing the outside link deletes only the symlinks.
    def test_rules_enable_state_and_outside_links_persist(self):
        working = self.make_skill_repository("rules-link-repo", {"AGENTS.md": "# Working rules\n"})
        other = self.make_skill_repository("rules-link-claude-repo", {
            "CLAUDE.md": "# Claude-only rules\n", ".claude/rules/topic.md": "A topic rule.\n",
        })
        task = self.create_skills_task("Rules links", [working, other])
        other_worktree = Path(next(record["worktreePath"] for record in task["repositoryWorktrees"] if record["repositoryPath"] == str(other)))
        shared_path = self.skills_home / ".agents" / "AGENTS.md"
        self.write_file(shared_path, "# Personal rules\n")
        self.write_file(self.rules_managed / "CLAUDE.md", "# Company policy\n")
        claude_rules = self.rules_claude_config / "CLAUDE.md"
        self.write_file(claude_rules, "Mine, in the way.\n")

        def rule(rule_id):
            catalog = self.rule_catalog(task["id"])
            rules = [rule for section in catalog["repositories"] for rule in section["rules"]] + catalog["global"]
            return next(rule for rule in rules if rule["id"] == rule_id)

        agents_id = f"repo:{working}#AGENTS.md"
        lone = rule(agents_id)
        self.assertEqual(lone["nativeProviders"], ["claude", "codex"], "Both CLIs read an AGENTS.md with no CLAUDE.md beside it.")
        self.assertTrue(lone["availableOutsidePlayhouse"])
        self.assertFalse(any(location["isSymlink"] for location in lone["locations"]), "Nothing links to it.")
        self.assertFalse(lone["linkable"], "A rule both CLIs already read has nothing to link.")
        disabled = self.assert_success(self.call_cli("rules", "disable", "--task", task["id"], "--rule", agents_id)[0])
        self.assertFalse(disabled["enabled"])
        self.assertEqual(disabled["alwaysOnFor"], ["codex"], "Codex still reads the working repository's AGENTS.md itself.")
        self.assertEqual(disabled["providers"], ["codex"])
        self.assertFalse(rule(agents_id)["enabled"], "Turning a rule off survives a fresh CLI process.")
        off = self.assert_success(self.call_cli("rules", "disable", "--task", task["id"], "--rule", "global:agents/AGENTS.md")[0])
        self.assertEqual(off["providers"], [], "A rule only Playhouse shares reaches neither agent once off.")
        self.assertEqual(off["alwaysOnFor"], [])
        self.assertFalse((self.skills_codex_home / "config.toml").exists(), "Codex's config is not written.")
        self.assertFalse((self.rules_claude_config / "settings.json").exists(), "Claude's settings are not written.")
        self.assert_failure(self.call_cli("rules", "disable", "--task", task["id"], "--rule", "managed:claude/CLAUDE.md", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("rules", "disable", "--rule", "global:no-such-rule", expected_status=3)[0], "not_found")
        for rule_id in [agents_id, "global:agents/AGENTS.md"]:
            self.assertTrue(self.assert_success(self.call_cli("rules", "enable", "--task", task["id"], "--rule", rule_id)[0])["enabled"])
        self.assertEqual(rule(agents_id)["providers"], ["claude", "codex"])

        codex_link = self.skills_codex_home / "AGENTS.md"
        self.assert_failure(self.call_cli("rules", "link", "--task", task["id"], "--rule", "global:agents/AGENTS.md", expected_status=1)[0], "already_exists")
        self.assertEqual(claude_rules.read_text(encoding="utf-8"), "Mine, in the way.\n", "An existing file at a link path is left untouched.")
        self.assertFalse(codex_link.exists() or codex_link.is_symlink(), "A blocked link writes no link at all.")
        self.assert_success(self.call_cli("rules", "delete", "--task", task["id"], "--rule", "global:claude/CLAUDE.md")[0])

        linked = self.assert_success(self.call_cli("rules", "link", "--task", task["id"], "--rule", "global:agents/AGENTS.md")[0])
        self.assertTrue(linked["availableOutsidePlayhouse"])
        self.assertEqual(linked["nativeProviders"], ["claude", "codex"])
        self.assertFalse(linked["linkable"], "A linked rule has nothing left to link.")
        for link in [codex_link, claude_rules]:
            self.assertTrue(link.is_symlink())
            self.assertTrue(os.path.isabs(os.readlink(link)), "A global link is absolute.")
            self.assertSamePath(os.readlink(link), shared_path)
        self.assertEqual([rule["id"] for rule in self.rule_catalog(task["id"])["global"]], ["global:agents/AGENTS.md"],
                         "The linked files are one rule.")

        claude_id = f"repo:{other}#CLAUDE.md"
        self.assertTrue(rule(claude_id)["linkable"])
        self.assertFalse(rule(f"repo:{other}#.claude/rules/topic.md")["linkable"], "A rule Codex has no place for offers no link.")
        repo_linked = self.assert_success(self.call_cli("rules", "link", "--task", task["id"], "--rule", claude_id)[0])
        self.assertTrue(repo_linked["availableOutsidePlayhouse"])
        self.assertEqual(os.readlink(other_worktree / "AGENTS.md"), "CLAUDE.md", "A repository link is relative, so it can be committed.")
        self.assert_failure(self.call_cli("rules", "link", "--task", task["id"], "--rule", f"repo:{other}#.claude/rules/topic.md", expected_status=2)[0], "invalid_argument")

        unlinked = self.assert_success(self.call_cli("rules", "unlink", "--task", task["id"], "--rule", "global:agents/AGENTS.md")[0])
        self.assertFalse(unlinked["availableOutsidePlayhouse"])
        self.assertFalse(codex_link.exists() or codex_link.is_symlink() or claude_rules.is_symlink(), "Removing the outside link deletes only the symlinks.")
        self.assertEqual(shared_path.read_text(encoding="utf-8"), "# Personal rules\n")
        self.assert_failure(self.call_cli("rules", "unlink", "--task", task["id"], "--rule", "global:agents/AGENTS.md", expected_status=2)[0], "invalid_argument")
    # case-contract: test_rules_fix_with_agent_starts_task_for_problem_rules | A rule with a problem offers a Fix button on its row, which creates a task on the source task's provider whose saved prompt explains how both agents read rules and lists each rule with its problem: repository rules by repository-relative path, to be fixed in the new task's own worktree and committed and pushed, and global rules by absolute path, to be fixed in place with their folder opened as a context folder, and fixing only global rules needs no repository. The view switches to the new task's conversation, which sends that prompt once and leaves no unsent draft. A rule with no problem, the managed rule, an unknown rule, and a request without a task are rejected without opening a task.
    def test_rules_fix_with_agent_starts_task_for_problem_rules(self):
        repository = self.make_skill_repository("rules-fix-repo", {
            "AGENTS.md": "# Fine rules\n", "CLAUDE.md": "# Claude notes\n@docs/missing.md\n",
        })
        broken = self.rules_claude_config / "rules" / "broken.md"
        self.write_file(broken, "---\npaths:\n  - src/**\nThe frontmatter never closes.\n")
        self.write_file(self.rules_managed / "CLAUDE.md", "# Company policy\n")
        environment = self.install_claude_fixture("claude-fixture-rules-fix")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        source = self.create_skills_task("Rules fix source", [repository], provider="claude")
        source_worktree = Path(source["repositoryWorktrees"][0]["worktreePath"])
        tasks_before = len(self.assert_success(self.call_cli("board", "list")[0])["tasks"])

        def fix(*rules, expected_status=0):
            arguments = [argument for rule in rules for argument in ("--rule", rule)]
            return self.call_cli("rules", "fix", "--task", source["id"], *arguments, expected_status=expected_status)[0]

        self.assert_failure(fix(f"repo:{repository}#AGENTS.md", expected_status=2), "invalid_argument")
        self.assert_failure(fix("managed:claude/CLAUDE.md", expected_status=2), "invalid_argument")
        self.assert_failure(fix("global:no-such-rule", expected_status=3), "not_found")
        self.assert_failure(self.call_cli("rules", "fix", "--rule", "global:claude/rules/broken.md", expected_status=2)[0], "invalid_argument")
        self.assertEqual(len(self.assert_success(self.call_cli("board", "list")[0])["tasks"]), tasks_before, "A rejected fix opens no task.")

        created = self.assert_success(fix(f"repo:{repository}#CLAUDE.md", "global:claude/rules/broken.md"))
        task, prompt = created["task"], created["prompt"]
        self.assertEqual(task["title"], "Fix 2 rules")
        self.assertEqual(task["conversationProvider"], "claude", "The fixing task uses the source task's provider.")
        self.assertEqual([record["repositoryPath"] for record in task["repositoryWorktrees"]], [str(repository)])
        self.assertEqual([os.path.realpath(folder) for folder in task["contextFolders"]], [os.path.realpath(broken.parent)],
                         "A global rule's folder is opened to the agent.")
        self.assertEqual(task["savedPrompt"], prompt)
        self.assertIn("Codex reads AGENTS.md", prompt)
        self.assertIn("commit and push", prompt)
        self.assertIn("`CLAUDE.md` in rules-fix-repo", prompt)
        self.assertIn("@docs/missing.md", prompt)
        self.assertNotIn(str(source_worktree), prompt, "Repository paths are relative, so they point into the fixing task's worktree.")
        self.assertTrue(str(broken) in prompt or os.path.realpath(broken) in prompt, "A global rule is named by its absolute path.")
        self.assertIn("not tracked by Git", prompt)
        self.assertNotIn("Fine rules", prompt)

        global_only = self.assert_success(fix("global:claude/rules/broken.md"))["task"]
        self.assertEqual(global_only["title"], "Fix rule ~/.claude/rules/broken.md")
        self.assertEqual(global_only["repositoryWorktrees"], [], "Fixing only global rules needs no repository.")

        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", prompt, extra_environment=environment)[0])
        turns = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == prompt]
        self.assertEqual(len(turns), 1, "The fixing prompt is sent once.")
        started = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertFalse(started["hasUnsentDraft"])
        self.assertSamePath(turns[0]["cwd"], started["repositoryWorktrees"][0]["worktreePath"])
        self.assertNotEqual(os.path.realpath(started["repositoryWorktrees"][0]["worktreePath"]), os.path.realpath(source_worktree))
    # case-contract: test_rules_bridge_claude_launch_follows_shared_rules | A Claude turn follows the rules Claude Code does not read itself: after the task instructions, its appended system prompt carries ~/.agents/AGENTS.md with its @import of another file expanded inline, Codex's global AGENTS.md, and the AGENTS.md of the task's other repository, plus a pointer naming the globs and file of that repository's path-scoped rule; rules Claude reads itself, such as Claude's global CLAUDE.md and the working repository's CLAUDE.md and AGENTS.md, are not repeated. Because the working repository has both AGENTS.md and CLAUDE.md, --settings tells Claude Code to read both, and a rule turned off on the page is excluded for that run with claudeMdExcludes, without writing to the repository or Claude's settings. The resumed second turn carries the same rules, and turning the rule back on drops the exclusion.
    def test_rules_bridge_claude_launch_follows_shared_rules(self):
        repository = self.make_skill_repository("rules-claude-repo", {
            "AGENTS.md": "# Repo agents\nRepo AGENTS text.\n",
            "CLAUDE.md": "# Claude repo notes\nClaude repo text.\n",
            "CLAUDE.local.md": "Local text turned off.\n",
        })
        extra = self.make_skill_repository("rules-claude-extra", {
            "AGENTS.md": "Extra repo agents text.\n",
            ".claude/rules/extra.md": "---\npaths:\n  - \"lib/**\"\n---\n\nExtra scoped text.\n",
        })
        self.write_file(self.skills_home / ".agents" / "AGENTS.md", "# Personal rules\nShared global text.\n@~/notes/imported.md\n")
        self.write_file(self.skills_home / "notes" / "imported.md", "Imported text.\n")
        self.write_file(self.skills_codex_home / "AGENTS.md", "Codex global text.\n")
        self.write_file(self.rules_claude_config / "CLAUDE.md", "Claude global text.\n")
        environment = self.install_claude_fixture("claude-fixture-rules-bridge")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        task = self.create_skills_task("Claude rules", [repository, extra], provider="claude")
        worktree = Path(next(record["worktreePath"] for record in task["repositoryWorktrees"] if record["repositoryPath"] == str(repository)))
        extra_worktree = Path(next(record["worktreePath"] for record in task["repositoryWorktrees"] if record["repositoryPath"] == str(extra)))
        local_id = f"repo:{repository}#CLAUDE.local.md"
        self.assert_success(self.call_cli("rules", "disable", "--task", task["id"], "--rule", local_id)[0])
        before = self.run_git(repository, "status", "--porcelain")

        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Follow the rules.", extra_environment=environment)[0])
        turns = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText")]
        arguments = turns[0]["arguments"]
        prompt = arguments[arguments.index("--append-system-prompt") + 1]
        for text in ["Shared global text.", "Imported text.", "Codex global text.", "Extra repo agents text."]:
            self.assertIn(text, prompt, f"{text} reaches Claude through the system prompt.")
        self.assertIn("`lib/**` in rules-claude-extra:", prompt, "A path-scoped rule in another repository is a pointer.")
        self.assertTrue(str(extra_worktree / ".claude" / "rules" / "extra.md") in prompt
                        or os.path.realpath(extra_worktree / ".claude" / "rules" / "extra.md") in prompt)
        self.assertNotIn("Extra scoped text.", prompt, "A path-scoped rule is shared by its file, not its text.")
        for text in ["Claude global text.", "Claude repo text.", "Repo AGENTS text.", "Local text turned off.", "@~/notes/imported.md"]:
            self.assertNotIn(text, prompt, f"{text} should not be added: Claude reads it itself, it is off, or it was expanded.")
        self.assertGreater(prompt.index("# Rules Playhouse shares with you"), 0, "Rules follow the task instructions.")
        settings = json.loads(arguments[arguments.index("--settings") + 1])
        self.assertEqual({os.path.realpath(path) for path in settings["claudeMdExcludes"]}, {os.path.realpath(worktree / "CLAUDE.local.md")},
                         "The turned-off rule is excluded for this run.")
        self.assertEqual(settings["pluginConfigs"], {"cc-plugin-agents-md@builtin": {"options": {"instructionFiles": "claude-md-and-agents-md"}}},
                         "Claude Code reads AGENTS.md alongside CLAUDE.md.")
        self.assertEqual(self.run_git(repository, "status", "--porcelain"), before, "The repository is not written to.")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "The worktree is not written to.")
        self.assertFalse((self.rules_claude_config / "settings.json").exists(), "Claude's settings are not written.")

        bridge = self.assert_success(self.call_cli("rules", "bridge", "--task", task["id"])[0])
        self.assertEqual([rule["id"] for rule in bridge["claudeShared"]],
                         ["global:agents/AGENTS.md", "global:codex/AGENTS.md", f"repo:{extra}#AGENTS.md", f"repo:{extra}#.claude/rules/extra.md"])
        self.assertTrue(bridge["claudeReadsAgentsAlongsideClaude"])
        extra_agents = next(rule for section in self.rule_catalog(task["id"])["repositories"] for rule in section["rules"] if rule["id"] == f"repo:{extra}#AGENTS.md")
        self.assertEqual(extra_agents["sharedWith"], ["claude", "codex"], "Neither agent loads another task repository's rules on its own.")

        self.assert_success(self.call_cli("rules", "enable", "--task", task["id"], "--rule", local_id)[0])
        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", "Follow them again.", extra_environment=environment)[0])
        second = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == "Follow them again."][-1]
        self.assertTrue(second["resumed"], "The second turn resumes the Claude session.")
        resumed = second["arguments"]
        self.assertIn("Shared global text.", resumed[resumed.index("--append-system-prompt") + 1], "A resumed turn carries the same rules.")
        self.assertNotIn("claudeMdExcludes", json.loads(resumed[resumed.index("--settings") + 1]), "Turning the rule back on drops the exclusion.")
    # case-contract: test_rules_bridge_codex_thread_follows_claude_rules | A Codex turn follows the rules Codex does not read itself: after the task instructions, the thread starts with developer instructions carrying ~/.agents/AGENTS.md, Claude's global CLAUDE.md, and the working repository's CLAUDE.md and always-on .claude/rules files, with CLAUDE.md's @AGENTS.md import left out because Codex already reads that file, and each path-scoped rule as a pointer naming its globs and file rather than its text. The working repository's AGENTS.md and Codex's global AGENTS.md are not repeated, a rule turned off on the page is left out, and Codex's config.toml is not written. A thread resumed on a fresh app-server gets the same rules.
    def test_rules_bridge_codex_thread_follows_claude_rules(self):
        repository = self.make_skill_repository("rules-codex-repo", {
            "AGENTS.md": "Repo AGENTS text for Codex.\n",
            "CLAUDE.md": "# Claude repo notes\n@AGENTS.md\nClaude repo text for Codex.\n",
            ".claude/rules/testing.md": "Always run tests.\n",
            ".claude/rules/api.md": "---\npaths:\n  - \"src/api/**\"\n---\n\nAPI rule text.\n",
            ".claude/rules/off.md": "Turned off text.\n",
        })
        self.write_file(self.skills_home / ".agents" / "AGENTS.md", "Shared global text for Codex.\n")
        self.write_file(self.rules_claude_config / "CLAUDE.md", "Claude global text for Codex.\n")
        self.write_file(self.skills_codex_home / "AGENTS.md", "Codex global native text.\n")
        task = self.create_skills_task("Codex rules", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.assert_success(self.call_cli("rules", "disable", "--task", task["id"], "--rule", f"repo:{repository}#.claude/rules/off.md")[0])

        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-rules", message="Follow the rules.")
        history = json.loads((self.data_directory / "codex-fixture-rules.history").read_text(encoding="utf-8"))
        instructions = history["threadStartDeveloperInstructions"]
        for text in ["Shared global text for Codex.", "Claude global text for Codex.", "Claude repo text for Codex.", "Always run tests."]:
            self.assertIn(text, instructions, f"{text} reaches Codex through the thread's developer instructions.")
        self.assertIn("`src/api/**` in rules-codex-repo:", instructions, "A path-scoped rule is a pointer naming its globs.")
        self.assertTrue(str(worktree / ".claude" / "rules" / "api.md") in instructions
                        or os.path.realpath(worktree / ".claude" / "rules" / "api.md") in instructions)
        for text in ["API rule text.", "Repo AGENTS text for Codex.", "Codex global native text.", "Turned off text.", "@AGENTS.md"]:
            self.assertNotIn(text, instructions, f"{text} should not be added: Codex reads it itself, it is off, or it is a pointer.")
        self.assertGreater(instructions.index("# Rules Playhouse shares with you"), 0, "Rules follow the task instructions.")
        self.assertFalse((self.skills_codex_home / "config.toml").exists(), "Codex's config.toml is not written.")
        bridge = self.assert_success(self.call_cli("rules", "bridge", "--task", task["id"])[0])
        self.assertEqual([rule["name"] for rule in bridge["codexShared"]],
                         ["~/.agents/AGENTS.md", "~/.claude/CLAUDE.md", "CLAUDE.md", ".claude/rules/api.md", ".claude/rules/testing.md"])

        self.restart_provider(self.data_directory / "codex-fixture-rules")
        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-rules", message="Follow them again.")
        history = json.loads((self.data_directory / "codex-fixture-rules.history").read_text(encoding="utf-8"))
        self.assertGreaterEqual(history.get("threadResumeCount", 0), 1, "The second turn resumes the thread on a fresh app-server.")
        rules_section = instructions[instructions.index("# Rules Playhouse shares with you"):]
        resumed = history["threadResumeDeveloperInstructions"][-1]
        self.assertEqual(resumed[resumed.index("# Rules Playhouse shares with you"):], rules_section, "The resumed thread gets the same rules.")
    # case-contract: test_mcp_catalog_lists_repo_global_and_managed_servers | The Skills page, titled Skills, Rules & MCP, switches to its MCP list with a Skills | Rules | MCP picker. MCP lists, in one sectioned list whose Repo, Global and Managed anchors scroll it to their sections, each task repository's servers from its worktree's .mcp.json and .codex/config.toml (keyed by the source repository and the server's name), the user's global servers from Claude Code's ~/.claude.json and Codex's config.toml, and the organization's managed-mcp.json. Each server row shows only its name and Claude and Codex badges for the agents that start it in Playhouse sessions, without hovering, and its other details show in a hint while the pointer rests on it, which carries no provider badge: each server shows its command or URL and only the names of its environment variables and headers, never their values, and names the agents that start it on their own and the ones Playhouse passes it to: a .mcp.json server is Claude's own and passed to Codex, a server defined the same way in both global files is one entry both CLIs start, a server only one CLI defines is passed to the other, an SSE server or one with a working folder reaches only the agent that can run it with the reason shown, a server Codex's config.toml turns off reaches neither, a server written inline in config.toml is listed but not editable, two global definitions that differ are flagged as a conflict, and the managed server is Claude's only and read-only. A repository without servers shows an empty state and an unreadable configuration file is reported. Reading a server returns its full definition, and an unknown server is not_found.
    def test_mcp_catalog_lists_repo_global_and_managed_servers(self):
        working = self.make_skill_repository("mcp-catalog-repo", {
            ".mcp.json": json.dumps({"mcpServers": {
                "repo-docs": {"type": "stdio", "command": "node", "args": ["docs.js"],
                              "env": {"DOCS_TOKEN": "${DOCS_TOKEN}", "DOCS_MODE": "secret-mode-value"}},
                "repo-sse": {"type": "sse", "url": "https://sse.example.com/mcp"},
            }}),
            ".codex/config.toml": '[mcp_servers.repo-codex]\ncommand = "python3"\nargs = ["serve.py"]\n',
        })
        other = self.make_skill_repository("mcp-other-repo", {
            ".mcp.json": json.dumps({"mcpServers": {
                "other-api": {"type": "http", "url": "https://api.example.com/mcp", "headers": {"Authorization": "Bearer ${API_TOKEN}"}},
            }}),
            ".codex/config.toml": "[mcp_servers.broken\ncommand = \n",
        })
        empty = self.make_skill_repository("mcp-empty-repo", {})
        self.write_json(self.mcp_claude_state, {"numStartups": 5, "mcpServers": {
            "shared": {"type": "stdio", "command": "npx", "args": ["-y", "shared-server"], "env": {}},
            "claude-only": {"type": "http", "url": "https://claude.example.com/mcp", "headers": {"X-Team": "core-secret-team"}},
            "clash": {"type": "stdio", "command": "clash-a", "args": [], "env": {}},
        }})
        self.write_file(self.mcp_codex_config, "\n".join([
            'model = "gpt-6-luna"', "",
            "[mcp_servers]", 'inline-tool = { command = "inline-tool" }', "",
            "[mcp_servers.shared]", 'command = "npx"', 'args = ["-y", "shared-server"]', "",
            "[mcp_servers.codex-only]", 'command = "uvx"', 'args = ["codex-tool"]', 'env_vars = ["CODEX_TOOL_KEY"]', "",
            "[mcp_servers.clash]", 'command = "clash-b"', "",
            "[mcp_servers.folder-tool]", 'command = "./tool"', 'cwd = "."', "",
            "[mcp_servers.off-tool]", 'command = "off-tool"', "enabled = false", "",
        ]))
        self.write_json(self.mcp_managed, {"mcpServers": {"company": {"type": "http", "url": "https://mcp.company.example/mcp"}}})

        task = self.create_skills_task("MCP catalog", [working, other, empty])
        worktrees = {record["repositoryPath"]: record["worktreePath"] for record in task["repositoryWorktrees"]}
        catalog = self.mcp_catalog(task["id"])
        self.assertEqual([section["name"] for section in catalog["repositories"]], ["mcp-catalog-repo", "mcp-other-repo", "mcp-empty-repo"])
        self.assertEqual(catalog["repositories"][0]["repositoryPath"], str(working), "Servers are keyed by the source repository.")
        self.assertSamePath(catalog["repositories"][0]["rootPath"], worktrees[str(working)])
        self.assertEqual(catalog["repositories"][2]["servers"], [], "A repository without servers has an empty section.")
        self.assertEqual([os.path.realpath(problem["path"]) for problem in catalog["problems"]],
                         [os.path.realpath(Path(worktrees[str(other)]) / ".codex" / "config.toml")], "An unreadable config file is reported.")
        serialized = json.dumps(catalog)
        for secret in ["secret-mode-value", "core-secret-team", "Bearer ${API_TOKEN}", "${DOCS_TOKEN}"]:
            self.assertNotIn(secret, serialized, "The list names variables and headers, never their values.")

        repo = self.mcp_section(catalog, "mcp-catalog-repo")
        self.assertEqual(list(repo), ["repo-codex", "repo-docs", "repo-sse"])
        docs = repo["repo-docs"]
        self.assertEqual(docs["id"], f"repo:{working}#repo-docs")
        self.assertEqual(docs["summary"], "node docs.js")
        self.assertEqual(docs["transport"], "stdio")
        self.assertEqual(docs["envNames"], ["DOCS_MODE", "DOCS_TOKEN"])
        self.assertEqual(docs["nativeProviders"], ["claude"], ".mcp.json is Claude Code's own.")
        self.assertEqual(docs["providers"], ["claude", "codex"])
        self.assertEqual(docs["sharedWith"], ["codex"], "Playhouse passes it to Codex.")
        self.assertEqual([location["layout"] for location in docs["locations"]], ["projectJSON"])
        self.assertTrue(docs["linkable"])
        self.assertEqual(repo["repo-sse"]["providers"], ["claude"], "Codex can't run an SSE server.")
        self.assertIn("SSE", repo["repo-sse"]["limitation"])
        self.assertFalse(repo["repo-sse"]["linkable"])
        self.assertEqual(repo["repo-codex"]["nativeProviders"], ["codex"])
        self.assertEqual(repo["repo-codex"]["providers"], ["claude", "codex"])
        other_api = self.mcp_section(catalog, "mcp-other-repo")["other-api"]
        self.assertEqual(other_api["headerNames"], ["Authorization"])
        self.assertEqual(other_api["sharedWith"], ["claude", "codex"], "Neither agent reads another task repository's servers on its own.")

        global_servers = self.mcp_by_name(catalog["global"])
        self.assertEqual(list(global_servers), ["clash", "claude-only", "codex-only", "folder-tool", "inline-tool", "off-tool", "shared"])
        shared = global_servers["shared"]
        self.assertEqual(shared["id"], "global:shared")
        self.assertEqual([location["layout"] for location in shared["locations"]], ["claudeUser", "codexGlobal"], "Both files define one server.")
        self.assertTrue(shared["availableOutsidePlayhouse"])
        self.assertEqual(shared["sharedWith"], [])
        self.assertFalse(shared["conflict"])
        clash = global_servers["clash"]
        self.assertTrue(clash["conflict"])
        self.assertIn("differently", clash["issue"])
        self.assertFalse(clash["linkable"])
        self.assertEqual(global_servers["claude-only"]["sharedWith"], ["codex"])
        self.assertEqual(global_servers["claude-only"]["headerNames"], ["X-Team"])
        self.assertEqual(global_servers["codex-only"]["sharedWith"], ["claude"])
        self.assertEqual(global_servers["codex-only"]["envNames"], ["CODEX_TOOL_KEY"])
        self.assertEqual(global_servers["folder-tool"]["providers"], ["codex"], "Claude Code can't run a server with a working folder.")
        self.assertIn("working folder", global_servers["folder-tool"]["limitation"])
        self.assertEqual(global_servers["off-tool"]["providers"], [], "A server Codex's config turns off reaches neither agent.")
        self.assertIn("enabled = false", global_servers["off-tool"]["limitation"])
        self.assertFalse(global_servers["inline-tool"]["locations"][0]["editable"], "An inline config.toml server is left to the user.")
        self.assertFalse(global_servers["inline-tool"]["editable"], "An inline config.toml server is not editable.")
        self.assertEqual(global_servers["inline-tool"]["providers"], ["claude", "codex"])

        managed = catalog["managed"]
        self.assertEqual([server["id"] for server in managed], ["managed:company"])
        self.assertEqual(managed[0]["providers"], ["claude"], "The managed server is Claude's only.")
        self.assertFalse(managed[0]["editable"])

        detail = self.assert_success(self.call_cli("mcp", "get", "--task", task["id"], "--server", "global:claude-only")[0])
        self.assertEqual(detail["server"]["id"], "global:claude-only")
        self.assertEqual(detail["config"]["url"], "https://claude.example.com/mcp")
        self.assertEqual(detail["config"]["headers"], {"X-Team": "core-secret-team"}, "Reading a server returns its full definition.")
        codex_detail = self.assert_success(self.call_cli("mcp", "get", "--task", task["id"], "--server", "global:codex-only")[0])["config"]
        self.assertEqual(codex_detail["env"], {"CODEX_TOOL_KEY": "${CODEX_TOOL_KEY}"}, "Codex's env_vars read as ${NAME} references.")
        self.assert_failure(self.call_cli("mcp", "get", "--task", task["id"], "--server", "global:no-such-server", expected_status=3)[0], "not_found")
        without_task = self.mcp_catalog()
        self.assertEqual(without_task["repositories"], [])
        self.assertEqual([server["name"] for server in without_task["global"]], list(global_servers))
    # case-contract: test_mcp_create_update_and_delete_in_both_configs | New Server writes a global server straight into both Claude Code's ~/.claude.json mcpServers and Codex's config.toml [mcp_servers] table, with ${NAME} environment references written as Codex env_vars and every other setting, comment and server in both files kept; a repository server goes into the chosen task worktree's .mcp.json and the source checkout is left alone. An invalid name, a missing command, an SSE server, a URL that is not http, an environment reference Codex can't pass through, the managed scope, and an existing name are rejected with nothing written. Clicking a server opens its editor, and saving rewrites it in every file that defines it while keeping each provider's own keys, such as Codex's startup_timeout_sec and Claude's oauth; an invalid edit and an edit to a server written inline in config.toml are rejected while keeping the files. Deleting a server removes it from every file that defines it, and every change is visible to a fresh CLI process and on the page. Right after a create closes its panel, one click on New Server opens it again.
    def test_mcp_create_update_and_delete_in_both_configs(self):
        repository = self.make_skill_repository("mcp-manage-repo", {})
        task = self.create_skills_task("MCP manage", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.write_json(self.mcp_claude_state, {"numStartups": 7, "projects": {"/elsewhere": {"allowedTools": []}}, "mcpServers": {
            "legacy": {"type": "http", "url": "https://legacy.example.com/mcp", "oauth": {"clientId": "abc"}},
        }})
        codex_text = "\n".join([
            "# my settings", 'model = "gpt-6-luna"', "",
            "[mcp_servers]", 'inline-tool = { command = "inline-tool" }', "",
            "[mcp_servers.legacy]", 'url = "https://legacy.example.com/mcp"', "startup_timeout_sec = 45", "",
            "[profiles.fast]", 'model = "gpt-6-mini"', "",
        ])
        self.write_file(self.mcp_codex_config, codex_text)
        self.write_json(self.mcp_managed, {"mcpServers": {"company": {"type": "http", "url": "https://mcp.company.example/mcp"}}})

        def create(*arguments, expected_status=0):
            return self.call_cli("mcp", "create", "--task", task["id"], *arguments, expected_status=expected_status)[0]

        for arguments in [
            ["--scope", "global", "--name", "bad name", "--command", "npx"],
            ["--scope", "global", "--name", "no-command", "--command", ""],
            ["--scope", "global", "--name", "events", "--config-json", '{"transport": "sse", "url": "https://sse.example.com"}'],
            ["--scope", "global", "--name", "ftp-server", "--url", "ftp://files.example.com"],
            ["--scope", "global", "--name", "renamed-env", "--command", "npx", "--env", "TOKEN=${OTHER_TOKEN}"],
            ["--scope", "managed", "--name", "company-two", "--command", "npx"],
        ]:
            self.assert_failure(create(*arguments, expected_status=2), "invalid_argument")
        self.assertNotIn("bad name", self.read_json(self.mcp_claude_state)["mcpServers"])
        self.assertEqual(list(self.read_json(self.mcp_claude_state)["mcpServers"]), ["legacy"], "A rejected server writes nothing.")
        self.assertEqual(self.mcp_codex_config.read_text(encoding="utf-8"), codex_text)

        created = self.assert_success(create("--scope", "global", "--name", "notes", "--command", "npx", "--arg", "-y", "--arg", "notes-server",
                                             "--env", "NOTES_TOKEN=${NOTES_TOKEN}", "--env", "MODE=fast"))
        self.assertEqual(created["id"], "global:notes")
        self.assertTrue(created["availableOutsidePlayhouse"], "A new global server is in both CLIs' configuration.")
        state = self.read_json(self.mcp_claude_state)
        self.assertEqual(state["mcpServers"]["notes"], {"type": "stdio", "command": "npx", "args": ["-y", "notes-server"],
                                                        "env": {"NOTES_TOKEN": "${NOTES_TOKEN}", "MODE": "fast"}})
        self.assertEqual(state["numStartups"], 7, "Claude Code's other state is kept.")
        self.assertEqual(state["projects"], {"/elsewhere": {"allowedTools": []}})
        config = self.read_toml(self.mcp_codex_config)
        self.assertEqual(config["mcp_servers"]["notes"], {"command": "npx", "args": ["-y", "notes-server"], "env": {"MODE": "fast"}, "env_vars": ["NOTES_TOKEN"]},
                         "${NAME} references become Codex env_vars.")
        self.assertEqual(config["profiles"], {"fast": {"model": "gpt-6-mini"}}, "Codex's other settings are kept.")
        self.assertEqual(config["model"], "gpt-6-luna")
        self.assertIn("# my settings", self.mcp_codex_config.read_text(encoding="utf-8"), "Comments are kept.")
        self.assert_failure(create("--scope", "global", "--name", "notes", "--command", "npx", expected_status=1), "already_exists")

        remote = self.assert_success(create("--scope", "global", "--name", "remote-notes", "--url", "https://notes.example.com/mcp",
                                            "--header", "Authorization: Bearer ${NOTES_API_TOKEN}", "--header", "X-Team: core"))
        self.assertEqual(remote["transport"], "http")
        self.assertEqual(self.read_toml(self.mcp_codex_config)["mcp_servers"]["remote-notes"],
                         {"url": "https://notes.example.com/mcp", "bearer_token_env_var": "NOTES_API_TOKEN", "http_headers": {"X-Team": "core"}})
        self.assertEqual(self.read_json(self.mcp_claude_state)["mcpServers"]["remote-notes"]["headers"],
                         {"Authorization": "Bearer ${NOTES_API_TOKEN}", "X-Team": "core"})

        repo_server = self.assert_success(create("--scope", "repo", "--root", str(repository), "--name", "repo-search",
                                                 "--url", "https://search.example.com/mcp"))
        self.assertEqual(repo_server["id"], f"repo:{repository}#repo-search")
        self.assertEqual(repo_server["sharedWith"], ["codex"])
        self.assertEqual(self.read_json(worktree / ".mcp.json"), {"mcpServers": {"repo-search": {"type": "http", "url": "https://search.example.com/mcp"}}})
        self.assertFalse((repository / ".mcp.json").exists(), "The source checkout is left alone.")

        def update(server_id, *arguments, expected_status=0):
            return self.call_cli("mcp", "update", "--task", task["id"], "--server", server_id, *arguments, expected_status=expected_status)[0]

        edited = self.assert_success(update("global:notes", "--config-json", json.dumps(
            {"transport": "stdio", "command": "npx", "args": ["notes-server", "--stdio"], "env": {"NOTES_TOKEN": "${NOTES_TOKEN}"}})))
        self.assertEqual(edited["summary"], "npx notes-server --stdio")
        self.assertEqual(self.read_json(self.mcp_claude_state)["mcpServers"]["notes"]["args"], ["notes-server", "--stdio"])
        self.assertEqual(self.read_toml(self.mcp_codex_config)["mcp_servers"]["notes"],
                         {"command": "npx", "args": ["notes-server", "--stdio"], "env_vars": ["NOTES_TOKEN"]}, "An edit reaches both files.")
        self.assert_success(update("global:legacy", "--url", "https://legacy.example.com/v2"))
        legacy_claude = self.read_json(self.mcp_claude_state)["mcpServers"]["legacy"]
        self.assertEqual(legacy_claude["url"], "https://legacy.example.com/v2")
        self.assertEqual(legacy_claude["oauth"], {"clientId": "abc"}, "Claude's own keys are kept.")
        legacy_codex = self.read_toml(self.mcp_codex_config)["mcp_servers"]["legacy"]
        self.assertEqual(legacy_codex, {"url": "https://legacy.example.com/v2", "startup_timeout_sec": 45}, "Codex's own keys are kept.")

        before_claude = self.mcp_claude_state.read_text(encoding="utf-8")
        before_codex = self.mcp_codex_config.read_text(encoding="utf-8")
        self.assert_failure(update("global:notes", "--command", "", expected_status=2), "invalid_argument")
        self.assert_failure(update("global:notes", "--command", "npx", "--env", "TOKEN=${OTHER_TOKEN}", expected_status=2), "invalid_argument")
        inline = update("global:inline-tool", "--command", "inline-tool-2", expected_status=2)
        self.assert_failure(inline, "invalid_argument")
        self.assertIn("inline", inline["error"]["message"])
        self.assert_failure(update("managed:company", "--url", "https://other.example.com", expected_status=2), "invalid_argument")
        self.assertEqual(self.mcp_claude_state.read_text(encoding="utf-8"), before_claude, "A rejected edit keeps the files.")
        self.assertEqual(self.mcp_codex_config.read_text(encoding="utf-8"), before_codex)

        self.assertEqual(self.assert_success(self.call_cli("mcp", "delete", "--task", task["id"], "--server", "global:notes")[0]), {"deleted": True})
        self.assertNotIn("notes", self.read_json(self.mcp_claude_state)["mcpServers"], "Deleting removes the server from Claude Code's file.")
        self.assertNotIn("notes", self.read_toml(self.mcp_codex_config)["mcp_servers"], "Deleting removes the server from Codex's file.")
        self.assertIn("# my settings", self.mcp_codex_config.read_text(encoding="utf-8"))
        self.assert_failure(self.call_cli("mcp", "delete", "--task", task["id"], "--server", "global:inline-tool", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("mcp", "delete", "--task", task["id"], "--server", "managed:company", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("mcp", "get", "--task", task["id"], "--server", "global:notes", expected_status=3)[0], "not_found")
        fresh = self.mcp_catalog(task["id"])
        self.assertEqual([server["name"] for server in fresh["global"]], ["inline-tool", "legacy", "remote-notes"])
        self.assertEqual([server["name"] for server in fresh["repositories"][0]["servers"]], ["repo-search"])
    # case-contract: test_mcp_enable_state_and_link_persist | Turning a server off is stored by Playhouse rather than in either provider's configuration, survives fresh CLI processes and reopening the page, and can be turned back on; the managed server can't be turned off. A turned-off server in Claude Code's own configuration still lists Claude and the page says Claude still starts it, so turning it off applies to Codex only, while a turned-off server only Codex defines reaches neither agent. Make Available Outside Playhouse writes a Claude-only global server into Codex's config.toml, a Codex-only one into Claude Code's ~/.claude.json, and a repository .mcp.json server into the worktree's .codex/config.toml, after which each is one entry both CLIs start; a conflicting server can't be linked and nothing is written.
    def test_mcp_enable_state_and_link_persist(self):
        repository = self.make_skill_repository("mcp-link-repo", {
            ".mcp.json": json.dumps({"mcpServers": {"repo-tool": {"type": "stdio", "command": "repo-tool", "args": [], "env": {}}}}),
        })
        task = self.create_skills_task("MCP links", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.write_json(self.mcp_claude_state, {"mcpServers": {
            "claude-tool": {"type": "stdio", "command": "claude-tool", "args": ["--serve"], "env": {}},
            "clash": {"type": "stdio", "command": "clash-a", "args": [], "env": {}},
        }})
        self.write_file(self.mcp_codex_config, '[mcp_servers.codex-tool]\ncommand = "codex-tool"\nenv_vars = ["CODEX_KEY"]\n\n[mcp_servers.clash]\ncommand = "clash-b"\n')
        self.write_json(self.mcp_managed, {"mcpServers": {"company": {"type": "http", "url": "https://mcp.company.example/mcp"}}})
        before_claude = self.mcp_claude_state.read_text(encoding="utf-8")
        before_codex = self.mcp_codex_config.read_text(encoding="utf-8")

        disabled = self.assert_success(self.call_cli("mcp", "disable", "--task", task["id"], "--server", "global:claude-tool")[0])
        self.assertFalse(disabled["enabled"])
        self.assertEqual(disabled["alwaysOnFor"], ["claude"], "Claude Code still starts a server from its own configuration.")
        self.assertEqual(disabled["providers"], ["claude"])
        self.assertFalse(self.mcp_server(task["id"], "global:claude-tool")["enabled"], "Turning a server off survives a fresh CLI process.")
        off = self.assert_success(self.call_cli("mcp", "disable", "--task", task["id"], "--server", "global:codex-tool")[0])
        self.assertEqual(off["providers"], [], "A server only Codex defines reaches neither agent once off.")
        self.assertEqual(off["alwaysOnFor"], [])
        self.assertEqual(self.mcp_claude_state.read_text(encoding="utf-8"), before_claude, "Claude Code's configuration is not written.")
        self.assertEqual(self.mcp_codex_config.read_text(encoding="utf-8"), before_codex, "Codex's configuration is not written.")
        self.assertFalse((self.rules_claude_config / "settings.json").exists())
        self.assert_failure(self.call_cli("mcp", "disable", "--task", task["id"], "--server", "managed:company", expected_status=2)[0], "invalid_argument")
        self.assert_failure(self.call_cli("mcp", "disable", "--server", "global:no-such-server", expected_status=3)[0], "not_found")
        for server_id in ["global:claude-tool", "global:codex-tool"]:
            self.assertTrue(self.assert_success(self.call_cli("mcp", "enable", "--task", task["id"], "--server", server_id)[0])["enabled"])
        self.assertEqual(self.mcp_server(task["id"], "global:codex-tool")["providers"], ["claude", "codex"])

        self.assert_failure(self.call_cli("mcp", "link", "--task", task["id"], "--server", "global:clash", expected_status=2)[0], "invalid_argument")
        self.assertEqual(self.mcp_claude_state.read_text(encoding="utf-8"), before_claude, "A conflicting server can't be linked.")
        self.assertEqual(self.mcp_codex_config.read_text(encoding="utf-8"), before_codex)

        linked = self.assert_success(self.call_cli("mcp", "link", "--task", task["id"], "--server", "global:claude-tool")[0])
        self.assertTrue(linked["availableOutsidePlayhouse"])
        self.assertFalse(linked["linkable"])
        self.assertEqual(self.read_toml(self.mcp_codex_config)["mcp_servers"]["claude-tool"], {"command": "claude-tool", "args": ["--serve"]})
        codex_linked = self.assert_success(self.call_cli("mcp", "link", "--task", task["id"], "--server", "global:codex-tool")[0])
        self.assertEqual(codex_linked["nativeProviders"], ["claude", "codex"])
        self.assertEqual(self.read_json(self.mcp_claude_state)["mcpServers"]["codex-tool"],
                         {"type": "stdio", "command": "codex-tool", "args": [], "env": {"CODEX_KEY": "${CODEX_KEY}"}})
        self.assertEqual([location["layout"] for location in self.mcp_server(task["id"], "global:codex-tool")["locations"]], ["claudeUser", "codexGlobal"],
                         "The linked server is one entry.")

        repo_linked = self.assert_success(self.call_cli("mcp", "link", "--task", task["id"], "--server", f"repo:{repository}#repo-tool")[0])
        self.assertTrue(repo_linked["availableOutsidePlayhouse"])
        self.assertEqual(self.read_toml(worktree / ".codex" / "config.toml")["mcp_servers"]["repo-tool"], {"command": "repo-tool"})
        self.assertFalse((repository / ".codex").exists(), "The source checkout is left alone.")

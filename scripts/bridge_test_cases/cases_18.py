from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases18:
    # case-contract: test_task_cpu_usage_attributes_codex_load_by_worktree | Two Codex tasks rooted in different repository folders share one real fixture app-server. Before any turn each reports cpu-usage as not running. While task A's turn runs a real CPU-burning child process in A's folder and task B's concurrent turn runs an idle child in B's folder, both children belong to the same app-server process; once a baseline is sampled, `task cpu-usage` attributes a plausible non-zero percentage to A and a near-zero one to B, and the task cards show A's CPU bar reading hot against a lowered ceiling beside B's visible but empty bar. Both readings return to not-running once the turns complete.
    def test_task_cpu_usage_attributes_codex_load_by_worktree(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py"
        executable = self.data_directory / "codex-fixture-cpu-attribution"
        copy_file(fixture, executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(executable)}
        busy_id = self.create_task(title="Codex busy worktree", roots=[self.primary], provider="codex")["id"]
        idle_id = self.create_task(title="Codex idle worktree", roots=[self.secondary], provider="codex")["id"]
        for task_id in (busy_id, idle_id):
            before = self.assert_success(self.call_cli("task", "cpu-usage", task_id)[0])
            self.assertIsNone(before["cpuPercent"], "A Codex task with no turn yet has nothing to sample.")
            self.assertEqual(before["reason"], "not_running")

        busy = self.start_cli("conversation", "send", busy_id, "--message", "Please burn cpu for 25 seconds.", extra_environment=environment)
        idle = self.start_cli("conversation", "send", idle_id, "--message", "Please idle cpu for 25 seconds.", extra_environment=environment)
        try:
            deadline = time.monotonic() + 15
            children = {}
            while time.monotonic() < deadline and len(children) < 2:
                children = {kind: child for kind in ("burn", "idle") if (child := self.cpu_attribution_child(executable, kind))}
                time.sleep(0.1)
            self.assertEqual(set(children), {"burn", "idle"}, "Both tasks' turns should be running their command children.")
            self.assertEqual(children["burn"]["parentPID"], children["idle"]["parentPID"], "Both tasks' commands should run under one shared app-server.")
            self.assertEqual(os.path.realpath(children["burn"]["workingDirectory"]), os.path.realpath(self.primary), "The busy command runs in its task's folder.")
            self.assertEqual(os.path.realpath(children["idle"]["workingDirectory"]), os.path.realpath(self.secondary), "The idle command runs in its task's folder.")

            # The first read only establishes the baseline (reported as not
            # running), so poll until both tasks have a measured value, then
            # let the idle child's own start-up CPU fall out of the window.
            readings = {}
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                readings = {task_id: self.assert_success(self.call_cli("task", "cpu-usage", task_id)[0]) for task_id in (busy_id, idle_id)}
                if all(reading["cpuPercent"] is not None for reading in readings.values()):
                    break
                time.sleep(0.3)
            self.assertTrue(all(reading["cpuPercent"] is not None for reading in readings.values()), f"Both running Codex tasks should be sampled: {readings}")
            time.sleep(1)
            busy_reading = self.assert_success(self.call_cli("task", "cpu-usage", busy_id)[0])
            idle_reading = self.assert_success(self.call_cli("task", "cpu-usage", idle_id)[0])
            self.assertIsNone(busy_reading["reason"])
            self.assertIsNone(idle_reading["reason"], "A running Codex task with an idle command still reports a value, not not-running.")
            self.assertGreater(busy_reading["cpuPercent"], 20, "The busy-looping command's CPU should be attributed to its own task.")
            self.assertLess(busy_reading["cpuPercent"], (os.cpu_count() or 1) * 100 + 50, "One busy loop can't exceed every core.")
            self.assertLess(idle_reading["cpuPercent"], 5, "The other task's busy command must not leak into the idle task's reading.")

            self.finish_cli(busy, ["conversation", "send", busy_id], timeout=45)
            self.finish_cli(idle, ["conversation", "send", idle_id], timeout=45)
        finally:
            for process in (busy, idle):
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=10)
            # A failed assertion must not leave the daemon-side burn running into later cases.
            if burner := self.cpu_attribution_child(executable, "burn"):
                subprocess.run(["/bin/kill", str(burner["pid"])], check=False, capture_output=True)
        for task_id in (busy_id, idle_id):
            finished = self.assert_success(self.call_cli("task", "cpu-usage", task_id)[0])
            self.assertIsNone(finished["cpuPercent"], "A finished Codex turn is no longer running.")
            self.assertEqual(finished["reason"], "not_running")
    # case-contract: test_settings_cpu_usage_color_max_round_trip | The CPU usage color maximum defaults to one fully busy core per logical CPU, round-trips through the CLI/XPC settings commands, and rejects a non-positive value as invalid_argument without changing the stored setting.
    def test_settings_cpu_usage_color_max_round_trip(self):
        settings = self.assert_success(self.call_cli("settings", "get")[0])
        expected_default = (os.cpu_count() or 1) * 100
        self.assertEqual(settings["cpuUsageColorMax"], expected_default, "The bar's scale tops out at one busy core per logical CPU by default.")

        updated = self.assert_success(self.call_cli("settings", "set-cpu-usage-color-max", "250")[0])
        self.assertEqual(updated["cpuUsageColorMax"], 250)
        self.assertEqual(
            self.assert_success(self.call_cli("settings", "get")[0])["cpuUsageColorMax"], 250,
            "The edited maximum should survive a fresh read.",
        )

        response, _ = self.call_cli("settings", "set-cpu-usage-color-max", "0", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        self.assertEqual(
            self.assert_success(self.call_cli("settings", "get")[0])["cpuUsageColorMax"], 250,
            "A rejected maximum should leave the stored one alone.",
        )
    # case-contract: test_settings_status_sounds_toggle_mutes_task_sounds | Task status sounds are on by default and turn off and back on through the CLI/XPC settings commands, persisting across a fresh read; an unknown value is rejected as invalid_argument without changing the stored setting. With sounds off, a task that waits for a response and then settles in Review after its turn plays no sound and records the Ping and Glass it would have played as muted; once sounds are back on, the next such task plays Ping then Glass, and because the test runner sets PLAYHOUSE_MUTE_SOUNDS=1 each played sound is recorded as muted by the environment (played at volume 0). In the visible UI, the Workspace Settings Sounds toggle shows the stored setting and turning it off or on changes the setting the bridge reads.
    def test_settings_status_sounds_toggle_mutes_task_sounds(self):
        def sounds(task_id, event):
            return [e["sound"] for e in self.diagnostic_events() if e.get("event") == event and e.get("taskID") == task_id]

        def stored():
            return self.assert_success(self.call_cli("settings", "get")[0])["statusSounds"]

        self.assertIs(stored(), True, "Status sounds are on by default.")
        self.assertIs(self.assert_success(self.call_cli("settings", "set-status-sounds", "off")[0])["statusSounds"], False)
        self.assertIs(stored(), False, "Turning sounds off should survive a fresh read.")
        response, _ = self.call_cli("settings", "set-status-sounds", "maybe", expected_status=2)
        self.assert_failure(response, "invalid_argument")
        self.assertIs(stored(), False, "A rejected value should leave the stored setting alone.")

        muted_id = self.create_task("Muted status sound")["id"]
        self.complete_fixture_turn(muted_id, message="Ask me before finishing.", outcome="waiting-response", expected_status="Waiting Response")
        self.complete_fixture_turn(muted_id)
        self.assertEqual(sounds(muted_id, "task.status_sound.played"), [], "A muted task waiting for a response and reaching Review plays no sound.")
        self.assertEqual(sounds(muted_id, "task.status_sound.muted"), ["Ping", "Glass"])

        self.assertIs(self.assert_success(self.call_cli("settings", "set-status-sounds", "on")[0])["statusSounds"], True)
        self.assertIs(stored(), True)
        audible_id = self.create_task("Audible status sound")["id"]
        self.complete_fixture_turn(audible_id, message="Ask me before finishing.", outcome="waiting-response", expected_status="Waiting Response")
        self.complete_fixture_turn(audible_id, message="Complete this task again.")
        self.assertEqual(sounds(audible_id, "task.status_sound.played"), ["Ping", "Glass"], "Turning sounds back on restores them.")
        self.assertEqual(sounds(audible_id, "task.status_sound.muted"), [])
        played = [e for e in self.diagnostic_events() if e.get("event") == "task.status_sound.played" and e.get("taskID") == audible_id]
        self.assertEqual([e.get("environmentMuted") for e in played], ["true", "true"],
                         "PLAYHOUSE_MUTE_SOUNDS=1 should reach the daemon that plays the sounds, so they play at volume 0.")
    # case-contract: test_skills_catalog_lists_repo_global_and_builtin_skills | The Skills page opens from the Skills button beside the terminal button at the bottom of the task sidebar (the composer has no Skills button there; with the sidebar collapsed, its rail keeps that one Skills button and it opens the page) as a modal card centered over the task, a narrow column 403 points wide and nearly as tall as the window, over a dimmed backdrop, and its close button returns to the conversation. Opened from the composer's Skills button in a standalone chat, which has no task sidebar, its backdrop likewise covers the whole window rather than only the sidebar, the card centers in the window, and closing it keeps the chat open. It lists, in one sectioned list whose Repo, Global and Built-in anchors scroll it to their sections, the task's repository skills per repository (from each worktree's .agents/skills and .claude/skills, keyed by the source repository), the user's global skills (~/.agents/skills, Claude's skills folder, and Codex's legacy skills folder), and built-in skills (Codex's bundled .system skills, claude.ai-synced skills, and Claude Code's built-ins read from a provider session), whose section starts collapsed until its header or anchor expands it. The header shows the Skills | Rules | MCP tabs after the page's icon. Each section's header has an info icon whose hover hint (not a tooltip) opens below it and explains the section. Each skill row shows only its name led by one icon for the agents that can use it (the Claude logo for Claude only, the Codex logo for Codex only, a green check for both), on the name's line left of the name and without hovering, and its other details show in a hint left of the row while the pointer rests on it, which carries no provider icon: each user skill's row shows it usable by both Claude and Codex and its hint shows its description; a skill linked into both layouts is one Linked entry, two different skills with the same name in one repository are flagged right of the name as a conflict, a SKILL.md without valid frontmatter is flagged invalid and usable by neither provider, a repository without skills shows an empty state, and built-ins name only the provider they ship with. Reading a skill returns its SKILL.md, and an unknown skill is not_found.
    def test_skills_catalog_lists_repo_global_and_builtin_skills(self):
        manifest = self.skill_manifest
        repository = self.make_skill_repository("skills-catalog-repo", {
            ".agents/skills/repo-agents/SKILL.md": manifest("repo-agents", "Agents layout repository skill"),
            ".claude/skills/repo-claude/SKILL.md": manifest("repo-claude", "Claude layout repository skill"),
            ".agents/skills/repo-shared/SKILL.md": manifest("repo-shared", "Shared into both layouts by a link"),
            ".agents/skills/repo-dup/SKILL.md": manifest("repo-dup", "The agents copy"),
            ".claude/skills/repo-dup/SKILL.md": manifest("repo-dup", "A different Claude copy"),
            ".agents/skills/repo-broken/SKILL.md": "This skill has no frontmatter.\n",
        }, links={".claude/skills/repo-shared": "../../.agents/skills/repo-shared"})
        empty = self.make_skill_repository("skills-empty-repo", {})
        self.write_skill(self.skills_home / ".agents" / "skills", "global-agents", "Global agents skill")
        self.write_skill(self.skills_home / ".claude" / "skills", "global-claude", "Global Claude skill")
        self.write_skill(self.skills_codex_home / "skills", "codex-legacy", "Codex legacy user skill")
        self.write_skill(self.skills_codex_home / "skills" / ".system", "codex-system-skill", "Bundled with Codex")
        self.write_skill(self.skills_home / ".claude" / "skills" / "synced" / "bucket-one", "synced-skill", "Synced from claude.ai")

        task = self.create_skills_task("Skills catalog", [repository, empty])
        worktrees = {record["repositoryPath"]: record["worktreePath"] for record in task["repositoryWorktrees"]}
        self.assertNotEqual(worktrees[str(repository)], str(repository), "The task should read skills from its own worktree.")

        catalog = self.skill_catalog(task_id=task["id"])
        sections = catalog["repositories"]
        self.assertEqual([section["name"] for section in sections], ["skills-catalog-repo", "skills-empty-repo"])
        self.assertEqual(sections[0]["repositoryPath"], str(repository), "Repository skills are keyed by the source repository.")
        self.assertSamePath(sections[0]["rootPath"], worktrees[str(repository)])
        self.assertEqual(sections[1]["skills"], [], "A repository without skills has an empty section.")
        names = [skill["name"] for skill in sections[0]["skills"]]
        self.assertEqual(len(names), len(set(names)), "Each skill is listed once, even when it sits in both layouts.")
        repo = self.skills_by_name(sections[0]["skills"])
        self.assertEqual(sorted(repo), ["repo-agents", "repo-broken", "repo-claude", "repo-dup", "repo-shared"])
        for name in ["repo-agents", "repo-claude", "repo-shared"]:
            self.assertEqual(repo[name]["providers"], ["claude", "codex"], f"{name} should be usable by both providers.")
            self.assertIsNone(repo[name].get("issue"))
            self.assertTrue(repo[name]["enabled"])
            self.assertEqual(repo[name]["id"], f"repo:{repository}#{name}")
        self.assertEqual(repo["repo-agents"]["description"], "Agents layout repository skill")
        self.assertEqual([location["layout"] for location in repo["repo-agents"]["locations"]], ["agents"])
        self.assertEqual([location["layout"] for location in repo["repo-claude"]["locations"]], ["claude"])
        self.assertFalse(repo["repo-agents"]["availableOutsidePlayhouse"])
        shared = repo["repo-shared"]
        self.assertTrue(shared["availableOutsidePlayhouse"], "A skill linked into both layouts is one Linked entry.")
        self.assertEqual(sorted(location["layout"] for location in shared["locations"]), ["agents", "claude"])
        self.assertEqual([location["isSymlink"] for location in shared["locations"] if location["layout"] == "claude"], [True])
        self.assertTrue(repo["repo-dup"]["conflict"])
        self.assertIn(".agents/skills and .claude/skills", repo["repo-dup"]["issue"])
        self.assertFalse(repo["repo-dup"]["availableOutsidePlayhouse"])
        self.assertFalse(repo["repo-broken"]["conflict"])
        self.assertIn("frontmatter", repo["repo-broken"]["issue"])
        self.assertEqual(repo["repo-broken"]["providers"], [], "An invalid skill is usable by neither provider.")

        global_skills = self.skills_by_name(catalog["global"])
        self.assertEqual(sorted(global_skills), ["codex-legacy", "global-agents", "global-claude"])
        self.assertEqual({name: skill["locations"][0]["layout"] for name, skill in global_skills.items()},
                         {"codex-legacy": "codexLegacy", "global-agents": "agents", "global-claude": "claude"})
        self.assertTrue(all(skill["providers"] == ["claude", "codex"] for skill in global_skills.values()))
        self.assertEqual(global_skills["global-agents"]["id"], "global:global-agents")
        self.assertNotIn("synced", global_skills, "claude.ai's synced folder is not a global skill.")

        builtin = self.skills_by_name(catalog["builtin"])
        self.assertEqual(sorted(builtin), ["codex-system-skill", "synced-skill"])
        self.assertEqual(builtin["codex-system-skill"]["providers"], ["codex"])
        self.assertEqual(builtin["synced-skill"]["providers"], ["claude"])
        self.assertFalse(builtin["codex-system-skill"]["editable"])

        environment = self.install_claude_fixture("claude-fixture-skills-catalog")
        bundled = self.skills_by_name(self.skill_catalog("--include-bundled", "true", task_id=task["id"], extra_environment=environment)["builtin"])
        self.assertEqual(bundled["simplify"]["providers"], ["claude"], "Claude Code's built-ins come from its own session.")
        self.assertEqual(bundled["simplify"]["locations"][0]["layout"], "claudeBundled")
        self.assertIsNone(bundled["simplify"].get("folderPath"))
        self.assertIn("compact", bundled)
        self.assertIn("codex-system-skill", bundled)

        without_task = self.skill_catalog()
        self.assertEqual(without_task["repositories"], [])
        self.assertEqual(sorted(skill["name"] for skill in without_task["global"]), sorted(global_skills))

        detail = self.assert_success(self.call_cli("skills", "get", "--task", task["id"], "--skill", repo["repo-agents"]["id"])[0])
        self.assertEqual(detail["content"], manifest("repo-agents", "Agents layout repository skill"))
        self.assertEqual(detail["skill"]["name"], "repo-agents")
        missing, _ = self.call_cli("skills", "get", "--task", task["id"], "--skill", "global:no-such-skill", expected_status=3)
        self.assert_failure(missing, "not_found")
    # case-contract: test_skills_create_update_move_and_delete_on_disk | Creating a skill writes SKILL.md with name and description frontmatter into the open Agent Skills layout, ~/.agents/skills for a global skill or the chosen task worktree's .agents/skills for a repository skill; invalid names, a missing description, a duplicate name, and the built-in scope are rejected with nothing written. Editing saves the new SKILL.md exactly as written, keeping frontmatter Playhouse does not parse, and rejects a renamed or description-less frontmatter while keeping the file. Clicking a skill row opens the editor modal straight on its whole SKILL.md, frontmatter included, with no structured header form, and its Preview tab shows that Markdown rendered with the frontmatter as a table; saving there writes the edited file, a description-less edit is rejected in the editor while keeping the file, and after the editor closes the page still answers clicks. A structured CLI edit rewrites the header (reading a YAML list as one field), removes an emptied field, keeps frontmatter Playhouse does not edit, and rejects an unknown field or an empty description while keeping the file. Clicking a built-in skill with a folder opens it read-only, without Save. New Skill asks only for a name, a description, and instructions it can preview, and a header field given to the CLI's create is written into the new SKILL.md. Moving a skill between a repository and the global gallery moves its folder and rejects a move onto an existing name. Deleting removes the folder from disk, built-in skills are read-only, and every change is visible to a fresh CLI process and on the Skills page.
    def test_skills_create_update_move_and_delete_on_disk(self):
        repository = self.make_skill_repository("skills-manage-repo", {})
        task = self.create_skills_task("Skills manage", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        global_folder = self.skills_home / ".agents" / "skills"

        def create(*arguments, expected_status=0):
            return self.call_cli("skills", "create", "--task", task["id"], *arguments, expected_status=expected_status)[0]

        for arguments, code in [
            (["--scope", "global", "--name", "Release Notes", "--description", "Bad name"], "invalid_argument"),
            (["--scope", "global", "--name", "release-notes"], "invalid_argument"),
            (["--scope", "builtin", "--name", "release-notes", "--description", "Built-in scope"], "invalid_argument"),
        ]:
            self.assert_failure(create(*arguments, expected_status=2), code)
        self.assertFalse(global_folder.exists(), "A rejected skill writes nothing.")

        created = self.assert_success(create("--scope", "global", "--name", "release-notes", "--description", "Draft release notes", "--body", "Summarize merged changes."))
        self.assertEqual(created["id"], "global:release-notes")
        self.assertEqual(created["providers"], ["claude", "codex"])
        manifest_path = global_folder / "release-notes" / "SKILL.md"
        self.assertEqual(manifest_path.read_text(encoding="utf-8"),
                         '---\nname: release-notes\ndescription: "Draft release notes"\n---\n\nSummarize merged changes.\n')
        self.assert_failure(create("--scope", "global", "--name", "release-notes", "--description", "Again", expected_status=1), "already_exists")

        repo_skill = self.assert_success(create("--scope", "repo", "--root", str(repository), "--name", "repo-new", "--description", "Repository only"))
        self.assertEqual(repo_skill["id"], f"repo:{repository}#repo-new")
        self.assertTrue((worktree / ".agents" / "skills" / "repo-new" / "SKILL.md").is_file(),
                        "A repository skill is written into the task worktree's Agent Skills folder.")
        self.assertFalse((repository / ".agents").exists(), "The source checkout is left alone.")

        def update(content, expected_status=0):
            path = self.data_directory / f"skill-edit-{uuid.uuid4().hex}.md"
            path.write_text(content, encoding="utf-8")
            return self.call_cli("skills", "update", "--task", task["id"], "--skill", "global:release-notes",
                                 "--content-file", path, expected_status=expected_status)[0]

        for rejected in [self.skill_manifest("other-name", "Renamed"), "---\nname: release-notes\n---\nNo description.\n"]:
            response = update(rejected, expected_status=2)
            self.assert_failure(response, "invalid_argument")
            self.assertNotIn("Expected a value", response["error"]["message"], "The edit itself must be what is rejected.")
        self.assertIn("Draft release notes", manifest_path.read_text(encoding="utf-8"), "A rejected edit keeps the file.")
        edited = self.skill_manifest("release-notes", "Draft concise release notes", "Group changes by area.")
        updated = self.assert_success(update(edited))
        self.assertEqual(updated["description"], "Draft concise release notes")
        self.assertEqual(manifest_path.read_text(encoding="utf-8"), edited)
        # The editor saves the whole file, so frontmatter Playhouse does not parse is written as typed.
        verbatim = "---\nname: release-notes\ndescription: Draft concise release notes\nmetadata:\n  owner: docs\n---\n\n# Release notes\n\n- Group changes by area.\n"
        self.assertEqual(self.assert_success(update(verbatim))["description"], "Draft concise release notes")
        self.assertEqual(manifest_path.read_text(encoding="utf-8"), verbatim, "A whole-file edit is saved exactly as written.")
        self.assertEqual(self.assert_success(self.call_cli("skills", "get", "--task", task["id"], "--skill", "global:release-notes")[0])["content"], verbatim)

        # The editor works on the parsed header: name, description, and the
        # optional Agent Skills fields, with other frontmatter kept as written.
        manifest_path.write_text(
            "---\nname: release-notes\ndescription: Draft concise release notes\nallowed-tools:\n  - Read\n  - Bash\nmetadata:\n  owner: docs\n---\n\nGroup changes by area.\n",
            encoding="utf-8",
        )
        detail = self.assert_success(self.call_cli("skills", "get", "--task", task["id"], "--skill", "global:release-notes")[0])
        self.assertEqual(detail["manifest"]["name"], "release-notes")
        self.assertEqual(detail["manifest"]["description"], "Draft concise release notes")
        self.assertEqual(detail["manifest"]["fields"], {"allowed-tools": "Read, Bash"}, "A YAML list reads as one editable field.")
        self.assertEqual(detail["manifest"]["body"], "Group changes by area.")
        self.assertEqual(detail["manifest"]["preservedFrontmatter"], ["metadata:", "  owner: docs"])
        structured = self.assert_success(self.call_cli(
            "skills", "update", "--task", task["id"], "--skill", "global:release-notes",
            "--description", "Draft release notes by area", "--field", "license=MIT", "--field", "allowed-tools=",
            "--body", "List each change under its area.",
        )[0])
        self.assertEqual(structured["description"], "Draft release notes by area")
        self.assertEqual(manifest_path.read_text(encoding="utf-8"),
                         '---\nname: release-notes\ndescription: "Draft release notes by area"\nlicense: "MIT"\nmetadata:\n  owner: docs\n---\n\nList each change under its area.\n',
                         "A structured edit rewrites the header, removes an emptied field, and keeps unknown keys.")
        for arguments in [["--field", "model=opus"], ["--description", "  "]]:
            self.assert_failure(self.call_cli("skills", "update", "--task", task["id"], "--skill", "global:release-notes",
                                              *arguments, expected_status=2)[0], "invalid_argument")
        self.assertIn("List each change under its area.", manifest_path.read_text(encoding="utf-8"), "A rejected structured edit keeps the file.")
        self.assert_failure(self.call_cli("skills", "update", "--task", task["id"], "--skill", "global:release-notes", expected_status=2)[0], "invalid_argument")
        fielded = self.assert_success(create("--scope", "global", "--name", "fielded", "--description", "Has header fields",
                                             "--field", "compatibility=Needs git", "--body", "Steps."))
        self.assertEqual(fielded["id"], "global:fielded")
        self.assertEqual((global_folder / "fielded" / "SKILL.md").read_text(encoding="utf-8"),
                         '---\nname: fielded\ndescription: "Has header fields"\ncompatibility: "Needs git"\n---\n\nSteps.\n')
        self.assert_failure(create("--scope", "global", "--name", "bad-field", "--description", "Unknown field", "--field", "model=opus", expected_status=2), "invalid_argument")
        self.assertFalse((global_folder / "bad-field").exists(), "A rejected field writes nothing.")
        self.assert_success(self.call_cli("skills", "delete", "--task", task["id"], "--skill", "global:fielded")[0])

        moved = self.assert_success(self.call_cli("skills", "move", "--task", task["id"], "--skill", repo_skill["id"], "--scope", "global")[0])
        self.assertEqual(moved["id"], "global:repo-new")
        self.assertTrue((global_folder / "repo-new" / "SKILL.md").is_file())
        self.assertFalse((worktree / ".agents" / "skills" / "repo-new").exists())
        self.assert_failure(self.call_cli("skills", "move", "--task", task["id"], "--skill", "global:repo-new", "--scope", "global", expected_status=2)[0], "invalid_argument")
        back = self.assert_success(self.call_cli("skills", "move", "--task", task["id"], "--skill", "global:repo-new", "--scope", "repo", "--root", str(repository))[0])
        self.assertEqual(back["id"], f"repo:{repository}#repo-new")
        self.assertTrue((worktree / ".agents" / "skills" / "repo-new" / "SKILL.md").is_file(), "A global skill moves into the chosen worktree.")
        self.assertFalse((global_folder / "repo-new").exists())
        self.assert_success(self.call_cli("skills", "move", "--task", task["id"], "--skill", back["id"], "--scope", "global")[0])
        self.write_skill(worktree / ".claude" / "skills", "release-notes", "A repository skill with the same name")
        self.assert_failure(self.call_cli("skills", "move", "--task", task["id"], "--skill", "global:release-notes", "--scope", "repo", "--root", str(repository), expected_status=1)[0], "already_exists")
        self.assertTrue(manifest_path.is_file(), "A rejected move leaves the skill in place.")

        fresh = self.skill_catalog(task_id=task["id"])
        self.assertEqual(sorted(skill["name"] for skill in fresh["global"]), ["release-notes", "repo-new"])
        self.assertEqual(self.skills_by_name(fresh["global"])["release-notes"]["description"], "Draft release notes by area")
        self.assertEqual([skill["name"] for skill in fresh["repositories"][0]["skills"]], ["release-notes"])

        self.write_skill(self.skills_codex_home / "skills" / ".system", "codex-system-skill", "Bundled with Codex")
        self.assert_failure(self.call_cli("skills", "delete", "--task", task["id"], "--skill", "builtin:codex:codex-system-skill", expected_status=2)[0], "invalid_argument")
        self.assertTrue((self.skills_codex_home / "skills" / ".system" / "codex-system-skill").is_dir())
        self.assertEqual(self.assert_success(self.call_cli("skills", "delete", "--task", task["id"], "--skill", "global:repo-new")[0]), {"deleted": True})
        self.assertFalse((global_folder / "repo-new").exists(), "Deleting removes the skill folder from disk.")
        self.assert_failure(self.call_cli("skills", "get", "--skill", "global:repo-new", expected_status=3)[0], "not_found")
    # case-contract: test_skills_enable_state_and_outside_links_persist | Turning a skill off is stored by Playhouse rather than in either provider's settings, survives fresh CLI processes and reopening the Skills page, and can be turned back on. The row's actions menu has Disable, or Enable for a skill that is off, which takes effect as soon as it is chosen; a skill that is off shows grayed out, its menu's Use is disabled, and the row still responds, and turning a skill on disk on or off never starts a Claude Code session. Making a skill available outside Playhouse writes a real symlink into the other provider's layout (an absolute link in Claude's global skills folder, a relative link inside the repository), after which the skill shows as Linked; an existing file at the link path is left untouched and the request fails with already_exists, removing the outside link deletes only the symlink and keeps the skill, and a skill without a link cannot be unlinked.
    def test_skills_enable_state_and_outside_links_persist(self):
        repository = self.make_skill_repository("skills-link-repo", {
            ".agents/skills/repo-agents/SKILL.md": self.skill_manifest("repo-agents", "Repository agents skill"),
        })
        task = self.create_skills_task("Skills links", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        self.write_skill(self.skills_home / ".agents" / "skills", "global-agents", "Global agents skill")
        self.write_skill(self.skills_home / ".agents" / "skills", "blocked", "Its link path is taken")
        claude_skills = self.skills_home / ".claude" / "skills"
        claude_skills.mkdir(parents=True)
        (claude_skills / "blocked").write_text("Not a skill, just a file in the way.\n", encoding="utf-8")

        def skill(name, scope="global"):
            catalog = self.skill_catalog(task_id=task["id"])
            skills = catalog["global"] if scope == "global" else catalog["repositories"][0]["skills"]
            return self.skills_by_name(skills)[name]

        environment = self.install_claude_fixture("claude-fixture-skills-toggle")
        sessions = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".sessions")
        disabled = self.assert_success(self.call_cli("skills", "disable", "--task", task["id"], "--skill", "global:global-agents",
                                                     "--include-bundled", "true", extra_environment=environment)[0])
        self.assertFalse(disabled["enabled"])
        self.assertFalse(sessions.exists(), "Turning a skill on disk off must not start a Claude Code session.")
        self.assertFalse(skill("global-agents")["enabled"], "Turning a skill off survives a fresh CLI process.")
        self.assertFalse((self.skills_codex_home / "config.toml").exists(), "Codex's config is not written.")
        self.assertFalse((self.skills_home / ".claude" / "settings.json").exists(), "Claude's settings are not written.")
        self.assert_failure(self.call_cli("skills", "disable", "--skill", "global:no-such-skill", expected_status=3)[0], "not_found")
        self.assertTrue(self.assert_success(self.call_cli("skills", "enable", "--task", task["id"], "--skill", "global:global-agents")[0])["enabled"])
        self.assertTrue(skill("global-agents")["enabled"])

        linked = self.assert_success(self.call_cli("skills", "link", "--task", task["id"], "--skill", "global:global-agents")[0])
        self.assertTrue(linked["availableOutsidePlayhouse"])
        link = claude_skills / "global-agents"
        self.assertTrue(link.is_symlink())
        self.assertSamePath(os.readlink(link), self.skills_home / ".agents" / "skills" / "global-agents")
        self.assertTrue(skill("global-agents")["availableOutsidePlayhouse"])

        repo_linked = self.assert_success(self.call_cli("skills", "link", "--task", task["id"], "--skill", f"repo:{repository}#repo-agents")[0])
        self.assertTrue(repo_linked["availableOutsidePlayhouse"])
        repo_link = worktree / ".claude" / "skills" / "repo-agents"
        self.assertEqual(os.readlink(repo_link), "../../.agents/skills/repo-agents", "A repository link is relative, so it can be committed.")
        self.assertEqual((repo_link / "SKILL.md").read_text(encoding="utf-8"), self.skill_manifest("repo-agents", "Repository agents skill"))

        self.assert_failure(self.call_cli("skills", "link", "--task", task["id"], "--skill", "global:blocked", expected_status=1)[0], "already_exists")
        self.assertEqual((claude_skills / "blocked").read_text(encoding="utf-8"), "Not a skill, just a file in the way.\n")

        unlinked = self.assert_success(self.call_cli("skills", "unlink", "--task", task["id"], "--skill", "global:global-agents")[0])
        self.assertFalse(unlinked["availableOutsidePlayhouse"])
        self.assertFalse(link.exists() or link.is_symlink(), "Removing the outside link deletes only the symlink.")
        self.assertTrue((self.skills_home / ".agents" / "skills" / "global-agents" / "SKILL.md").is_file())
        self.assert_failure(self.call_cli("skills", "unlink", "--task", task["id"], "--skill", "global:global-agents", expected_status=2)[0], "invalid_argument")
    # case-contract: test_skills_select_many_and_delete_together | Pressing and holding a skill row starts selecting skills, with no separate Select button: each editable row shows a checkbox that a click toggles, built-in skills show none and cannot be selected, and the header shows how many are selected with Fix, Delete, and Done. Deleting the selection after one confirmation removes every selected skill folder, repository and global alike, from disk, leaves unselected skills in place, forgets a deleted skill's off state, and ends selecting. A batch that includes a read-only or unknown skill deletes nothing and fails with invalid_argument or not_found.
    def test_skills_select_many_and_delete_together(self):
        repository = self.make_skill_repository("skills-select-repo", {
            ".agents/skills/repo-one/SKILL.md": self.skill_manifest("repo-one", "First repository skill"),
            ".agents/skills/repo-keep/SKILL.md": self.skill_manifest("repo-keep", "Stays after the bulk delete"),
        })
        task = self.create_skills_task("Skills select", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        global_folder = self.skills_home / ".agents" / "skills"
        for name in ["global-one", "global-two"]:
            self.write_skill(global_folder, name, f"Global skill {name}")
        self.write_skill(self.skills_codex_home / "skills" / ".system", "codex-system-skill", "Bundled with Codex")
        self.assert_success(self.call_cli("skills", "disable", "--task", task["id"], "--skill", "global:global-two")[0])

        rejected = self.call_cli("skills", "delete", "--task", task["id"], "--skill", "global:global-one",
                                 "--skill", "builtin:codex:codex-system-skill", expected_status=2)[0]
        self.assert_failure(rejected, "invalid_argument")
        self.assertTrue((global_folder / "global-one").is_dir(), "One read-only skill in the batch deletes nothing.")
        missing = self.call_cli("skills", "delete", "--task", task["id"], "--skill", "global:global-one",
                                "--skill", "global:no-such-skill", expected_status=3)[0]
        self.assert_failure(missing, "not_found")
        self.assertTrue((global_folder / "global-one").is_dir(), "One unknown skill in the batch deletes nothing.")

        deleted = self.assert_success(self.call_cli(
            "skills", "delete", "--task", task["id"], "--skill", "global:global-one", "--skill", "global:global-two",
            "--skill", f"repo:{repository}#repo-one",
        )[0])
        self.assertEqual(deleted, {"deleted": True})
        self.assertFalse((global_folder / "global-one").exists())
        self.assertFalse((global_folder / "global-two").exists())
        self.assertFalse((worktree / ".agents" / "skills" / "repo-one").exists(), "A repository skill in the batch is deleted from the worktree.")
        self.assertTrue((worktree / ".agents" / "skills" / "repo-keep" / "SKILL.md").is_file(), "Unselected skills stay.")
        fresh = self.skill_catalog(task_id=task["id"])
        self.assertEqual(fresh["global"], [])
        self.assertEqual([skill["name"] for skill in fresh["repositories"][0]["skills"]], ["repo-keep"])
        self.write_skill(global_folder, "global-two", "Recreated with the same name")
        self.assertTrue(self.skills_by_name(self.skill_catalog(task_id=task["id"])["global"])["global-two"]["enabled"],
                        "Deleting a skill forgets that it was turned off.")
    # case-contract: test_skills_fix_with_agent_starts_task_for_repo_and_global_skills | A conflicting or invalid skill offers a Fix button on its row (and in the selection bar while selecting), and several selected skills can be fixed in one task. Fixing creates a task, on the source task's provider, whose saved prompt teaches the agent the skill format and lists each skill with its problem: repository skills by repository-relative path, to be fixed in the new task's own worktree of the source repository and committed and pushed like any code change, and global skills by absolute path, to be fixed in place with nothing to commit; the global skill folders are opened to the agent as context folders, and fixing only global skills needs no repository. The view switches to the new task's conversation, which sends that prompt as its own composer draft, leaving the composer empty and no unsent draft behind, so the turn runs in the new task's worktree with the global folders reachable. A skill with no problem, a built-in skill, an unknown skill, and a request without a task are rejected without opening a task.
    def test_skills_fix_with_agent_starts_task_for_repo_and_global_skills(self):
        manifest = self.skill_manifest
        repository = self.make_skill_repository("skills-fix-repo", {
            ".agents/skills/repo-dup/SKILL.md": manifest("repo-dup", "The agents copy"),
            ".claude/skills/repo-dup/SKILL.md": manifest("repo-dup", "A different Claude copy"),
            ".agents/skills/repo-ok/SKILL.md": manifest("repo-ok", "Nothing to fix"),
        })
        self.write_skill(self.skills_home / ".agents" / "skills", "global-dup", "The global agents copy")
        self.write_skill(self.skills_home / ".claude" / "skills", "global-dup", "The global Claude copy")
        broken = self.skills_home / ".agents" / "skills" / "global-broken"
        broken.mkdir(parents=True)
        (broken / "SKILL.md").write_text("No frontmatter here.\n", encoding="utf-8")
        self.write_skill(self.skills_codex_home / "skills" / ".system", "codex-system-skill", "Bundled with Codex")
        environment = self.install_claude_fixture("claude-fixture-skills-fix")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        source = self.create_skills_task("Skills fix source", [repository], provider="claude")
        source_worktree = Path(source["repositoryWorktrees"][0]["worktreePath"])
        tasks_before = len(self.assert_success(self.call_cli("board", "list")[0])["tasks"])

        def fix(*skills, expected_status=0, task_id=source["id"]):
            arguments = [argument for skill in skills for argument in ("--skill", skill)]
            return self.call_cli("skills", "fix", "--task", task_id, *arguments, expected_status=expected_status)[0]

        self.assert_failure(fix(f"repo:{repository}#repo-ok", expected_status=2), "invalid_argument")
        self.assert_failure(fix("builtin:codex:codex-system-skill", expected_status=2), "invalid_argument")
        self.assert_failure(fix("global:no-such-skill", expected_status=3), "not_found")
        self.assert_failure(self.call_cli("skills", "fix", "--skill", "global:global-dup", expected_status=2)[0], "invalid_argument")
        self.assertEqual(len(self.assert_success(self.call_cli("board", "list")[0])["tasks"]), tasks_before, "A rejected fix opens no task.")

        created = self.assert_success(fix(f"repo:{repository}#repo-dup", "global:global-dup", "global:global-broken"))
        task, prompt = created["task"], created["prompt"]
        self.assertEqual(task["title"], "Fix skills repo-dup, global-dup, global-broken")
        self.assertEqual(task["status"], "Backlog")
        self.assertEqual(task["conversationProvider"], "claude", "The fixing task uses the source task's provider.")
        self.assertEqual([record["repositoryPath"] for record in task["repositoryWorktrees"]], [str(repository)],
                         "A repository skill is fixed in the new task's own worktree of its source repository.")
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(sorted(os.path.realpath(folder) for folder in task["contextFolders"]),
                         sorted(os.path.realpath(self.skills_home / folder) for folder in [".agents/skills", ".claude/skills"]),
                         "Global skill folders are opened to the agent so it can fix them in place.")
        self.assertEqual(task["savedPrompt"], prompt)
        self.assertIn("commit and push", prompt)
        self.assertIn("`repo-dup` in skills-fix-repo: `.agents/skills/repo-dup`, `.claude/skills/repo-dup`", prompt)
        self.assertNotIn(str(source_worktree), prompt, "Repository paths are relative, so they point into the fixing task's worktree.")
        self.assertIn("not tracked by Git: fix them directly in place", prompt)
        for folder in [".agents/skills/global-dup", ".claude/skills/global-dup"]:
            path = self.skills_home / folder
            self.assertTrue(str(path) in prompt or os.path.realpath(path) in prompt, f"The prompt names the global skill's absolute path {path}.")
        self.assertIn("`global-broken`", prompt)
        self.assertIn("frontmatter", prompt)
        self.assertNotIn("repo-ok", prompt)
        stored = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(stored["savedPrompt"], prompt, "The fixing task and its prompt are saved for a fresh CLI process.")

        global_only = self.assert_success(fix("global:global-dup"))["task"]
        self.assertEqual(global_only["title"], "Fix skill global-dup")
        self.assertEqual(global_only["repositoryWorktrees"], [], "Fixing only global skills needs no repository.")
        self.assertNotIn("commit and push", self.assert_success(self.call_cli("task", "get", global_only["id"])[0])["savedPrompt"])

        self.assert_success(self.call_cli("conversation", "send", task["id"], "--message", prompt, extra_environment=environment)[0])
        turn = next(turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == prompt)
        started = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        worktree = started["repositoryWorktrees"][0]
        self.assertFalse(worktree["isPending"], "Starting the fix creates the task's worktree.")
        self.assertNotEqual(os.path.realpath(worktree["worktreePath"]), os.path.realpath(source_worktree))
        self.assertSamePath(turn["cwd"], worktree["worktreePath"])
        self.assertIsNone(started.get("pendingSubmittedPrompt"), "The sent prompt is no longer pending.")
        self.assertFalse(started["hasUnsentDraft"], "The sent prompt leaves no unsent draft behind.")
        self.assertTrue((Path(worktree["worktreePath"]) / ".claude" / "skills" / "repo-dup" / "SKILL.md").is_file(),
                        "The fixing task's worktree holds the committed skills to fix.")
        directories = [os.path.realpath(turn["arguments"][index + 1]) for index, value in enumerate(turn["arguments"]) if value == "--add-dir"]
        for folder in [".agents/skills", ".claude/skills"]:
            self.assertIn(os.path.realpath(self.skills_home / folder), directories, f"Claude Code can reach the global {folder} folder.")
    # case-contract: test_skills_bridge_claude_launch_sees_agents_skills | A Claude turn sees the skills Claude Code does not read natively: Playhouse passes a Playhouse-owned --add-dir wrapper whose .claude/skills links to the task worktree's and the global .agents/skills folders, leaves skills Claude already reads out of the wrapper, and turns disabled skills off for that run with --settings skillOverrides, without writing to the repository or Claude's settings. Using a skill from the Skills page puts /skill-name at the start of the composer and the message reaches Claude Code unchanged. The resumed second turn gets the same wrapper, and turning the skill back on drops the override.
    def test_skills_bridge_claude_launch_sees_agents_skills(self):
        repository = self.make_skill_repository("skills-claude-repo", {
            ".agents/skills/repo-agents/SKILL.md": self.skill_manifest("repo-agents", "Bridged to Claude"),
            ".claude/skills/repo-claude/SKILL.md": self.skill_manifest("repo-claude", "Claude reads this natively"),
            ".claude/skills/repo-off/SKILL.md": self.skill_manifest("repo-off", "Turned off in Playhouse"),
        })
        self.write_skill(self.skills_home / ".agents" / "skills", "global-agents", "Global skill bridged to Claude")
        environment = self.install_claude_fixture("claude-fixture-skills-bridge")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        task_id = self.create_skills_task("Claude skills", [repository], provider="claude")["id"]
        self.assert_success(self.call_cli("skills", "disable", "--task", task_id, "--skill", f"repo:{repository}#repo-off")[0])
        bundled = self.assert_success(self.call_cli("skills", "disable", "--task", task_id, "--skill", "builtin:claude:simplify",
                                                    "--include-bundled", "true", extra_environment=environment)[0])
        self.assertFalse(bundled["enabled"])
        before = self.run_git(repository, "status", "--porcelain")

        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "/repo-agents Tell me a story.", extra_environment=environment)[0])
        worktree = Path(self.assert_success(self.call_cli("task", "get", task_id)[0])["repositoryWorktrees"][0]["worktreePath"])
        turns = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText")]
        first = turns[0]
        self.assertEqual(first["userText"], "/repo-agents Tell me a story.", "The skill invocation reaches Claude Code unchanged.")
        self.assertSamePath(first["cwd"], worktree)
        arguments = first["arguments"]
        directories = [arguments[index + 1] for index, value in enumerate(arguments) if value == "--add-dir"]
        self.assertEqual(len(directories), 1, f"One Playhouse wrapper should be added: {arguments}")
        wrapper = Path(directories[0])
        self.assertSamePath(wrapper.parent, self.data_directory / "skill-bridge" / "claude")
        links = wrapper / ".claude" / "skills"
        self.assertEqual(sorted(entry.name for entry in links.iterdir()), ["global-agents", "repo-agents"],
                         "Only skills Claude does not read natively are bridged.")
        self.assertSamePath(links / "repo-agents", worktree / ".agents" / "skills" / "repo-agents")
        self.assertSamePath(links / "global-agents", self.skills_home / ".agents" / "skills" / "global-agents")
        self.assertEqual(json.loads(arguments[arguments.index("--settings") + 1]), {"skillOverrides": {"repo-off": "off", "simplify": "off"}},
                         "Disabled repository and Claude built-in skills are turned off for this run.")
        self.assertEqual(sorted(first["skills"]), ["global-agents", "repo-agents", "repo-claude"],
                         "Claude Code should load the bridged skills and leave the disabled one off.")
        self.assertEqual(self.run_git(repository, "status", "--porcelain"), before, "The repository is not written to.")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "The worktree is not written to.")
        self.assertFalse((self.skills_home / ".claude" / "settings.json").exists())

        bridge = self.assert_success(self.call_cli("skills", "bridge", "--task", task_id)[0])
        self.assertEqual([os.path.realpath(path) for path in bridge["claudeAddDirectories"]], [os.path.realpath(wrapper)])
        self.assertEqual(bridge["claudeDisabledSkillNames"], ["repo-off", "simplify"])

        self.assert_success(self.call_cli("skills", "enable", "--task", task_id, "--skill", f"repo:{repository}#repo-off")[0])
        self.assert_success(self.call_cli("skills", "enable", "--task", task_id, "--skill", "builtin:claude:simplify",
                                          "--include-bundled", "true", extra_environment=environment)[0])
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Tell me a story again.", extra_environment=environment)[0])
        turns = [turn for turn in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if turn.get("userText") == "Tell me a story again."]
        second = turns[-1]
        self.assertTrue(second["resumed"], "The second turn resumes the Claude session.")
        resumed_directories = [second["arguments"][index + 1] for index, value in enumerate(second["arguments"]) if value == "--add-dir"]
        self.assertEqual([os.path.realpath(path) for path in resumed_directories], [os.path.realpath(wrapper)], "A resumed turn gets the same wrapper.")
        self.assertNotIn("--settings", second["arguments"], "Turning the skill back on drops the override.")
        self.assertIn("repo-off", second["skills"])
    # case-contract: test_skills_bridge_codex_thread_sees_claude_skills | A Codex turn sees the skills Codex does not read natively: Playhouse gives the shared app-server extra skill roots made of Playhouse-owned wrapper folders that link to the task worktree's and the global .claude/skills folders, leaves the cwd repository's .agents/skills to Codex, and starts the thread with a per-thread skills config that disables both the task's disabled skills and other tasks' bridged skills, without writing Codex's config.toml. Using a skill from the Skills page puts /skill-name in the composer, and the turn sends Codex a structured skill input naming that skill's SKILL.md alongside the text; a later turn without a skill sends none.
    def test_skills_bridge_codex_thread_sees_claude_skills(self):
        other = self.make_skill_repository("skills-other-repo", {
            ".claude/skills/other-claude/SKILL.md": self.skill_manifest("other-claude", "Belongs to another task"),
        })
        other_task = self.create_task("Other skills task", roots=[other])
        other_bridge = self.assert_success(self.call_cli("skills", "bridge", "--task", other_task["id"])[0])
        self.assertEqual([link["name"] for link in other_bridge["codexLinks"]], ["other-claude"])
        other_wrapper = Path(other_bridge["codexLinks"][0]["link"]).parent

        repository = self.make_skill_repository("skills-codex-repo", {
            ".claude/skills/repo-claude/SKILL.md": self.skill_manifest("repo-claude", "Bridged to Codex"),
            ".agents/skills/repo-agents/SKILL.md": self.skill_manifest("repo-agents", "Codex reads this natively"),
            ".agents/skills/repo-off/SKILL.md": self.skill_manifest("repo-off", "Turned off in Playhouse"),
        })
        self.write_skill(self.skills_home / ".claude" / "skills", "global-claude", "Global skill bridged to Codex")
        task = self.create_skills_task("Codex skills", [repository])
        self.assert_success(self.call_cli("skills", "disable", "--task", task["id"], "--skill", f"repo:{repository}#repo-off")[0])

        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-skills", message="/repo-claude Complete this task.")
        worktree = Path(self.assert_success(self.call_cli("task", "get", task["id"])[0])["repositoryWorktrees"][0]["worktreePath"])
        history = json.loads((self.data_directory / "codex-fixture-skills.history").read_text(encoding="utf-8"))
        bridge = self.assert_success(self.call_cli("skills", "bridge", "--task", task["id"])[0])
        own_wrapper = Path(bridge["codexLinks"][0]["link"]).parent
        self.assertSamePath(own_wrapper.parent, self.data_directory / "skill-bridge" / "codex")
        self.assertEqual(sorted(entry.name for entry in own_wrapper.iterdir() if not entry.name.startswith(".")),
                         ["global-claude", "repo-claude"], "The cwd repository's .agents skills stay native to Codex.")
        self.assertSamePath(own_wrapper / "repo-claude", worktree / ".claude" / "skills" / "repo-claude")
        self.assertSamePath(own_wrapper / "global-claude", self.skills_home / ".claude" / "skills" / "global-claude")
        self.assertEqual(sorted(os.path.realpath(root) for root in history["skillExtraRoots"]),
                         sorted(os.path.realpath(root) for root in [own_wrapper, other_wrapper]),
                         "The shared app-server gets every task's wrapper as an extra root.")
        disabled = {entry["path"] for entry in history["threadStartConfig"]["skills"]["config"] if entry["enabled"] is False}
        disabled_real = {os.path.realpath(path) for path in disabled}
        self.assertIn(os.path.realpath(other_wrapper / "other-claude" / "SKILL.md"), disabled_real,
                      "Another task's bridged skill is hidden from this thread.")
        self.assertIn(os.path.realpath(worktree / ".agents" / "skills" / "repo-off" / "SKILL.md"), disabled_real,
                      "A disabled native skill is turned off for this thread.")
        self.assertFalse(any(path.startswith(os.path.realpath(own_wrapper)) for path in disabled_real), "The thread's own bridged skills stay on.")
        self.assertFalse((self.skills_codex_home / "config.toml").exists(), "Codex's config.toml is not written.")
        first = history["turns"][0]
        self.assertEqual(first["userMessage"], "/repo-claude Complete this task.")
        self.assertEqual(len(first["skillInputs"]), 1)
        self.assertEqual(first["skillInputs"][0]["type"], "skill")
        self.assertEqual(first["skillInputs"][0]["name"], "repo-claude")
        self.assertSamePath(first["skillInputs"][0]["path"], worktree / ".claude" / "skills" / "repo-claude" / "SKILL.md")

        # A restarted app-server loads the thread again, and must get the bridge again.
        self.restart_provider(self.data_directory / "codex-fixture-skills")
        calls_before = history["skillExtraRootsCalls"]
        self.complete_fixture_turn(task["id"], executable_name="codex-fixture-skills", message="Complete this task again.")
        history = json.loads((self.data_directory / "codex-fixture-skills.history").read_text(encoding="utf-8"))
        self.assertGreaterEqual(history.get("threadResumeCount", 0), 1, "The second turn resumes the thread on a fresh app-server.")
        self.assertGreater(history["skillExtraRootsCalls"], calls_before, "The fresh app-server gets the extra skill roots again.")
        resumed_disabled = {os.path.realpath(entry["path"]) for entry in history["threadResumeConfig"]["skills"]["config"] if entry["enabled"] is False}
        self.assertEqual(resumed_disabled, disabled_real, "The resumed thread gets the same per-thread skill config.")
        later = [turn for turn in history["turns"] if turn["userMessage"] == "Complete this task again."][-1]
        self.assertEqual(later["skillInputs"], [], "A turn that names no skill sends none.")
    # case-contract: test_skills_private_create_list_convert_and_delete | A repository skill created with Private on is written only to Playhouse's private skill store, in a folder keyed by the source repository and laid out as .claude/skills/<name>/SKILL.md, with nothing written to the repository or the task worktree, whose git status stays clean. It is listed under its repository with scope private and a Private badge, every task on that repository sees it from its own worktree, and a task on another repository does not. A private skill cannot take a name that the committed skills of any of the task's repositories, the global skills, or the built-in skills already use, and a committed skill of the same name that appears later in a worktree takes precedence there: the private one is shown as Shadowed and used by neither provider. Editing saves the store's SKILL.md, a private skill cannot be linked outside Playhouse, Convert to Repository Skill moves it into the worktree's .agents/skills as a repository skill ready to commit, Make Private moves a repository skill back into the store and out of the worktree, Make Private to a repository moves a global skill into that repository's store, and Delete removes only its store folder.
    def test_skills_private_create_list_convert_and_delete(self):
        repository = self.make_skill_repository("skills-private-repo", {
            ".agents/skills/committed/SKILL.md": self.skill_manifest("committed", "A committed repository skill"),
        })
        other = self.make_skill_repository("skills-private-other", {})
        self.write_skill(self.skills_home / ".agents" / "skills", "global-taken", "A global skill")
        task = self.create_skills_task("Private skills", [repository])
        worktree = Path(task["repositoryWorktrees"][0]["worktreePath"])
        digest = hashlib.sha256(str(repository).encode("utf-8")).hexdigest()[:12]
        store = self.data_directory / "private-skills" / f"skills-private-repo-{digest}"
        private_id = f"private:{repository}#deploy-notes"

        def create(*arguments, expected_status=0):
            return self.call_cli("skills", "create", "--task", task["id"], "--scope", "private", *arguments, expected_status=expected_status)[0]

        def section(task_id=task["id"]):
            return self.skills_by_name(self.skill_catalog(task_id=task_id)["repositories"][0]["skills"])

        for taken in ["committed", "global-taken"]:
            self.assert_failure(create("--name", taken, "--description", "Taken", expected_status=1), "already_exists")
        self.write_skill(self.skills_codex_home / "skills" / ".system", "codex-system-skill", "Bundled with Codex")
        self.assert_failure(create("--name", "codex-system-skill", "--description", "Taken", expected_status=1), "already_exists")
        both = self.create_skills_task("Private skills two repositories", [repository, other])
        self.assert_failure(self.call_cli("skills", "create", "--task", both["id"], "--scope", "private", "--root", str(other),
                                          "--name", "committed", "--description", "Taken in the other repository", expected_status=1)[0], "already_exists")
        self.assertFalse(store.exists(), "A rejected private skill writes nothing.")

        created = self.assert_success(create("--name", "deploy-notes", "--description", "Write deploy notes", "--body", "List the deploy steps."))
        self.assertEqual(created["id"], private_id)
        self.assertEqual(created["scope"], "private")
        self.assertEqual(created["repositoryPath"], str(repository))
        self.assertEqual(created["providers"], ["claude", "codex"])
        self.assertEqual([location["layout"] for location in created["locations"]], ["playhousePrivate"])
        folder = store / ".claude" / "skills" / "deploy-notes"
        self.assertSamePath(created["folderPath"], folder)
        self.assertEqual((folder / "SKILL.md").read_text(encoding="utf-8"),
                         '---\nname: deploy-notes\ndescription: "Write deploy notes"\n---\n\nList the deploy steps.\n')
        self.assertEqual((store / "repository").read_text(encoding="utf-8").strip(), str(repository),
                         "The store folder records the repository it belongs to.")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "Creating a private skill writes nothing into the worktree.")
        self.assertEqual(self.run_git(repository, "status", "--porcelain"), "", "Creating a private skill writes nothing into the repository.")
        self.assertFalse((worktree / ".agents" / "skills" / "deploy-notes").exists())
        self.assert_failure(create("--name", "deploy-notes", "--description", "Again", expected_status=1), "already_exists")

        listed = section()
        self.assertEqual(sorted(listed), ["committed", "deploy-notes"], "The private skill is listed with the repository's skills.")
        self.assertEqual(listed["deploy-notes"]["scope"], "private")
        self.assertEqual(listed["committed"]["scope"], "repo")
        self.assertIsNone(listed["deploy-notes"].get("issue"))
        self.assertTrue(listed["deploy-notes"]["enabled"])

        again = self.create_skills_task("Private skills again", [repository])
        again_worktree = Path(again["repositoryWorktrees"][0]["worktreePath"])
        self.assertNotEqual(os.path.realpath(again_worktree), os.path.realpath(worktree))
        self.assertEqual(section(again["id"])["deploy-notes"]["id"], private_id, "Every task on the repository sees its private skills.")
        other_task = self.create_skills_task("Private skills elsewhere", [other])
        self.assertEqual(self.skill_catalog(task_id=other_task["id"])["repositories"][0]["skills"], [], "A task on another repository does not.")

        edited = self.skill_manifest("deploy-notes", "Write short deploy notes", "Name each deployed service.")
        edit_file = self.data_directory / "private-skill-edit.md"
        edit_file.write_text(edited, encoding="utf-8")
        self.assertEqual(self.assert_success(self.call_cli("skills", "update", "--task", task["id"], "--skill", private_id, "--content-file", edit_file)[0])["description"],
                         "Write short deploy notes")
        self.assertEqual((folder / "SKILL.md").read_text(encoding="utf-8"), edited, "Editing saves the store's SKILL.md.")
        self.assert_failure(self.call_cli("skills", "link", "--task", task["id"], "--skill", private_id, expected_status=2)[0], "invalid_argument")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "Editing a private skill writes nothing into the worktree.")

        # A committed skill of the same name takes precedence in the worktree it appears in.
        self.write_skill(worktree / ".claude" / "skills", "deploy-notes", "A committed copy")
        shadowed = section()
        private = next(skill for skill in self.skill_catalog(task_id=task["id"])["repositories"][0]["skills"] if skill["id"] == private_id)
        self.assertEqual(private["providers"], [], "A shadowed private skill is used by neither provider.")
        self.assertIn("takes precedence", private["issue"])
        self.assertEqual(private["shadowedBy"], "skills-private-repo's committed skills")
        self.assertIn("deploy-notes", shadowed)
        self.assertEqual(section(again["id"])["deploy-notes"]["providers"], ["claude", "codex"], "Another worktree without the copy still uses the private skill.")
        shutil.rmtree(worktree / ".claude")

        converted = self.assert_success(self.call_cli("skills", "move", "--task", task["id"], "--skill", private_id, "--scope", "repo")[0])
        self.assertEqual(converted["id"], f"repo:{repository}#deploy-notes")
        self.assertEqual(converted["scope"], "repo")
        self.assertEqual((worktree / ".agents" / "skills" / "deploy-notes" / "SKILL.md").read_text(encoding="utf-8"), edited,
                         "Converting moves the private skill into the worktree's Agent Skills folder.")
        self.assertFalse(folder.exists(), "Converting removes the skill from the store.")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain").strip(), "?? .agents/skills/deploy-notes/", "The converted skill is ready to commit.")
        self.assertEqual(sorted(section(again["id"])), ["committed"], "A converted skill is no longer private to the repository's other tasks.")

        made_private = self.assert_success(self.call_cli("skills", "move", "--task", task["id"], "--skill", converted["id"], "--scope", "private")[0])
        self.assertEqual(made_private["id"], private_id)
        self.assertEqual((folder / "SKILL.md").read_text(encoding="utf-8"), edited, "Make Private moves the skill back into the store.")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "Make Private takes the skill out of the worktree.")
        self.assert_failure(self.call_cli("skills", "move", "--task", task["id"], "--skill", private_id, "--scope", "private", expected_status=2)[0], "invalid_argument")

        self.assertEqual(self.assert_success(self.call_cli("skills", "delete", "--task", task["id"], "--skill", private_id)[0]), {"deleted": True})
        self.assertFalse(folder.exists(), "Deleting removes the private skill's store folder.")
        self.assertEqual(sorted(section()), ["committed"])
        self.assertTrue((worktree / ".agents" / "skills" / "committed" / "SKILL.md").is_file(), "Deleting a private skill leaves committed skills alone.")
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "")

        # A global skill can be made private to one of the task's repositories.
        global_private = self.assert_success(self.call_cli("skills", "move", "--task", task["id"], "--skill", "global:global-taken",
                                                           "--scope", "private", "--root", str(repository))[0])
        self.assertEqual(global_private["id"], f"private:{repository}#global-taken")
        self.assertTrue((store / ".claude" / "skills" / "global-taken" / "SKILL.md").is_file(), "The global skill moves into the repository's store.")
        self.assertFalse((self.skills_home / ".agents" / "skills" / "global-taken").exists(), "It leaves the global skills folder.")
        self.assertEqual(sorted(section()), ["committed", "global-taken"])
        self.assertEqual(self.skill_catalog(task_id=task["id"])["global"], [])
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "Making a global skill private writes nothing into the worktree.")
    # case-contract: test_skills_private_bridge_reaches_claude_and_codex_for_its_repository | A turn on a repository with private skills gets them as native skills, and a task on any other repository gets no extra folder, flag, or skill. Claude Code gets one more --add-dir, a Playhouse-owned wrapper named after the repository whose .claude/skills links to the store, so it lists the private skill and a /skill message reaches it unchanged; the link shows later edits, and a turned-off private skill is left out of the next turn without a skillOverrides entry and hidden from Codex threads. In a task with two repositories whose private skills share a name, each repository's wrapper is passed, and the later one is listed and invoked as /<repository>:<name>. Codex gets the repository's private wrapper among the shared app-server's extra skill roots, with other repositories' private skills disabled for its thread, and a /skill message, plain or namespaced, sends a structured skill input naming the private SKILL.md.
    def test_skills_private_bridge_reaches_claude_and_codex_for_its_repository(self):
        repository = self.make_skill_repository("skills-private-bridge", {
            ".claude/skills/repo-claude/SKILL.md": self.skill_manifest("repo-claude", "Claude reads this natively"),
        })
        second = self.make_skill_repository("skills-private-second", {})
        plain = self.make_skill_repository("skills-private-plain", {})
        environment = self.install_claude_fixture("claude-fixture-private-skills")
        history_path = Path(environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] + ".history")
        task_id = self.create_skills_task("Private Claude skills", [repository], provider="claude")["id"]
        worktree = Path(self.assert_success(self.call_cli("task", "get", task_id)[0])["repositoryWorktrees"][0]["worktreePath"])

        def create(target_task, root, name, description):
            return self.assert_success(self.call_cli("skills", "create", "--task", target_task, "--scope", "private", "--root", str(root),
                                                     "--name", name, "--description", description)[0])

        release = create(task_id, repository, "release-check", "Check a release")
        shared = create(task_id, repository, "shared-name", "The first repository's copy")

        def turn(text):
            return [entry for entry in json.loads(history_path.read_text(encoding="utf-8"))["turns"] if entry.get("userText") == text][-1]

        def directories(entry):
            arguments = entry["arguments"]
            return [arguments[index + 1] for index, value in enumerate(arguments) if value == "--add-dir"]

        plain_id = self.create_skills_task("Plain Claude skills", [plain], provider="claude")["id"]
        self.assert_success(self.call_cli("conversation", "send", plain_id, "--message", "Hello plain.", extra_environment=environment)[0])
        plain_turn = turn("Hello plain.")
        self.assertEqual(directories(plain_turn), [], "A repository without private skills adds no folder.")
        self.assertNotIn("--settings", plain_turn["arguments"])
        self.assertNotIn("release-check", plain_turn["skills"], "A task on another repository does not see the private skill.")

        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "/release-check Run it.", extra_environment=environment)[0])
        first = turn("/release-check Run it.")
        added = directories(first)
        self.assertEqual(len(added), 1, f"One private wrapper should be added: {first['arguments']}")
        wrapper = Path(added[0])
        self.assertEqual(wrapper.name, "skills-private-bridge", "The wrapper is named after the repository.")
        self.assertSamePath(wrapper.parent.parent, self.data_directory / "skill-bridge" / "claude")
        links = wrapper / ".claude" / "skills"
        self.assertEqual(sorted(entry.name for entry in links.iterdir()), ["release-check", "shared-name"])
        self.assertSamePath(links / "release-check", release["folderPath"])
        self.assertEqual(first["userText"], "/release-check Run it.", "The skill invocation reaches Claude Code unchanged.")
        self.assertIn("release-check", first["skills"], "Claude Code lists the private skill natively.")
        self.assertIn("shared-name", first["skills"])
        self.assertEqual(self.run_git(worktree, "status", "--porcelain"), "", "The worktree is not written to.")

        edited = self.skill_manifest("release-check", "Check a release carefully", "Compare the changelog.")
        edit_file = self.data_directory / "private-skill-edit.md"
        edit_file.write_text(edited, encoding="utf-8")
        self.assert_success(self.call_cli("skills", "update", "--task", task_id, "--skill", release["id"], "--content-file", edit_file)[0])
        self.assertEqual((links / "release-check" / "SKILL.md").read_text(encoding="utf-8"), edited, "The wrapper shows the edited skill.")
        enabled_bridge = self.assert_success(self.call_cli("skills", "bridge", "--task", task_id)[0])
        old_codex_release = next(Path(link["link"]) for link in enabled_bridge["codexLinks"] if link["name"] == "release-check")
        self.assert_success(self.call_cli("skills", "disable", "--task", task_id, "--skill", release["id"])[0])
        self.assert_success(self.call_cli("conversation", "send", task_id, "--message", "Run it again.", extra_environment=environment)[0])
        resumed = turn("Run it again.")
        self.assertTrue(resumed["resumed"])
        self.assertNotIn("release-check", resumed["skills"], "A turned-off private skill is left out of the next turn.")
        self.assertIn("shared-name", resumed["skills"])
        self.assertIn("repo-claude", resumed["skills"], "Turning a private skill off leaves other skills alone.")
        self.assertNotIn("--settings", resumed["arguments"], "A private skill is turned off without a skillOverrides entry.")
        self.assertEqual(sorted(entry.name for entry in (Path(directories(resumed)[0]) / ".claude" / "skills").iterdir()), ["shared-name"])

        both_id = self.create_skills_task("Two private repositories", [repository, second], provider="claude")["id"]
        namespaced = create(both_id, second, "shared-name", "The second repository's copy")
        catalog = self.skill_catalog(task_id=both_id)["repositories"]
        self.assertIsNone(self.skills_by_name(catalog[0]["skills"])["shared-name"].get("invocationName"), "The first repository keeps the plain name.")
        self.assertEqual(self.skills_by_name(catalog[1]["skills"])["shared-name"]["invocationName"], "skills-private-second:shared-name")
        self.assert_success(self.call_cli("conversation", "send", both_id, "--message", "/skills-private-second:shared-name Go.", extra_environment=environment)[0])
        both = turn("/skills-private-second:shared-name Go.")
        self.assertEqual([Path(path).name for path in directories(both)][-2:], ["skills-private-bridge", "skills-private-second"],
                         "Each repository's private wrapper is passed.")
        self.assertIn("shared-name", both["skills"])
        self.assertIn("skills-private-second:shared-name", both["skills"], "Claude Code namespaces the later repository's skill.")
        bridged = self.assert_success(self.call_cli("skills", "bridge", "--task", both_id, "--message", "/skills-private-second:shared-name Go.")[0])
        self.assertEqual(len(bridged["invocations"]), 1)
        self.assertEqual(bridged["invocations"][0]["name"], "shared-name")
        self.assertSamePath(bridged["invocations"][0]["path"], Path(namespaced["folderPath"]) / "SKILL.md")
        second_wrapper = next(Path(link["link"]).parent for link in bridged["codexLinks"] if os.path.realpath(link["source"]) == os.path.realpath(namespaced["folderPath"]))

        codex = self.create_skills_task("Private Codex skills", [repository])
        self.complete_fixture_turn(codex["id"], executable_name="codex-fixture-private-skills", message="/shared-name Complete this task.")
        history = json.loads((self.data_directory / "codex-fixture-private-skills.history").read_text(encoding="utf-8"))
        codex_bridge = self.assert_success(self.call_cli("skills", "bridge", "--task", codex["id"])[0])
        own = [Path(link["link"]).parent for link in codex_bridge["codexLinks"] if link["name"] == "shared-name"]
        self.assertEqual(len(own), 1)
        self.assertSamePath(own[0] / "shared-name", shared["folderPath"])
        roots = {os.path.realpath(root) for root in history["skillExtraRoots"]}
        self.assertIn(os.path.realpath(own[0]), roots, "The app-server gets the repository's private wrapper as an extra root.")
        disabled = {os.path.realpath(entry["path"]) for entry in history["threadStartConfig"]["skills"]["config"] if entry["enabled"] is False}
        self.assertIn(os.path.realpath(second_wrapper / "shared-name" / "SKILL.md"), disabled, "Another repository's private skill is hidden from this thread.")
        self.assertIn(os.path.realpath(old_codex_release / "SKILL.md"), disabled, "A turned-off private skill is hidden from the Codex thread.")
        self.assertNotIn("release-check", [link["name"] for link in codex_bridge["codexLinks"]], "A turned-off private skill is left out of the Codex wrapper.")
        self.assertFalse(any(path.startswith(os.path.realpath(own[0]) + "/") for path in disabled), "The thread's own private skills stay on.")
        inputs = history["turns"][0]["skillInputs"]
        self.assertEqual([entry["name"] for entry in inputs], ["shared-name"])
        self.assertSamePath(inputs[0]["path"], Path(shared["folderPath"]) / "SKILL.md")
        self.assertFalse((self.skills_codex_home / "config.toml").exists(), "Codex's config.toml is not written.")

        plain_bridge = self.assert_success(self.call_cli("skills", "bridge", "--task", plain_id, "--message", "/shared-name Go.")[0])
        self.assertEqual(plain_bridge["claudeAddDirectories"], [], "A repository without private skills adds no folder.")
        self.assertEqual(plain_bridge["codexLinks"], [])
        self.assertEqual(plain_bridge["invocations"], [], "Another repository's private skill cannot be invoked.")

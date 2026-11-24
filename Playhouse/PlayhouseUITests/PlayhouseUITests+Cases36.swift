import Foundation
import XCTest

extension PlayhouseUITests {
    func openCodeTurns(_ executable: String) -> [[String: Any]] {
        jsonLines(executable + ".history").compactMap { $0 as? [String: Any] }
    }

    func waitForOpenCodeTurn(_ executable: String, containing prompt: String, timeout: TimeInterval = 30) -> [String: Any]? {
        var found: [String: Any]?
        _ = waitUntil({
            found = self.openCodeTurns(executable).last { ($0["prompt"] as? String ?? "").contains(prompt) }
            return found != nil && self.noTurnIsRunning()
        }, timeout: timeout)
        return found
    }

    func createOpenCodeTask(title: String, roots: [String]) throws -> String {
        var command = ["task", "create", "--title", title, "--prompt", "Fixture task description.", "--provider", "opencode"]
        for root in roots { command += ["--root", root] }
        let created = try XCTUnwrap(try runCLI(command)["result"] as? [String: Any])
        return try XCTUnwrap(created["id"] as? String)
    }

    // case-contract: test_opencode_turn_runs_tools_and_resumes_session | An OpenCode task lists the models OpenCode's server offers the task's folder once its list settles, never the built-in models OpenCode lists briefly while it loads, after the picker's own Default, without creating a session, and its selected model and effort reach the session, with Extra High asking for the model's strongest variant, high. A turn runs on the one `opencode serve` every task shares, started on a loopback port behind a password with OpenCode's self-update turned off and no skill, rule or MCP configuration of Playhouse's (no inline config, no config file, its Claude Code compatibility left on): the session works in the task's working folder, the task's other roots are allowed to it as external directories, and Playhouse's task instructions reach OpenCode as a session instruction entry, writing nothing into the repository, while code mode adds no permission rules over the user's own. The turn's commentary, shell and edit tool rows, real file edit and final answer are recorded, and the tokens of every step are added to the task's usage. The task keeps the OpenCode session ID, a second turn prompts that same session on the same server without handoff context or a new session, and a plan-mode turn runs OpenCode's plan agent. With automatic compaction on, switching a large session's model compacts it first through OpenCode's own compaction, recorded as an automatic compaction row and as the compaction in the task's token map. Playhouse passes OpenCode none of the gallery: a global rule OpenCode doesn't read itself isn't added to the session's instructions, and a skill turned off in Playhouse or a repository's .mcp.json server adds no permission rule or server, while the skills and `opencode.json` MCP servers of the task's working folder are what OpenCode finds itself. The @ mention menu lists an agent from .opencode/agents as an OpenCode agent. In the window the composer offers OpenCode, its model picker lists OpenCode's models with its default shown and saves the one picked, the conversation shows the commentary, the shell and edit rows labelled with their command or file and Completed, and the final answer, the second and plan answers appear after them, and a turn sent from the window carries only Playhouse's task instructions.
    func test_opencode_turn_runs_tools_and_resumes_session() throws {
        let environment = try installOpenCodeFixture(named: "opencode-fixture-ui-turns")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"])
        // OpenCode's first model list names only its built-in models, as it does while it loads.
        let transient = executable + ".transient-models"
        touch(transient)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOpenCodeTask(title: "OpenCode tools", roots: [fixture.primary.path, fixture.secondary.path])
        openTask(named: "OpenCode tools")
        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(waitUntil({ providerMenu.exists && providerMenu.label.contains("OpenCode") }, timeout: 10),
                      "The composer names OpenCode as the task's provider.")
        providerMenu.click()
        let openCodeItem = app.menuItems["conversation-provider-opencode"]
        XCTAssertTrue(openCodeItem.waitToExist(timeout: 5), "The provider menu offers OpenCode.")
        attachScreenshot(named: "opencode-1-provider-menu")
        attachRegionScreenshot([openCodeItem], named: "opencode-1-provider-menu-item")
        app.typeKey(.escape, modifierFlags: [])

        // The model picker lists the models a new OpenCode session offers, OpenCode's own default checked.
        let picker = element("model-picker-menu")
        XCTAssertTrue(waitUntil({ picker.exists && (picker.value as? String ?? picker.label).contains("Fixture Fast") }, timeout: 15),
                      "The picker shows OpenCode's default model: \(picker.value ?? picker.label)")
        picker.click()
        let deep = app.buttons["model-option-fixture/deep"]
        XCTAssertTrue(deep.waitToExist(timeout: 10) && app.buttons["model-option-fixture/fast"].exists, "The picker lists OpenCode's models.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transient), "OpenCode answered once with only its built-in models.")
        XCTAssertFalse(app.buttons["model-option-builtin/free"].exists, "The list OpenCode answered while it loaded isn't shown.")
        attachScreenshot(named: "opencode-1-model-picker")
        deep.click()
        picker.click()
        XCTAssertTrue(waitUntil({ (try? self.runCLI(["conversation", "model", taskID])["result"] as? [String: Any])?["modelID"] as? String == "fixture/deep" }, timeout: 10),
                      "Choosing a model in the picker saves it for the task.")
        XCTAssertTrue(waitUntil({ (picker.value as? String ?? picker.label).contains("Fixture Deep") }, timeout: 10))

        let target = fixture.primary.appendingPathComponent("opencode-fixture.txt")
        try? FileManager.default.removeItem(at: target)
        defer { try? FileManager.default.removeItem(at: target) }
        sendFromComposer("[[tools]] Update the fixture file.")
        let first = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "[[tools]]"), "The OpenCode turn runs.")
        XCTAssertEqual(first["model"] as? String, "fixture/deep")
        XCTAssertEqual(Set((first["additionalDirectories"] as? [String] ?? []).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }),
                       [fixture.secondary.resolvingSymlinksInPath().path], "The task's other roots are allowed to the session.")
        XCTAssertEqual(first["instructionKeys"] as? [String], ["playhouse"])
        XCTAssertTrue((first["instructions"] as? String ?? "").contains(taskID), "The task instructions reach OpenCode as a session instruction entry.")
        let launch = try XCTUnwrap(jsonLines(executable + ".launches").last as? [String: Any])
        XCTAssertEqual(launch["arguments"] as? [String], ["serve", "--hostname", "127.0.0.1", "--port", "0"], "The turn runs on `opencode serve`.")
        XCTAssertEqual(launch["hasPassword"] as? Bool, true)
        XCTAssertNil(launch["configFile"] as? String, "Playhouse gives the server no config file of its own.")
        XCTAssertNil(launch["inlineConfig"] as? String, "Playhouse gives the server no inline config.")
        XCTAssertTrue((first["permissions"] as? [[String: String]] ?? []).allSatisfy { $0["action"] == "external_directory" },
                      "Code mode keeps the user's own OpenCode permission rules.")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Written by the OpenCode fixture.\n")
        XCTAssertTrue(transcriptMessage("OpenCode fixture edited opencode-fixture.txt.").waitToExist(timeout: 15),
                      "The window shows OpenCode's final answer.")
        XCTAssertTrue(expandActivityDetails(), "The settled turn's work opens.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("Looking at the repository first.") }, timeout: 10),
                      "The window shows the commentary OpenCode wrote before its tools.")
        let shellRow = element("codex-activity-row-call_shell")
        let editRow = element("codex-activity-row-call_edit")
        XCTAssertTrue(shellRow.waitToExist(timeout: 10), "The shell tool call has its row.")
        XCTAssertTrue(editRow.waitToExist(timeout: 10), "The edit tool call has its row.")
        XCTAssertEqual(shellRow.label, "Running echo fixture-shell, Completed", "The shell row names its command and that it completed.")
        XCTAssertEqual(editRow.label, "Editing 1 file, Completed", "The edit row says it edited a file and completed.")
        attachScreenshot(named: "opencode-2-tools-turn")
        attachElementScreenshot(shellRow, named: "opencode-2-shell-row")
        let session = try XCTUnwrap(try taskRecord(id: taskID)?["openCodeSessionID"] as? String)

        sendFromComposer("Anything else?")
        let second = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "Anything else?"))
        XCTAssertEqual(second["sessionId"] as? String, session, "The second turn resumes the same OpenCode session.")
        XCTAssertFalse((second["prompt"] as? String ?? "").contains("<playhouse-handoff-context>"))
        XCTAssertTrue(transcriptMessage("OpenCode fixture answered in build mode with fixture/deep.").waitToExist(timeout: 15))

        setPlanMode(true)
        sendFromComposer("Plan the next change.")
        let planned = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "Plan the next change."))
        XCTAssertEqual(planned["mode"] as? String, "plan")
        XCTAssertTrue(transcriptMessage("OpenCode fixture answered in plan mode with fixture/deep.").waitToExist(timeout: 15),
                      "The plan-mode answer appears after the earlier ones.")
        setPlanMode(false)
        attachScreenshot(named: "opencode-3-resumed-and-plan")

        // Switching a large session's model compacts it first, through OpenCode's own compaction.
        _ = try runCLI(["settings", "set-auto-compaction", "--enabled", "true", "--minimum", "10000"])
        picker.click()
        let fast = app.buttons["model-option-fixture/fast"]
        XCTAssertTrue(fast.waitToExist(timeout: 10))
        fast.click()
        picker.click()
        XCTAssertTrue(waitUntil({ (picker.value as? String ?? picker.label).contains("Fixture Fast") }, timeout: 10), "The picker switches the task to Fixture Fast.")
        sendFromComposer("After the model switch.")
        XCTAssertNotNil(waitForOpenCodeTurn(executable, containing: "After the model switch."))
        XCTAssertEqual(jsonLines(executable + ".compactions").compactMap { ($0 as? [String: Any])?["sessionId"] as? String }, [session])
        XCTAssertTrue(transcriptMessage("OpenCode fixture answered in build mode with fixture/fast.").waitToExist(timeout: 15))
        let compacted = try XCTUnwrap(try runCLI(["task", "token-waste", taskID])["result"] as? [String: Any])
        XCTAssertEqual((compacted["agents"] as? [[String: Any]])?.filter { $0["id"] as? String == "opencode" }.map { $0["compactions"] as? Int }, [1],
                       "The token map shows OpenCode's compaction.")
        let compactionRow = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "context-compaction-row-", "Context compacted automatically"
        )).firstMatch
        XCTAssertTrue(scrollTranscriptUntilExists(compactionRow), "The window shows the automatic compaction row.")
        let switchedAnswer = transcriptMessage("OpenCode fixture answered in build mode with fixture/fast.")
        XCTAssertLessThan(compactionRow.frame.minY, switchedAnswer.frame.minY, "The compaction comes before the turn's answer.")
        attachElementScreenshot(compactionRow, named: "opencode-3-compaction-row")
        attachScreenshot(named: "opencode-3-compacted-on-model-switch")
        try assertOpenCodeLaunchSharesGallery(executable: executable)
    }

    /// Playhouse passes OpenCode none of the gallery for a turn sent from the window: OpenCode uses
    /// what it finds in the task's working folder itself.
    func assertOpenCodeLaunchSharesGallery(executable: String) throws {
        let root = dataDirectory.appendingPathComponent("opencode-shared", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".opencode/agents"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["oc-stdio": ["type": "stdio", "command": "node", "args": ["server.js"]]]])
            .write(to: root.appendingPathComponent(".mcp.json"))
        try JSONSerialization.data(withJSONObject: ["mcp": ["oc-own": ["type": "local", "command": ["node", "own.js"]]]])
            .write(to: root.appendingPathComponent("opencode.json"))
        try "---\nname: oc-planner\ndescription: Plans with OpenCode\n---\n\nPlan.\n".write(
            to: root.appendingPathComponent(".opencode/agents/oc-planner.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: skillsHome.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try "Shared OpenCode rule marker.\n".write(to: skillsHome.appendingPathComponent(".agents/AGENTS.md"), atomically: true, encoding: .utf8)
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills"), "oc-codex-own", "A Codex skill OpenCode doesn't read")
        try writeSkill(in: root.appendingPathComponent(".agents/skills"), "oc-native", "A skill OpenCode reads itself")
        try writeSkill(in: root.appendingPathComponent(".claude/skills"), "oc-off", "A skill turned off in Playhouse")
        let taskID = try createOpenCodeTask(title: "OpenCode shared gallery", roots: [root.path])
        let catalog = try XCTUnwrap(try runCLI(["skills", "list", "--task", taskID])["result"] as? [String: Any])
        let skills = ((catalog["repositories"] as? [[String: Any]])?.first?["skills"] as? [[String: Any]]) ?? []
        let offID = try XCTUnwrap(skills.first { $0["name"] as? String == "oc-off" }?["id"] as? String)
        _ = try runCLI(["skills", "disable", "--task", taskID, "--skill", offID])
        let mentions = try XCTUnwrap(try runCLI(["mentions", "list", "--task", taskID, "--query", "oc-planner"])["result"] as? [String: Any])
        let planner = try XCTUnwrap((mentions["items"] as? [[String: Any]])?.first { $0["id"] as? String == "agent:oc-planner" })
        XCTAssertTrue((planner["reference"] as? String ?? "").contains("the OpenCode agent `oc-planner`"), "\(planner)")
        openTask(named: "OpenCode shared gallery")
        sendFromComposer("Use the gallery.")
        let turn = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "Use the gallery."))
        XCTAssertFalse((turn["instructions"] as? String ?? "").contains("Shared OpenCode rule marker."), "A rule OpenCode doesn't read itself isn't added.")
        XCTAssertEqual((turn["permissions"] as? [Any])?.count, 0, "A skill turned off in Playhouse adds no rule: OpenCode uses what it finds.")
        XCTAssertEqual(turn["skills"] as? [String], ["oc-native", "oc-off"], "OpenCode finds the working folder's skills itself.")
        XCTAssertEqual(turn["mcp"] as? NSDictionary, ["oc-own": ["type": "local", "command": ["node", "own.js"]]] as NSDictionary,
                       "OpenCode runs the folder's own opencode.json servers, and none from .mcp.json.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("opencode-runs/shared-config").path),
                       "Playhouse writes no OpenCode config.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("OpenCode fixture answered in build mode") }, timeout: 15), "The gallery turn's answer shows.")
        attachScreenshot(named: "opencode-3-gallery-turn")
    }

    /// How many answers in the window read exactly `text`.
    func transcriptMessages(_ text: String) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "assistant-message-", text)).count
    }

    /// The manifest of the one OpenCode server this case's data folder records.
    func openCodeServerManifest() -> [String: Any]? {
        agentManifests().first { $0.kind == "opencode" }?.manifest
    }

    // case-contract: test_opencode_tasks_share_one_server_with_native_discovery | Tasks on different repositories run on the one `opencode serve` every task shares, which Playhouse starts once with no skill, rule or MCP configuration of its own. Each task's turn sees only what OpenCode finds in its own working folder: that folder's committed .agents and .claude skills and the MCP servers of its own `opencode.json`, never the other task's, and OpenCode's MCP status for each task lists only its folder's servers. A global MCP server added in Playhouse writes no OpenCode configuration and starts no server. When the server process stops, the next turn starts one new server and continues the task's session, and the folder's skills and servers are there again with nothing for Playhouse to restore. In the window, the answers to the turns sent from the composer of each task, and after the server stopped, show in the conversation.
    func test_opencode_tasks_share_one_server_with_native_discovery() throws {
        let environment = try installOpenCodeFixture(named: "opencode-fixture-ui-shared")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"])
        let first = try makeSkillRepository("oc-shared-first", skills: [
            ".agents/skills/oc-first-skill/SKILL.md": skillManifest("oc-first-skill", "The first repository's skill"),
            "opencode.json": #"{"mcp": {"oc-first-mcp": {"type": "local", "command": ["node", "first.js"]}}}"#,
        ])
        let second = try makeSkillRepository("oc-shared-second", skills: [
            ".claude/skills/oc-second-skill/SKILL.md": skillManifest("oc-second-skill", "The second repository's skill"),
            "opencode.json": #"{"mcp": {"oc-second-mcp": {"type": "remote", "url": "https://example.test/mcp"}}}"#,
        ])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let firstID = try XCTUnwrap(try createSkillsTask("OpenCode shared first", repositories: [first], provider: "opencode")["id"] as? String)
        let secondID = try XCTUnwrap(try createSkillsTask("OpenCode shared second", repositories: [second], provider: "opencode")["id"] as? String)
        openTask(named: "OpenCode shared first")
        sendFromComposer("First repository.")
        let firstTurn = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "First repository."))
        XCTAssertTrue(transcriptMessage("OpenCode fixture answered in build mode with fixture/fast.").waitToExist(timeout: 15), "The first task's answer shows.")
        attachScreenshot(named: "opencode-13-first-task-turn")
        openTask(named: "OpenCode shared second")
        sendFromComposer("Second repository.")
        let secondTurn = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "Second repository."))
        XCTAssertTrue(transcriptMessage("OpenCode fixture answered in build mode with fixture/fast.").waitToExist(timeout: 15), "The second task's answer shows.")
        attachScreenshot(named: "opencode-13-second-task-turn")
        XCTAssertNotEqual(firstTurn["cwd"] as? String, secondTurn["cwd"] as? String, "Each session works in its own task's folder.")
        XCTAssertEqual(firstTurn["skills"] as? [String], ["oc-first-skill"])
        XCTAssertEqual(firstTurn["mcp"] as? NSDictionary, ["oc-first-mcp": ["type": "local", "command": ["node", "first.js"]]] as NSDictionary)
        XCTAssertEqual(secondTurn["skills"] as? [String], ["oc-second-skill"], "The second task sees its own folder's skills, not the first's.")
        XCTAssertEqual(secondTurn["mcp"] as? NSDictionary, ["oc-second-mcp": ["type": "remote", "url": "https://example.test/mcp"]] as NSDictionary)
        let launches = jsonLines(executable + ".launches").compactMap { $0 as? [String: Any] }
        XCTAssertEqual(launches.count, 1, "Both tasks run on one server.")
        XCTAssertNil(launches.first?["configFile"] as? String)
        XCTAssertNil(launches.first?["inlineConfig"] as? String)
        XCTAssertEqual(agentManifests().filter { $0.kind == "opencode" }.count, 1)
        for (task, name) in [(firstID, "oc-first-mcp"), (secondID, "oc-second-mcp")] {
            let report = try XCTUnwrap(try runCLI(["mcp", "status", "--task", task, "--provider", "opencode"])["result"] as? [String: Any])
            XCTAssertEqual((report["opencode"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, [name], "OpenCode reports the task's own folder's servers.")
        }

        // A global server added in Playhouse changes nothing on OpenCode.
        _ = try runCLI(["mcp", "create", "--scope", "global", "--name", "oc-global-tool", "--command", "node", "--arg", "global.js"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("opencode-runs/shared-config").path),
                       "Playhouse writes no OpenCode config.")
        openTask(named: "OpenCode shared first")
        sendFromComposer("After the global change.")
        let changed = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "After the global change."))
        XCTAssertNil((changed["mcp"] as? [String: Any])?["oc-global-tool"])
        XCTAssertEqual(jsonLines(executable + ".launches").count, 1, "The change starts no server.")
        XCTAssertTrue(waitUntil({ self.transcriptMessages("OpenCode fixture answered in build mode with fixture/fast.") >= 2 }, timeout: 15),
                      "The answer after the global change shows.")

        // The server process stops: the next turn starts one new server, with nothing to restore.
        let session = try XCTUnwrap(try taskRecord(id: firstID)?["openCodeSessionID"] as? String)
        let manifest = try XCTUnwrap(openCodeServerManifest())
        let process = manifest["process"] as? [String: Any]
        let pid = try XCTUnwrap((process?["pid"] as? NSNumber)?.int32Value)
        kill(pid, SIGKILL)
        XCTAssertTrue(waitUntil({ !self.agentIsAlive(process) }, timeout: 15), "The OpenCode server process is gone.")
        sendFromComposer("After the server stopped.")
        let after = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "After the server stopped."))
        XCTAssertEqual(jsonLines(executable + ".launches").count, 2, "The next turn starts one new server.")
        XCTAssertEqual(after["sessionId"] as? String, session, "The task continues its OpenCode session on the new server.")
        XCTAssertEqual(after["skills"] as? [String], ["oc-first-skill"])
        XCTAssertEqual(after["mcp"] as? NSDictionary, firstTurn["mcp"] as? NSDictionary, "The folder's servers are there again with nothing restored.")
        XCTAssertTrue(waitUntil({ self.transcriptMessages("OpenCode fixture answered in build mode with fixture/fast.") >= 3 }, timeout: 15),
                      "The answer after the server stopped shows.")
        attachScreenshot(named: "opencode-14-after-server-stopped")
    }

    // case-contract: test_opencode_catalog_marks_what_opencode_cannot_use | The Skills, Rules and MCP pages mark OpenCode only on what it finds itself, since Playhouse passes its one shared server nothing. For a task on two repositories: the working repository's committed skill is every agent's; a skill committed in the second repository is Claude's and Codex's only, noting that OpenCode reads skills only from the task's working folder; a private skill is Claude's and Codex's only, noting that OpenCode reads only the repository's and the home folder's skills; a Codex-only global skill is Claude's and Codex's only, while global .agents and .claude skills are every agent's; and a working-folder skill turned off in Playhouse still lists OpenCode, noting that OpenCode still uses it. The repositories' .mcp.json servers are Claude's and Codex's only. The working repository's AGENTS.md reaches OpenCode, which still reads it when it is turned off, while ~/.agents/AGENTS.md, which Playhouse shares with Claude and Codex, doesn't; a CLAUDE.md reaches OpenCode only in the working folder with no AGENTS.md beside it, and the global CLAUDE.md only until OpenCode's own global AGENTS.md exists. A plugin editor can't run on OpenCode: one authored with OpenCode as its provider starts on Codex, and switching it to OpenCode is refused, saying plugin editors need Claude or Codex. In the window, the Skills page shows the two-agent mark and the note in each skill's hint and every agent's mark on the global .agents and .claude skills, the MCP page shows the two-agent mark, and a plugin editor's provider menu, once it lists the installed providers, doesn't offer OpenCode or its install.
    func test_opencode_catalog_marks_what_opencode_cannot_use() throws {
        let first = try makeSkillRepository("oc-catalog-first", skills: [
            ".agents/skills/oc-first-skill/SKILL.md": skillManifest("oc-first-skill", "Committed in the working repository"),
            ".claude/skills/oc-first-off/SKILL.md": skillManifest("oc-first-off", "Turned off in Playhouse"),
            "AGENTS.md": "Working repository rules.\n",
            "CLAUDE.md": "Claude rules beside AGENTS.md.\n",
            ".mcp.json": #"{"mcpServers": {"oc-first-server": {"type": "stdio", "command": "first"}}}"#,
        ])
        let second = try makeSkillRepository("oc-catalog-second", skills: [
            ".claude/skills/oc-second-skill/SKILL.md": skillManifest("oc-second-skill", "Committed in the second repository"),
            "CLAUDE.md": "The second repository's rules.\n",
            ".mcp.json": #"{"mcpServers": {"oc-second-server": {"type": "stdio", "command": "second"}}}"#,
        ])
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills"), "oc-codex-only", "A Codex-only global skill")
        try writeSkill(in: skillsHome.appendingPathComponent(".agents/skills"), "oc-global-agents", "A global .agents skill")
        try writeSkill(in: skillsHome.appendingPathComponent(".claude/skills"), "oc-global-claude", "A global .claude skill")
        try "Global Claude rules.\n".write(to: skillsHome.appendingPathComponent(".claude/CLAUDE.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: skillsHome.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try "Shared global rules.\n".write(to: skillsHome.appendingPathComponent(".agents/AGENTS.md"), atomically: true, encoding: .utf8)
        // OpenCode and Codex are installed and Claude isn't, so the menu's Add Claude item shows only
        // once the daemon has reported what's installed.
        var environment = try installOpenCodeFixture(named: "opencode-fixture-ui-catalog")
        environment.merge(try installCodexFixture(named: "codex-fixture-ui-catalog")) { _, new in new }
        environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] = "none"
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOpenCodeTask(title: "OpenCode catalog", roots: [first.path, second.path])
        _ = try runCLI(["skills", "create", "--task", taskID, "--scope", "private", "--root", first.path, "--name", "oc-private", "--description", "Private to the first repository"])
        let catalog = try XCTUnwrap(try runCLI(["skills", "list", "--task", taskID])["result"] as? [String: Any])
        let firstSkills = ((catalog["repositories"] as? [[String: Any]])?.first?["skills"] as? [[String: Any]]) ?? []
        let offID = try XCTUnwrap(firstSkills.first { $0["name"] as? String == "oc-first-off" }?["id"] as? String)
        _ = try runCLI(["skills", "disable", "--task", taskID, "--skill", offID])

        openTask(named: "OpenCode catalog")
        openSkillsPage()
        XCTAssertEqual(rowProviders("skill-provider-oc-first-skill"), ["claude", "codex", "opencode"], "The working repository's skill keeps every agent.")
        XCTAssertFalse(accessibleLabelOrValue(of: element("skill-location-oc-first-skill")).contains("OpenCode"), "A skill every agent uses has no OpenCode note.")
        XCTAssertEqual(rowProviders("skill-provider-oc-global-agents"), ["claude", "codex", "opencode"], "OpenCode reads global .agents skills itself.")
        XCTAssertEqual(rowProviders("skill-provider-oc-global-claude"), ["claude", "codex", "opencode"], "OpenCode reads Claude Code's global skills itself.")
        XCTAssertEqual(rowProviders("skill-provider-oc-second-skill"), ["claude", "codex"], "The second repository's skill is Claude's and Codex's only.")
        let secondHint = revealSkillHint("oc-second-skill")
        XCTAssertTrue(accessibleLabelOrValue(of: element("skill-location-oc-second-skill"))
            .contains("Not on OpenCode: it reads skills only from the task's working folder"), "The hint says why.")
        attachElementScreenshot(secondHint, named: "opencode-16-second-repository-skill-hint")
        XCTAssertEqual(rowProviders("skill-provider-oc-private"), ["claude", "codex"], "A private skill is Claude's and Codex's only.")
        let privateHint = revealSkillHint("oc-private")
        XCTAssertTrue(accessibleLabelOrValue(of: element("skill-location-oc-private")).contains("reads only skills in the repository and your home folder"), "The hint says why.")
        attachElementScreenshot(privateHint, named: "opencode-16-private-skill-hint")
        XCTAssertEqual(rowProviders("skill-provider-oc-codex-only"), ["claude", "codex"], "A Codex-only global skill is Claude's and Codex's only.")
        let codexHint = revealSkillHint("oc-codex-only")
        XCTAssertTrue(accessibleLabelOrValue(of: element("skill-location-oc-codex-only")).contains("doesn't read Codex's skill folder"), "The hint says why.")
        attachElementScreenshot(codexHint, named: "opencode-16-codex-only-skill-hint")
        XCTAssertTrue(rowProviders("skill-provider-oc-first-off").contains("opencode"), "OpenCode still uses a skill it finds itself.")
        let offHint = revealSkillHint("oc-first-off")
        XCTAssertTrue(accessibleLabelOrValue(of: element("skill-location-oc-first-off")).contains("OpenCode still uses it"), "The hint says OpenCode still uses it.")
        attachElementScreenshot(offHint, named: "opencode-16-turned-off-skill-hint")
        attachScreenshot(named: "opencode-16-skills-page")
        app.typeKey(.escape, modifierFlags: [])

        openMcpPage()
        XCTAssertEqual(rowProviders("mcp-provider-oc-catalog-first:oc-first-server"), ["claude", "codex"], "OpenCode doesn't read .mcp.json.")
        XCTAssertEqual(rowProviders("mcp-provider-oc-catalog-second:oc-second-server"), ["claude", "codex"])
        attachElementScreenshot(element("mcp-row-oc-catalog-first:oc-first-server"), named: "opencode-17-mcp-row-claude-and-codex")
        attachScreenshot(named: "opencode-17-mcp-page")
        app.typeKey(.escape, modifierFlags: [])

        let rules = try XCTUnwrap(try runCLI(["rules", "list", "--task", taskID])["result"] as? [String: Any])
        let workingRules = ((rules["repositories"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]]) ?? []
        let agents = try XCTUnwrap(workingRules.first { $0["name"] as? String == "AGENTS.md" })
        XCTAssertTrue((agents["providers"] as? [String] ?? []).contains("opencode"))
        XCTAssertFalse((agents["sharedWith"] as? [String] ?? []).contains("opencode"), "OpenCode reads AGENTS.md itself.")
        let shared = try XCTUnwrap((rules["global"] as? [[String: Any]])?.first { ($0["name"] as? String ?? "").hasSuffix(".agents/AGENTS.md") })
        XCTAssertEqual(shared["providers"] as? [String], ["claude", "codex"], "Playhouse shares ~/.agents/AGENTS.md with Claude and Codex only.")
        func providers(_ rules: [[String: Any]]?, _ name: String) -> [String] {
            (rules ?? []).first { ($0["name"] as? String ?? "").hasSuffix(name) }?["providers"] as? [String] ?? []
        }
        XCTAssertFalse(providers(workingRules, "CLAUDE.md").contains("opencode"), "OpenCode reads AGENTS.md, not a CLAUDE.md beside it.")
        let secondRules = (rules["repositories"] as? [[String: Any]])?.dropFirst().first?["rules"] as? [[String: Any]]
        XCTAssertFalse(providers(secondRules, "CLAUDE.md").contains("opencode"), "OpenCode reads rules only from the working folder.")
        let aloneID = try createOpenCodeTask(title: "OpenCode catalog second alone", roots: [second.path])
        let aloneRules = try XCTUnwrap(try runCLI(["rules", "list", "--task", aloneID])["result"] as? [String: Any])
        XCTAssertTrue(providers((aloneRules["repositories"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]], "CLAUDE.md").contains("opencode"),
                      "OpenCode reads the working folder's CLAUDE.md when it has no AGENTS.md.")
        XCTAssertTrue(providers(rules["global"] as? [[String: Any]], ".claude/CLAUDE.md").contains("opencode"), "OpenCode reads Claude Code's global CLAUDE.md.")
        try FileManager.default.createDirectory(at: skillsHome.appendingPathComponent(".config/opencode"), withIntermediateDirectories: true)
        try "OpenCode's own global rules.\n".write(to: skillsHome.appendingPathComponent(".config/opencode/AGENTS.md"), atomically: true, encoding: .utf8)
        let replaced = try XCTUnwrap(try runCLI(["rules", "list", "--task", taskID])["result"] as? [String: Any])
        XCTAssertFalse(providers(replaced["global"] as? [[String: Any]], ".claude/CLAUDE.md").contains("opencode"), "OpenCode's own global AGENTS.md replaces CLAUDE.md for it.")
        _ = try runCLI(["rules", "disable", "--task", taskID, "--rule", try XCTUnwrap(agents["id"] as? String)])
        let disabledRules = try XCTUnwrap(try runCLI(["rules", "list", "--task", taskID])["result"] as? [String: Any])
        let disabled = (((disabledRules["repositories"] as? [[String: Any]])?.first?["rules"] as? [[String: Any]]) ?? []).first { $0["name"] as? String == "AGENTS.md" }
        XCTAssertTrue((disabled?["alwaysOnFor"] as? [String] ?? []).contains("opencode"), "OpenCode still reads a turned-off AGENTS.md.")

        // A plugin editor isn't offered OpenCode.
        let authored = try XCTUnwrap(try runCLI(["plugin", "author", "--placement", "mainSidebar", "--name", "OC Plugin", "--presentation", "popover", "--provider", "opencode"])["result"] as? [String: Any])
        let editor = try XCTUnwrap(authored["task"] as? [String: Any])
        XCTAssertEqual(editor["conversationProvider"] as? String, "codex", "A plugin editor asked for on OpenCode starts on Codex.")
        let editorID = try XCTUnwrap(editor["id"] as? String)
        let refused = try runCLI(["conversation", "provider", editorID, "set", "opencode"], expectedStatus: 2)
        XCTAssertTrue("\(refused)".contains("Plugin editors can't use OpenCode"), "\(refused)")
        let sessions = try XCTUnwrap(try runCLI(["plugin", "sessions"])["result"] as? [String: Any])
        XCTAssertEqual((sessions["sessions"] as? [[String: Any]])?.first { $0["id"] as? String == editorID }?["conversationProvider"] as? String, "codex",
                       "The refused switch leaves the editor on Codex.")
        _ = try runCLI(["plugin", "mode", "--on"])
        clickInstalledPluginAction("Edit…", pluginRow: "OC Plugin — Main sidebar (Unsaved)")
        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(providerMenu.waitToExist(timeout: 15), "The plugin editor's composer has a provider menu.")
        // Add Claude shows only once the daemon has reported what's installed.
        let addClaude = app.menuItems["conversation-provider-install-claude"]
        XCTAssertTrue(waitUntil({
            providerMenu.click()
            if addClaude.waitToExist(timeout: 2) { return true }
            self.app.typeKey(.escape, modifierFlags: [])
            return false
        }, timeout: 30), "The menu lists the installed providers and offers to add Claude.")
        let codexItem = app.menuItems["conversation-provider-codex"]
        XCTAssertTrue(codexItem.exists, "The menu offers Codex.")
        XCTAssertFalse(app.menuItems["conversation-provider-opencode"].exists, "A plugin editor's provider menu doesn't offer the installed OpenCode.")
        XCTAssertFalse(app.menuItems["conversation-provider-install-opencode"].exists, "Nor does it offer to install OpenCode.")
        attachRegionScreenshot([codexItem, addClaude], named: "opencode-18-plugin-editor-provider-menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    // case-contract: test_opencode_answers_questions_and_side_chat_stays_read_only | A question OpenCode's question tool asks through its form is shown as a structured question and answered through the form with the chosen option or with the user's own text, and OpenCode answers with what it received. In code mode every permission OpenCode asks for is allowed once. A side chat forks the task's OpenCode session into its own session and runs read-only: its session denies edits and asks before every command, so an edit is refused by the rule and shell commands are rejected except the Playhouse CLI's board commands, and the task's own session, status and prompt are left unchanged. In the window the question appears with its choices, the chosen answer and OpenCode's reply show in the conversation, and the side chat's reply reports the read-only decisions.
    func test_opencode_answers_questions_and_side_chat_stays_read_only() throws {
        let environment = try installOpenCodeFixture(named: "opencode-fixture-ui-questions")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOpenCodeTask(title: "OpenCode questions", roots: [fixture.primary.path])
        openTask(named: "OpenCode questions")
        sendFromComposer("[[question]] Pick a color.")
        XCTAssertTrue(element("conversation-user-input-request").waitToExist(timeout: 20), "OpenCode's question appears in the conversation.")
        XCTAssertTrue(app.staticTexts["Which color should the fixture use?"].waitToExist(timeout: 5))
        XCTAssertFalse(transcriptContains("Playhouse denied it"), "A question is not an approval Playhouse denied.")
        attachScreenshot(named: "opencode-4-question")
        selectQuestionOption(identifier: "ai-question-option-question-1-Blue")
        element("submit-ai-answers-button").click()
        let asked = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "[[question]]"))
        XCTAssertEqual(asked["formReply"] as? [String: String], ["q0": "Blue"], "The answer goes through OpenCode's form.")
        XCTAssertTrue(transcriptMessage("OpenCode fixture got the color Blue.").waitToExist(timeout: 15), "OpenCode's reply to the answer shows.")
        attachScreenshot(named: "opencode-5-question-answered")

        sendFromComposer("[[permissions]] Check permissions.")
        let allowed = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "Check permissions."))
        XCTAssertEqual(allowed["permissionDecisions"] as? [String: String], ["shell": "once", "cli": "once", "edit": "once"])

        // The side chat opens on the reply and runs in its own read-only OpenCode session.
        let before = try XCTUnwrap(try taskRecord(id: taskID))
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let reply = try XCTUnwrap((history["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "assistant" })
        let replyText = element("assistant-message-\(try XCTUnwrap(reply["id"] as? String))").descendants(matching: .staticText).firstMatch
        XCTAssertTrue(replyText.waitToExist(timeout: 10))
        XCTAssertTrue(waitForStableFrame(replyText))
        replyText.click()
        replyText.typeKey("a", modifierFlags: .command)
        _ = try waitForSideChatBubble(at: replyText, hintScreenshot: "opencode-side-chat-pill")
        let answer = sendSideChatMessage("[[permissions]] Can you edit?", answerIndex: 1, containing: "Permissions: shell=reject, cli=once, edit=reject.")
        attachElementScreenshot(answer, named: "opencode-6-side-chat-read-only")
        let side = try XCTUnwrap(openCodeTurns(executable).last)
        XCTAssertNotEqual(side["sessionId"] as? String, before["openCodeSessionID"] as? String)
        let sideRules = side["permissions"] as? [[String: String]] ?? []
        XCTAssertTrue(sideRules.contains(["action": "edit", "resource": "*", "effect": "deny"]), "The side chat's session denies edits: \(sideRules)")
        XCTAssertTrue(sideRules.contains(["action": "shell", "resource": "*", "effect": "ask"]), "The side chat's session asks before commands.")
        let after = try XCTUnwrap(try taskRecord(id: taskID))
        for field in ["status", "openCodeSessionID", "savedPrompt"] {
            XCTAssertEqual(after[field] as? String, before[field] as? String, "The side chat leaves the task's \(field) alone.")
        }
    }

    // case-contract: test_opencode_steer_and_stop_running_turn | While an OpenCode turn runs, the runtime lists its session, and a steer reaches the running execution through the session's inbox: the steer shows in the conversation below what OpenCode wrote before it, and OpenCode's answer to it ends the turn. Stopping a later running turn interrupts the session, settles the task in Waiting Response with no failure reason, and leaves the shared server running with no turn recorded for the session. While a turn holds a background job OpenCode started, Stop asks for confirmation and declining keeps the turn and its job running; confirming cancels the job through OpenCode's API, settles the task in Waiting Response, and keeps the shared server running. In the window the steered message and its answer appear in order, and Stop ends the held turn with the composer ready again; with a background job running Stop asks first, Keep Running leaves the turn going and Stop All ends it.
    func test_opencode_steer_and_stop_running_turn() throws {
        let environment = try installOpenCodeFixture(named: "opencode-fixture-ui-hold")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"])
        let ready = executable + ".hold-ready"
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOpenCodeTask(title: "OpenCode steering", roots: [fixture.primary.path])
        openTask(named: "OpenCode steering")
        sendFromComposer("[[hold]] Work for a while.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready) }, timeout: 20), "The OpenCode turn holds.")
        XCTAssertTrue(transcriptMessage("Holding the OpenCode turn.").waitToExist(timeout: 10))
        steerFromComposer("Also check the tests.")
        let steerAnswer = transcriptMessage("OpenCode fixture took the steer: Also check the tests.")
        XCTAssertTrue(steerAnswer.waitToExist(timeout: 20), "OpenCode answers the steer in the same turn.")
        // A settled turn may fold what OpenCode wrote before its answer into its work.
        if element("codex-activity-disclosure").exists { XCTAssertTrue(expandActivityDetails(), "The settled turn's work opens.") }
        let steered = transcriptMessage("Also check the tests.")
        XCTAssertTrue(steered.waitToExist(timeout: 10), "The steered message shows in the conversation.")
        XCTAssertTrue(waitUntil({ self.transcriptContains("Holding the OpenCode turn.") }, timeout: 10), "What OpenCode wrote before the steer shows in the turn.")
        let held = [app.groups, app.staticTexts, app.textViews, app.otherElements]
            .map { $0.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Holding the OpenCode turn.", "Holding the OpenCode turn.")).firstMatch }
            .first { $0.exists }
        XCTAssertLessThan(try XCTUnwrap(held).frame.minY, steered.frame.minY, "What OpenCode wrote before the steer stays above it.")
        XCTAssertLessThan(steered.frame.minY, steerAnswer.frame.minY, "OpenCode's answer to the steer follows it.")
        let texts = try historyTexts(taskID: taskID)
        let steerIndex = try XCTUnwrap(texts.firstIndex(of: "Also check the tests."))
        XCTAssertLessThan(try XCTUnwrap(texts.firstIndex(of: "Holding the OpenCode turn.")), steerIndex)
        XCTAssertEqual(texts.last, "OpenCode fixture took the steer: Also check the tests.")
        let steerRequest = jsonLines(executable + ".methods").compactMap { $0 as? [String: Any] }.last {
            ($0["path"] as? String ?? "").hasSuffix("/prompt") && (($0["body"] as? [String: Any])?["text"] as? String) == "Also check the tests."
        }
        XCTAssertEqual((steerRequest?["body"] as? [String: Any])?["delivery"] as? String, "steer", "The steer goes to the running execution's inbox.")
        attachScreenshot(named: "opencode-7-steered")

        try FileManager.default.removeItem(atPath: ready)
        sendFromComposer("[[hold]] Keep going.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready) }, timeout: 20))
        let stop = element("pause-response-button")
        XCTAssertTrue(stop.waitToExist(timeout: 10))
        stop.click()
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response"), "Stop settles the OpenCode turn in Waiting Response.")
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 15))
        let session = try XCTUnwrap(try taskRecord(id: taskID)?["openCodeSessionID"] as? String)
        XCTAssertTrue(jsonLines(executable + ".methods").contains {
            let request = $0 as? [String: Any]
            return request?["method"] as? String == "POST" && request?["path"] as? String == "/api/session/\(session)/interrupt"
        }, "Stop interrupts the OpenCode session.")
        XCTAssertTrue(waitUntil({ !self.openCodeServerTurns().contains(session) }, timeout: 10), "No turn stays recorded on the server.")
        XCTAssertFalse(element("codex-chat-error").exists, "A stopped turn is not a failed turn.")
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 10), "The composer is ready again, offering Continue for the stopped turn.")
        XCTAssertFalse(element("pause-response-button").exists, "Nothing is left to stop.")
        attachScreenshot(named: "opencode-8-stopped")

        // With a background job running, Stop asks first.
        try FileManager.default.removeItem(atPath: ready)
        // A stopped turn offers Continue; the turn it resumes answers before the next message.
        element("continue-response-button").click()
        XCTAssertTrue(waitUntil({ (try? self.historyTexts(taskID: taskID).last?.hasPrefix("OpenCode fixture answered")) == true }, timeout: 20),
                      "Continue resumes the conversation.")
        XCTAssertTrue(waitUntil({ self.noTurnIsRunning() }, timeout: 15))
        sendFromComposer("[[background-hold]] Start a background job.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready) }, timeout: 20))
        XCTAssertTrue(stop.waitToExist(timeout: 10) && waitUntil({ stop.isEnabled }, timeout: 5))
        stop.click()
        let confirmation = app.sheets.containing(.staticText, identifier: "Stop background work?").firstMatch
        XCTAssertTrue(confirmation.waitToExist(timeout: 10), "Stop asks before ending OpenCode's background job.")
        attachElementScreenshot(confirmation, named: "opencode-8-background-confirmation")
        confirmation.buttons["Keep Running"].click()
        XCTAssertTrue(waitUntil({ !confirmation.exists }, timeout: 5), "Keep Running closes the sheet.")
        XCTAssertFalse(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String) != "In Progress" || !self.jsonLines(executable + ".job-cancels").isEmpty
        }, timeout: 3), "Keep Running leaves the turn and its job running.")
        XCTAssertTrue(stop.exists && stop.isEnabled, "The turn still shows Stop.")
        XCTAssertFalse(element("continue-response-button").exists, "Nothing was stopped.")
        stop.click()
        XCTAssertTrue(confirmation.waitToExist(timeout: 10))
        confirmation.buttons["Stop All"].click()
        XCTAssertTrue(waitForStatus(taskID, "Waiting Response"), "Stop All settles the turn in Waiting Response.")
        let job = try XCTUnwrap(openCodeTurns(executable).last?["job"] as? String)
        XCTAssertTrue(waitUntil({ self.jsonLines(executable + ".job-cancels").compactMap { ($0 as? [String: Any])?["id"] as? String } == [job] }, timeout: 10),
                      "Stop All cancels the background job through OpenCode's API.")
        XCTAssertTrue(element("continue-response-button").waitToExist(timeout: 10), "The composer is ready again.")
        attachScreenshot(named: "opencode-8-background-stopped")
    }

    // case-contract: test_opencode_missing_session_and_unavailable_provider | When OpenCode no longer has a task's session after a daemon restart, the next turn starts a new OpenCode session seeded with Playhouse's own transcript of the conversation and the task keeps the new session ID. A prompt OpenCode can't run for want of a model provider fails with a message naming `opencode auth login`, an OpenCode release older than the minimum (OpenCode 1) is reported as too old, and a missing CLI reports OpenCode wasn't found. Providers list reports OpenCode with its product name, installed state and official OpenCode 2 curl installer. MCP status for OpenCode lists the servers OpenCode's server runs for the task from the folder's own opencode.json, with the one that needs a sign-in marked, and status for every provider includes them; signing in to that server starts OpenCode's own OAuth for its integration, returns its link, and waits for OpenCode to finish it, after which the server needs no sign-in. An out-of-turn MCP tool call is refused because OpenCode has no API for it. A plugin's background agent runs on OpenCode in a read-only session of its own that is removed when it ends, and its plugin hears its answer. An OpenCode subagent shows as a completed agent row whose history opens from its own child session. Usage reports OpenCode installed and signed out with no connected model provider, and once one is connected (as `opencode auth login`, which runs in Terminal, leaves it) a refresh shows it as OpenCode's account, with no plan. In the window the recovered answer appears after the earlier conversation, the failed turn shows its sign-in error, the MCP page marks the server that needs a sign-in with an OpenCode badge that is gone once it is signed in, the subagent row shows and opens its history, and the Agents info section shows an OpenCode block offering Log in until a model provider is connected, which then shows as its account.
    func test_opencode_missing_session_and_unavailable_provider() throws {
        let environment = try installOpenCodeFixture(named: "opencode-fixture-ui-recovery")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOpenCodeTask(title: "OpenCode recovery", roots: [fixture.primary.path])
        openTask(named: "OpenCode recovery")
        sendFromComposer("Remember the word lantern.")
        XCTAssertNotNil(waitForOpenCodeTurn(executable, containing: "lantern"))
        let lost = try XCTUnwrap(try taskRecord(id: taskID)?["openCodeSessionID"] as? String)
        let sessionsURL = URL(fileURLWithPath: executable + ".sessions.json")
        var sessions = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: sessionsURL)) as? [String: Any])
        sessions.removeValue(forKey: lost)
        try JSONSerialization.data(withJSONObject: sessions).write(to: sessionsURL)
        app.terminate()
        XCTAssertTrue(waitUntil({ self.app.state == .notRunning }, timeout: 12))
        if let pid = try daemonProcessID(environment: environment) { kill(pid_t(pid), SIGKILL) }
        relaunchApp()
        openTask(named: "OpenCode recovery")
        sendFromComposer("What word?")
        let recovered = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "What word?"))
        XCTAssertTrue((recovered["prompt"] as? String ?? "").contains("Remember the word lantern."),
                      "The new session starts with the earlier conversation.")
        let replaced = try XCTUnwrap(try taskRecord(id: taskID)?["openCodeSessionID"] as? String)
        XCTAssertNotEqual(replaced, lost)
        XCTAssertTrue(waitUntil({ self.transcriptContains("Remember the word lantern.") }, timeout: 10))
        XCTAssertEqual(try historyTexts(taskID: taskID).filter { $0.hasPrefix("OpenCode fixture answered") }.count, 2,
                       "The recovered answer follows the earlier one.")
        let recoveredHistory = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let recoveredReply = try XCTUnwrap((recoveredHistory["messages"] as? [[String: Any]])?.last { $0["role"] as? String == "assistant" })
        let recoveredAnswer = element("assistant-message-\(try XCTUnwrap(recoveredReply["id"] as? String))")
        let recoveringMessage = transcriptMessage("What word?")
        XCTAssertTrue(recoveredAnswer.waitToExist(timeout: 15) && recoveringMessage.exists, "The window shows the recovered answer and the message that recovered it.")
        XCTAssertGreaterThan(recoveredAnswer.frame.minY, recoveringMessage.frame.minY, "The recovered answer follows the message that recovered it.")
        attachScreenshot(named: "opencode-9-recovered-session")

        sendFromComposer("[[auth]] Try.")
        let error = element("codex-chat-error")
        XCTAssertTrue(waitUntil({ error.exists && error.label.contains("opencode auth login") }, timeout: 20),
                      "The failed turn shows how to give OpenCode a model provider: \(error.exists ? error.label : "no error")")
        attachScreenshot(named: "opencode-10-auth-error")
        attachElementScreenshot(error, named: "opencode-10-auth-error-detail")
        try assertOpenCodeServerFeatures(executable: executable)
        sendFromComposer("[[subagent]] Look around.")
        XCTAssertNotNil(waitForOpenCodeTurn(executable, containing: "[[subagent]]"))
        XCTAssertTrue(transcriptMessage("OpenCode fixture's explore agent reported back.").waitToExist(timeout: 15))
        XCTAssertTrue(expandActivityDetails(), "The turn's work opens.")
        let subagentTurn = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let agentActivity = try XCTUnwrap((subagentTurn["activities"] as? [[String: Any]])?.first { $0["agentPath"] as? String == "explore" })
        let child = try XCTUnwrap(agentActivity["childThreadID"] as? String)
        let parent = try XCTUnwrap(try taskRecord(id: taskID)?["openCodeSessionID"] as? String)
        let fixtureSessions = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: sessionsURL)) as? [String: Any])
        XCTAssertEqual((fixtureSessions[child] as? [String: Any])?["parentID"] as? String, parent, "The row stands for the subagent's child session.")
        let agentRow = element("codex-subagent-row-\(child)")
        XCTAssertTrue(agentRow.waitToExist(timeout: 10), "OpenCode's explore agent shows under Agents used.")
        XCTAssertTrue(agentRow.label.hasPrefix("Explore"), "The row names the agent: \(agentRow.label)")
        XCTAssertEqual(agentRow.label, "Explore finished working", "The finished agent shows as completed.")
        XCTAssertTrue(app.staticTexts["Agents used"].exists, "Finished agents are listed under Agents used.")
        attachElementScreenshot(agentRow, named: "opencode-10-subagent-row")
        // The row opens the subagent's own work, read from its child session.
        agentRow.descendants(matching: .any).matching(identifier: "subagent-row-chevron").firstMatch.click()
        XCTAssertTrue(element("subagent-conversation-panel").waitToExist(timeout: 10), "The row's arrow opens the subagent's window.")
        let panel = element("subagent-conversation-panel")
        let panelAnswer = panel.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "assistant-message-", "The README is at the repository root."
        )).firstMatch
        XCTAssertTrue(panelAnswer.waitToExist(timeout: 20), "The subagent's window loads its history from the child session and shows its answer.")
        XCTAssertFalse(panel.staticTexts["Loading agent conversation…"].exists, "The subagent's window finished loading.")
        attachScreenshot(named: "opencode-10-subagent-history")
        let subagent = try XCTUnwrap(try runCLI(["conversation", "subagent-history", taskID, "--activity",
                                                 String(decoding: try JSONSerialization.data(withJSONObject: agentActivity), as: UTF8.self)])["result"] as? [String: Any])
        XCTAssertEqual(((subagent["messages"] as? [[String: Any]])?.last)?["text"] as? String, "The README is at the repository root.")
        element("subagent-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("subagent-conversation-panel").exists }, timeout: 5))

        // Agents info, at the bottom of the board's sidebar, shows OpenCode with the model
        // providers it is connected to as its account.
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        let block = element("agents-info-opencode")
        XCTAssertTrue(block.waitToExist(timeout: 40), "The installed OpenCode has an Agents info block.")
        let login = element("agents-info-login-opencode")
        XCTAssertTrue(login.waitToExist(timeout: 40), "OpenCode with no connected model provider offers Log in.")
        attachElementScreenshot(block, named: "opencode-11-agents-info-signed-out")
        // Log in opens `opencode auth login` in Terminal, which the test can't drive; it connects a
        // model provider the way that login would leave it, and the open window follows the refresh.
        try JSONSerialization.data(withJSONObject: [["integrationID": "anthropic", "type": "api"]])
            .write(to: URL(fileURLWithPath: executable + ".auth.json"))
        _ = try runCLI(["usage", "get", "--refresh"])
        XCTAssertTrue(waitUntil({ !login.exists && block.staticTexts["anthropic"].exists }, timeout: 40),
                      "A connected model provider shows as OpenCode's account.")
        attachElementScreenshot(block, named: "opencode-11-agents-info-connected")
        let providers = try XCTUnwrap(try runCLI(["providers", "list"])["result"] as? [[String: Any]])
        let opencode = try XCTUnwrap(providers.first { $0["provider"] as? String == "opencode" })
        XCTAssertEqual(opencode["productName"] as? String, "OpenCode")
        XCTAssertEqual(opencode["isInstalled"] as? Bool, true)
        XCTAssertEqual(opencode["installCommand"] as? String, "curl -fsSL https://opencode.ai/v2/install | bash")
        let missing = try runCLI(["conversation", "send", taskID, "--message", "Hello?"], expectedStatus: 1,
                                 extraEnvironment: ["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE": "none"])
        XCTAssertTrue("\(missing)".contains("OpenCode wasn't found"), "\(missing)")
        let old = try installOpenCodeFixture(named: "opencode-fixture-ui-old")
        let tooOld = try runCLI(["conversation", "send", taskID, "--message", "Hello?"], expectedStatus: 1, extraEnvironment: old)
        XCTAssertTrue("\(tooOld)".contains("too old for Playhouse") && "\(tooOld)".contains("2.4.0"), "\(tooOld)")
    }

    /// The servers an OpenCode server records for its turns, by session.
    func openCodeServerTurns() -> Set<String> {
        let folder = dataDirectory.appendingPathComponent("opencode-runs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(files.filter { $0.pathExtension == "json" }.flatMap { file -> [String] in
            guard let data = try? Data(contentsOf: file), let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return Array((manifest["turns"] as? [String: Any] ?? [:]).keys)
        })
    }

    /// What OpenCode's server reports reaches Playhouse: MCP status and its OAuth sign-in, and a
    /// plugin's background agent; an out-of-turn MCP call is refused.
    func assertOpenCodeServerFeatures(executable: String) throws {
        let root = dataDirectory.appendingPathComponent("opencode-mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let servers: [String: Any] = ["mcpServers": [
            "oc-local": ["type": "stdio", "command": "node", "args": ["server.js"]],
            "oc-remote": ["type": "http", "url": "https://example.test/mcp"],
        ]]
        // The page lists the servers Claude and Codex read; OpenCode runs the same ones from the
        // folder's own opencode.json, which it reads itself.
        try JSONSerialization.data(withJSONObject: servers).write(to: root.appendingPathComponent(".mcp.json"))
        try JSONSerialization.data(withJSONObject: ["mcp": [
            "oc-local": ["type": "local", "command": ["node", "server.js"]],
            "oc-remote": ["type": "remote", "url": "https://example.test/mcp"],
        ]]).write(to: root.appendingPathComponent("opencode.json"))
        let mcpTask = try createOpenCodeTask(title: "OpenCode MCP", roots: [root.path])
        func statuses() throws -> [String: [String: Any]] {
            let report = try XCTUnwrap(try runCLI(["mcp", "status", "--task", mcpTask, "--provider", "opencode"])["result"] as? [String: Any])
            return Dictionary(uniqueKeysWithValues: (report["opencode"] as? [[String: Any]] ?? []).compactMap { entry in
                (entry["name"] as? String).map { ($0, entry) }
            })
        }
        let before = try statuses()
        XCTAssertEqual(before["oc-local"]?["status"] as? String, "connected")
        XCTAssertEqual(before["oc-remote"]?["needsSignIn"] as? Bool, true, "\(before)")
        // The MCP page marks the server OpenCode can't start without a sign-in with an OpenCode badge.
        func openCodeBadge(_ server: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND identifier CONTAINS %@", "mcp-signin-", "-opencode", server
            )).firstMatch
        }
        openTask(named: "OpenCode MCP")
        openMcpPage()
        XCTAssertTrue(openCodeBadge("oc-remote").waitToExist(timeout: 30), "The server that needs a sign-in has an OpenCode badge.")
        XCTAssertFalse(openCodeBadge("oc-local").exists, "A connected server has no sign-in badge.")
        attachElementScreenshot(openCodeBadge("oc-remote"), named: "opencode-10-mcp-signin-badge")
        attachElementScreenshot(element("skills-page"), named: "opencode-10-mcp-page")
        app.typeKey(.escape, modifierFlags: [])
        let started = try XCTUnwrap(try runCLI(["mcp", "authenticate", "--provider", "opencode", "--name", "oc-remote", "--task", mcpTask])["result"] as? [String: Any])
        XCTAssertTrue((started["authorizationUrl"] as? String ?? "").hasPrefix("https://example.test/oauth/mcp-oc-remote?attempt="), "\(started)")
        touch(executable + ".oauth-complete")
        let finished = try XCTUnwrap(try runCLI(["mcp", "authenticate-wait", "--provider", "opencode", "--name", "oc-remote", "--task", mcpTask])["result"] as? [String: Any])
        XCTAssertEqual(finished["signedIn"] as? Bool, true)
        XCTAssertEqual(try statuses()["oc-remote"]?["needsSignIn"] as? Bool, false, "The finished sign-in no longer needs one.")
        openMcpPage()
        XCTAssertTrue(waitUntil({ !self.element("mcp-checking-status").exists }, timeout: 30), "The page finishes checking.")
        XCTAssertFalse(openCodeBadge("oc-remote").exists, "The signed-in server no longer has a sign-in badge.")
        attachElementScreenshot(element("skills-page"), named: "opencode-10-mcp-signed-in")
        app.typeKey(.escape, modifierFlags: [])
        openTask(named: "OpenCode recovery")
        let call = try runCLI(["mcp", "call", "--tool", "mcp__docs__search", "--provider", "opencode"], expectedStatus: 1)
        XCTAssertEqual((call["error"] as? [String: Any])?["code"] as? String, "unavailable")
        try writeInstalledPlugin("oc-agent", source: """
        Playhouse.service.on("agent.finished", function (e) { return Playhouse.setState("finished", { status: e.status, result: e.result, error: e.error }); });
        """, placement: "composerActions", presentation: "headless", extra: ["events": ["agent.finished"]])
        _ = try runCLI(["agent", "run", "--plugin", "oc-agent", "--provider", "opencode", "--prompt", "Summarize the board."])
        var agentFinished: [String: Any]?
        XCTAssertTrue(waitUntil({
            let state = (try? self.runCLI(["plugin", "state", "--id", "oc-agent"])["result"] as? [String: Any])?["state"] as? [String: Any]
            agentFinished = state?["finished"] as? [String: Any]
            return agentFinished != nil
        }, timeout: 30), "The plugin hears its OpenCode agent finish.")
        XCTAssertEqual(agentFinished?["status"] as? String, "done", "\(agentFinished ?? [:])")
        XCTAssertEqual(agentFinished?["result"] as? String, "OpenCode fixture answered in build mode with fixture/fast.")
    }

    // case-contract: test_opencode_turn_survives_daemon_restart | An OpenCode turn runs on a shared server that outlives a daemon killed mid-turn and records the running turn in its manifest; the next daemon reconnects to the same server, rebuilds the turn from the session's messages and follows it live, and records the answer OpenCode gives after the restart exactly once, without repeating what was recorded before. The session's messages reach the token map's log while the turn runs, once a model request ends, and the reattached turn writes the rest when it finishes, so the map holds both of its requests. The finished turn leaves its server with no turn recorded, and the adopted server stops once it has been idle for the idle timeout, removing its manifest. In the window the answer given after the restart appears once in the conversation and the task leaves In Progress.
    func test_opencode_turn_survives_daemon_restart() throws {
        _ = try installOpenCodeFixture(named: "opencode-fixture-ui-reattach")
        let executable = try XCTUnwrap(openCodeFixtureExecutable)
        let environment = restartServiceEnvironment(["PLAYHOUSE_E2E_OPENCODE_SERVER_IDLE_SECONDS": "3"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let task = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "OpenCode restart", "--prompt", "Fixture task description.", "--root", fixture.primary.path, "--provider", "opencode",
        ], extraEnvironment: environment)["result"] as? [String: Any])
        let taskID = try XCTUnwrap(task["id"] as? String)
        XCTAssertTrue(app.buttons["OpenCode restart"].waitToExist(timeout: 10))
        openTask(named: "OpenCode restart")
        sendFromComposer("[[hold]] [[step]] Survive a restart.")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: executable + ".hold-ready") }, timeout: 20))
        XCTAssertTrue(transcriptMessage("Holding the OpenCode turn.").waitToExist(timeout: 10))
        let server = try XCTUnwrap(agentManifest(kind: "opencode", service: environment))
        let session = try XCTUnwrap(try taskRecord(id: taskID)?["openCodeSessionID"] as? String)
        XCTAssertNotNil((server.manifest["turns"] as? [String: Any])?[session], "The running turn is recorded on its server.")
        let requestLog = dataDirectory.appendingPathComponent("opencode-request-logs/\(session).jsonl")
        func logged(_ text: String) -> Bool { ((try? String(contentsOf: requestLog, encoding: .utf8)) ?? "").contains(text) }
        XCTAssertTrue(waitUntil({ logged("Holding the OpenCode turn.") }, timeout: 15), "The running turn's finished model request reaches the token map's log.")
        let agent = try XCTUnwrap(server.manifest["process"] as? [String: Any])
        attachScreenshot(named: "opencode-11-before-restart")

        let launchesBefore = jsonLines(executable + ".launches").count
        try killDaemon(environment: environment)
        XCTAssertTrue(agentIsAlive(agent), "The OpenCode server outlives the daemon that started it.")
        XCTAssertTrue(waitForStatus(taskID, "In Progress", environment: environment), "The next daemon carries the turn on.")
        touch(executable + ".hold-release")
        XCTAssertTrue(transcriptMessage("Released the OpenCode turn.").waitToExist(timeout: 30), "The window shows the answer given after the restart.")
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } ?? false
        }, timeout: 30), "The task leaves In Progress.")
        if element("codex-activity-disclosure").exists { XCTAssertTrue(expandActivityDetails(), "The settled turn's work opens.") }
        func shown(_ text: String) -> Int {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "assistant-message-", text)).count
        }
        XCTAssertEqual(shown("Released the OpenCode turn."), 1, "The answer given after the restart appears once in the window.")
        XCTAssertLessThanOrEqual(shown("Holding the OpenCode turn."), 1, "What OpenCode wrote before the restart isn't shown again.")
        let texts = try historyTexts(taskID: taskID, environment: environment)
        XCTAssertEqual(texts.filter { $0 == "Released the OpenCode turn." }.count, 1, "\(texts)")
        XCTAssertEqual(texts.filter { $0 == "Holding the OpenCode turn." }.count, 1, "\(texts)")
        XCTAssertTrue(waitUntil({ logged("Released the OpenCode turn.") }, timeout: 15), "The reattached turn writes the rest of its messages when it finishes.")
        let waste = try XCTUnwrap(try runCLI(["task", "token-waste", taskID], extraEnvironment: environment)["result"] as? [String: Any])
        XCTAssertEqual((waste["agents"] as? [[String: Any]])?.filter { $0["id"] as? String == "opencode" }.map { $0["requests"] as? Int }, [2],
                       "The map holds the request before the restart and the one after it.")
        XCTAssertEqual(jsonLines(executable + ".launches").count, launchesBefore, "The next daemon reconnects to the same server instead of starting one.")
        XCTAssertTrue(waitUntil({ !self.openCodeServerTurns().contains(session) }, timeout: 15), "The finished turn leaves no turn on its server.")
        XCTAssertTrue(waitUntil({ !self.agentIsAlive(agent) }, timeout: 30), "The idle OpenCode server stops.")
        XCTAssertTrue(waitUntil({ self.agentManifest(kind: "opencode", service: environment) == nil }, timeout: 10), "The stopped server's manifest is removed.")
        attachScreenshot(named: "opencode-12-after-restart")
    }

    // case-contract: test_opencode_token_map_reads_session_messages | An OpenCode task with no turn has no token map. After an OpenCode turn that reads a long build log and runs an explore subagent, the token map reads the messages OpenCode's server lists for the task's session and the subagent's child session, which the turn wrote beside the store before it finished: each assistant message is a request that was sent every message before it, the build log the read tool returned is the largest item, OpenCode's system prompt and tool definitions, which its server doesn't return, are one hidden-overhead item sent with every request and measured at about the 2,000 tokens the fixture bills for them, the final transcript's tokens equal the last request's reported input, and the subagent's child session is its own agent. With --turn, the turn's map holds its three main requests and the subagent's one, and its summary lists 4 model calls. The raw input's single-request scope labels each request reconstructed, its items add up to the input OpenCode reported with the earlier request's share as cache read, the log's full text reads back exactly as OpenCode returned it, and the JSON export holds the messages the request was sent. The map still reads after the daemon restarts with OpenCode gone, and deleting the task removes the messages it saved. The Token Stats modal shows the build log as the largest waster and opens its full text, lists the hidden overhead and the subagent, and the raw input's latest request reads as reconstructed.
    func test_opencode_token_map_reads_session_messages() throws {
        let environment = try installOpenCodeFixture(named: "opencode-fixture-ui-token-map")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        let taskID = try createOpenCodeTask(title: "OpenCode token map", roots: [fixture.primary.path])
        let empty = try XCTUnwrap(try runCLI(["task", "token-waste", taskID])["result"] as? [String: Any])
        XCTAssertEqual(empty["available"] as? Bool, false, "A task with no OpenCode turn has no token map.")
        openTask(named: "OpenCode token map")
        sendFromComposer("[[token-map]] Map the tokens.")
        let turn = try XCTUnwrap(waitForOpenCodeTurn(executable, containing: "[[token-map]]"))
        XCTAssertTrue(transcriptMessage("OpenCode fixture mapped its tokens.").waitToExist(timeout: 15))
        let child = try XCTUnwrap(turn["child"] as? String)
        let log = try XCTUnwrap(turn["log"] as? String)
        let sessionID = try XCTUnwrap(try taskRecord(id: taskID)?["openCodeSessionID"] as? String)
        let logs = dataDirectory.appendingPathComponent("opencode-request-logs", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.appendingPathComponent("\(sessionID).jsonl").path),
                      "The turn wrote its session's messages beside the store.")

        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        openTokenStats(of: "OpenCode token map")
        showTokenStatsSection("wasters")
        assertText("token-stats-waster-0-label", equals: "read")
        attachScreenshot(named: "OpenCode wasters rank the build log first")
        element("token-stats-waster-0-show").click()
        assertText("raw-input-text-label", equals: "read")
        let firstLine = element("raw-input-text-line-1")
        XCTAssertTrue(firstLine.waitToExist(timeout: 10), "The build log's full text opens from its waster row.")
        XCTAssertTrue(accessibleLabelOrValue(of: firstLine).contains("fixture build log line 0000: compiled module 0"),
                      "The first line is the log exactly as OpenCode returned it.")
        attachScreenshot(named: "Showing the OpenCode waster opens the build log")
        element("close-raw-input-button").click()
        showTokenStatsSection("overhead")
        XCTAssertTrue(
            element(containingAccessibilityText: "System prompt, tool definitions and other context OpenCode does not return").waitToExist(timeout: 5),
            "OpenCode's system prompt and tools show as one hidden-overhead line."
        )
        XCTAssertTrue(element("token-stats-agent-opencode/\(child)").waitToExist(timeout: 5), "The subagent's child session is its own agent.")
        attachScreenshot(named: "OpenCode overhead lists the hidden system prompt and the subagent")

        element("token-stats-raw-input-button").click()
        let requestScope = element("raw-input-scope-request")
        XCTAssertTrue(requestScope.waitToExist(timeout: 10))
        requestScope.click()
        assertText("raw-input-request-number", equals: "Request 3 of 3")
        assertText("raw-input-request-exactness", equals: "Reconstructed")
        XCTAssertTrue(
            accessibleLabelOrValue(of: element("raw-input-request-note")).hasPrefix("Reconstructed: OpenCode resends the session's messages"),
            "The view says how the OpenCode request was rebuilt."
        )
        attachScreenshot(named: "An OpenCode request rebuilt from the session's messages")
        element("close-raw-input-button").click()
        element("close-token-stats-button").click()

        let report = try XCTUnwrap(try runCLI(["task", "token-waste", taskID])["result"] as? [String: Any])
        let agents = try XCTUnwrap(report["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.map { $0["id"] as? String }, ["opencode", "opencode/\(child)"])
        XCTAssertEqual(agents.first?["requests"] as? Int, 3)
        let hidden = try XCTUnwrap((report["overhead"] as? [[String: Any]])?.first { $0["kind"] as? String == "hiddenOverhead" })
        XCTAssertEqual(hidden["everyRequest"] as? Bool, true)
        XCTAssertTrue((1_900...2_100).contains(hidden["tokens"] as? Int ?? 0), "The hidden overhead is about what the fixture bills: \(hidden)")
        let topItem = try XCTUnwrap((report["wasters"] as? [[String: Any]])?.first?["item"] as? Int)
        let text = try XCTUnwrap(try runCLI(["task", "raw-input-text", taskID, "--item", String(topItem), "--length", "100000"])["result"] as? [String: Any])
        XCTAssertEqual(text["text"] as? String, log, "The log reads back exactly as OpenCode returned it.")
        let page = try XCTUnwrap(try runCLI(["task", "raw-input", taskID, "--scope", "request"])["result"] as? [String: Any])
        let request = try XCTUnwrap(page["request"] as? [String: Any])
        XCTAssertEqual(request["itemTokens"] as? Int, request["contextTokens"] as? Int, "The items add up to the input OpenCode reported.")
        let exported = try XCTUnwrap(try runCLI(["task", "raw-input-export", taskID, "--request", "1", "--format", "json"])["result"] as? [String: Any])
        XCTAssertEqual(exported["text"] as? String, "{\n  \"messages\" : [\n    \"[[token-map]] Map the tokens.\"\n  ]\n}")
        let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
        let turnID = try XCTUnwrap((history["messages"] as? [[String: Any]])?.first {
            $0["role"] as? String == "user" && $0["text"] as? String == "[[token-map]] Map the tokens."
        }?["turnID"] as? String)
        let scoped = try XCTUnwrap(try runCLI(["task", "token-waste", taskID, "--turn", turnID])["result"] as? [String: Any])
        XCTAssertEqual((scoped["agents"] as? [[String: Any]])?.map { $0["requests"] as? Int }, [3, 1], "The turn's three main requests and its subagent's one.")
        let turnUsage = try XCTUnwrap(try runCLI(["task", "token-usage", taskID, "--turn", turnID])["result"] as? [String: Any])
        XCTAssertEqual((turnUsage["callUsage"] as? [String: Any])?["totalCalls"] as? Int, 4)

        // The written messages outlive the daemon and OpenCode's server.
        app.terminate()
        XCTAssertTrue(waitUntil({ self.app.state == .notRunning }, timeout: 12))
        if let pid = try daemonProcessID(environment: environment) { kill(pid_t(pid), SIGKILL) }
        let gone = try XCTUnwrap(try runCLI(["task", "token-waste", taskID], extraEnvironment: ["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE": "none"])["result"] as? [String: Any])
        XCTAssertEqual((gone["agents"] as? [[String: Any]])?.count, 2, "The map still reads with OpenCode gone.")
        _ = try runCLI(["task", "delete", taskID])
        let saved = [logs.appendingPathComponent("\(sessionID).jsonl"), logs.appendingPathComponent("\(sessionID).subagent.\(child).jsonl")]
        XCTAssertFalse(saved.contains { FileManager.default.fileExists(atPath: $0.path) }, "Deleting the task removes the messages it saved.")
    }

    // case-contract: test_plugin_agent_run_opencode_json_schema | agent.run with provider opencode and a JSON schema (CLI agent run --provider opencode --json-schema, Playhouse.agent.run from the popover with the plugin's provider) sends the plugin's prompt with the schema and an instruction to answer with only matching JSON to a read-only OpenCode session of its own. An answer whose JSON matches the schema, inside a Markdown code block or not, is the run's structured result, which the plugin's handler uses to create a board task. An answer that isn't JSON or doesn't match is asked for once more in the same session, naming what was wrong, and a matching second answer is the result; a second mismatch fails the run with an error saying OpenCode's answer didn't match the JSON schema and why, which the plugin files on the board. Each run's session is removed when it ends. In the window the popover's run on OpenCode creates the task from the corrected answer and shows its result, and a run that never matched shows on the board as a failed task.
    func test_plugin_agent_run_opencode_json_schema() throws {
        let environment = try installOpenCodeFixture(named: "opencode-fixture-ui-json")
        let executable = try XCTUnwrap(environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"])
        let answers = URL(fileURLWithPath: executable + ".json-answers")
        let corrected = "```json\n" + #"{"title": "Reply to Omri", "prompt": "Answer Omri's question.", "nothingNew": false}"# + "\n```"
        try JSONSerialization.data(withJSONObject: ["I'll draft the task for Dana.", corrected]).write(to: answers)
        try writeInstalledPlugin("slack-dms", source: Self.serviceAgentPluginSource, placement: "mainSidebar", presentation: "popover",
                                 name: "Slack DMs", icon: "bubble.left.and.bubble.right", extra: ["events": ["agent.finished"]])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: environment)
        _ = try runCLI(["plugin", "refresh"])
        _ = try runCLI(["plugin", "state", "--id", "slack-dms", "--key", "provider", "--value", #""opencode""#])
        func finished() -> [String: Any]? { (try? pluginState("slack-dms"))?["finished"] as? [String: Any] }
        func boardCard(_ title: String) -> XCUIElement? {
            guard let id = (try? taskRecord(named: title))??["id"] as? String else { return nil }
            return element("task-card-\(id)")
        }
        func liveSessions() -> Set<String> {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: executable + ".sessions.json"))) ?? Data("{}".utf8)
            return Set(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]).keys)
        }

        // The popover runs the agent on OpenCode; its first answer isn't JSON, so it is asked again.
        let entry = element("plugin-entry-slack-dms")
        XCTAssertTrue(entry.waitToExist(timeout: 10), "The popover plugin has its sidebar button.")
        entry.click()
        let create = element("dm-create-U7")
        XCTAssertTrue(create.waitToExist(timeout: 10))
        create.click()
        XCTAssertTrue(waitUntil({ finished()?["status"] as? String == "done" }, timeout: 30), "The plugin hears the OpenCode agent finish: \(finished() ?? [:])")
        XCTAssertEqual(finished()?["title"] as? String, "Reply to Omri")
        let turns = openCodeTurns(executable)
        XCTAssertEqual(turns.count, 2, "The answer that wasn't JSON is asked for once more.")
        let first = turns.first?["prompt"] as? String ?? ""
        XCTAssertTrue(first.hasPrefix("Read the DMs of U7 and draft a task.\n\nAnswer with only a JSON value that matches this JSON Schema"), first)
        XCTAssertTrue(first.contains("\"nothingNew\""), "The prompt carries the plugin's schema.")
        XCTAssertEqual(turns.first?["sessionId"] as? String, turns.last?["sessionId"] as? String, "The correction goes to the same session.")
        XCTAssertTrue((turns.last?["prompt"] as? String ?? "").hasPrefix("Your answer didn't match the JSON Schema: the answer isn't JSON."))
        XCTAssertEqual(turns.last?["model"] as? String, "fixture/fast")
        XCTAssertTrue((turns.first?["permissions"] as? [[String: String]] ?? []).contains(["action": "edit", "resource": "*", "effect": "deny"]),
                      "The run's session is read-only.")
        XCTAssertFalse(liveSessions().contains(turns.first?["sessionId"] as? String ?? ""), "The run's session is removed when it ends.")
        XCTAssertTrue(waitUntil({ boardCard("Reply to Omri")?.exists == true }, timeout: 15), "The task from the corrected answer is on the board.")
        let result = element("dm-finished")
        XCTAssertTrue(waitUntil({ self.pluginText(result) == "done U7 Reply to Omri" }, timeout: 10), "The popover shows the result: \(pluginText(result))")
        attachElementScreenshot(element("plugin-surface-slack-dms"), named: "The OpenCode agent's corrected answer created a task")
        app.typeKey(.escape, modifierFlags: [])
        attachElementScreenshot(try XCTUnwrap(boardCard("Reply to Omri")), named: "The task from the OpenCode agent's structured answer")

        // Two answers that don't match fail the run, and the plugin files it on the board.
        try JSONSerialization.data(withJSONObject: [#"{"title": "Only a title"}"#, #"{"title": "Still", "prompt": "No flag."}"#]).write(to: answers)
        _ = try runCLI(["plugin", "state", "--id", "slack-dms", "--key", "finished", "--value", "null"])
        entry.click()
        XCTAssertTrue(create.waitToExist(timeout: 10))
        create.click()
        XCTAssertTrue(waitUntil({ finished()?["status"] as? String == "failed" }, timeout: 30), "The run fails after a second mismatch: \(finished() ?? [:])")
        let reason = #"OpenCode's answer didn't match the JSON schema: $ is missing the required property "nothingNew"."#
        XCTAssertEqual(finished()?["error"] as? String, reason)
        app.typeKey(.escape, modifierFlags: [])
        let failedCard = "Slack task failed for U7: \(reason)"
        XCTAssertTrue(waitUntil({ boardCard(failedCard)?.exists == true }, timeout: 15), "The failed run is on the board.")
        attachElementScreenshot(try XCTUnwrap(boardCard(failedCard)), named: "An OpenCode run that never matched the schema is filed as failed")
        XCTAssertEqual(openCodeTurns(executable).count, 4)
        XCTAssertTrue(liveSessions().isDisjoint(with: openCodeTurns(executable).compactMap { $0["sessionId"] as? String }), "Every run's session is removed.")
    }
}

import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
import SQLite3
import Vision

extension PlayhouseUITests {
    // case-contract: test_mentions_menu_lists_expands_and_remembers_recent | Typing @ in the composer opens a mention menu that lists, in order, the task's enabled rules, then its skills, MCP servers, agents (Claude Code's .claude/agents and Codex's .codex/agents, an agent both define being one item that names both files, the running provider's first), repositories (the task's own and those under the repository root), then other board tasks; before anything was mentioned, an empty query shows that whole list. Typing after the @ filters it, items whose handle starts with the query first, and a query nothing matches shows an empty state. The arrow keys move the highlight, Return or Tab inserts the highlighted item, and a click inserts the clicked one, as @handle drawn in the accent color; Escape closes the menu while keeping the typed text. Sending appends a <playhouse-mentions> block naming each mentioned item with its full path or details (for the task's repository, also its worktree), only for known handles that start a word, and the provider receives it while the transcript shows only the typed message, once, with its mentions drawn in the accent color, and the task's saved prompt keeps the typed text. Steering an active Codex turn expands its mentions the same way, exactly once, and shows the steer once, while a steer that misses its turn is queued as typed. The sent mentions become the recent mentions, most recent first and ten at most, which an empty query then shows instead, and they persist across fresh CLI processes. Listing mentions without a task is a usage error, and for an unknown task is not_found.
    func test_mentions_menu_lists_expands_and_remembers_recent() throws {
        let repository = try makeSkillRepository("mention-repo", skills: [
            "AGENTS.md": "# Mention repo rules\nKeep it tidy.\n",
            ".agents/skills/mention-skill/SKILL.md": skillManifest("mention-skill", "A skill to mention"),
            ".agents/skills/mention-extra-1/SKILL.md": skillManifest("mention-extra-1", "Another skill to mention"),
            ".agents/skills/mention-extra-2/SKILL.md": skillManifest("mention-extra-2", "Another skill to mention"),
            ".agents/skills/mention-extra-3/SKILL.md": skillManifest("mention-extra-3", "Another skill to mention"),
            ".agents/skills/mention-extra-4/SKILL.md": skillManifest("mention-extra-4", "Another skill to mention"),
            ".mcp.json": #"{"mcpServers": {"docs-server": {"type": "stdio", "command": "node", "args": ["docs.js"]}}}"#,
            ".claude/agents/reviewer.md": "---\nname: reviewer\ndescription: Reviews changes\n---\n\nReview the diff.\n",
            ".codex/agents/reviewer.toml": "name = \"reviewer\"\ndescription = \"Reviews changes\"\n",
            ".codex/agents/helper.toml": "name = \"helper\"\ndescription = \"Codex-only helper\"\n",
        ])
        let executable = try installSkillsClaudeFixture("claude-fixture-mentions")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        // A held Codex turn for the steer at the end; the fixture's name selects its hold mode.
        let codex = dataDirectory.appendingPathComponent("codex-fixture-mention-steer-serial-success-wait")
        try copyFixtureFile(at: WorkspaceFixture.root.appendingPathComponent("codex-fixture-ui"), to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        try Data("Playhouse test owns this Codex protocol fixture (v1).\n".utf8).write(to: dataDirectory.appendingPathComponent(".playhouse-codex-fixture-owner"))
        codexFixtureExecutable = codex.path
        launchApp(defaultParent: fixture.parent.path)
        try createTaskFixture(title: "Other mention task", roots: [])
        let task = try createSkillsTask("Mention task", repositories: [repository], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
        _ = try createSkillsTask("Mention steer task", repositories: [repository], provider: "codex")
        func mentions() throws -> [String: Any] {
            try XCTUnwrap(try runCLI(["mentions", "list", "--task", taskID])["result"] as? [String: Any])
        }
        func menuRowElements() -> [XCUIElement] {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "mention-item-")).allElementsBoundByIndex
                .filter(\.exists).sorted { $0.frame.minY < $1.frame.minY }
        }
        /// The menu's rows, top to bottom.
        func menuRows() -> [String] { menuRowElements().map { String($0.identifier.dropFirst("mention-item-".count)) } }
        func highlightedRow() -> String? {
            menuRowElements().first(where: \.isSelected).map { String($0.identifier.dropFirst("mention-item-".count)) }
        }
        let items = try XCTUnwrap(try mentions()["items"] as? [[String: Any]])
        let handles = items.compactMap { $0["handle"] as? String }
        XCTAssertEqual(items.first?["kind"] as? String, "rule", "Rules come first.")

        openTask(named: "Mention task")
        let composer = element("message-composer")
        XCTAssertTrue(composer.waitToExist(timeout: 10))
        composer.click()
        composer.typeText("@")
        let menu = element("mention-menu")
        XCTAssertTrue(menu.waitToExist(timeout: 10), "Typing @ opens the mention menu.")
        XCTAssertLessThanOrEqual(menu.frame.maxY, composer.frame.minY, "The menu opens above the composer, leaving the typed text visible.")
        XCTAssertTrue(element("mention-item-mention-repo/AGENTS.md").waitToExist(timeout: 10))
        let rows = menuRows()
        XCTAssertEqual(rows.first, "mention-repo/AGENTS.md", "Before anything was mentioned, the whole list shows, a rule first.")
        XCTAssertEqual(rows, Array(handles.prefix(rows.count)), "The menu keeps the catalog's order: rules, skills, MCP servers, agents, repositories, tasks.")
        for row in ["mention-skill", "docs-server", "reviewer", "mention-repo", "Other-mention-task"] {
            XCTAssertTrue(rows.contains(row), "The menu lists \(row).")
        }
        XCTAssertEqual(highlightedRow(), rows.first)
        composer.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil({ highlightedRow() == rows[1] }, timeout: 5), "Down moves the highlight to the next row.")
        composer.typeKey(.downArrow, modifierFlags: [])
        composer.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(waitUntil({ highlightedRow() == rows[1] }, timeout: 5), "Up moves it back.")
        attachScreenshot(named: "Mention menu listing rules, skills, MCP servers and agents")
        attachElementScreenshot(menu, named: "Mention menu, full list")

        composer.typeText("rev")
        XCTAssertTrue(waitUntil({ menuRows().first == "reviewer" && highlightedRow() == "reviewer" }, timeout: 5),
                      "Typing after @ filters, handle prefixes first, and highlights the first match.")
        XCTAssertFalse(element("mention-item-mention-repo/AGENTS.md").exists)
        XCTAssertEqual(element("mention-menu-title").value as? String, "Mention matching “rev”")
        attachElementScreenshot(menu, named: "Mention menu filtered by the typed query")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "@reviewer " }, timeout: 5), "Return inserts the highlighted mention.")
        XCTAssertTrue(waitUntil({ !self.element("mention-menu").exists }, timeout: 5))
        XCTAssertTrue(waitUntil({ composer.title == "Mentions @reviewer" }, timeout: 5), "The inserted mention is drawn in the accent color.")

        composer.typeText("check @zzz-nothing")
        let empty = element("mention-menu-empty")
        XCTAssertTrue(empty.waitToExist(timeout: 5))
        XCTAssertTrue((empty.value as? String ?? "").contains("Nothing to mention matches"), "A query nothing matches shows an empty state: \(String(describing: empty.value))")
        for _ in 0..<"@zzz-nothing".count { composer.typeText(XCUIKeyboardKey.delete.rawValue) }
        composer.typeText("@mention-re")
        let repositoryRow = element("mention-item-mention-repo")
        XCTAssertTrue(repositoryRow.waitToExist(timeout: 5))
        // XCUITest reports rows of the menu, which floats over the transcript, as not hittable;
        // a real click at the row's center must still choose it.
        repositoryRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "@reviewer check @mention-repo " }, timeout: 5), "A click inserts the clicked mention.")
        composer.typeText("and @docs")
        XCTAssertTrue(waitUntil({ highlightedRow() == "docs-server" }, timeout: 5))
        composer.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "@reviewer check @mention-repo and @docs-server " }, timeout: 5), "Tab inserts the highlighted mention.")

        composer.typeText("then @")
        XCTAssertTrue(menu.waitToExist(timeout: 5))
        composer.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !self.element("mention-menu").exists }, timeout: 5), "Escape closes the menu.")
        XCTAssertEqual(composer.value as? String, "@reviewer check @mention-repo and @docs-server then @", "Escape keeps the typed text.")
        composer.typeText(XCUIKeyboardKey.delete.rawValue)
        composer.typeText("report back.")
        XCTAssertTrue(waitUntil({ composer.title == "Mentions @reviewer, @mention-repo, @docs-server" }, timeout: 5))
        attachScreenshot(named: "Composer with mentions in the accent color")
        attachElementScreenshot(element("message-composer-scroll-view"), named: "Composer mentions close up")

        let typed = "@reviewer check @mention-repo and @docs-server then report back."
        element("send-message-button").click()
        func sentText() -> String? {
            guard let data = try? Data(contentsOf: historyURL),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (history["turns"] as? [[String: Any]] ?? []).compactMap { $0["userText"] as? String }.first { $0.hasPrefix(typed) }
        }
        XCTAssertTrue(waitUntil({ sentText() != nil }, timeout: 20), "The message reaches Claude Code.")
        let sent = try XCTUnwrap(sentText())
        XCTAssertTrue(sent.hasPrefix(typed + "\n\n<playhouse-mentions>\n"), sent)
        XCTAssertEqual(sent.components(separatedBy: "\n").filter { $0.hasPrefix("- @") }.count, 3, sent)
        XCTAssertTrue(sent.contains("- @reviewer (agent): the Claude Code subagent `reviewer` defined in `"), sent)
        XCTAssertTrue(sent.contains(".codex/agents/reviewer.toml`"), sent)
        XCTAssertTrue(sent.contains("- @mention-repo (repository): the Git repository at `\(repository.path)`; this task works on it in its worktree `\(worktree)`"), sent)
        XCTAssertTrue(sent.contains("- @docs-server (mcp): the MCP server `docs-server`"), sent)
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "user-message-", typed)).firstMatch
        XCTAssertTrue(bubble.waitToExist(timeout: 10))
        XCTAssertFalse(bubble.label.contains("playhouse-mentions"), "The transcript hides the mention block.")
        XCTAssertTrue(waitUntil({ bubble.textViews.firstMatch.title == "Mentions @reviewer, @mention-repo, @docs-server" }, timeout: 10),
                      "The sent message draws its mentions in the accent color.")
        // The fixture turn reports no outcome, so Playhouse nudges it once it completes.
        let nudge = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "playhouse-message-")).firstMatch
        XCTAssertTrue(nudge.waitToExist(timeout: 30), "The sent turn completes before the composer is used again.")
        // The persisted message's bubble ends in -user; once it shows, the live copy must be gone.
        let sentBubbles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "user-message-", typed))
        XCTAssertTrue(waitUntil({ sentBubbles.matching(NSPredicate(format: "identifier ENDSWITH %@", "-user")).count == 1 }, timeout: 10))
        XCTAssertEqual(sentBubbles.count, 1, "The live message and the one persisted with its mention block are one bubble.")
        XCTAssertEqual(try taskRecord(id: taskID)?["savedPrompt"] as? String, typed, "The task's saved prompt keeps the typed text.")
        attachScreenshot(named: "Sent message with its mentions colored")
        attachElementScreenshot(bubble, named: "Sent message mentions close up")

        let recentIDs = try XCTUnwrap(try mentions()["recentIDs"] as? [String])
        XCTAssertEqual(Array(recentIDs.prefix(2)), ["agent:reviewer", "repository:\(repository.path)"], "Sent mentions become recent, in order.")
        XCTAssertEqual(recentIDs.count, 3)
        composer.click()
        composer.typeText("@")
        XCTAssertTrue(menu.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ menuRows() == ["reviewer", "mention-repo", "docs-server"] }, timeout: 10),
                      "An empty query now shows the recent mentions, most recent first.")
        XCTAssertEqual(element("mention-menu-title").value as? String, "Recent mentions")
        attachElementScreenshot(menu, named: "Mention menu showing recent mentions")
        // Moving the keyboard out of the composer closes the menu; typing there again reopens it.
        bubble.textViews.firstMatch.click()
        XCTAssertTrue(waitUntil({ !self.element("mention-menu").exists }, timeout: 5), "The menu closes when the composer loses focus.")
        composer.click()
        composer.typeText(XCUIKeyboardKey.delete.rawValue + "@")
        XCTAssertTrue(menu.waitToExist(timeout: 5), "Typing in the composer again reopens the menu.")
        composer.typeKey(.escape, modifierFlags: [])
        composer.typeText(XCUIKeyboardKey.delete.rawValue)

        // Steering a held Codex turn from the composer expands its mentions, Codex's agent file first.
        openTask(named: "Mention steer task")
        let steerComposer = element("message-composer")
        XCTAssertTrue(waitUntil({ steerComposer.exists && steerComposer.isHittable }, timeout: 15))
        steerComposer.click()
        steerComposer.typeText("Hold this turn for a steer.")
        element("send-message-button").click()
        let ready = URL(fileURLWithPath: codex.path + ".resolve-ready")
        let release = URL(fileURLWithPath: codex.path + ".resolve-continue")
        defer { try? Data("Release the active turn.\n".utf8).write(to: release) }
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: ready.path) }, timeout: 20), "The fixture holds the Codex turn.")
        // A steer that misses its turn is queued as typed; it is expanded only when it is sent.
        try "The expected turn ID is stale.\n".write(to: URL(fileURLWithPath: codex.path + ".reject-next-steer"), atomically: true, encoding: .utf8)
        let steerTaskID = try self.taskID(named: "Mention steer task")
        steerComposer.typeText("@helper later")
        XCTAssertTrue(waitUntil({ !self.element("mention-menu").exists }, timeout: 5), "The space after a mention closes the menu.")
        steerComposer.typeKey(.return, modifierFlags: .command)
        func queuedTexts() -> [String] {
            ((try? runCLI(["conversation", "queue-list", steerTaskID]))?["result"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        }
        XCTAssertTrue(waitUntil({ queuedTexts() == ["@helper later"] }, timeout: 10), "A missed steer is queued as typed, not expanded: \(queuedTexts())")
        let queuedID = try XCTUnwrap(((try runCLI(["conversation", "queue-list", steerTaskID]))["result"] as? [[String: Any]])?.first?["id"] as? String)
        let queuedText = element("queued-message-text-\(queuedID)")
        XCTAssertTrue(queuedText.waitToExist(timeout: 10))
        XCTAssertEqual(queuedText.value as? String, "@helper later", "The queued follow-up shows only the typed text.")
        _ = try runCLI(["conversation", "queue-remove", steerTaskID, queuedID])
        XCTAssertTrue(waitUntil({ (steerComposer.value as? String)?.isEmpty == true }, timeout: 10))
        steerComposer.click()
        steerComposer.typeText("Hurry, @rev")
        XCTAssertTrue(waitUntil({ self.element("mention-item-reviewer").exists }, timeout: 10))
        steerComposer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil({ (steerComposer.value as? String) == "Hurry, @reviewer " }, timeout: 5))
        steerComposer.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitUntil({ (steerComposer.value as? String)?.isEmpty == true }, timeout: 10), "The steer is accepted and clears the draft.")
        let steerBubbles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "user-message-", "Hurry, @reviewer"))
        XCTAssertTrue(steerBubbles.firstMatch.waitToExist(timeout: 10))
        // The provider echoes the steer with its mention block; it must still match the local copy.
        XCTAssertFalse(waitUntil({ steerBubbles.count > 1 }, timeout: 3), "The steer shows once: \(steerBubbles.count)")
        XCTAssertFalse(steerBubbles.firstMatch.label.contains("playhouse-mentions"), "The steered message hides its mention block.")
        try Data("Release the active turn.\n".utf8).write(to: release)
        func steerText() -> String? {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: codex.path + ".history")),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requests = history["steerRequests"] as? [[String: Any]], !requests.isEmpty else { return nil }
            return requests.flatMap { ($0["input"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.joined()
        }
        XCTAssertTrue(waitUntil({ steerText() != nil }, timeout: 20), "Codex receives the steer.")
        let steered = try XCTUnwrap(steerText())
        XCTAssertTrue(steered.hasPrefix("Hurry, @reviewer\n\n<playhouse-mentions>\n"), steered)
        XCTAssertEqual(steered.components(separatedBy: "<playhouse-mentions>").count, 2, "The steer is expanded exactly once.")
        let agentLine = try XCTUnwrap(steered.components(separatedBy: "\n").first { $0.hasPrefix("- @reviewer (agent): ") })
        XCTAssertLessThan(try XCTUnwrap(agentLine.range(of: "Codex agent `reviewer`")).lowerBound,
                          try XCTUnwrap(agentLine.range(of: "Claude Code subagent")).lowerBound, "A Codex task names Codex's agent file first.")

        XCTAssertEqual(try runCLI(["mentions", "list", "--task", UUID().uuidString], expectedStatus: 3)["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "not_found")
        XCTAssertEqual(try runCLI(["mentions", "list"], expectedStatus: 2)["error"].flatMap { ($0 as? [String: Any])?["code"] as? String }, "invalid_argument")
    }
    // case-contract: test_rules_catalog_lists_repo_global_and_managed_rules | The Skills page, titled Skills, Rules & MCP, switches to its Rules list with a Skills | Rules | MCP picker. Rules lists each task repository's instruction files from its worktree (AGENTS.override.md, AGENTS.md, CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md, and every .md file under .claude/rules, keyed by the source repository and the file's path), the user's global rules (~/.agents/AGENTS.md, Codex's AGENTS.md, and Claude's CLAUDE.md and rules folder), and the organization's managed CLAUDE.md. Each rule names the agents that follow it in Playhouse sessions and the ones that read it natively: a repository AGENTS.md beside a CLAUDE.md is followed by both but read natively only by Codex, ~/.agents/AGENTS.md is read natively by neither yet shared with both, a CLAUDE.md symlinked to AGENTS.md is one Linked rule read natively by both, AGENTS.override.md is Codex's own and leaves the AGENTS.md beside it to Claude, a .claude/rules file shows its paths globs, the managed CLAUDE.md is Claude's only and read-only, and an @import of a missing file is flagged as a problem. A repository without rules shows an empty state. Reading a rule returns its file exactly, and an unknown rule is not_found.
    func test_rules_catalog_lists_repo_global_and_managed_rules() throws {
        let working = try makeSkillRepository("rules-catalog-repo", skills: [
            "AGENTS.md": "# Repository conventions\nUse tabs.\n",
            "CLAUDE.md": "# Claude notes\n@docs/missing.md\n",
            ".claude/CLAUDE.md": "Claude folder notes.\n",
            "CLAUDE.local.md": "My sandbox URL.\n",
            ".claude/rules/api.md": "---\npaths:\n  - \"src/api/**\"\n---\n\n# API rules\nValidate input.\n",
            ".claude/rules/style/naming.md": "Name things plainly.\n",
        ])
        let linked = try makeSkillRepository("rules-linked-repo", skills: ["AGENTS.md": "# Linked rules\nShared by both.\n"], links: ["CLAUDE.md": "AGENTS.md"])
        let override = try makeSkillRepository("rules-override-repo", skills: ["AGENTS.md": "# Team rules\n", "AGENTS.override.md": "# Codex override\n"])
        let empty = try makeSkillRepository("rules-empty-repo", skills: [:])
        try writeRuleFile(skillsHome.appendingPathComponent(".agents/AGENTS.md"), "# Personal rules\nBe brief.\n")
        try writeRuleFile(skillsCodexHome.appendingPathComponent("AGENTS.md"), "# Codex home rules\n")
        try writeRuleFile(rulesClaudeConfig.appendingPathComponent("CLAUDE.md"), "# Claude home rules\n")
        try writeRuleFile(rulesClaudeConfig.appendingPathComponent("rules/global-style.md"), "Prefer small functions.\n")
        try writeRuleFile(rulesManaged.appendingPathComponent("CLAUDE.md"), "# Company policy\n")
        _ = try installSkillsClaudeFixture("claude-fixture-rules-catalog")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Rules catalog", repositories: [working, linked, override, empty])
        let taskID = try XCTUnwrap(task["id"] as? String)
        openTask(named: "Rules catalog")
        openRulesPage()

        for name in ["rules-catalog-repo", "rules-linked-repo", "rules-override-repo", "rules-empty-repo"] {
            XCTAssertTrue(element("rules-repo-section-\(name)").waitToExist(timeout: 10), "\(name) has a section.")
        }
        XCTAssertTrue(element("rules-empty-rules-empty-repo").exists, "A repository without rules shows an empty state.")
        for name in ["AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md", ".claude/rules/api.md", ".claude/rules/style/naming.md"] {
            XCTAssertTrue(element("rule-row-rules-catalog-repo:\(name)").exists, "\(name) is listed.")
        }
        let agents = "rules-catalog-repo:AGENTS.md"
        XCTAssertTrue(element("rule-provider-\(agents)-claude").exists && element("rule-provider-\(agents)-codex").exists,
                      "Both agents follow the repository's AGENTS.md.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-shared-\(agents)")), "Playhouse shares it with Claude.",
                       "Claude Code skips AGENTS.md beside a CLAUDE.md on its own, so Playhouse shares it.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-summary-\(agents)")), "Repository conventions")
        XCTAssertTrue(element("rule-problem-rules-catalog-repo:CLAUDE.md").exists, "An import of a missing file is a problem.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("rule-issue-rules-catalog-repo:CLAUDE.md")).contains("@docs/missing.md"))
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-paths-rules-catalog-repo:.claude/rules/api.md")), "src/api/**",
                       "A .claude/rules file shows its paths globs.")
        XCTAssertTrue(element("rule-linked-rules-linked-repo:AGENTS.md").exists, "A CLAUDE.md symlinked to AGENTS.md is one Linked rule.")
        XCTAssertFalse(element("rule-row-rules-linked-repo:CLAUDE.md").exists, "The symlink is not listed separately.")
        XCTAssertTrue(element("rule-provider-rules-override-repo:AGENTS.override.md-codex").exists)
        XCTAssertFalse(element("rule-provider-rules-override-repo:AGENTS.override.md-claude").exists, "AGENTS.override.md is Codex's own.")
        XCTAssertFalse(element("rule-provider-rules-override-repo:AGENTS.md-codex").exists, "Codex reads the override instead of AGENTS.md.")
        XCTAssertTrue(element("rule-provider-rules-override-repo:AGENTS.md-claude").exists, "The AGENTS.md beside the override is left to Claude.")
        attachScreenshot(named: "Rules tab lists each repository's rule files")
        let search = element("rules-search")
        typeIntoField(search, text: "CONVENTIONS")
        XCTAssertTrue(waitUntil({ !self.element("rule-row-rules-catalog-repo:CLAUDE.md").exists }, timeout: 5), "Search hides rules that don't match.")
        XCTAssertTrue(element("rule-row-\(agents)").exists, "Search keeps a rule whose summary matches, ignoring case.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("rules-empty-rules-linked-repo")), "No matching rules.",
                       "A repository with rules but no match shows its empty state.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("rules-empty-rules-empty-repo")), "No rules in rules-empty-repo.",
                       "A repository without rules still says so while searching.")
        attachScreenshot(named: "Rules search keeps the matching rule")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("naming")
        XCTAssertTrue(element("rule-row-rules-catalog-repo:.claude/rules/style/naming.md").waitToExist(timeout: 5), "Search matches a rule's path.")
        XCTAssertTrue(waitUntil({ !self.element("rule-row-\(agents)").exists }, timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-rule-matches-this")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("rules-empty-rules-catalog-repo")) == "No matching rules." }, timeout: 5),
                      "A search with no match shows its empty state.")
        attachScreenshot(named: "Rules search with no matching rule")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("rule-row-rules-catalog-repo:CLAUDE.md").waitToExist(timeout: 5), "Clearing the search shows every rule again.")
        XCTAssertFalse(element("rules-empty-rules-linked-repo").exists)

        selectSkillsTab("Global", picker: "rules-tab-picker")
        let shared = "~/.agents/AGENTS.md"
        XCTAssertTrue(element("rule-row-\(shared)").waitToExist(timeout: 5))
        typeIntoField(search, text: "personal")
        XCTAssertTrue(waitUntil({ !self.element("rule-row-~/.claude/CLAUDE.md").exists }, timeout: 5), "Search filters the Global tab too.")
        XCTAssertTrue(element("rule-row-\(shared)").exists, "The global rule whose summary matches stays.")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-rule-matches-this")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("rules-empty-global")) == "No matching rules." }, timeout: 5),
                      "A Global search with no match shows its empty state.")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("rule-row-~/.claude/CLAUDE.md").waitToExist(timeout: 5), "Clearing the search shows every global rule again.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-shared-\(shared)")), "Playhouse shares it with Claude and Codex.",
                       "Neither CLI reads ~/.agents/AGENTS.md on its own.")
        for name in ["~/.claude/CLAUDE.md", "~/.claude/rules/global-style.md"] {
            XCTAssertTrue(element("rule-row-\(name)").exists, "\(name) is a global rule.")
            XCTAssertTrue(element("rule-provider-\(name)-claude").exists && element("rule-provider-\(name)-codex").exists)
        }
        let codexName = realPath(skillsCodexHome.appendingPathComponent("AGENTS.md").path)
        XCTAssertTrue(element("rule-row-global:codex/AGENTS.md").exists, "Codex's global AGENTS.md is listed (\(codexName)).")
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-shared-global:codex/AGENTS.md")), "Playhouse shares it with Claude.")
        attachScreenshot(named: "Rules Global tab")

        selectSkillsTab("Managed", picker: "rules-tab-picker")
        let managed = realPath(rulesManaged.appendingPathComponent("CLAUDE.md").path)
        let managedRow = element("rule-row-managed:claude/CLAUDE.md")
        XCTAssertTrue(managedRow.waitToExist(timeout: 5), "The managed CLAUDE.md is listed (\(managed)).")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'rule-toggle-'")).firstMatch.exists,
                       "The managed CLAUDE.md can't be turned off.")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'rule-provider-' AND identifier ENDSWITH '-codex'")).firstMatch.exists,
                       "The managed CLAUDE.md is Claude's only.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'rule-provider-' AND identifier ENDSWITH '-claude'")).firstMatch.exists,
                      "Claude follows the managed CLAUDE.md.")
        attachScreenshot(named: "Rules Managed tab")

        let catalog = try ruleCatalog(taskID: taskID)
        let byID = rulesByID(catalog)
        XCTAssertEqual(byID["repo:\(working.path)#AGENTS.md"]?["nativeProviders"] as? [String], ["codex"])
        XCTAssertEqual(byID["global:agents/AGENTS.md"]?["nativeProviders"] as? [String], [])
        XCTAssertEqual(byID["global:agents/AGENTS.md"]?["providers"] as? [String], ["claude", "codex"])
        XCTAssertEqual(byID["repo:\(linked.path)#AGENTS.md"]?["availableOutsidePlayhouse"] as? Bool, true)
        XCTAssertEqual(byID["managed:claude/CLAUDE.md"]?["editable"] as? Bool, false)
        let detail = try XCTUnwrap(try runCLI(["rules", "get", "--task", taskID, "--rule", "repo:\(working.path)#AGENTS.md"])["result"] as? [String: Any])
        XCTAssertEqual(detail["content"] as? String, "# Repository conventions\nUse tabs.\n")
        assertCLIError(try runCLI(["rules", "get", "--task", taskID, "--rule", "global:no-such-rule"], expectedStatus: 3), code: "not_found")

        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 5), "Back returns to the conversation.")
    }
    // case-contract: test_rules_create_update_and_delete_on_disk | New Rule writes the shared AGENTS.md (the chosen task worktree's, or ~/.agents/AGENTS.md for a global rule) or, given a name, a topic file in .claude/rules (the worktree's, or Claude's global rules folder) whose paths frontmatter lists the globs given; empty instructions, an invalid name, globs without a name, the managed scope, and an existing file are rejected with nothing written, and the source checkout is left alone. Clicking a rule opens its editor on the whole file with a Markdown preview, and saving writes the file exactly as typed; empty instructions and a rules-folder file whose frontmatter never closes are rejected while keeping the file. The managed CLAUDE.md opens read-only without Save and can be neither edited nor deleted. Deleting a rule removes its file from disk, and every change is visible to a fresh CLI process and on the page.
    func test_rules_create_update_and_delete_on_disk() throws {
        let repository = try makeSkillRepository("rules-manage-repo", skills: [:])
        try writeRuleFile(rulesManaged.appendingPathComponent("CLAUDE.md"), "# Company policy\n")
        _ = try installSkillsClaudeFixture("claude-fixture-rules-manage")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Rules manage", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        let sharedFile = skillsHome.appendingPathComponent(".agents/AGENTS.md")
        openTask(named: "Rules manage")
        openRulesPage()

        XCTAssertTrue(openPanel("new-rule-panel", with: element("new-rule-button")), "New Rule opens its panel.")
        element("new-rule-create").click()
        XCTAssertTrue(element("new-rule-error").waitToExist(timeout: 5), "Empty instructions are rejected in the panel.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedFile.path), "A rejected rule writes nothing.")
        attachScreenshot(named: "New Rule rejects empty instructions")
        typeIntoField(element("new-rule-body"), text: "Answer briefly.")
        element("new-rule-create").click()
        XCTAssertTrue(waitUntil({ !self.element("new-rule-panel").exists }, timeout: 10), "Creating closes the panel.")
        XCTAssertTrue(element("rule-row-~/.agents/AGENTS.md").waitToExist(timeout: 10), "The new global rule shows on the Global tab.")
        XCTAssertEqual(try String(contentsOf: sharedFile, encoding: .utf8), "Answer briefly.\n", "A global rule is ~/.agents/AGENTS.md.")

        typeIntoField(element("rules-search"), text: "no-rule-matches-this")
        XCTAssertTrue(waitUntil({ !self.element("rule-row-~/.agents/AGENTS.md").exists }, timeout: 5))
        XCTAssertTrue(openPanel("new-rule-panel", with: element("new-rule-button")))
        element("new-rule-scope").click()
        XCTAssertTrue(app.menuItems["rules-manage-repo"].waitToExist(timeout: 5))
        app.menuItems["rules-manage-repo"].click()
        XCTAssertFalse(element("new-rule-name").exists, "Shared instructions need no name.")
        typeIntoField(element("new-rule-body"), text: "Run the linter.")
        element("new-rule-create").click()
        XCTAssertTrue(waitUntil({ !self.element("new-rule-panel").exists }, timeout: 10))
        XCTAssertTrue(element("rule-row-rules-manage-repo:AGENTS.md").waitToExist(timeout: 10),
                      "The repository's AGENTS.md shows on the Repo tab: creating a rule clears a search that would hide it.")
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("AGENTS.md"), encoding: .utf8), "Run the linter.\n",
                       "Shared instructions in a repository are its worktree's AGENTS.md.")

        XCTAssertTrue(openPanel("new-rule-panel", with: element("new-rule-button")))
        selectSkillsTab("Topic rule", picker: "new-rule-form")
        let scope = element("new-rule-scope")
        scope.click()
        let repoItem = app.menuItems["rules-manage-repo"]
        XCTAssertTrue(repoItem.waitToExist(timeout: 5), "New Rule can save into the task's repository.")
        repoItem.click()
        typeIntoField(element("new-rule-name"), text: "api-style")
        typeIntoField(element("new-rule-paths"), text: "src/**/*.ts, lib/**")
        typeIntoField(element("new-rule-body"), text: "Validate every input.")
        attachScreenshot(named: "New Rule panel for a path-scoped topic rule")
        element("new-rule-create").click()
        XCTAssertTrue(waitUntil({ !self.element("new-rule-panel").exists }, timeout: 10))
        let topicKey = "rules-manage-repo:.claude/rules/api-style.md"
        XCTAssertTrue(element("rule-row-\(topicKey)").waitToExist(timeout: 10), "The topic rule shows on the Repo tab.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-paths-\(topicKey)")), "src/**/*.ts, lib/**")
        attachScreenshot(named: "A new path-scoped topic rule shows its globs")
        let topicFile = worktree.appendingPathComponent(".claude/rules/api-style.md")
        XCTAssertEqual(try String(contentsOf: topicFile, encoding: .utf8), "---\npaths:\n  - \"src/**/*.ts\"\n  - \"lib/**\"\n---\n\nValidate every input.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".claude").path), "The source checkout is left alone.")

        XCTAssertTrue(openPanel("new-rule-panel", with: element("new-rule-button")))
        selectSkillsTab("Topic rule", picker: "new-rule-form")
        typeIntoField(element("new-rule-name"), text: "global-topic")
        typeIntoField(element("new-rule-body"), text: "Global topic.")
        element("new-rule-create").click()
        XCTAssertTrue(waitUntil({ !self.element("new-rule-panel").exists }, timeout: 10))
        XCTAssertTrue(element("rule-row-~/.claude/rules/global-topic.md").waitToExist(timeout: 10), "A global topic rule shows on the Global tab.")
        XCTAssertEqual(try String(contentsOf: rulesClaudeConfig.appendingPathComponent("rules/global-topic.md"), encoding: .utf8), "Global topic.\n",
                       "A named global rule goes in Claude's rules folder.")
        XCTAssertFalse(element("rule-paths-~/.claude/rules/global-topic.md").exists, "A topic rule without globs always loads.")
        selectSkillsTab("Repo", picker: "rules-tab-picker")
        for arguments in [
            ["--scope", "repo", "--root", repository.path, "--name", "Bad Name", "--body", "Text."],
            ["--scope", "repo", "--root", repository.path, "--path", "src/**", "--body", "Scoped without a name."],
            ["--scope", "managed", "--body", "Not allowed."],
        ] {
            assertCLIError(try runCLI(["rules", "create", "--task", taskID] + arguments, expectedStatus: 2), code: "invalid_argument")
        }
        assertCLIError(try runCLI(["rules", "create", "--task", taskID, "--scope", "global", "--body", "Again."], expectedStatus: 1), code: "already_exists")
        XCTAssertEqual(try String(contentsOf: sharedFile, encoding: .utf8), "Answer briefly.\n", "An existing rule file is left alone.")

        selectSkillsTab("Global", picker: "rules-tab-picker")
        XCTAssertTrue(openPanel("rule-editor-panel", with: element("rule-row-~/.agents/AGENTS.md")), "Clicking a rule opens its editor.")
        let editor = element("rule-editor")
        XCTAssertEqual(editor.value as? String, "Answer briefly.\n", "The editor opens the whole file.")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("  \n")
        element("rule-editor-save").click()
        XCTAssertTrue(element("rule-editor-error").waitToExist(timeout: 5), "Empty instructions are rejected in the editor.")
        XCTAssertEqual(try String(contentsOf: sharedFile, encoding: .utf8), "Answer briefly.\n", "A rejected edit keeps the file.")
        let edited = "# Personal rules\n\n- Answer briefly.\n- Cite files.\n"
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(edited)
        selectSkillsTab("Preview", picker: "rule-editor-tab-picker")
        XCTAssertTrue(waitUntil({ self.element("rule-editor-preview").staticTexts["Personal rules"].exists }, timeout: 5), "The preview renders the heading.")
        attachScreenshot(named: "Rule editor previews the edited Markdown")
        element("rule-editor-save").click()
        XCTAssertTrue(waitUntil({ !self.element("rule-editor-panel").exists }, timeout: 10), "Saving closes the editor.")
        XCTAssertEqual(try String(contentsOf: sharedFile, encoding: .utf8), edited, "Saving writes the file exactly as typed.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("rule-summary-~/.agents/AGENTS.md")) == "Personal rules" }, timeout: 10))
        let unclosed = dataDirectory.appendingPathComponent("rule-unclosed.md")
        try "---\npaths:\n  - src/**\nNo closing line.\n".write(to: unclosed, atomically: true, encoding: .utf8)
        assertCLIError(try runCLI(["rules", "update", "--task", taskID, "--rule", "repo:\(repository.path)#.claude/rules/api-style.md", "--content-file", unclosed.path], expectedStatus: 2), code: "invalid_argument")
        XCTAssertTrue(try String(contentsOf: topicFile, encoding: .utf8).contains("Validate every input."), "A rejected edit keeps the file.")

        selectSkillsTab("Managed", picker: "rules-tab-picker")
        let managedRow = element("rule-row-managed:claude/CLAUDE.md")
        XCTAssertTrue(managedRow.waitToExist(timeout: 5))
        XCTAssertTrue(openPanel("rule-editor-panel", with: managedRow), "The managed CLAUDE.md opens to read.")
        XCTAssertFalse(element("rule-editor-save").exists, "The managed CLAUDE.md opens read-only, without Save.")
        let managedEditor = element("rule-editor")
        managedEditor.click()
        managedEditor.typeText("Typed into a read-only file.")
        XCTAssertEqual(managedEditor.value as? String, "# Company policy\n", "The managed CLAUDE.md can't be edited.")
        attachScreenshot(named: "The managed CLAUDE.md opens read-only")
        element("rule-editor-cancel").click()
        XCTAssertTrue(waitUntil({ !self.element("rule-editor-panel").exists }, timeout: 5))
        let managedKey = "managed:claude/CLAUDE.md"
        openRuleActions(managedKey)
        XCTAssertFalse(app.menuItems["Delete…"].exists || app.menuItems.matching(identifier: "rule-delete-\(managedKey)").firstMatch.exists,
                       "The managed CLAUDE.md offers no Delete.")
        XCTAssertFalse(app.menuItems["Make Available Outside Playhouse…"].exists, "The managed CLAUDE.md offers no link.")
        app.typeKey(.escape, modifierFlags: [])
        assertCLIError(try runCLI(["rules", "delete", "--task", taskID, "--rule", "managed:claude/CLAUDE.md"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try String(contentsOf: rulesManaged.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "# Company policy\n")

        selectSkillsTab("Repo", picker: "rules-tab-picker")
        clickRuleMenuItem(rule: topicKey, item: "rule-delete-\(topicKey)", title: "Delete…")
        clickDialogButton("confirm-delete-rule", title: "Delete")
        XCTAssertTrue(waitUntil({ !self.element("rule-row-\(topicKey)").exists }, timeout: 10), "Deleting removes the rule from the page.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: topicFile.path), "Deleting removes the rule file from disk.")
        XCTAssertTrue(element("rule-row-rules-manage-repo:AGENTS.md").exists, "Other rules stay.")
        let fresh = rulesByID(try ruleCatalog(taskID: taskID))
        XCTAssertNil(fresh["repo:\(repository.path)#.claude/rules/api-style.md"])
        XCTAssertNotNil(fresh["global:agents/AGENTS.md"])
    }
    // case-contract: test_rules_enable_state_and_outside_links_persist | A lone AGENTS.md that both CLIs already read on their own shows Both CLIs rather than Linked, since nothing links to it. Turning a rule off is stored by Playhouse rather than in either provider's settings, survives fresh CLI processes and reopening the page, and can be turned back on; the managed CLAUDE.md can't be turned off. A turned-off rule Codex reads itself, such as the working repository's AGENTS.md, still lists Codex and the page says Codex still reads it, while a rule only Playhouse shares, such as ~/.agents/AGENTS.md, reaches neither agent. Making ~/.agents/AGENTS.md available outside Playhouse writes absolute symlinks as Codex's AGENTS.md and Claude's CLAUDE.md, after which it is one Linked rule read natively by both; a repository CLAUDE.md gets a relative AGENTS.md symlink beside it. An existing file at a link path is left untouched and the request fails with already_exists without writing any link, a rule Codex has no place for can't be linked, and removing the outside link deletes only the symlinks.
    func test_rules_enable_state_and_outside_links_persist() throws {
        let working = try makeSkillRepository("rules-link-repo", skills: ["AGENTS.md": "# Working rules\n"])
        let other = try makeSkillRepository("rules-link-claude-repo", skills: ["CLAUDE.md": "# Claude-only rules\n", ".claude/rules/topic.md": "A topic rule.\n"])
        let sharedFile = skillsHome.appendingPathComponent(".agents/AGENTS.md")
        try writeRuleFile(sharedFile, "# Personal rules\n")
        try writeRuleFile(rulesManaged.appendingPathComponent("CLAUDE.md"), "# Company policy\n")
        let claudeFile = rulesClaudeConfig.appendingPathComponent("CLAUDE.md")
        try writeRuleFile(claudeFile, "Mine, in the way.\n")
        _ = try installSkillsClaudeFixture("claude-fixture-rules-link")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Rules links", repositories: [working, other])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let otherWorktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first { $0["repositoryPath"] as? String == other.path }?["worktreePath"] as? String))
        func rule(_ id: String) throws -> [String: Any]? { rulesByID(try ruleCatalog(taskID: taskID))[id] }
        openTask(named: "Rules links")
        openRulesPage()

        let agents = "rules-link-repo:AGENTS.md"
        let toggle = element("rule-toggle-\(agents)")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(element("rule-native-\(agents)").exists, "An AGENTS.md with no CLAUDE.md beside it is read by both CLIs on their own.")
        XCTAssertFalse(element("rule-linked-\(agents)").exists, "A file nothing links to is not shown as Linked.")
        XCTAssertTrue(isOn(toggle))
        toggle.click()
        XCTAssertTrue(waitUntil({ !self.isOn(toggle) }, timeout: 0.75), "The switch flips as soon as it is clicked.")
        XCTAssertTrue(waitUntil({ ((try? rule("repo:\(working.path)#AGENTS.md"))??["enabled"] as? Bool) == false }, timeout: 10),
                      "Turning a rule off is saved where a fresh CLI process reads it.")
        XCTAssertTrue(element("rule-always-on-\(agents)").waitToExist(timeout: 5), "The page says Codex still reads the file itself.")
        XCTAssertTrue(element("rule-provider-\(agents)-codex").exists)
        XCTAssertFalse(element("rule-provider-\(agents)-claude").exists, "Turning it off stops Claude following it.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsCodexHome.appendingPathComponent("config.toml").path), "Codex's config is not written.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulesClaudeConfig.appendingPathComponent("settings.json").path), "Claude's settings are not written.")
        attachScreenshot(named: "A rule Codex reads itself, turned off")
        element("skills-back-button").click()
        openRulesPage()
        XCTAssertTrue(waitUntil({ self.element("rule-toggle-\(agents)").exists && !self.isOn(self.element("rule-toggle-\(agents)")) }, timeout: 10),
                      "The off state survives reopening the page.")
        element("rule-toggle-\(agents)").click()
        XCTAssertTrue(waitUntil({ ((try? rule("repo:\(working.path)#AGENTS.md"))??["enabled"] as? Bool) == true }, timeout: 10))

        selectSkillsTab("Global", picker: "rules-tab-picker")
        let shared = "~/.agents/AGENTS.md"
        XCTAssertTrue(element("rule-toggle-\(shared)").waitToExist(timeout: 5))
        element("rule-toggle-\(shared)").click()
        XCTAssertTrue(waitUntil({ !self.element("rule-provider-\(shared)-claude").exists && !self.element("rule-provider-\(shared)-codex").exists }, timeout: 10),
                      "A rule only Playhouse shares reaches neither agent once off.")
        XCTAssertFalse(element("rule-always-on-\(shared)").exists)
        element("rule-toggle-\(shared)").click()
        XCTAssertTrue(waitUntil({ self.element("rule-provider-\(shared)-codex").exists }, timeout: 10))
        assertCLIError(try runCLI(["rules", "disable", "--task", taskID, "--rule", "managed:claude/CLAUDE.md"], expectedStatus: 2), code: "invalid_argument")

        clickRuleMenuItem(rule: shared, item: "rule-link-\(shared)", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-rule", title: "Create Link")
        XCTAssertTrue(element("rules-error").waitToExist(timeout: 10), "A link onto an existing file shows an error.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("rules-error")).contains("already exists"))
        attachScreenshot(named: "A blocked outside link shows its error")
        XCTAssertEqual(try String(contentsOf: claudeFile, encoding: .utf8), "Mine, in the way.\n", "An existing file is left untouched.")
        let codexLink = skillsCodexHome.appendingPathComponent("AGENTS.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: codexLink.path), "A blocked link writes no link at all.")
        _ = try runCLI(["rules", "delete", "--task", taskID, "--rule", "global:claude/CLAUDE.md"])

        clickRuleMenuItem(rule: shared, item: "rule-link-\(shared)", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-rule", title: "Create Link")
        XCTAssertTrue(element("rule-linked-\(shared)").waitToExist(timeout: 10), "A linked rule shows as Linked.")
        for link in [codexLink, claudeFile] {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
            XCTAssertTrue(destination.hasPrefix("/"), "A global link is absolute.")
            XCTAssertEqual(realPath(destination), realPath(sharedFile.path))
        }
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'rule-row-'")).count, 1,
                       "The linked files are one rule.")
        XCTAssertFalse(element("rule-shared-\(shared)").exists, "Both CLIs read the linked rule natively, so Playhouse no longer shares it.")
        attachScreenshot(named: "~/.agents/AGENTS.md linked for both CLIs")

        selectSkillsTab("Repo", picker: "rules-tab-picker")
        let otherClaude = "rules-link-claude-repo:CLAUDE.md"
        clickRuleMenuItem(rule: otherClaude, item: "rule-link-\(otherClaude)", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-rule", title: "Create Link")
        XCTAssertTrue(element("rule-linked-\(otherClaude)").waitToExist(timeout: 10))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: otherWorktree.appendingPathComponent("AGENTS.md").path), "CLAUDE.md",
                       "A repository link is relative, so it can be committed.")
        attachScreenshot(named: "A repository CLAUDE.md linked as AGENTS.md")
        let topic = "rules-link-claude-repo:.claude/rules/topic.md"
        openRuleActions(topic)
        XCTAssertFalse(app.menuItems["Make Available Outside Playhouse…"].exists || app.menuItems.matching(identifier: "rule-link-\(topic)").firstMatch.exists,
                       "A rule Codex has no place for offers no link.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherWorktree.appendingPathComponent(".agents").path), "No link is written for it.")
        assertCLIError(try runCLI(["rules", "link", "--task", taskID, "--rule", "repo:\(other.path)#.claude/rules/topic.md"], expectedStatus: 2), code: "invalid_argument")

        selectSkillsTab("Global", picker: "rules-tab-picker")
        clickRuleMenuItem(rule: shared, item: "rule-unlink-\(shared)", title: "Remove Outside Link")
        XCTAssertTrue(waitUntil({ !self.element("rule-linked-\(shared)").exists }, timeout: 10))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: codexLink.path), "Removing the outside link deletes the symlinks.")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: claudeFile.path))
        XCTAssertEqual(try String(contentsOf: sharedFile, encoding: .utf8), "# Personal rules\n", "The rule itself stays.")
        assertCLIError(try runCLI(["rules", "unlink", "--task", taskID, "--rule", "global:agents/AGENTS.md"], expectedStatus: 2), code: "invalid_argument")
    }
    // case-contract: test_rules_fix_with_agent_starts_task_for_problem_rules | A rule with a problem offers Fix with Agent, which creates a task on the source task's provider whose saved prompt explains how both agents read rules and lists each rule with its problem: repository rules by repository-relative path, to be fixed in the new task's own worktree and committed and pushed, and global rules by absolute path, to be fixed in place with their folder opened as a context folder, and fixing only global rules needs no repository. The view switches to the new task's conversation, which sends that prompt once and leaves no unsent draft. A rule with no problem, the managed rule, an unknown rule, and a request without a task are rejected without opening a task.
    func test_rules_fix_with_agent_starts_task_for_problem_rules() throws {
        let repository = try makeSkillRepository("rules-fix-repo", skills: ["AGENTS.md": "# Fine rules\n", "CLAUDE.md": "# Claude notes\n@docs/missing.md\n"])
        let broken = rulesClaudeConfig.appendingPathComponent("rules/broken.md")
        try writeRuleFile(broken, "---\npaths:\n  - src/**\nThe frontmatter never closes.\n")
        try writeRuleFile(rulesManaged.appendingPathComponent("CLAUDE.md"), "# Company policy\n")
        let executable = try installSkillsClaudeFixture("claude-fixture-rules-fix")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        launchApp(defaultParent: fixture.parent.path)
        let source = try createSkillsTask("Rules fix source", repositories: [repository], provider: "claude")
        let sourceID = try XCTUnwrap(source["id"] as? String)
        let sourceWorktree = try XCTUnwrap((source["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
        let tasksBefore = try boardTaskRecords().count
        assertCLIError(try runCLI(["rules", "fix", "--task", sourceID, "--rule", "repo:\(repository.path)#AGENTS.md"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["rules", "fix", "--task", sourceID, "--rule", "managed:claude/CLAUDE.md"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["rules", "fix", "--task", sourceID, "--rule", "global:no-such-rule"], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["rules", "fix", "--rule", "global:claude/rules/broken.md"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try boardTaskRecords().count, tasksBefore, "A rejected fix opens no task.")

        openTask(named: "Rules fix source")
        openRulesPage()
        XCTAssertTrue(element("rule-fix-rules-fix-repo:CLAUDE.md").waitToExist(timeout: 10), "A rule with a problem offers Fix with Agent.")
        XCTAssertFalse(element("rule-fix-rules-fix-repo:AGENTS.md").exists, "A rule without a problem has nothing to fix.")
        selectSkillsTab("Global", picker: "rules-tab-picker")
        XCTAssertTrue(element("rule-fix-~/.claude/rules/broken.md").waitToExist(timeout: 5))
        attachScreenshot(named: "A broken global rule offers Fix with Agent")

        element("rule-fix-~/.claude/rules/broken.md").click()
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 10), "Fixing closes the page.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Fix rule ~/.claude/rules/broken.md" }, timeout: 15),
                      "The view switches to the fixing task's conversation.")
        let single = try XCTUnwrap(try boardTaskRecords().first { $0["title"] as? String == "Fix rule ~/.claude/rules/broken.md" })
        XCTAssertEqual((single["repositoryWorktrees"] as? [Any])?.count, 0, "Fixing only global rules needs no repository.")
        XCTAssertEqual(((single["contextFolders"] as? [String]) ?? []).map(realPath), [realPath(broken.deletingLastPathComponent().path)],
                       "The global rule's folder is opened to the agent.")
        let singlePrompt = try XCTUnwrap(single["savedPrompt"] as? String)
        XCTAssertTrue(singlePrompt.contains("not tracked by Git"))
        XCTAssertTrue(singlePrompt.contains(broken.path) || singlePrompt.contains(realPath(broken.path)), "A global rule is named by its absolute path.")
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == singlePrompt } }, timeout: 20),
                      "The fixing task sends its prompt as soon as it opens.")

        openTask(named: "Rules fix source")
        openRulesPage()
        XCTAssertTrue(element("rule-fix-rules-fix-repo:CLAUDE.md").waitToExist(timeout: 10))
        element("rule-fix-rules-fix-repo:CLAUDE.md").click()
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Fix rule CLAUDE.md" }, timeout: 15))
        let fixing = try XCTUnwrap(try boardTaskRecords().first { $0["title"] as? String == "Fix rule CLAUDE.md" })
        let fixingID = try XCTUnwrap(fixing["id"] as? String)
        let prompt = try XCTUnwrap(fixing["savedPrompt"] as? String)
        XCTAssertEqual(fixing["conversationProvider"] as? String, "claude", "The fixing task uses the source task's provider.")
        XCTAssertTrue(prompt.contains("Codex reads AGENTS.md"), "The prompt explains how both agents read rules.")
        XCTAssertTrue(prompt.contains("commit and push"))
        XCTAssertTrue(prompt.contains("`CLAUDE.md` in rules-fix-repo"))
        XCTAssertTrue(prompt.contains("@docs/missing.md"))
        XCTAssertFalse(prompt.contains(sourceWorktree), "Repository paths are relative, so they point into the fixing task's worktree.")
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == prompt } }, timeout: 20), "The conversation sends the fixing prompt.")
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String ?? "").isEmpty }, timeout: 10),
                      "The sent prompt leaves the composer, so it cannot be sent twice.")
        attachScreenshot(named: "The rule-fixing task's conversation")
        XCTAssertEqual(claudeTurns(historyURL).filter { $0["userText"] as? String == prompt }.count, 1, "The fixing prompt is sent exactly once.")
        let started = try XCTUnwrap(try taskRecord(id: fixingID))
        XCTAssertEqual(started["hasUnsentDraft"] as? Bool, false)
        let worktree = try XCTUnwrap((started["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(worktree["repositoryPath"] as? String, repository.path)
        let turn = try XCTUnwrap(claudeTurns(historyURL).first { $0["userText"] as? String == prompt })
        XCTAssertEqual(realPath(turn["cwd"] as? String ?? ""), realPath(worktree["worktreePath"] as? String ?? ""), "The turn runs in the fixing task's worktree.")
        XCTAssertNotEqual(realPath(worktree["worktreePath"] as? String ?? ""), realPath(sourceWorktree))
    }
    // case-contract: test_rules_bridge_claude_launch_follows_shared_rules | A Claude turn follows the rules Claude Code does not read itself: after the task instructions, its appended system prompt carries ~/.agents/AGENTS.md with its @import of another file expanded inline, Codex's global AGENTS.md, and the AGENTS.md of the task's other repository, plus a pointer naming the globs and file of that repository's path-scoped rule; rules Claude reads itself, such as Claude's global CLAUDE.md and the working repository's CLAUDE.md and AGENTS.md, are not repeated. Because the working repository has both AGENTS.md and CLAUDE.md, --settings tells Claude Code to read both, and a rule turned off on the page is excluded for that run with claudeMdExcludes, without writing to the repository or Claude's settings. The resumed second turn carries the same rules, and turning the rule back on drops the exclusion.
    func test_rules_bridge_claude_launch_follows_shared_rules() throws {
        let repository = try makeSkillRepository("rules-claude-repo", skills: [
            "AGENTS.md": "# Repo agents\nRepo AGENTS text.\n",
            "CLAUDE.md": "# Claude repo notes\nClaude repo text.\n",
            "CLAUDE.local.md": "Local text turned off.\n",
        ])
        let extra = try makeSkillRepository("rules-claude-extra", skills: [
            "AGENTS.md": "Extra repo agents text.\n",
            ".claude/rules/extra.md": "---\npaths:\n  - \"lib/**\"\n---\n\nExtra scoped text.\n",
        ])
        try writeRuleFile(skillsHome.appendingPathComponent(".agents/AGENTS.md"), "# Personal rules\nShared global text.\n@~/notes/imported.md\n")
        try writeRuleFile(skillsHome.appendingPathComponent("notes/imported.md"), "Imported text.\n")
        try writeRuleFile(skillsCodexHome.appendingPathComponent("AGENTS.md"), "Codex global text.\n")
        try writeRuleFile(rulesClaudeConfig.appendingPathComponent("CLAUDE.md"), "Claude global text.\n")
        let executable = try installSkillsClaudeFixture("claude-fixture-rules-bridge")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Claude rules", repositories: [repository, extra], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        let records = try XCTUnwrap(task["repositoryWorktrees"] as? [[String: Any]])
        let worktree = URL(fileURLWithPath: try XCTUnwrap(records.first { $0["repositoryPath"] as? String == repository.path }?["worktreePath"] as? String))
        let extraWorktree = URL(fileURLWithPath: try XCTUnwrap(records.first { $0["repositoryPath"] as? String == extra.path }?["worktreePath"] as? String))
        openTask(named: "Claude rules")
        openRulesPage()
        let local = "rules-claude-repo:CLAUDE.local.md"
        XCTAssertTrue(element("rule-toggle-\(local)").waitToExist(timeout: 10))
        element("rule-toggle-\(local)").click()
        XCTAssertTrue(waitUntil({ !self.isOn(self.element("rule-toggle-\(local)")) }, timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-shared-rules-claude-extra:AGENTS.md")), "Playhouse shares it with Claude and Codex.",
                       "Neither agent loads another task repository's rules on its own.")
        attachScreenshot(named: "Rules a Claude turn will follow, with one turned off")
        element("skills-back-button").click()
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Follow the rules.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == "Follow the rules." } }, timeout: 20))
        let first = try XCTUnwrap(claudeTurns(historyURL).first { $0["userText"] as? String == "Follow the rules." })
        let arguments = try XCTUnwrap(first["arguments"] as? [String])
        let prompt = arguments[try XCTUnwrap(arguments.firstIndex(of: "--append-system-prompt")) + 1]
        for text in ["Shared global text.", "Imported text.", "Codex global text.", "Extra repo agents text.", "`lib/**` in rules-claude-extra:"] {
            XCTAssertTrue(prompt.contains(text), "\(text) reaches Claude through the system prompt.")
        }
        let extraRule = extraWorktree.appendingPathComponent(".claude/rules/extra.md").path
        XCTAssertTrue(prompt.contains(extraRule) || prompt.contains(realPath(extraRule)), "The pointer names the path-scoped rule's file.")
        for text in ["Extra scoped text.", "Claude global text.", "Claude repo text.", "Repo AGENTS text.", "Local text turned off.", "@~/notes/imported.md"] {
            XCTAssertFalse(prompt.contains(text), "\(text) should not be added to Claude's system prompt.")
        }
        XCTAssertGreaterThan(try XCTUnwrap(prompt.range(of: "# Rules Playhouse shares with you")).lowerBound, prompt.startIndex, "Rules follow the task instructions.")
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(arguments[try XCTUnwrap(arguments.firstIndex(of: "--settings")) + 1].utf8)) as? [String: Any])
        XCTAssertEqual(Set(((settings["claudeMdExcludes"] as? [String]) ?? []).map(realPath)), [realPath(worktree.appendingPathComponent("CLAUDE.local.md").path)],
                       "The turned-off rule is excluded for this run.")
        let plugin = ((settings["pluginConfigs"] as? [String: Any])?["cc-plugin-agents-md@builtin"] as? [String: Any])?["options"] as? [String: String]
        XCTAssertEqual(plugin, ["instructionFiles": "claude-md-and-agents-md"], "Claude Code reads AGENTS.md alongside CLAUDE.md.")
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "The worktree is not written to.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulesClaudeConfig.appendingPathComponent("settings.json").path), "Claude's settings are not written.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } == true }, timeout: 30),
                      "The first turn should settle before the next message.")

        openRulesPage()
        element("rule-toggle-\(local)").click()
        XCTAssertTrue(waitUntil({ self.isOn(self.element("rule-toggle-\(local)")) }, timeout: 10))
        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Follow them again.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == "Follow them again." } }, timeout: 20))
        let second = try XCTUnwrap(claudeTurns(historyURL).last { $0["userText"] as? String == "Follow them again." })
        XCTAssertEqual(second["resumed"] as? Bool, true, "The second turn resumes the Claude session.")
        let resumed = try XCTUnwrap(second["arguments"] as? [String])
        XCTAssertTrue(resumed[try XCTUnwrap(resumed.firstIndex(of: "--append-system-prompt")) + 1].contains("Shared global text."), "A resumed turn carries the same rules.")
        let resumedSettings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(resumed[try XCTUnwrap(resumed.firstIndex(of: "--settings")) + 1].utf8)) as? [String: Any])
        XCTAssertNil(resumedSettings["claudeMdExcludes"], "Turning the rule back on drops the exclusion.")
    }
    // case-contract: test_rules_bridge_codex_thread_follows_claude_rules | A Codex turn follows the rules Codex does not read itself: after the task instructions, the thread starts with developer instructions carrying ~/.agents/AGENTS.md, Claude's global CLAUDE.md, and the working repository's CLAUDE.md and always-on .claude/rules files, with CLAUDE.md's @AGENTS.md import left out because Codex already reads that file, and each path-scoped rule as a pointer naming its globs and file rather than its text. The working repository's AGENTS.md and Codex's global AGENTS.md are not repeated, a rule turned off on the page is left out, and Codex's config.toml is not written. A thread resumed on a fresh app-server gets the same rules.
    func test_rules_bridge_codex_thread_follows_claude_rules() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let historyURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        let repository = try makeSkillRepository("rules-codex-repo", skills: [
            "AGENTS.md": "Repo AGENTS text for Codex.\n",
            "CLAUDE.md": "# Claude repo notes\n@AGENTS.md\nClaude repo text for Codex.\n",
            ".claude/rules/testing.md": "Always run tests.\n",
            ".claude/rules/api.md": "---\npaths:\n  - \"src/api/**\"\n---\n\nAPI rule text.\n",
            ".claude/rules/off.md": "Turned off text.\n",
        ])
        try writeRuleFile(skillsHome.appendingPathComponent(".agents/AGENTS.md"), "Shared global text for Codex.\n")
        try writeRuleFile(rulesClaudeConfig.appendingPathComponent("CLAUDE.md"), "Claude global text for Codex.\n")
        try writeRuleFile(skillsCodexHome.appendingPathComponent("AGENTS.md"), "Codex global native text.\n")
        _ = try installSkillsClaudeFixture("claude-fixture-rules-codex")
        // Its own daemon, so restarting it below leaves the UI runner's shared one alone.
        let daemonEnvironment = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).rules-codex-\(UUID().uuidString.prefix(8))"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: daemonEnvironment)
        let task = try createSkillsTask("Codex rules", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        func history() -> [String: Any] {
            guard let data = try? Data(contentsOf: historyURL) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        func answerQuestionIfAsked() {
            guard element("ai-question-form-title").waitToExist(timeout: 10) else { return }
            selectQuestionOption("Blue")
            typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
            element("submit-ai-answers-button").click()
        }

        openTask(named: "Codex rules")
        openRulesPage()
        let off = "rules-codex-repo:.claude/rules/off.md"
        XCTAssertTrue(element("rule-toggle-\(off)").waitToExist(timeout: 10))
        element("rule-toggle-\(off)").click()
        XCTAssertTrue(waitUntil({ !self.isOn(self.element("rule-toggle-\(off)")) }, timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: element("rule-shared-rules-codex-repo:CLAUDE.md")), "Playhouse shares it with Codex.",
                       "Codex doesn't read CLAUDE.md on its own, so Playhouse shares it.")
        attachScreenshot(named: "Rules a Codex turn will follow, with one turned off")
        element("skills-back-button").click()
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Follow the rules.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "Follow the rules." }, timeout: 20))
        let instructions = try XCTUnwrap(history()["threadStartDeveloperInstructions"] as? String)
        for text in ["Shared global text for Codex.", "Claude global text for Codex.", "Claude repo text for Codex.", "Always run tests.", "`src/api/**` in rules-codex-repo:"] {
            XCTAssertTrue(instructions.contains(text), "\(text) reaches Codex through the thread's developer instructions.")
        }
        let apiRule = worktree.appendingPathComponent(".claude/rules/api.md").path
        XCTAssertTrue(instructions.contains(apiRule) || instructions.contains(realPath(apiRule)), "The pointer names the path-scoped rule's file.")
        for text in ["API rule text.", "Repo AGENTS text for Codex.", "Codex global native text.", "Turned off text.", "@AGENTS.md"] {
            XCTAssertFalse(instructions.contains(text), "\(text) should not be added to Codex's instructions.")
        }
        let rulesStart = try XCTUnwrap(instructions.range(of: "# Rules Playhouse shares with you"))
        XCTAssertGreaterThan(rulesStart.lowerBound, instructions.startIndex, "Rules follow the task instructions.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsCodexHome.appendingPathComponent("config.toml").path), "Codex's config.toml is not written.")
        answerQuestionIfAsked()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } == true }, timeout: 30),
                      "The first turn should settle before the next message.")

        // Stopping the bridge daemon also ends its app-server; the next send resumes the thread on a fresh one.
        let daemonPID = try XCTUnwrap((try runCLI(["status"], extraEnvironment: daemonEnvironment)["result"] as? [String: Any])?["processID"] as? Int)
        XCTAssertEqual(kill(pid_t(daemonPID), SIGKILL), 0, "The bridge daemon should stop so its Codex app-server restarts.")
        XCTAssertTrue(waitUntil({ kill(pid_t(daemonPID), 0) != 0 }, timeout: 10), "The stopped daemon should exit.")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 20))
        composer.click()
        composer.typeText("Follow them again.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "Follow them again." }, timeout: 20))
        let resumedAll = try XCTUnwrap(history()["threadResumeDeveloperInstructions"] as? [Any])
        let resumed = try XCTUnwrap(resumedAll.last as? String)
        let resumedStart = try XCTUnwrap(resumed.range(of: "# Rules Playhouse shares with you"))
        XCTAssertEqual(String(resumed[resumedStart.lowerBound...]), String(instructions[rulesStart.lowerBound...]), "The resumed thread gets the same rules.")
        answerQuestionIfAsked()
    }
}

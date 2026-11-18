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
    // case-contract: test_mcp_catalog_lists_repo_global_and_managed_servers | The Skills page, titled Skills, Rules & MCP, switches to its MCP list with a Skills | Rules | MCP picker. MCP lists, in one sectioned list whose Repo, Global and Managed anchors scroll it to their sections, each task repository's servers from its worktree's .mcp.json and .codex/config.toml (keyed by the source repository and the server's name), the user's global servers from Claude Code's ~/.claude.json and Codex's config.toml, and the organization's managed-mcp.json. Each server row shows only its name led by one icon for the agents that start it in Playhouse sessions (the Claude logo for Claude only, the Codex logo for Codex only, a green check for both), without hovering, and its other details show in a hint while the pointer rests on it, which carries no provider icon: each server shows its command or URL and only the names of its environment variables and headers, never their values, and names the agents that start it on their own and the ones Playhouse passes it to: a .mcp.json server is Claude's own and passed to Codex, a server defined the same way in both global files is one entry both CLIs start, a server only one CLI defines is passed to the other, an SSE server or one with a working folder reaches only the agent that can run it with the reason shown, a server Codex's config.toml turns off reaches neither, a server written inline in config.toml is listed but not editable, two global definitions that differ are flagged as a conflict, and the managed server is Claude's only and read-only. A repository without servers shows an empty state and an unreadable configuration file is reported. Reading a server returns its full definition, and an unknown server is not_found.
    func test_mcp_catalog_lists_repo_global_and_managed_servers() throws {
        let working = try makeSkillRepository("mcp-catalog-repo", skills: [
            ".mcp.json": #"{"mcpServers": {"repo-docs": {"type": "stdio", "command": "node", "args": ["docs.js"], "env": {"DOCS_TOKEN": "${DOCS_TOKEN}", "DOCS_MODE": "secret-mode-value"}}, "repo-sse": {"type": "sse", "url": "https://sse.example.com/mcp"}}}"#,
            ".codex/config.toml": "[mcp_servers.repo-codex]\ncommand = \"python3\"\nargs = [\"serve.py\"]\n",
        ])
        let other = try makeSkillRepository("mcp-other-repo", skills: [
            ".mcp.json": #"{"mcpServers": {"other-api": {"type": "http", "url": "https://api.example.com/mcp", "headers": {"Authorization": "Bearer ${API_TOKEN}"}}}}"#,
            ".codex/config.toml": "[mcp_servers.broken\ncommand = \n",
        ])
        let empty = try makeSkillRepository("mcp-empty-repo", skills: [:])
        try writeMcpJSON(mcpClaudeState, ["numStartups": 5, "mcpServers": [
            "shared": ["type": "stdio", "command": "npx", "args": ["-y", "shared-server"], "env": [:]],
            "claude-only": ["type": "http", "url": "https://claude.example.com/mcp", "headers": ["X-Team": "core-secret-team"]],
            "clash": ["type": "stdio", "command": "clash-a", "args": [], "env": [:]],
        ]])
        try writeRuleFile(mcpCodexConfig, [
            "model = \"gpt-6-luna\"", "",
            "[mcp_servers]", "inline-tool = { command = \"inline-tool\" }", "",
            "[mcp_servers.shared]", "command = \"npx\"", "args = [\"-y\", \"shared-server\"]", "",
            "[mcp_servers.codex-only]", "command = \"uvx\"", "args = [\"codex-tool\"]", "env_vars = [\"CODEX_TOOL_KEY\"]", "",
            "[mcp_servers.clash]", "command = \"clash-b\"", "",
            "[mcp_servers.folder-tool]", "command = \"./tool\"", "cwd = \".\"", "",
            "[mcp_servers.off-tool]", "command = \"off-tool\"", "enabled = false", "",
        ].joined(separator: "\n"))
        try writeMcpJSON(mcpManaged, ["mcpServers": ["company": ["type": "http", "url": "https://mcp.company.example/mcp"]]])
        _ = try installSkillsClaudeFixture("claude-fixture-mcp-catalog")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("MCP catalog", repositories: [working, other, empty])
        let taskID = try XCTUnwrap(task["id"] as? String)
        openTask(named: "MCP catalog")
        openMcpPage()

        for name in ["mcp-catalog-repo", "mcp-other-repo", "mcp-empty-repo"] {
            XCTAssertTrue(element("mcp-repo-section-\(name)").waitToExist(timeout: 10), "\(name) has a section.")
        }
        XCTAssertTrue(element("mcp-empty-mcp-empty-repo").exists, "A repository without servers shows an empty state.")
        XCTAssertTrue(element("mcp-file-problem").exists, "An unreadable config file is reported.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("mcp-file-problem")).contains(".codex/config.toml"))
        let docs = "mcp-catalog-repo:repo-docs"
        XCTAssertTrue(element("mcp-row-\(docs)").exists)
        for detail in ["mcp-summary-\(docs)", "mcp-env-\(docs)", "mcp-shared-\(docs)"] {
            XCTAssertFalse(element(detail).exists, "A server row shows only its name and agents until the pointer rests on it (\(detail)).")
        }
        XCTAssertFalse(app.staticTexts["node docs.js"].exists, "The server's command waits for its hint.")
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-summary-\(docs)")), "node docs.js", "A server shows its command.")
        attachElementScreenshot(revealMcpHint(docs), named: "Resting on a server shows its details in a hint")
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-env-\(docs)")), "Environment: DOCS_MODE, DOCS_TOKEN",
                       "Only the names of its environment variables are shown.")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'secret-mode-value'")).firstMatch.exists, "Values are never shown.")
        XCTAssertEqual(rowProviders("mcp-provider-\(docs)"), ["claude", "codex"], "The agents that start it show on its row.")
        XCTAssertEqual(rowBadge("mcp-provider-\(docs)-both").label, "Claude and Codex", "One green icon marks a server both agents start.")
        XCTAssertFalse(revealMcpHint(docs).descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'mcp-provider-'")).firstMatch.exists,
                       "The agents show on the row, not in the hint.")
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-\(docs)")), "Playhouse passes it to Codex.", ".mcp.json is Claude's own.")
        let sse = "mcp-catalog-repo:repo-sse"
        XCTAssertEqual(rowProviders("mcp-provider-\(sse)"), ["claude"], "Codex can't run an SSE server.")
        XCTAssertEqual(rowBadge("mcp-provider-\(sse)-claude").label, "Claude only", "A Claude-only server shows the Claude logo.")
        XCTAssertTrue(accessibleLabelOrValue(of: hintDetail("mcp-limitation-\(sse)")).contains("SSE"))
        XCTAssertTrue(element("mcp-row-mcp-catalog-repo:repo-codex").exists, "The worktree's .codex/config.toml servers are listed.")
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-mcp-other-repo:other-api")), "Playhouse passes it to Claude and Codex.",
                       "Neither agent reads another task repository's servers on its own.")
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-env-mcp-other-repo:other-api")), "Headers: Authorization")
        assertSkillsModalLayout(search: "mcp-search", newButton: "new-mcp-server-button", anchors: "mcp-tab-picker")
        assertRowFitsSkillsModal("mcp-row-\(docs)", name: "mcp-name-\(docs)")
        restPointerOffList(hints: "mcp-hint-")
        attachScreenshot(named: "MCP list with each repository's servers")
        attachElementScreenshot(element("skills-page"), named: "MCP rows led by one provider icon in the narrow modal")
        let search = element("mcp-search")
        typeIntoField(search, text: "docs.js")
        XCTAssertTrue(waitUntil({ !self.element("mcp-row-\(sse)").exists }, timeout: 5), "Search hides servers that don't match.")
        XCTAssertTrue(element("mcp-row-\(docs)").exists, "Search keeps a server whose command matches.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("mcp-empty-mcp-other-repo")), "No matching servers.",
                       "A repository with servers but no match shows its empty state.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("mcp-empty-mcp-empty-repo")), "No MCP servers in mcp-empty-repo.",
                       "A repository without servers still says so while searching.")
        attachScreenshot(named: "MCP search keeps the matching server")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("REPO-CODEX")
        XCTAssertTrue(element("mcp-row-mcp-catalog-repo:repo-codex").waitToExist(timeout: 5), "Search matches a server's name, ignoring case.")
        XCTAssertTrue(waitUntil({ !self.element("mcp-row-\(docs)").exists }, timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-server-matches-this")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("mcp-empty-mcp-catalog-repo")) == "No matching servers." }, timeout: 5),
                      "A search with no match shows its empty state.")
        attachScreenshot(named: "MCP search with no matching server")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("mcp-row-\(sse)").waitToExist(timeout: 5), "Clearing the search shows every server again.")
        XCTAssertFalse(element("mcp-empty-mcp-other-repo").exists)

        jumpToSection("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-row-shared").waitToExist(timeout: 5))
        XCTAssertTrue(isListed("mcp-row-shared", inSection: "mcp-group-global"), "The Global anchor's section lists the global servers.")
        XCTAssertFalse(isListed("mcp-row-\(docs)", inSection: "mcp-group-global"), "Repository servers stay in the Repo section.")
        XCTAssertTrue(isListed("mcp-row-\(docs)", inSection: "mcp-group-repo"), "Jumping keeps the Repo section in the list.")
        typeIntoField(search, text: "shared-server")
        XCTAssertTrue(waitUntil({ !self.element("mcp-row-claude-only").exists }, timeout: 5), "Search filters the Global section too.")
        XCTAssertTrue(element("mcp-row-shared").exists, "The global server whose command matches stays.")
        search.typeKey("a", modifierFlags: .command)
        search.typeText("no-server-matches-this")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("mcp-empty-global")) == "No matching servers." }, timeout: 5),
                      "A Global search with no match shows its empty state.")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("mcp-row-claude-only").waitToExist(timeout: 5), "Clearing the search shows every global server again.")
        XCTAssertTrue(hintDetail("mcp-native-shared").exists, "A server both global files define the same way is one entry both CLIs start.")
        XCTAssertFalse(hintDetail("mcp-shared-shared").exists)
        XCTAssertTrue(element("mcp-conflict-clash").exists, "Two global definitions that differ are a conflict.")
        XCTAssertTrue(accessibleLabelOrValue(of: hintDetail("mcp-issue-clash")).contains("differently"))
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-claude-only")), "Playhouse passes it to Codex.")
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-codex-only")), "Playhouse passes it to Claude.")
        XCTAssertFalse(rowProviders("mcp-provider-folder-tool").contains("claude"), "Claude Code can't run a server with a working folder.")
        XCTAssertTrue(accessibleLabelOrValue(of: hintDetail("mcp-limitation-folder-tool")).contains("working folder"))
        XCTAssertEqual(rowProviders("mcp-provider-off-tool"), [],
                       "A server Codex's config turns off reaches neither agent.")
        XCTAssertTrue(accessibleLabelOrValue(of: hintDetail("mcp-limitation-off-tool")).contains("enabled = false"))
        XCTAssertTrue(element("mcp-row-inline-tool").exists, "An inline config.toml server is listed.")
        attachScreenshot(named: "MCP Global section")
        // The inline server is last on a long list, below the visible part of the page.
        XCTAssertTrue(scrollFullyIntoView(element("mcp-row-inline-tool"), in: element("mcp-list")), "The inline server scrolls into view.")
        XCTAssertTrue(openPanel("mcp-editor-panel", with: element("mcp-row-inline-tool")), "An inline server opens to read.")
        XCTAssertFalse(element("mcp-editor-save").exists, "An inline config.toml server opens without Save.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("mcp-editor-read-only")).contains("inline"), "The editor says why it is read-only.")
        attachScreenshot(named: "An inline config.toml server opens read-only")
        element("mcp-editor-cancel").click()
        XCTAssertTrue(waitUntil({ !self.element("mcp-editor-panel").exists }, timeout: 5))
        let inlineActions = element("mcp-actions-inline-tool")
        XCTAssertTrue(waitUntil({ inlineActions.isHittable }, timeout: 5))
        inlineActions.click()
        XCTAssertTrue(app.menuItems["View…"].waitToExist(timeout: 5), "An inline server offers View rather than Edit.")
        XCTAssertFalse(app.menuItems["Delete…"].exists || app.menuItems["Make Available Outside Playhouse…"].exists,
                       "An inline server offers no Delete or link.")
        app.typeKey(.escape, modifierFlags: [])

        selectSkillsTab("Managed", picker: "mcp-tab-picker")
        let managed = "managed:company"
        XCTAssertTrue(element("mcp-row-\(managed)").waitToExist(timeout: 5), "The managed server is listed.")
        XCTAssertTrue(isListed("mcp-row-\(managed)", inSection: "mcp-group-managed"), "The managed server is in the Managed section.")
        XCTAssertEqual(rowProviders("mcp-provider-\(managed)"), ["claude"], "The managed server is Claude's only.")
        XCTAssertFalse(element("mcp-toggle-\(managed)").exists, "The managed server can't be turned off.")
        attachScreenshot(named: "MCP Managed section")

        let byID = mcpServersByID(try mcpCatalog(taskID: taskID))
        XCTAssertEqual(byID["repo:\(working.path)#repo-docs"]?["nativeProviders"] as? [String], ["claude"])
        XCTAssertEqual(byID["global:shared"]?["availableOutsidePlayhouse"] as? Bool, true)
        XCTAssertEqual(((byID["global:inline-tool"]?["locations"] as? [[String: Any]])?.first)?["editable"] as? Bool, false,
                       "An inline config.toml server is not editable.")
        XCTAssertEqual(byID["managed:company"]?["editable"] as? Bool, false)
        let detail = try XCTUnwrap(try runCLI(["mcp", "get", "--task", taskID, "--server", "global:claude-only"])["result"] as? [String: Any])
        XCTAssertEqual((detail["config"] as? [String: Any])?["headers"] as? [String: String], ["X-Team": "core-secret-team"], "Reading a server returns its full definition.")
        assertCLIError(try runCLI(["mcp", "get", "--task", taskID, "--server", "global:no-such-server"], expectedStatus: 3), code: "not_found")

        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 5), "Back returns to the conversation.")
    }
    // case-contract: test_mcp_create_update_and_delete_in_both_configs | New Server writes a global server straight into both Claude Code's ~/.claude.json mcpServers and Codex's config.toml [mcp_servers] table, with ${NAME} environment references written as Codex env_vars and every other setting, comment and server in both files kept; a repository server goes into the chosen task worktree's .mcp.json and the source checkout is left alone. An invalid name, a missing command, an SSE server, a URL that is not http, an environment reference Codex can't pass through, the managed scope, and an existing name are rejected with nothing written. Clicking a server opens its editor, and saving rewrites it in every file that defines it while keeping each provider's own keys, such as Codex's startup_timeout_sec and Claude's oauth; an invalid edit and an edit to a server written inline in config.toml are rejected while keeping the files. Deleting a server removes it from every file that defines it, and every change is visible to a fresh CLI process and on the page. Right after a create closes its panel, one click on New Server opens it again.
    func test_mcp_create_update_and_delete_in_both_configs() throws {
        let repository = try makeSkillRepository("mcp-manage-repo", skills: [:])
        try writeMcpJSON(mcpClaudeState, ["numStartups": 7, "mcpServers": [
            "legacy": ["type": "http", "url": "https://legacy.example.com/mcp", "oauth": ["clientId": "abc"]],
        ]])
        try writeRuleFile(mcpCodexConfig, [
            "# my settings", "model = \"gpt-6-luna\"", "",
            "[mcp_servers]", "inline-tool = { command = \"inline-tool\" }", "",
            "[mcp_servers.legacy]", "url = \"https://legacy.example.com/mcp\"", "startup_timeout_sec = 45", "",
            "[profiles.fast]", "model = \"gpt-6-mini\"", "",
        ].joined(separator: "\n"))
        try writeMcpJSON(mcpManaged, ["mcpServers": ["company": ["type": "http", "url": "https://mcp.company.example/mcp"]]])
        _ = try installSkillsClaudeFixture("claude-fixture-mcp-manage")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("MCP manage", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        openTask(named: "MCP manage")
        openMcpPage()

        XCTAssertTrue(openPanel("mcp-editor-panel", with: element("new-mcp-server-button")), "New Server opens its panel.")
        XCTAssertLessThanOrEqual(element("mcp-editor-panel").frame.width, element("skills-page").frame.width + 1, "The New Server panel fits the narrow modal.")
        typeIntoField(element("mcp-editor-name"), text: "bad name")
        typeIntoField(element("mcp-editor-command"), text: "npx")
        element("mcp-editor-save").click()
        XCTAssertTrue(element("mcp-editor-error").waitToExist(timeout: 5), "An invalid name is rejected in the panel.")
        XCTAssertNil((try readMcpJSON(mcpClaudeState)["mcpServers"] as? [String: Any])?["bad name"], "A rejected server writes nothing.")
        attachScreenshot(named: "New Server rejects an invalid name")
        replaceText(in: element("mcp-editor-name"), with: "notes")
        replaceText(in: element("mcp-editor-command"), with: "")
        element("mcp-editor-save").click()
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("mcp-editor-error")).contains("command") }, timeout: 5),
                      "A missing command is rejected in the panel.")
        XCTAssertNil((try readMcpJSON(mcpClaudeState)["mcpServers"] as? [String: Any])?["notes"], "A rejected server writes nothing.")
        replaceText(in: element("mcp-editor-command"), with: "npx")
        typeIntoField(element("mcp-editor-args"), text: "-y\nnotes-server")
        typeIntoField(element("mcp-editor-env"), text: "NOTES_TOKEN=${NOTES_TOKEN}\nMODE=fast")
        XCTAssertTrue(accessibleLabelOrValue(of: element("mcp-editor-target")).contains("config.toml"), "A global server is saved for both CLIs.")
        attachScreenshot(named: "New Server panel for a global local command")
        element("mcp-editor-save").click()
        XCTAssertTrue(waitUntil({ !self.element("mcp-editor-panel").exists }, timeout: 10), "Creating closes the panel.")
        XCTAssertTrue(element("mcp-row-notes").waitToExist(timeout: 10), "The new global server shows in the Global section.")
        XCTAssertTrue(isListed("mcp-row-notes", inSection: "mcp-group-global"))
        XCTAssertTrue(hintDetail("mcp-native-notes").exists, "A new global server is in both CLIs' configuration.")
        let state = try readMcpJSON(mcpClaudeState)
        let notes = try XCTUnwrap((state["mcpServers"] as? [String: Any])?["notes"] as? [String: Any])
        XCTAssertEqual(notes["command"] as? String, "npx")
        XCTAssertEqual(notes["args"] as? [String], ["-y", "notes-server"])
        XCTAssertEqual(notes["env"] as? [String: String], ["NOTES_TOKEN": "${NOTES_TOKEN}", "MODE": "fast"])
        XCTAssertEqual(state["numStartups"] as? Int, 7, "Claude Code's other state is kept.")
        let codexText = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        for line in ["# my settings", "[mcp_servers.notes]", "command = \"npx\"", "args = [\"-y\", \"notes-server\"]", "env_vars = [\"NOTES_TOKEN\"]",
                     "[mcp_servers.notes.env]", "MODE = \"fast\"", "[profiles.fast]"] {
            XCTAssertTrue(codexText.contains(line), "Codex's config.toml has \(line).")
        }
        attachScreenshot(named: "A new global server both CLIs start")

        typeIntoField(element("mcp-search"), text: "no-server-matches-this")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("mcp-empty-global")) == "No matching servers." }, timeout: 5))
        XCTAssertTrue(openPanel("mcp-editor-panel", with: element("new-mcp-server-button")))
        element("mcp-editor-scope").click()
        XCTAssertTrue(app.menuItems["mcp-manage-repo"].waitToExist(timeout: 5), "New Server can save into the task's repository.")
        app.menuItems["mcp-manage-repo"].click()
        selectSkillsTab("Remote HTTP", picker: "mcp-editor-kind")
        typeIntoField(element("mcp-editor-name"), text: "repo-search")
        typeIntoField(element("mcp-editor-url"), text: "https://search.example.com/mcp")
        XCTAssertTrue(accessibleLabelOrValue(of: element("mcp-editor-target")).contains(".mcp.json"))
        element("mcp-editor-save").click()
        XCTAssertTrue(waitUntil({ !self.element("mcp-editor-panel").exists }, timeout: 10))
        XCTAssertTrue(element("mcp-row-mcp-manage-repo:repo-search").waitToExist(timeout: 10),
                      "The repository server shows in the Repo section: creating a server clears a search that would hide it.")
        XCTAssertTrue(isListed("mcp-row-mcp-manage-repo:repo-search", inSection: "mcp-group-repo"))
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-mcp-manage-repo:repo-search")), "Playhouse passes it to Codex.")
        let projectJSON = try readMcpJSON(worktree.appendingPathComponent(".mcp.json"))
        XCTAssertEqual(((projectJSON["mcpServers"] as? [String: Any])?["repo-search"] as? [String: Any])?["url"] as? String, "https://search.example.com/mcp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".mcp.json").path), "The source checkout is left alone.")

        let beforeRejected = (try String(contentsOf: mcpClaudeState, encoding: .utf8), try String(contentsOf: mcpCodexConfig, encoding: .utf8))
        for arguments in [
            ["--scope", "global", "--name", "no-command", "--command", ""],
            ["--scope", "global", "--name", "events", "--config-json", #"{"transport": "sse", "url": "https://sse.example.com"}"#],
            ["--scope", "global", "--name", "ftp-server", "--url", "ftp://files.example.com"],
            ["--scope", "global", "--name", "renamed-env", "--command", "npx", "--env", "TOKEN=${OTHER_TOKEN}"],
            ["--scope", "managed", "--name", "company-two", "--command", "npx"],
        ] {
            assertCLIError(try runCLI(["mcp", "create", "--task", taskID] + arguments, expectedStatus: 2), code: "invalid_argument")
        }
        assertCLIError(try runCLI(["mcp", "create", "--task", taskID, "--scope", "global", "--name", "notes", "--command", "npx"], expectedStatus: 1), code: "already_exists")
        XCTAssertEqual(try String(contentsOf: mcpClaudeState, encoding: .utf8), beforeRejected.0, "A rejected server writes nothing to Claude Code's file.")
        XCTAssertEqual(try String(contentsOf: mcpCodexConfig, encoding: .utf8), beforeRejected.1, "A rejected server writes nothing to Codex's file.")

        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(openPanel("mcp-editor-panel", with: element("mcp-row-legacy")), "Clicking a server opens its editor.")
        let url = element("mcp-editor-url")
        XCTAssertEqual(url.value as? String, "https://legacy.example.com/mcp", "The editor opens the server's definition.")
        replaceText(in: url, with: "ftp://legacy.example.com")
        element("mcp-editor-save").click()
        XCTAssertTrue(element("mcp-editor-error").waitToExist(timeout: 5), "An invalid edit is rejected in the editor.")
        XCTAssertTrue(try String(contentsOf: mcpCodexConfig, encoding: .utf8).contains("url = \"https://legacy.example.com/mcp\""), "A rejected edit keeps the files.")
        replaceText(in: url, with: "https://legacy.example.com/v2")
        attachScreenshot(named: "Editing a global server")
        element("mcp-editor-save").click()
        XCTAssertTrue(waitUntil({ !self.element("mcp-editor-panel").exists }, timeout: 10), "Saving closes the editor.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.hintDetail("mcp-summary-legacy")) == "https://legacy.example.com/v2" }, timeout: 10))
        let legacy = try XCTUnwrap((try readMcpJSON(mcpClaudeState)["mcpServers"] as? [String: Any])?["legacy"] as? [String: Any])
        XCTAssertEqual(legacy["url"] as? String, "https://legacy.example.com/v2")
        XCTAssertEqual(legacy["oauth"] as? [String: String], ["clientId": "abc"], "Claude's own keys are kept.")
        let editedCodex = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        XCTAssertTrue(editedCodex.contains("url = \"https://legacy.example.com/v2\""), "An edit reaches Codex's config.toml.")
        XCTAssertTrue(editedCodex.contains("startup_timeout_sec = 45"), "Codex's own keys are kept.")
        let beforeInline = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        let inline = try runCLI(["mcp", "update", "--task", taskID, "--server", "global:inline-tool", "--command", "inline-tool-2"], expectedStatus: 2)
        assertCLIError(inline, code: "invalid_argument")
        XCTAssertTrue(((inline["error"] as? [String: Any])?["message"] as? String ?? "").contains("inline"))
        XCTAssertEqual(try String(contentsOf: mcpCodexConfig, encoding: .utf8), beforeInline, "An edit to an inline server keeps the file.")

        selectSkillsTab("Managed", picker: "mcp-tab-picker")
        XCTAssertTrue(openPanel("mcp-editor-panel", with: element("mcp-row-managed:company")), "The managed server opens to read.")
        XCTAssertFalse(element("mcp-editor-save").exists, "The managed server opens read-only, without Save.")
        element("mcp-editor-cancel").click()
        XCTAssertTrue(waitUntil({ !self.element("mcp-editor-panel").exists }, timeout: 5))

        selectSkillsTab("Global", picker: "mcp-tab-picker")
        clickMcpMenuItem(server: "notes", item: "mcp-delete-notes", title: "Delete…")
        clickDialogButton("confirm-delete-mcp", title: "Delete")
        XCTAssertTrue(waitUntil({ !self.element("mcp-row-notes").exists }, timeout: 10), "Deleting removes the server from the page.")
        XCTAssertNil((try readMcpJSON(mcpClaudeState)["mcpServers"] as? [String: Any])?["notes"], "Deleting removes the server from Claude Code's file.")
        let afterDelete = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        XCTAssertFalse(afterDelete.contains("[mcp_servers.notes"), "Deleting removes the server from Codex's file.")
        XCTAssertTrue(afterDelete.contains("# my settings"))
        attachScreenshot(named: "A deleted server is gone from both files")
        let fresh = mcpServersByID(try mcpCatalog(taskID: taskID))
        XCTAssertNil(fresh["global:notes"])
        XCTAssertNotNil(fresh["repo:\(repository.path)#repo-search"])
    }
    // case-contract: test_mcp_enable_state_and_link_persist | Turning a server off is stored by Playhouse rather than in either provider's configuration, survives fresh CLI processes and reopening the page, and can be turned back on; the managed server can't be turned off. A turned-off server in Claude Code's own configuration still lists Claude and the page says Claude still starts it, so turning it off applies to Codex only, while a turned-off server only Codex defines reaches neither agent. Make Available Outside Playhouse writes a Claude-only global server into Codex's config.toml, a Codex-only one into Claude Code's ~/.claude.json, and a repository .mcp.json server into the worktree's .codex/config.toml, after which each is one entry both CLIs start; a conflicting server can't be linked and nothing is written.
    func test_mcp_enable_state_and_link_persist() throws {
        let repository = try makeSkillRepository("mcp-link-repo", skills: [
            ".mcp.json": #"{"mcpServers": {"repo-tool": {"type": "stdio", "command": "repo-tool", "args": [], "env": {}}}}"#,
        ])
        try writeMcpJSON(mcpClaudeState, ["mcpServers": [
            "claude-tool": ["type": "stdio", "command": "claude-tool", "args": ["--serve"], "env": [:]],
            "clash": ["type": "stdio", "command": "clash-a", "args": [], "env": [:]],
        ]])
        try writeRuleFile(mcpCodexConfig, "[mcp_servers.codex-tool]\ncommand = \"codex-tool\"\nenv_vars = [\"CODEX_KEY\"]\n\n[mcp_servers.clash]\ncommand = \"clash-b\"\n")
        try writeMcpJSON(mcpManaged, ["mcpServers": ["company": ["type": "http", "url": "https://mcp.company.example/mcp"]]])
        let beforeClaude = try String(contentsOf: mcpClaudeState, encoding: .utf8)
        let beforeCodex = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        _ = try installSkillsClaudeFixture("claude-fixture-mcp-link")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("MCP links", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        func server(_ id: String) throws -> [String: Any]? { mcpServersByID(try mcpCatalog(taskID: taskID))[id] }
        openTask(named: "MCP links")
        openMcpPage()
        selectSkillsTab("Global", picker: "mcp-tab-picker")

        let toggle = element("mcp-toggle-claude-tool")
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(isOn(toggle))
        toggle.click()
        XCTAssertTrue(waitUntil({ !self.isOn(toggle) }, timeout: 0.75), "The switch flips as soon as it is clicked.")
        XCTAssertTrue(waitUntil({ ((try? server("global:claude-tool"))??["enabled"] as? Bool) == false }, timeout: 10),
                      "Turning a server off is saved where a fresh CLI process reads it.")
        XCTAssertTrue(hintDetail("mcp-always-on-claude-tool").waitToExist(timeout: 5), "The page says Claude still starts it itself.")
        XCTAssertEqual(rowProviders("mcp-provider-claude-tool"), ["claude"], "Turning it off stops Codex getting it.")
        XCTAssertEqual(try String(contentsOf: mcpClaudeState, encoding: .utf8), beforeClaude, "Claude Code's configuration is not written.")
        XCTAssertEqual(try String(contentsOf: mcpCodexConfig, encoding: .utf8), beforeCodex, "Codex's configuration is not written.")
        attachScreenshot(named: "A server Claude starts itself, turned off")
        element("skills-back-button").click()
        openMcpPage()
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(waitUntil({ self.element("mcp-toggle-claude-tool").exists && !self.isOn(self.element("mcp-toggle-claude-tool")) }, timeout: 10),
                      "The off state survives reopening the page.")
        element("mcp-toggle-claude-tool").click()
        XCTAssertTrue(waitUntil({ ((try? server("global:claude-tool"))??["enabled"] as? Bool) == true }, timeout: 10))

        element("mcp-toggle-codex-tool").click()
        XCTAssertTrue(waitUntil({ self.rowProviders("mcp-provider-codex-tool").isEmpty }, timeout: 10),
                      "A server only Codex defines reaches neither agent once off.")
        XCTAssertFalse(hintDetail("mcp-always-on-codex-tool").exists)
        element("mcp-toggle-codex-tool").click()
        XCTAssertTrue(waitUntil({ self.rowProviders("mcp-provider-codex-tool").contains("claude") }, timeout: 10))
        assertCLIError(try runCLI(["mcp", "disable", "--task", taskID, "--server", "managed:company"], expectedStatus: 2), code: "invalid_argument")

        let actions = element("mcp-actions-clash")
        XCTAssertTrue(waitUntil({ actions.exists && actions.isHittable }, timeout: 10))
        actions.click()
        XCTAssertTrue(app.menuItems["Reveal in Finder"].waitToExist(timeout: 5))
        XCTAssertFalse(app.menuItems["Make Available Outside Playhouse…"].exists, "A conflicting server can't be linked.")
        app.typeKey(.escape, modifierFlags: [])
        assertCLIError(try runCLI(["mcp", "link", "--task", taskID, "--server", "global:clash"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try String(contentsOf: mcpCodexConfig, encoding: .utf8), beforeCodex, "Nothing is written for it.")

        clickMcpMenuItem(server: "claude-tool", item: "mcp-link-claude-tool", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-mcp", title: "Add to Both CLIs")
        XCTAssertTrue(hintDetail("mcp-native-claude-tool").waitToExist(timeout: 10), "A linked server is one entry both CLIs start.")
        let linkedCodex = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        XCTAssertTrue(linkedCodex.contains("[mcp_servers.claude-tool]") && linkedCodex.contains("args = [\"--serve\"]"),
                      "A Claude-only server is written into Codex's config.toml.")
        attachScreenshot(named: "A Claude server linked into Codex's config")
        clickMcpMenuItem(server: "codex-tool", item: "mcp-link-codex-tool", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-mcp", title: "Add to Both CLIs")
        XCTAssertTrue(hintDetail("mcp-native-codex-tool").waitToExist(timeout: 10))
        let codexTool = try XCTUnwrap((try readMcpJSON(mcpClaudeState)["mcpServers"] as? [String: Any])?["codex-tool"] as? [String: Any])
        XCTAssertEqual(codexTool["env"] as? [String: String], ["CODEX_KEY": "${CODEX_KEY}"], "A Codex-only server is written into Claude Code's file.")

        selectSkillsTab("Repo", picker: "mcp-tab-picker")
        let repoTool = "mcp-link-repo:repo-tool"
        clickMcpMenuItem(server: repoTool, item: "mcp-link-\(repoTool)", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-mcp", title: "Add to Both CLIs")
        XCTAssertTrue(hintDetail("mcp-native-\(repoTool)").waitToExist(timeout: 10))
        XCTAssertTrue(try String(contentsOf: worktree.appendingPathComponent(".codex/config.toml"), encoding: .utf8).contains("[mcp_servers.repo-tool]"),
                      "A repository server is written into the worktree's .codex/config.toml.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".codex").path), "The source checkout is left alone.")
        attachScreenshot(named: "A repository server linked for both CLIs")
    }
    // case-contract: test_mcp_fix_with_agent_starts_task_for_conflicting_servers | A server whose definitions conflict offers a Fix button on its row, which creates a task on the source task's provider whose saved prompt explains how both agents configure MCP servers and lists each server with its problem: repository servers by repository-relative file, to be fixed in the new task's own worktree and committed and pushed, and global servers by absolute file path, to be fixed in place with their folders opened as context folders. The view switches to the new task's conversation, which sends that prompt once and leaves no unsent draft. A server with no problem, a managed server, an unknown server, and a request without a task are rejected without opening a task.
    func test_mcp_fix_with_agent_starts_task_for_conflicting_servers() throws {
        let repository = try makeSkillRepository("mcp-fix-repo", skills: [
            ".mcp.json": #"{"mcpServers": {"repo-clash": {"type": "stdio", "command": "clash-json", "args": [], "env": {}}, "fine": {"type": "stdio", "command": "fine", "args": [], "env": {}}}}"#,
            ".codex/config.toml": "[mcp_servers.repo-clash]\ncommand = \"clash-toml\"\n",
        ])
        try writeMcpJSON(mcpClaudeState, ["mcpServers": ["clash": ["type": "stdio", "command": "clash-a", "args": [], "env": [:]]]])
        try writeRuleFile(mcpCodexConfig, "[mcp_servers.clash]\ncommand = \"clash-b\"\n")
        try writeMcpJSON(mcpManaged, ["mcpServers": ["company": ["type": "http", "url": "https://mcp.company.example/mcp"]]])
        let executable = try installSkillsClaudeFixture("claude-fixture-mcp-fix")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        launchApp(defaultParent: fixture.parent.path)
        let source = try createSkillsTask("MCP fix source", repositories: [repository], provider: "claude")
        let sourceID = try XCTUnwrap(source["id"] as? String)
        let sourceWorktree = try XCTUnwrap((source["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
        let tasksBefore = try boardTaskRecords().count
        assertCLIError(try runCLI(["mcp", "fix", "--task", sourceID, "--server", "repo:\(repository.path)#fine"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["mcp", "fix", "--task", sourceID, "--server", "managed:company"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["mcp", "fix", "--task", sourceID, "--server", "global:no-such-server"], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["mcp", "fix", "--server", "global:clash"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try boardTaskRecords().count, tasksBefore, "A rejected fix opens no task.")

        openTask(named: "MCP fix source")
        openMcpPage()
        XCTAssertTrue(element("mcp-fix-mcp-fix-repo:repo-clash").waitToExist(timeout: 10), "A conflicting server offers Fix with Agent.")
        XCTAssertTrue(element("mcp-conflict-mcp-fix-repo:repo-clash").exists)
        XCTAssertFalse(element("mcp-fix-mcp-fix-repo:fine").exists, "A server without a problem has nothing to fix.")
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-fix-clash").waitToExist(timeout: 5))
        attachScreenshot(named: "A conflicting global server offers Fix")

        element("mcp-fix-clash").click()
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 10), "Fixing closes the page.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Fix MCP server clash" }, timeout: 15),
                      "The view switches to the fixing task's conversation.")
        let single = try XCTUnwrap(try boardTaskRecords().first { $0["title"] as? String == "Fix MCP server clash" })
        XCTAssertEqual((single["repositoryWorktrees"] as? [Any])?.count, 0, "Fixing only global servers needs no repository.")
        XCTAssertEqual(Set(((single["contextFolders"] as? [String]) ?? []).map(realPath)), [realPath(skillsHome.path), realPath(skillsCodexHome.path)],
                       "The folders of the global files are opened to the agent.")
        let singlePrompt = try XCTUnwrap(single["savedPrompt"] as? String)
        XCTAssertTrue(singlePrompt.contains("not tracked by Git"))
        XCTAssertTrue(singlePrompt.contains(mcpClaudeState.path) || singlePrompt.contains(realPath(mcpClaudeState.path)), "A global server is named by its file's absolute path.")
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == singlePrompt } }, timeout: 20),
                      "The fixing task sends its prompt as soon as it opens.")

        openTask(named: "MCP fix source")
        openMcpPage()
        XCTAssertTrue(element("mcp-fix-mcp-fix-repo:repo-clash").waitToExist(timeout: 10))
        element("mcp-fix-mcp-fix-repo:repo-clash").click()
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Fix MCP server repo-clash" }, timeout: 15))
        let fixing = try XCTUnwrap(try boardTaskRecords().first { $0["title"] as? String == "Fix MCP server repo-clash" })
        let fixingID = try XCTUnwrap(fixing["id"] as? String)
        let prompt = try XCTUnwrap(fixing["savedPrompt"] as? String)
        XCTAssertEqual(fixing["conversationProvider"] as? String, "claude", "The fixing task uses the source task's provider.")
        XCTAssertTrue(prompt.contains("Claude Code reads `mcpServers`"), "The prompt explains how both agents configure servers.")
        XCTAssertTrue(prompt.contains("[mcp_servers.<name>]"))
        XCTAssertTrue(prompt.contains("commit and push"))
        XCTAssertTrue(prompt.contains("`repo-clash` in mcp-fix-repo: `.mcp.json`, `.codex/config.toml`"))
        XCTAssertFalse(prompt.contains(sourceWorktree), "Repository files are relative, so they point into the fixing task's worktree.")
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == prompt } }, timeout: 20), "The conversation sends the fixing prompt.")
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String ?? "").isEmpty }, timeout: 10),
                      "The sent prompt leaves the composer, so it cannot be sent twice.")
        attachScreenshot(named: "The server-fixing task's conversation")
        XCTAssertEqual(claudeTurns(historyURL).filter { $0["userText"] as? String == prompt }.count, 1, "The fixing prompt is sent exactly once.")
        let started = try XCTUnwrap(try taskRecord(id: fixingID))
        XCTAssertEqual(started["hasUnsentDraft"] as? Bool, false)
        let worktree = try XCTUnwrap((started["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(worktree["repositoryPath"] as? String, repository.path)
        XCTAssertNotEqual(realPath(worktree["worktreePath"] as? String ?? ""), realPath(sourceWorktree))
    }
    // case-contract: test_mcp_bridge_claude_launch_passes_shared_servers | A Claude turn starts the servers Claude Code does not read itself: its --mcp-config carries Codex's own global servers (with env_vars passed as ${NAME}), the working repository's .codex/config.toml servers, and the other task repository's .mcp.json servers, but not the servers Claude Code already reads or ones turned off on the page. Its --settings starts the working repository's .mcp.json servers that are on with enabledMcpjsonServers and skips turned-off ones with disabledMcpjsonServers, without writing to the repository or either provider's configuration. The resumed second turn carries the same servers, and turning a server back on adds it.
    func test_mcp_bridge_claude_launch_passes_shared_servers() throws {
        let repository = try makeSkillRepository("mcp-claude-repo", skills: [
            ".mcp.json": #"{"mcpServers": {"repo-tool": {"type": "stdio", "command": "repo-tool", "args": [], "env": {}}, "repo-off": {"type": "stdio", "command": "repo-off", "args": [], "env": {}}}}"#,
            ".codex/config.toml": "[mcp_servers.repo-codex]\ncommand = \"repo-codex\"\nargs = [\"--serve\"]\n",
        ])
        let extra = try makeSkillRepository("mcp-claude-extra", skills: [
            ".mcp.json": #"{"mcpServers": {"extra-api": {"type": "http", "url": "https://extra.example.com/mcp"}}}"#,
        ])
        try writeMcpJSON(mcpClaudeState, ["mcpServers": ["claude-tool": ["type": "stdio", "command": "claude-tool", "args": [], "env": [:]]]])
        try writeRuleFile(mcpCodexConfig, "[mcp_servers.codex-tool]\ncommand = \"codex-tool\"\nenv_vars = [\"CODEX_KEY\"]\n\n[mcp_servers.codex-off]\ncommand = \"codex-off\"\n")
        let beforeClaude = try String(contentsOf: mcpClaudeState, encoding: .utf8)
        let beforeCodex = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        let executable = try installSkillsClaudeFixture("claude-fixture-mcp-bridge")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Claude MCP", repositories: [repository, extra], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first { $0["repositoryPath"] as? String == repository.path }?["worktreePath"] as? String))
        openTask(named: "Claude MCP")
        openMcpPage()
        let repoOff = "mcp-claude-repo:repo-off"
        XCTAssertTrue(element("mcp-toggle-\(repoOff)").waitToExist(timeout: 10))
        element("mcp-toggle-\(repoOff)").click()
        XCTAssertTrue(waitUntil({ !self.isOn(self.element("mcp-toggle-\(repoOff)")) }, timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-mcp-claude-extra:extra-api")), "Playhouse passes it to Claude and Codex.")
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-mcp-claude-repo:repo-codex")), "Playhouse passes it to Claude and Codex.")
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-toggle-codex-off").waitToExist(timeout: 5))
        element("mcp-toggle-codex-off").click()
        XCTAssertTrue(waitUntil({ !self.isOn(self.element("mcp-toggle-codex-off")) }, timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-codex-tool")), "Playhouse passes it to Claude.")
        attachScreenshot(named: "Servers a Claude turn will start, with one turned off")
        element("skills-back-button").click()
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Use the tools.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == "Use the tools." } }, timeout: 20))
        let first = try XCTUnwrap(claudeTurns(historyURL).first { $0["userText"] as? String == "Use the tools." })
        let arguments = try XCTUnwrap(first["arguments"] as? [String])
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(arguments[try XCTUnwrap(arguments.firstIndex(of: "--mcp-config")) + 1].utf8)) as? [String: Any])
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["codex-tool", "extra-api", "repo-codex"],
                       "Claude gets the servers it does not read itself, without the ones it reads or ones turned off.")
        XCTAssertEqual((servers["codex-tool"] as? [String: Any])?["env"] as? [String: String], ["CODEX_KEY": "${CODEX_KEY}"])
        XCTAssertEqual((servers["extra-api"] as? [String: Any])?["url"] as? String, "https://extra.example.com/mcp")
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(arguments[try XCTUnwrap(arguments.firstIndex(of: "--settings")) + 1].utf8)) as? [String: Any])
        XCTAssertEqual(settings["enabledMcpjsonServers"] as? [String], ["repo-tool"], "The working repository's .mcp.json server that is on starts.")
        XCTAssertEqual(settings["disabledMcpjsonServers"] as? [String], ["repo-off"], "A turned-off .mcp.json server is skipped for this run.")
        XCTAssertEqual(try String(contentsOf: mcpClaudeState, encoding: .utf8), beforeClaude, "Claude Code's configuration is not written.")
        XCTAssertEqual(try String(contentsOf: mcpCodexConfig, encoding: .utf8), beforeCodex, "Codex's configuration is not written.")
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "The worktree is not written to.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } == true }, timeout: 30),
                      "The first turn should settle before the next message.")

        openMcpPage()
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-toggle-codex-off").waitToExist(timeout: 5))
        element("mcp-toggle-codex-off").click()
        XCTAssertTrue(waitUntil({ self.isOn(self.element("mcp-toggle-codex-off")) }, timeout: 10))
        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Use them again.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ self.claudeTurns(historyURL).contains { $0["userText"] as? String == "Use them again." } }, timeout: 20))
        let second = try XCTUnwrap(claudeTurns(historyURL).last { $0["userText"] as? String == "Use them again." })
        XCTAssertEqual(second["resumed"] as? Bool, true, "The second turn resumes the Claude session.")
        let resumed = try XCTUnwrap(second["arguments"] as? [String])
        let resumedConfig = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(resumed[try XCTUnwrap(resumed.firstIndex(of: "--mcp-config")) + 1].utf8)) as? [String: Any])
        XCTAssertEqual(Set(((resumedConfig["mcpServers"] as? [String: Any]) ?? [:]).keys), ["codex-off", "codex-tool", "extra-api", "repo-codex"],
                       "Turning a server back on adds it.")
    }
    // case-contract: test_mcp_bridge_codex_thread_gets_shared_servers | A Codex turn starts the servers Codex does not read itself: the thread's mcp_servers config carries the working repository's .mcp.json servers and Claude Code's own global servers, translated so ${NAME} environment references become env_vars and an Authorization bearer token becomes bearer_token_env_var, leaves out an SSE server Codex can't run and the servers Codex already reads, and turns off a server Codex may read itself (from its config.toml or the working repository's .codex/config.toml) that is turned off on the page with enabled = false, without writing Codex's config.toml. Turning servers on or off on the page resumes the thread on its next turn with the new mcp_servers config.
    func test_mcp_bridge_codex_thread_gets_shared_servers() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let historyURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        let repository = try makeSkillRepository("mcp-codex-repo", skills: [
            ".mcp.json": #"{"mcpServers": {"repo-tool": {"type": "stdio", "command": "repo-tool", "args": ["--serve"], "env": {"REPO_TOKEN": "${REPO_TOKEN}", "MODE": "fast"}}, "repo-sse": {"type": "sse", "url": "https://sse.example.com/mcp"}}}"#,
            ".codex/config.toml": "[mcp_servers.repo-codex-off]\ncommand = \"repo-codex-off\"\n",
        ])
        try writeMcpJSON(mcpClaudeState, ["mcpServers": [
            "claude-remote": ["type": "http", "url": "https://remote.example.com/mcp", "headers": ["Authorization": "Bearer ${REMOTE_TOKEN}", "X-Team": "core"]],
        ]])
        try writeRuleFile(mcpCodexConfig, "[mcp_servers.codex-tool]\ncommand = \"codex-tool\"\n\n[mcp_servers.codex-off]\ncommand = \"codex-off\"\n")
        let beforeCodex = try String(contentsOf: mcpCodexConfig, encoding: .utf8)
        _ = try installSkillsClaudeFixture("claude-fixture-mcp-codex")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Codex MCP", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
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

        openTask(named: "Codex MCP")
        openMcpPage()
        let sse = "mcp-codex-repo:repo-sse"
        XCTAssertTrue(element("mcp-row-\(sse)").waitToExist(timeout: 10))
        XCTAssertFalse(rowProviders("mcp-provider-\(sse)").contains("codex"), "Codex can't run an SSE server.")
        let repoCodexOff = "mcp-codex-repo:repo-codex-off"
        XCTAssertTrue(element("mcp-toggle-\(repoCodexOff)").exists)
        element("mcp-toggle-\(repoCodexOff)").click()
        XCTAssertTrue(waitUntil({ !self.isOn(self.element("mcp-toggle-\(repoCodexOff)")) }, timeout: 10))
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-toggle-codex-off").waitToExist(timeout: 5))
        element("mcp-toggle-codex-off").click()
        XCTAssertTrue(waitUntil({ !self.isOn(self.element("mcp-toggle-codex-off")) }, timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: hintDetail("mcp-shared-claude-remote")), "Playhouse passes it to Codex.")
        attachScreenshot(named: "Servers a Codex turn will start, with one turned off")
        element("skills-back-button").click()
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Use the tools.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "Use the tools." }, timeout: 20))
        let servers = try XCTUnwrap((history()["threadStartConfig"] as? [String: Any])?["mcp_servers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["repo-tool", "claude-remote", "codex-off", "repo-codex-off"],
                       "Codex gets the servers it does not read itself, without an SSE server or the ones it reads.")
        let repoTool = try XCTUnwrap(servers["repo-tool"] as? [String: Any])
        XCTAssertEqual(repoTool["env_vars"] as? [String], ["REPO_TOKEN"], "${NAME} references become env_vars.")
        XCTAssertEqual(repoTool["env"] as? [String: String], ["MODE": "fast"])
        let remote = try XCTUnwrap(servers["claude-remote"] as? [String: Any])
        XCTAssertEqual(remote["bearer_token_env_var"] as? String, "REMOTE_TOKEN", "A bearer token becomes bearer_token_env_var.")
        XCTAssertEqual(remote["http_headers"] as? [String: String], ["X-Team": "core"])
        let off = try XCTUnwrap(servers["codex-off"] as? [String: Any])
        XCTAssertEqual(off["enabled"] as? Bool, false, "A Codex server turned off on the page is turned off for the thread.")
        XCTAssertEqual(off["command"] as? String, "codex-off")
        XCTAssertEqual((servers["repo-codex-off"] as? [String: Any])?["enabled"] as? Bool, false,
                       "A turned-off server in the working repository's .codex/config.toml is turned off for the thread.")
        XCTAssertEqual(try String(contentsOf: mcpCodexConfig, encoding: .utf8), beforeCodex, "Codex's config.toml is not written.")
        answerQuestionIfAsked()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } == true }, timeout: 30),
                      "The first turn should settle before the next message.")

        let resumesBefore = history()["threadResumeCount"] as? Int ?? 0
        openMcpPage()
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-toggle-codex-off").waitToExist(timeout: 5))
        element("mcp-toggle-codex-off").click()
        XCTAssertTrue(waitUntil({ self.isOn(self.element("mcp-toggle-codex-off")) }, timeout: 10))
        selectSkillsTab("Repo", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-toggle-mcp-codex-repo:repo-tool").waitToExist(timeout: 5))
        element("mcp-toggle-mcp-codex-repo:repo-tool").click()
        XCTAssertTrue(waitUntil({ !self.isOn(self.element("mcp-toggle-mcp-codex-repo:repo-tool")) }, timeout: 10))
        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 20))
        composer.click()
        composer.typeText("Use them again.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "Use them again." }, timeout: 20))
        XCTAssertGreaterThan(history()["threadResumeCount"] as? Int ?? 0, resumesBefore, "Changing the servers resumes the thread.")
        let resumed = try XCTUnwrap((history()["threadResumeConfig"] as? [String: Any])?["mcp_servers"] as? [String: Any])
        XCTAssertEqual(Set(resumed.keys), ["claude-remote", "repo-codex-off"], "The resumed thread gets the new servers.")
        answerQuestionIfAsked()
    }
    // case-contract: test_mcp_status_reports_sign_in_per_provider | Opening the MCP page asks both agents on its own, with no button to press, which servers they start and which need a sign-in, showing Checking sign-in… while they answer and asking again whenever the page is opened: Claude Code, asked with the task's own MCP bridge, reports each server including the ones Playhouse passes it, and Codex reports its own; a server that needs a sign-in shows a Sign in badge with the Claude or Codex logo on its row (labelled Sign in for Claude or Sign in for Codex), and the claude.ai connectors and plugin servers Claude Code starts that no file defines are listed under Also started by Claude Code in the Managed section, a connector that needs a sign-in with the same badge. Asking for one provider only asks that provider. An agent that can't be asked is reported by name on the page while the other agent's answer is still shown.
    func test_mcp_status_reports_sign_in_per_provider() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let codexStatus = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".mcp-status")
        let codexStatusFail = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".mcp-status-fail")
        try? FileManager.default.removeItem(at: codexStatusFail)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: codexStatus)
            try? FileManager.default.removeItem(at: codexStatusFail)
        }
        let repository = try makeSkillRepository("mcp-status-repo", skills: [:])
        try writeMcpJSON(mcpClaudeState, ["mcpServers": ["claude-remote": ["type": "http", "url": "https://remote.example.com/mcp"]]])
        try writeRuleFile(mcpCodexConfig, "[mcp_servers.codex-remote]\nurl = \"https://codex.example.com/mcp\"\n\n[mcp_servers.codex-tool]\ncommand = \"codex-tool\"\n")
        let claude = try installSkillsClaudeFixture("claude-fixture-mcp-status")
        try writeMcpJSON(URL(fileURLWithPath: claude.path + ".mcp-status"), [
            ["name": "claude-remote", "status": "needs-auth"],
            ["name": "claude.ai Notes", "status": "needs-auth"],
            ["name": "plugin:kit:helper", "status": "connected"],
        ])
        try writeMcpJSON(codexStatus, [
            ["name": "codex-remote", "authStatus": "notLoggedIn", "tools": [:]],
            ["name": "codex-tool", "authStatus": "unsupported", "tools": [:]],
        ])
        // Claude Code answers slowly, so the page can be seen while it is still checking.
        let claudeDelay = URL(fileURLWithPath: claude.path + ".mcp-status-delay")
        try "4\n".write(to: claudeDelay, atomically: true, encoding: .utf8)
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("MCP status", repositories: [repository], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        openTask(named: "MCP status")
        openMcpPage()
        XCTAssertTrue(element("mcp-checking-status").waitToExist(timeout: 10), "The page shows it is checking as soon as it opens.")
        XCTAssertEqual(accessibleLabelOrValue(of: element("mcp-checking-status")), "Checking sign-in…")
        XCTAssertFalse(element("mcp-signin-claude-remote-claude").exists, "No badge shows before the agents have answered.")
        attachScreenshot(named: "Checking sign-in while the agents answer")
        XCTAssertFalse(element("mcp-check-status").exists, "There is no button to press: the page checks on its own.")
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-row-claude-remote").waitToExist(timeout: 10))
        XCTAssertTrue(element("mcp-signin-claude-remote-claude").waitToExist(timeout: 30),
                      "A server Claude can't start without a sign-in is marked as soon as the page has asked.")
        XCTAssertTrue(element("mcp-signin-codex-remote-codex").exists, "A server Codex can't start without a sign-in is marked.")
        XCTAssertFalse(element("mcp-signin-codex-tool-codex").exists, "A server that needs no sign-in is not marked.")
        // The narrow card keeps a row's sign-in badge, a provider logo and "Sign in", inside it beside the name.
        for (server, provider) in [("claude-remote", "Claude"), ("codex-remote", "Codex")] {
            let badge = element("mcp-signin-\(server)-\(provider.lowercased())")
            XCTAssertLessThanOrEqual(badge.frame.maxX, element("mcp-row-\(server)").frame.maxX + 1, "\(server)'s sign-in badge fits inside its row.")
            XCTAssertTrue(accessibleLabelOrValue(of: badge).contains("Sign in for \(provider)"), "The short badge still names its agent to assistive tech.")
            assertRowFitsSkillsModal("mcp-row-\(server)", name: "mcp-name-\(server)")
        }
        attachElementScreenshot(element("skills-page"), named: "Sign-in badges in the narrow MCP modal")
        XCTAssertTrue(waitUntil({ !self.element("mcp-checking-status").exists }, timeout: 30), "The check finishes.")
        XCTAssertFalse(element("mcp-error").exists, "Both agents answered.")
        attachScreenshot(named: "Opening the page marks servers that need a sign-in")
        selectSkillsTab("Managed", picker: "mcp-tab-picker")
        XCTAssertTrue(element("mcp-connector-claude.ai Notes").waitToExist(timeout: 5), "A claude.ai connector is listed.")
        XCTAssertTrue(isListed("mcp-connector-claude.ai Notes", inSection: "mcp-group-managed"), "Connectors are listed in the Managed section.")
        let connectorSignIn = element("mcp-connector-signin-claude.ai Notes")
        XCTAssertTrue(connectorSignIn.exists, "A connector that needs a sign-in has the same badge.")
        XCTAssertTrue(connectorSignIn.isEnabled && connectorSignIn.isHittable, "The badge is a button, not a label.")
        // A claude.ai connector is signed in to on claude.ai: the click opens its settings (a test build never opens a browser).
        connectorSignIn.click()
        XCTAssertFalse(element("mcp-error").exists, "Clicking a connector's badge starts no sign-in that could fail.")
        XCTAssertTrue(connectorSignIn.exists && connectorSignIn.isEnabled, "The badge stays: it signs in on claude.ai, not here.")
        XCTAssertTrue(element("mcp-connector-plugin:kit:helper").exists, "A plugin server is listed.")
        XCTAssertFalse(element("mcp-connector-signin-plugin:kit:helper").exists, "A signed-in plugin server has no sign-in badge.")
        XCTAssertFalse(element("mcp-connector-claude-remote").exists, "A server a file defines is not repeated.")
        attachScreenshot(named: "Servers Claude Code starts on its own")
        let search = element("mcp-search")
        typeIntoField(search, text: "notes")
        XCTAssertTrue(waitUntil({ !self.element("mcp-connector-plugin:kit:helper").exists }, timeout: 5), "Search filters the servers Claude Code starts on its own.")
        XCTAssertTrue(element("mcp-connector-claude.ai Notes").exists, "A connector whose name matches stays, ignoring case.")
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(element("mcp-connector-plugin:kit:helper").waitToExist(timeout: 5), "Clearing the search shows every connector again.")

        // Opening the page again asks again, now with Codex unable to answer.
        try "Fail the status request.\n".write(to: codexStatusFail, atomically: true, encoding: .utf8)
        selectSkillsTab("Skills", picker: "skills-kind-picker")
        selectSkillsTab("MCP", picker: "skills-kind-picker")
        XCTAssertTrue(element("mcp-page").waitToExist(timeout: 10))
        XCTAssertTrue(element("mcp-checking-status").waitToExist(timeout: 10), "Opening the page checks again.")
        selectSkillsTab("Global", picker: "mcp-tab-picker")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("mcp-error")).contains("Codex") }, timeout: 30),
                      "An agent that can't be asked is reported by name.")
        XCTAssertTrue(element("mcp-signin-claude-remote-claude").exists, "The other agent's answer is still shown.")
        XCTAssertFalse(element("mcp-signin-codex-remote-codex").exists, "Codex's earlier answer is not kept as if it were current.")
        attachScreenshot(named: "Opening the page when Codex can't be asked")
        try FileManager.default.removeItem(at: codexStatusFail)
        try FileManager.default.removeItem(at: claudeDelay)

        let report = try XCTUnwrap(try runCLI(["mcp", "status", "--task", taskID])["result"] as? [String: Any])
        XCTAssertEqual((report["errors"] as? [String: Any])?.count, 0)
        let codexOnly = try XCTUnwrap(try runCLI(["mcp", "status", "--task", taskID, "--provider", "codex"])["result"] as? [String: Any])
        XCTAssertEqual((codexOnly["claude"] as? [Any])?.count, 0, "Asking for Codex alone doesn't ask Claude Code.")
        XCTAssertTrue(((codexOnly["codex"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "codex-remote" && $0["needsSignIn"] as? Bool == true })
        let claudeOnly = try XCTUnwrap(try runCLI(["mcp", "status", "--task", taskID, "--provider", "claude"])["result"] as? [String: Any])
        XCTAssertEqual((claudeOnly["codex"] as? [Any])?.count, 0, "Asking for Claude alone doesn't ask Codex.")
        XCTAssertTrue(((claudeOnly["claude"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "claude-remote" && $0["needsSignIn"] as? Bool == true })
        assertCLIError(try runCLI(["mcp", "status", "--provider", "gemini"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertTrue(((report["claude"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "codex-tool" && $0["status"] as? String == "connected" },
                      "Claude is asked with the servers Playhouse passes it.")
        try FileManager.default.removeItem(at: codexStatus)
        let noCodex = try XCTUnwrap(try runCLI(["mcp", "status", "--task", taskID], extraEnvironment: ["PLAYHOUSE_E2E_CODEX_EXECUTABLE": "none"])["result"] as? [String: Any])
        XCTAssertNotNil((noCodex["errors"] as? [String: Any])?["codex"], "An agent that can't be asked is reported by name.")
        XCTAssertTrue(((noCodex["claude"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "claude-remote" }, "The other agent's answer is still shown.")
    }
    // case-contract: test_mcp_authenticate_signs_in_each_provider | The Sign in badge with the Claude or Codex logo on a server (labelled Sign in for Claude or Sign in for Codex) is the button that signs in: it asks that agent to start the OAuth sign-in of that one server (Claude Code's mcp_authenticate, Codex's mcpServer/oauth/login) and returns the authorization link, which the page opens in the browser (a test build only records it, and never opens one) while the badge reads Waiting… (labelled Waiting for sign-in…). A server both agents have shows one Sign in button per agent on the same row, each just that agent's logo so the name keeps room in the narrow card (labelled the same way): each starts only its own agent's sign-in, waiting on one leaves the other clickable, and each badge clears on its own once that agent is signed in. The agent finishes the sign-in when the browser redirects back to it, and the page then checks again by itself and the badge goes away; waiting for it through the CLI keeps the bridge running and returns signed in. Starting one agent's sign-in never asks the other agent, a sign-in nobody finishes times out with a message that names the server, and waiting for a sign-in that was never started or was already reported with either agent, an unknown provider, and a blank server name are rejected or reported without starting anything.
    func test_mcp_authenticate_signs_in_each_provider() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let codexPath = try XCTUnwrap(codexFixtureExecutable)
        let codexSidecars = [".mcp-status", ".mcp-callback", ".mcp-login"].map { URL(fileURLWithPath: codexPath + $0) }
        codexSidecars.forEach { try? FileManager.default.removeItem(at: $0) }
        addTeardownBlock { codexSidecars.forEach { try? FileManager.default.removeItem(at: $0) } }
        let repository = try makeSkillRepository("mcp-auth-repo", skills: [:])
        try writeMcpJSON(mcpClaudeState, ["mcpServers": [
            "shared-remote": ["type": "http", "url": "https://remote.example.com/mcp"],
            "claude-other": ["type": "http", "url": "https://other.example.com/mcp"],
        ]])
        try writeRuleFile(mcpCodexConfig, "[mcp_servers.shared-remote]\nurl = \"https://remote.example.com/mcp\"\n\n[mcp_servers.codex-remote]\nurl = \"https://codex.example.com/mcp\"\n\n[mcp_servers.codex-other]\nurl = \"https://codex-other.example.com/mcp\"\n")
        let claude = try installSkillsClaudeFixture("claude-fixture-mcp-auth")
        try writeMcpJSON(URL(fileURLWithPath: claude.path + ".mcp-status"), [
            ["name": "shared-remote", "status": "needs-auth"], ["name": "claude-other", "status": "needs-auth"],
        ])
        try writeMcpJSON(URL(fileURLWithPath: codexPath + ".mcp-status"), [
            ["name": "shared-remote", "authStatus": "notLoggedIn", "tools": [:]],
            ["name": "codex-remote", "authStatus": "notLoggedIn", "tools": [:]], ["name": "codex-other", "authStatus": "notLoggedIn", "tools": [:]],
        ])
        func logged(_ path: String) -> [[String: String]] {
            ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String]
            }
        }
        /// The browser's redirect back to the agent, which the fixture reads from a file of server names.
        func redirect(_ name: String, to path: String) throws {
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try (existing + name + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("MCP authenticate", repositories: [repository], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        openTask(named: "MCP authenticate")
        openMcpPage()
        selectSkillsTab("Global", picker: "mcp-tab-picker")

        let claudeBadge = element("mcp-signin-shared-remote-claude")
        XCTAssertTrue(claudeBadge.waitToExist(timeout: 30), "The sign-in badges show up without pressing anything.")
        XCTAssertTrue(element("mcp-signin-codex-remote-codex").exists)
        let sharedCodexBadge = element("mcp-signin-shared-remote-codex")
        XCTAssertTrue(sharedCodexBadge.exists, "A server both agents have gets a sign-in button for each of them on the same row.")
        XCTAssertTrue(element("mcp-row-shared-remote").exists)
        XCTAssertLessThan(sharedCodexBadge.frame.width, element("mcp-signin-codex-remote-codex").frame.width,
                          "A row with a badge for each agent shows just the logos, narrower than a lone Sign in badge.")
        // Two sign-in badges, a switch and a menu make this the most crowded row; it still fits the narrow card.
        assertRowFitsSkillsModal("mcp-row-shared-remote", name: "mcp-name-shared-remote")
        attachElementScreenshot(element("skills-page"), named: "A server both agents have needs a sign-in for each of them")

        // A real click at the badge's position: it starts the sign-in rather than opening the server's editor.
        claudeBadge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: claudeBadge).contains("Waiting for sign-in") }, timeout: 15),
                      "The badge reads Waiting for sign-in… while Claude Code waits for the browser.")
        XCTAssertFalse(element("mcp-editor-panel").exists, "Clicking the badge doesn't open the server's editor.")
        XCTAssertTrue(sharedCodexBadge.isEnabled && accessibleLabelOrValue(of: sharedCodexBadge).contains("Sign in for Codex"),
                      "Codex's button on the same server stays available while Claude's waits.")
        XCTAssertTrue(waitUntil({ logged(claude.path + ".mcp-authenticate") == [["serverName": "shared-remote"]] }, timeout: 20),
                      "Claude Code is asked to sign in to that server only.")
        XCTAssertTrue(logged(codexPath + ".mcp-login").isEmpty, "Claude's sign-in doesn't ask Codex.")
        XCTAssertTrue(element("mcp-signin-codex-remote-codex").exists, "The other agent's badge is unchanged.")
        XCTAssertFalse(claudeBadge.isEnabled, "A sign-in that is waiting can't be started twice.")
        assertRowFitsSkillsModal("mcp-row-shared-remote", name: "mcp-name-shared-remote")
        attachScreenshot(named: "Claude sign-in waiting for the browser")
        try redirect("shared-remote", to: claude.path + ".mcp-callback")
        XCTAssertTrue(waitUntil({ !self.element("mcp-signin-shared-remote-claude").exists }, timeout: 30),
                      "Once the browser has redirected back, the badge goes away.")
        XCTAssertFalse(element("mcp-error").exists)
        XCTAssertTrue(element("mcp-signin-codex-remote-codex").exists)
        XCTAssertTrue(sharedCodexBadge.exists, "Signing in for Claude doesn't sign the same server in for Codex.")
        attachScreenshot(named: "Claude sign-in finished; the same server still needs Codex's")

        let codexBadge = element("mcp-signin-codex-remote-codex")
        codexBadge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: codexBadge).contains("Waiting for sign-in") }, timeout: 15))
        XCTAssertTrue(waitUntil({ logged(codexPath + ".mcp-login") == [["name": "codex-remote"]] }, timeout: 20), "Codex is asked to sign in to that server only.")
        XCTAssertEqual(logged(claude.path + ".mcp-authenticate"), [["serverName": "shared-remote"]], "Codex's sign-in doesn't ask Claude Code.")
        attachScreenshot(named: "Codex sign-in waiting for the browser")
        try redirect("codex-remote", to: codexPath + ".mcp-callback")
        XCTAssertTrue(waitUntil({ !self.element("mcp-signin-codex-remote-codex").exists }, timeout: 30), "The Codex badge goes away too.")
        XCTAssertFalse(element("mcp-error").exists)
        XCTAssertTrue(element("mcp-signin-claude-other-claude").exists && element("mcp-signin-codex-other-codex").exists, "Other servers still need theirs.")
        attachScreenshot(named: "Both sign-ins finished")

        func cli(_ command: [String], extra: [String: String] = [:], status: Int32 = 0) throws -> [String: Any] {
            try runCLI(["mcp"] + command + ["--task", taskID], expectedStatus: status, extraEnvironment: extra)
        }
        func result(_ response: [String: Any]) throws -> [String: Any] { try XCTUnwrap(response["result"] as? [String: Any]) }
        let started = try result(try cli(["authenticate", "--provider", "claude", "--name", "claude-other"], extra: ["PLAYHOUSE_E2E_MCP_LOGIN_TIMEOUT_SECONDS": "2"]))
        XCTAssertEqual(started["authorizationUrl"] as? String, "https://auth.example.test/claude/authorize?server=claude-other")
        let timedOut = try result(try cli(["authenticate-wait", "--provider", "claude", "--name", "claude-other"], extra: ["PLAYHOUSE_E2E_MCP_LOGIN_TIMEOUT_SECONDS": "2"]))
        XCTAssertEqual(timedOut["signedIn"] as? Bool, false, "A sign-in nobody finishes doesn't sign in.")
        XCTAssertTrue((timedOut["error"] as? String ?? "").contains("claude-other") && (timedOut["error"] as? String ?? "").contains("in time"))
        let codexStarted = try result(try cli(["authenticate", "--provider", "codex", "--name", "codex-other"]))
        XCTAssertEqual(codexStarted["authorizationUrl"] as? String, "https://auth.example.test/codex/authorize?server=codex-other")
        let codexTimedOut = try result(try cli(["authenticate-wait", "--provider", "codex", "--name", "codex-other"], extra: ["PLAYHOUSE_E2E_MCP_LOGIN_TIMEOUT_SECONDS": "2"]))
        XCTAssertEqual(codexTimedOut["signedIn"] as? Bool, false)
        XCTAssertTrue((codexTimedOut["error"] as? String ?? "").contains("codex-other"))
        let never = try result(try cli(["authenticate-wait", "--provider", "claude", "--name", "never-started"]))
        XCTAssertEqual(never["signedIn"] as? Bool, false, "Waiting for a sign-in that was never started reports it.")
        XCTAssertTrue((never["error"] as? String ?? "").contains("No sign-in"))
        for (provider, name) in [("claude", "shared-remote"), ("codex", "codex-remote")] {
            let reported = try result(try cli(["authenticate-wait", "--provider", provider, "--name", name]))
            XCTAssertEqual(reported["signedIn"] as? Bool, false, "A finished sign-in is reported once; waiting again finds none in progress.")
            XCTAssertTrue((reported["error"] as? String ?? "").contains("No sign-in"))
        }
        assertCLIError(try cli(["authenticate", "--provider", "gemini", "--name", "shared-remote"], status: 2), code: "invalid_argument")
        assertCLIError(try cli(["authenticate", "--provider", "claude", "--name", ""], status: 2), code: "invalid_argument")
        XCTAssertEqual(logged(claude.path + ".mcp-authenticate").last, ["serverName": "claude-other"], "A rejected request starts nothing.")
    }
}

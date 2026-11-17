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
    // case-contract: test_skills_enable_state_and_outside_links_persist | Turning a skill off is stored by Playhouse rather than in either provider's settings, survives fresh CLI processes and reopening the Skills page, and can be turned back on. The row's actions menu has Disable, or Enable for a skill that is off, which takes effect as soon as it is chosen; a skill that is off shows grayed out, its menu's Use is disabled, and the row still responds, and turning a skill on disk on or off never starts a Claude Code session. Making a skill available outside Playhouse writes a real symlink into the other provider's layout (an absolute link in Claude's global skills folder, a relative link inside the repository), after which the skill shows as Linked; an existing file at the link path is left untouched and the request fails with already_exists, removing the outside link deletes only the symlink and keeps the skill, and a skill without a link cannot be unlinked.
    func test_skills_enable_state_and_outside_links_persist() throws {
        let repository = try makeSkillRepository("skills-link-repo", skills: [
            ".agents/skills/repo-agents/SKILL.md": skillManifest("repo-agents", "Repository agents skill"),
        ])
        try writeSkill(in: skillsHome.appendingPathComponent(".agents/skills"), "global-agents", "Global agents skill")
        try writeSkill(in: skillsHome.appendingPathComponent(".agents/skills"), "blocked", "Its link path is taken")
        // The Skills page reads Claude Code's built-ins from a provider session.
        let claudeExecutable = try installSkillsClaudeFixture("claude-fixture-skills-link")
        let sessionsURL = URL(fileURLWithPath: claudeExecutable.path + ".sessions")
        func claudeSessions() -> Int { ((try? String(contentsOf: sessionsURL, encoding: .utf8)) ?? "").split(separator: "\n").count }
        let claudeSkills = skillsHome.appendingPathComponent(".claude/skills")
        try FileManager.default.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
        try "Not a skill, just a file in the way.\n".write(to: claudeSkills.appendingPathComponent("blocked"), atomically: true, encoding: .utf8)
        launchApp(defaultParent: fixture.parent.path)
        // The window reads Claude's plan usage once at launch, in a session of its own; count from after it.
        let usageReadsURL = URL(fileURLWithPath: claudeExecutable.path + ".usage-reads")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: usageReadsURL.path) }, timeout: 30), "Launch reads Claude's plan usage.")
        let sessionsAtLaunch = claudeSessions()
        let task = try createSkillsTask("Skills links", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        func globalSkill(_ name: String) throws -> [String: Any]? { skillsByName(try skillCatalog(taskID: taskID)["global"])[name] }
        openTask(named: "Skills links")
        openSkillsPage()
        selectSkillsTab("Global")

        XCTAssertTrue(element("skill-row-global-agents").waitToExist(timeout: 10))
        XCTAssertTrue(isSkillOn("global-agents"))
        XCTAssertFalse(element("skill-row-global-agents").switches.firstMatch.exists, "A row has no switch; its menu turns it on or off.")
        // The page reads Claude Code's built-ins once when it opens.
        XCTAssertTrue(waitUntil({ claudeSessions() > sessionsAtLaunch }, timeout: 20), "Opening the Skills page reads Claude Code's built-ins.")
        let sessionsBeforeToggle = claudeSessions()
        toggleSkill("global-agents")
        XCTAssertTrue(waitUntil({ self.isSkillOff("global-agents") }, timeout: 0.75), "Disable takes effect as soon as it is chosen.")
        XCTAssertTrue(waitUntil({ ((try? globalSkill("global-agents"))??["enabled"] as? Bool) == false }, timeout: 10),
                      "Turning a skill off is saved where a fresh CLI process reads it.")
        XCTAssertFalse(waitUntil({ claudeSessions() > sessionsBeforeToggle }, timeout: 3),
                       "Turning a skill on disk off must not start a Claude Code session.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsCodexHome.appendingPathComponent("config.toml").path), "Codex's config is not written.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsHome.appendingPathComponent(".claude/settings.json").path), "Claude's settings are not written.")
        element("skills-back-button").click()
        openSkillsPage()
        selectSkillsTab("Global")
        XCTAssertTrue(waitUntil({ self.element("skill-row-global-agents").exists && self.isSkillOff("global-agents") }, timeout: 10),
                      "The off state survives reopening the Skills page.")
        attachScreenshot(named: "A skill turned off in the Global section, grayed out")
        // A grayed-out skill still responds: its menu opens, with Use disabled and Enable offered.
        element("skill-actions-global-agents").click()
        let disabledUse = app.menuItems.matching(identifier: "skill-use-global-agents").firstMatch
        XCTAssertTrue(disabledUse.waitToExist(timeout: 5), "A skill that is off still opens its menu.")
        XCTAssertFalse(disabledUse.isEnabled, "A skill that is off can't be used.")
        XCTAssertTrue(app.menuItems["Enable"].exists, "A skill that is off offers Enable.")
        attachScreenshot(named: "The menu of a skill that is off: Use disabled, Enable offered")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil({ !disabledUse.exists }, timeout: 5))
        let sessionsBeforeTurningOn = claudeSessions()
        toggleSkill("global-agents")
        XCTAssertTrue(waitUntil({ self.isSkillOn("global-agents") }, timeout: 0.75), "Enable takes effect at once.")
        XCTAssertTrue(waitUntil({ ((try? globalSkill("global-agents"))??["enabled"] as? Bool) == true }, timeout: 10))
        XCTAssertFalse(waitUntil({ claudeSessions() > sessionsBeforeTurningOn }, timeout: 3),
                       "Turning a skill on disk back on must not start a Claude Code session.")

        clickSkillMenuItem(skill: "global-agents", item: "skill-link-global-agents", title: "Make Available Outside Playhouse…")
        XCTAssertTrue(waitUntil({ self.element("confirm-link-skill").exists || self.app.buttons["Create Link"].exists }, timeout: 5))
        attachScreenshot(named: "Make available outside Playhouse confirmation")
        clickDialogButton("confirm-link-skill", title: "Create Link")
        XCTAssertTrue(waitUntil({ (try? FileManager.default.destinationOfSymbolicLink(atPath: claudeSkills.appendingPathComponent("global-agents").path)) != nil }, timeout: 10))
        revealSkillHint("global-agents")
        XCTAssertTrue(element("skill-linked-global-agents").waitToExist(timeout: 10), "A linked skill's hint shows Linked.")
        let link = claudeSkills.appendingPathComponent("global-agents")
        XCTAssertEqual(realPath(try FileManager.default.destinationOfSymbolicLink(atPath: link.path)),
                       realPath(skillsHome.appendingPathComponent(".agents/skills/global-agents").path))
        attachScreenshot(named: "A global skill linked for use outside Playhouse")

        clickSkillMenuItem(skill: "blocked", item: "skill-link-blocked", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-skill", title: "Create Link")
        XCTAssertTrue(element("skills-error").waitToExist(timeout: 10), "A link onto an existing file shows an error.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("skills-error")).contains("already exists"), "The error names the existing file.")
        attachScreenshot(named: "A blocked outside link shows its error")
        XCTAssertEqual(try String(contentsOf: claudeSkills.appendingPathComponent("blocked"), encoding: .utf8), "Not a skill, just a file in the way.\n")
        assertCLIError(try runCLI(["skills", "link", "--task", taskID, "--skill", "global:blocked"], expectedStatus: 1), code: "already_exists")

        selectSkillsTab("Repo")
        clickSkillMenuItem(skill: "repo-agents", item: "skill-link-repo-agents", title: "Make Available Outside Playhouse…")
        clickDialogButton("confirm-link-skill", title: "Create Link")
        XCTAssertTrue(waitUntil({ (try? FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent(".claude/skills/repo-agents").path)) != nil }, timeout: 10))
        revealSkillHint("repo-agents")
        XCTAssertTrue(element("skill-linked-repo-agents").waitToExist(timeout: 10))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent(".claude/skills/repo-agents").path),
                       "../../.agents/skills/repo-agents", "A repository link is relative, so it can be committed.")

        selectSkillsTab("Global")
        clickSkillMenuItem(skill: "global-agents", item: "skill-unlink-global-agents", title: "Remove Outside Link")
        XCTAssertTrue(waitUntil({ (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil }, timeout: 10))
        revealSkillHint("global-agents")
        XCTAssertTrue(waitUntil({ !self.element("skill-linked-global-agents").exists }, timeout: 10), "The hint no longer shows Linked.")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "Removing the outside link deletes only the symlink.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillsHome.appendingPathComponent(".agents/skills/global-agents/SKILL.md").path))
        assertCLIError(try runCLI(["skills", "unlink", "--task", taskID, "--skill", "global:global-agents"], expectedStatus: 2), code: "invalid_argument")
    }
    // case-contract: test_skills_select_many_and_delete_together | Pressing and holding a skill row starts selecting skills, with no separate Select button: each editable row shows a checkbox that a click toggles, built-in skills show none and cannot be selected, and the header shows how many are selected with Fix with Agent, Delete, and Done. Deleting the selection after one confirmation removes every selected skill folder, repository and global alike, from disk, leaves unselected skills in place, forgets a deleted skill's off state, and ends selecting. A batch that includes a read-only or unknown skill deletes nothing and fails with invalid_argument or not_found.
    func test_skills_select_many_and_delete_together() throws {
        let repository = try makeSkillRepository("skills-select-repo", skills: [
            ".agents/skills/repo-one/SKILL.md": skillManifest("repo-one", "First repository skill"),
            ".agents/skills/repo-keep/SKILL.md": skillManifest("repo-keep", "Stays after the bulk delete"),
        ])
        let globalFolder = skillsHome.appendingPathComponent(".agents/skills")
        for name in ["global-one", "global-two"] { try writeSkill(in: globalFolder, name, "Global skill \(name)") }
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills/.system"), "codex-system-skill", "Bundled with Codex")
        _ = try installSkillsClaudeFixture("claude-fixture-skills-select")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Skills select", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        _ = try runCLI(["skills", "disable", "--task", taskID, "--skill", "global:global-two"])
        openTask(named: "Skills select")
        openSkillsPage()

        // There is no Select button: a press and hold is how selecting starts, and Done leaves it.
        XCTAssertTrue(element("new-skill-button").waitToExist(timeout: 5))
        XCTAssertFalse(element("skills-select-button").exists, "The header has no Select button.")
        element("skill-actions-repo-one").click()
        XCTAssertTrue(app.menuItems["Delete…"].waitToExist(timeout: 5), "The actions menu should open.")
        XCTAssertFalse(app.menuItems["Select"].exists, "The actions menu has no Select item.")
        app.typeKey(.escape, modifierFlags: [])
        element("skill-row-repo-one").press(forDuration: 1.0)
        XCTAssertTrue(element("skill-select-repo-one").waitToExist(timeout: 5), "Selecting shows a checkbox on each row.")
        XCTAssertFalse(element("skill-editor-panel").exists, "A press and hold selects rather than opening the editor.")
        element("skills-selection-done").click()
        XCTAssertTrue(waitUntil({ !self.element("skill-select-repo-one").exists }, timeout: 5), "Done stops selecting.")
        XCTAssertTrue(element("skill-actions-repo-one").exists, "Rows show their controls again.")

        // Press and hold a row to start selecting with it.
        element("skill-row-repo-one").press(forDuration: 1.0)
        XCTAssertTrue(waitUntil({ self.element("skills-selection-count").exists }, timeout: 5), "Pressing and holding a skill starts selecting.")
        XCTAssertEqual(selectionCount(), "1 selected", "The pressed skill is selected.")
        XCTAssertEqual(element("skill-select-repo-one").label, "Selected", "The pressed skill's checkbox is checked.")
        XCTAssertEqual(element("skill-select-repo-keep").label, "Not selected")
        XCTAssertFalse(element("skill-actions-repo-one").exists, "Selecting hides a row's own controls.")
        selectSkillsTab("Global")
        element("skill-row-global-one").click()
        element("skill-row-global-two").click()
        XCTAssertTrue(waitUntil({ self.selectionCount() == "3 selected" }, timeout: 5), "A click selects a skill, across sections.")
        attachScreenshot(named: "Several skills selected for one action")
        selectSkillsTab("Built-in")
        XCTAssertTrue(element("skill-row-codex-system-skill").waitToExist(timeout: 10))
        XCTAssertFalse(element("skill-select-codex-system-skill").exists, "A built-in skill shows no checkbox.")
        element("skill-row-codex-system-skill").click()
        XCTAssertEqual(selectionCount(), "3 selected", "A built-in skill cannot be selected.")
        selectSkillsTab("Global")
        element("skill-row-global-two").click()
        XCTAssertTrue(waitUntil({ self.selectionCount() == "2 selected" }, timeout: 5), "Clicking a selected skill deselects it.")
        XCTAssertEqual(element("skill-select-global-two").label, "Not selected")
        element("skill-row-global-two").click()
        XCTAssertTrue(waitUntil({ self.selectionCount() == "3 selected" }, timeout: 5))

        assertCLIError(try runCLI(["skills", "delete", "--task", taskID, "--skill", "global:global-one", "--skill", "builtin:codex:codex-system-skill"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["skills", "delete", "--task", taskID, "--skill", "global:global-one", "--skill", "global:no-such-skill"], expectedStatus: 3), code: "not_found")
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("global-one").path), "A rejected batch deletes nothing.")

        element("skills-delete-selected").click()
        XCTAssertTrue(waitUntil({ self.element("confirm-delete-skill").exists || self.app.buttons["Delete"].exists }, timeout: 5))
        attachScreenshot(named: "Delete several skills confirmation")
        clickDialogButton("confirm-delete-skill", title: "Delete")
        XCTAssertTrue(waitUntil({ !self.element("skill-row-global-one").exists && !self.element("skill-row-global-two").exists }, timeout: 10),
                      "Deleted skills leave the page.")
        XCTAssertTrue(element("new-skill-button").waitToExist(timeout: 5), "Deleting the selection ends selecting.")
        attachScreenshot(named: "Global section after deleting several skills")
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("global-one").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFolder.appendingPathComponent("global-two").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".agents/skills/repo-one").path),
                       "A repository skill in the selection is deleted from the worktree.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".agents/skills/repo-keep/SKILL.md").path), "Unselected skills stay.")
        selectSkillsTab("Repo")
        XCTAssertTrue(element("skill-row-repo-keep").waitToExist(timeout: 5))
        XCTAssertFalse(element("skill-row-repo-one").exists)
        let fresh = try skillCatalog(taskID: taskID)
        XCTAssertEqual((fresh["global"] as? [Any])?.count, 0)
        XCTAssertEqual(skillsByName((fresh["repositories"] as? [[String: Any]])?.first?["skills"]).keys.sorted(), ["repo-keep"])
        try writeSkill(in: globalFolder, "global-two", "Recreated with the same name")
        XCTAssertEqual(skillsByName(try skillCatalog(taskID: taskID)["global"])["global-two"]?["enabled"] as? Bool, true,
                       "Deleting a skill forgets that it was turned off.")
    }
    // case-contract: test_skills_fix_with_agent_starts_task_for_repo_and_global_skills | A conflicting or invalid skill offers a Fix button on its row (Fix with Agent while selecting), and several selected skills can be fixed in one task. Fixing creates a task, on the source task's provider, whose saved prompt teaches the agent the skill format and lists each skill with its problem: repository skills by repository-relative path, to be fixed in the new task's own worktree of the source repository and committed and pushed like any code change, and global skills by absolute path, to be fixed in place with nothing to commit; the global skill folders are opened to the agent as context folders, and fixing only global skills needs no repository. The view switches to the new task's conversation, which sends that prompt as its own composer draft, leaving the composer empty and no unsent draft behind, so the turn runs in the new task's worktree with the global folders reachable. A skill with no problem, a built-in skill, an unknown skill, and a request without a task are rejected without opening a task.
    func test_skills_fix_with_agent_starts_task_for_repo_and_global_skills() throws {
        let repository = try makeSkillRepository("skills-fix-repo", skills: [
            ".agents/skills/repo-dup/SKILL.md": skillManifest("repo-dup", "The agents copy"),
            ".claude/skills/repo-dup/SKILL.md": skillManifest("repo-dup", "A different Claude copy"),
            ".agents/skills/repo-ok/SKILL.md": skillManifest("repo-ok", "Nothing to fix"),
        ])
        try writeSkill(in: skillsHome.appendingPathComponent(".agents/skills"), "global-dup", "The global agents copy")
        try writeSkill(in: skillsHome.appendingPathComponent(".claude/skills"), "global-dup", "The global Claude copy")
        let broken = skillsHome.appendingPathComponent(".agents/skills/global-broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "No frontmatter here.\n".write(to: broken.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills/.system"), "codex-system-skill", "Bundled with Codex")
        let executable = try installSkillsClaudeFixture("claude-fixture-skills-fix")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        func turns() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: historyURL),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).filter { ($0["userText"] as? String)?.isEmpty == false }
        }
        launchApp(defaultParent: fixture.parent.path)
        let source = try createSkillsTask("Skills fix source", repositories: [repository], provider: "claude")
        let sourceID = try XCTUnwrap(source["id"] as? String)
        let sourceWorktree = try XCTUnwrap((source["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
        let tasksBefore = try boardTaskRecords().count
        assertCLIError(try runCLI(["skills", "fix", "--task", sourceID, "--skill", "repo:\(repository.path)#repo-ok"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["skills", "fix", "--task", sourceID, "--skill", "builtin:codex:codex-system-skill"], expectedStatus: 2), code: "invalid_argument")
        assertCLIError(try runCLI(["skills", "fix", "--task", sourceID, "--skill", "global:no-such-skill"], expectedStatus: 3), code: "not_found")
        assertCLIError(try runCLI(["skills", "fix", "--skill", "global:global-dup"], expectedStatus: 2), code: "invalid_argument")
        XCTAssertEqual(try boardTaskRecords().count, tasksBefore, "A rejected fix opens no task.")

        openTask(named: "Skills fix source")
        openSkillsPage()
        XCTAssertTrue(element("skill-fix-repo-dup").waitToExist(timeout: 10), "A conflicting skill offers Fix with Agent.")
        XCTAssertFalse(element("skill-fix-repo-ok").exists, "A skill without a problem has nothing to fix.")
        selectSkillsTab("Global")
        XCTAssertTrue(element("skill-fix-global-dup").waitToExist(timeout: 5))
        XCTAssertTrue(element("skill-fix-global-broken").exists, "An invalid skill offers Fix with Agent too.")
        attachScreenshot(named: "Conflicting and invalid skills offer Fix with Agent")

        // One skill, from its row: a global skill is fixed in place, with no repository.
        element("skill-fix-global-dup").click()
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 10), "Fixing closes the Skills page.")
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == "Fix skill global-dup" }, timeout: 15),
                      "The view switches to the fixing task's conversation.")
        let single = try XCTUnwrap(try boardTaskRecords().first { $0["title"] as? String == "Fix skill global-dup" })
        XCTAssertEqual((single["repositoryWorktrees"] as? [Any])?.count, 0, "Fixing only global skills needs no repository.")
        XCTAssertTrue(waitUntil({ turns().contains { ($0["userText"] as? String)?.contains("`global-dup`") == true } }, timeout: 20),
                      "The fixing task sends its prompt as soon as it opens.")
        XCTAssertFalse(try XCTUnwrap(single["savedPrompt"] as? String).contains("commit and push"))

        // Several skills, selected across sections, fixed in one task.
        openTask(named: "Skills fix source")
        openSkillsPage()
        XCTAssertTrue(element("skill-row-repo-dup").waitToExist(timeout: 10))
        element("skill-row-repo-dup").press(forDuration: 1.0)
        XCTAssertTrue(waitUntil({ self.selectionCount() == "1 selected" }, timeout: 5))
        selectSkillsTab("Global")
        element("skill-row-global-dup").click()
        element("skill-row-global-broken").click()
        XCTAssertTrue(waitUntil({ self.selectionCount() == "3 selected" }, timeout: 5))
        attachScreenshot(named: "Several broken skills selected to fix in one task")
        element("skills-fix-selected").click()
        // The selection is sent in the gallery's order: repositories, then global skills by name.
        let title = "Fix skills repo-dup, global-broken, global-dup"
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: self.element("task-view-title")) == title }, timeout: 15),
                      "The view switches to the new task's conversation.")
        let fixing = try XCTUnwrap(try boardTaskRecords().first { $0["title"] as? String == title })
        let fixingID = try XCTUnwrap(fixing["id"] as? String)
        let prompt = try XCTUnwrap(fixing["savedPrompt"] as? String)
        XCTAssertEqual(fixing["conversationProvider"] as? String, "claude", "The fixing task uses the source task's provider.")
        XCTAssertTrue(prompt.contains("commit and push"))
        XCTAssertTrue(prompt.contains("`repo-dup` in skills-fix-repo: `.agents/skills/repo-dup`, `.claude/skills/repo-dup`"))
        XCTAssertFalse(prompt.contains(sourceWorktree), "Repository paths are relative, so they point into the fixing task's worktree.")
        XCTAssertTrue(prompt.contains("not tracked by Git: fix them directly in place"))
        XCTAssertTrue(prompt.contains("`global-broken`"))
        XCTAssertFalse(prompt.contains("repo-ok"))
        XCTAssertEqual(Set(((fixing["contextFolders"] as? [String]) ?? []).map(realPath)),
                       Set([".agents/skills", ".claude/skills"].map { realPath(skillsHome.appendingPathComponent($0).path) }),
                       "Global skill folders are opened to the agent.")
        XCTAssertTrue(waitUntil({ turns().contains { $0["userText"] as? String == prompt } }, timeout: 20), "The conversation sends the fixing prompt.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'user-message-'")).firstMatch.waitToExist(timeout: 10),
                      "The prompt shows in the new task's conversation.")
        XCTAssertTrue(waitUntil({ (self.element("message-composer").value as? String ?? "").isEmpty }, timeout: 10),
                      "The sent prompt leaves the composer, so it cannot be sent twice.")
        attachScreenshot(named: "The fixing task's conversation after Fix with Agent")
        let turn = try XCTUnwrap(turns().first { $0["userText"] as? String == prompt })
        let started = try XCTUnwrap(try taskRecord(id: fixingID))
        XCTAssertEqual(started["hasUnsentDraft"] as? Bool, false, "The sent prompt leaves no unsent draft behind.")
        XCTAssertEqual(turns().filter { $0["userText"] as? String == prompt }.count, 1, "The fixing prompt is sent exactly once.")
        let worktree = try XCTUnwrap((started["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(worktree["repositoryPath"] as? String, repository.path)
        XCTAssertEqual(worktree["isPending"] as? Bool, false, "Starting the fix creates the task's own worktree.")
        let worktreePath = try XCTUnwrap(worktree["worktreePath"] as? String)
        XCTAssertNotEqual(realPath(worktreePath), realPath(sourceWorktree))
        XCTAssertEqual(realPath(turn["cwd"] as? String ?? ""), realPath(worktreePath), "The turn runs in the fixing task's worktree.")
        let arguments = try XCTUnwrap(turn["arguments"] as? [String])
        let directories = Set(arguments.indices.filter { arguments[$0] == "--add-dir" }.map { realPath(arguments[$0 + 1]) })
        for folder in [".agents/skills", ".claude/skills"] {
            XCTAssertTrue(directories.contains(realPath(skillsHome.appendingPathComponent(folder).path)), "Claude Code can reach the global \(folder) folder.")
        }
    }
    // case-contract: test_skills_bridge_claude_launch_sees_agents_skills | A Claude turn sees the skills Claude Code does not read natively: Playhouse passes a Playhouse-owned --add-dir wrapper whose .claude/skills links to the task worktree's and the global .agents/skills folders, leaves skills Claude already reads out of the wrapper, and turns disabled skills off for that run with --settings skillOverrides, without writing to the repository or Claude's settings. Using a skill from the Skills page puts /skill-name at the start of the composer and the message reaches Claude Code unchanged. The resumed second turn gets the same wrapper, and turning the skill back on drops the override.
    func test_skills_bridge_claude_launch_sees_agents_skills() throws {
        let repository = try makeSkillRepository("skills-claude-repo", skills: [
            ".agents/skills/repo-agents/SKILL.md": skillManifest("repo-agents", "Bridged to Claude"),
            ".claude/skills/repo-claude/SKILL.md": skillManifest("repo-claude", "Claude reads this natively"),
            ".claude/skills/repo-off/SKILL.md": skillManifest("repo-off", "Turned off in Playhouse"),
        ])
        try writeSkill(in: skillsHome.appendingPathComponent(".agents/skills"), "global-agents", "Global skill bridged to Claude")
        let executable = try installSkillsClaudeFixture("claude-fixture-skills-bridge")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Claude skills", repositories: [repository], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        func turns() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: historyURL),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).filter { ($0["userText"] as? String)?.isEmpty == false }
        }
        openTask(named: "Claude skills")
        openSkillsPage()
        XCTAssertTrue(element("skill-row-repo-off").waitToExist(timeout: 10))
        toggleSkill("repo-off")
        XCTAssertTrue(waitUntil({ self.isSkillOff("repo-off") }, timeout: 10))
        selectSkillsTab("Built-in")
        XCTAssertTrue(element("skill-row-simplify").waitToExist(timeout: 20), "Claude Code's built-ins load in the Built-in section.")
        toggleSkill("simplify")
        XCTAssertTrue(waitUntil({ self.isSkillOff("simplify") }, timeout: 10))
        selectSkillsTab("Repo")
        useSkill("repo-agents")
        XCTAssertTrue(waitUntil({ !self.element("skills-page").exists }, timeout: 5), "Use returns to the conversation.")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "/repo-agents " }, timeout: 5), "Use puts /skill-name at the start of the composer.")
        composer.typeText("Tell me a story.")
        attachScreenshot(named: "Composer with a skill inserted from the Skills page")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ turns().contains { $0["userText"] as? String == "/repo-agents Tell me a story." } }, timeout: 20),
                      "The skill invocation reaches Claude Code unchanged.")
        let first = try XCTUnwrap(turns().first { $0["userText"] as? String == "/repo-agents Tell me a story." })
        let arguments = try XCTUnwrap(first["arguments"] as? [String])
        let directories = arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] }
        XCTAssertEqual(directories.count, 1, "One Playhouse wrapper should be added: \(arguments)")
        let wrapper = URL(fileURLWithPath: try XCTUnwrap(directories.first))
        XCTAssertEqual(realPath(wrapper.deletingLastPathComponent().path), realPath(dataDirectory.appendingPathComponent("skill-bridge/claude").path))
        let links = wrapper.appendingPathComponent(".claude/skills")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: links.path).sorted(), ["global-agents", "repo-agents"],
                       "Only skills Claude does not read natively are bridged.")
        XCTAssertEqual(realPath(links.appendingPathComponent("repo-agents").path), realPath(worktree.appendingPathComponent(".agents/skills/repo-agents").path))
        let settingsIndex = try XCTUnwrap(arguments.firstIndex(of: "--settings"))
        let settings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(arguments[settingsIndex + 1].utf8)) as? [String: [String: String]])
        XCTAssertEqual(settings, ["skillOverrides": ["repo-off": "off", "simplify": "off"]],
                       "Disabled repository and Claude built-in skills are turned off for this run.")
        XCTAssertEqual((first["skills"] as? [String])?.sorted(), ["global-agents", "repo-agents", "repo-claude"])
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "The worktree is not written to.")
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 20))

        openSkillsPage()
        toggleSkill("repo-off")
        XCTAssertTrue(waitUntil({ self.isSkillOn("repo-off") }, timeout: 10))
        selectSkillsTab("Built-in")
        XCTAssertTrue(element("skill-row-simplify").waitToExist(timeout: 20))
        toggleSkill("simplify")
        XCTAssertTrue(waitUntil({ self.isSkillOn("simplify") }, timeout: 10))
        element("skills-back-button").click()
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 10))
        composer.click()
        composer.typeText("Tell me a story again.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ turns().contains { $0["userText"] as? String == "Tell me a story again." } }, timeout: 20))
        let second = try XCTUnwrap(turns().last { $0["userText"] as? String == "Tell me a story again." })
        XCTAssertEqual(second["resumed"] as? Bool, true, "The second turn resumes the Claude session.")
        let resumedArguments = try XCTUnwrap(second["arguments"] as? [String])
        XCTAssertEqual(resumedArguments.indices.filter { resumedArguments[$0] == "--add-dir" }.map { realPath(resumedArguments[$0 + 1]) },
                       [realPath(wrapper.path)], "A resumed turn gets the same wrapper.")
        XCTAssertFalse(resumedArguments.contains("--settings"), "Turning the skill back on drops the override.")
        XCTAssertTrue((second["skills"] as? [String])?.contains("repo-off") == true)
    }
    // case-contract: test_skills_bridge_codex_thread_sees_claude_skills | A Codex turn sees the skills Codex does not read natively: Playhouse gives the shared app-server extra skill roots made of Playhouse-owned wrapper folders that link to the task worktree's and the global .claude/skills folders, leaves the cwd repository's .agents/skills to Codex, and starts the thread with a per-thread skills config that disables both the task's disabled skills and other tasks' bridged skills, without writing Codex's config.toml. Using a skill from the Skills page puts /skill-name in the composer, and the turn sends Codex a structured skill input naming that skill's SKILL.md alongside the text; a later turn without a skill sends none.
    func test_skills_bridge_codex_thread_sees_claude_skills() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let historyURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        let other = try makeSkillRepository("skills-other-repo", skills: [
            ".claude/skills/other-claude/SKILL.md": skillManifest("other-claude", "Belongs to another task"),
        ])
        let repository = try makeSkillRepository("skills-codex-repo", skills: [
            ".claude/skills/repo-claude/SKILL.md": skillManifest("repo-claude", "Bridged to Codex"),
            ".agents/skills/repo-agents/SKILL.md": skillManifest("repo-agents", "Codex reads this natively"),
            ".agents/skills/repo-off/SKILL.md": skillManifest("repo-off", "Turned off in Playhouse"),
        ])
        try writeSkill(in: skillsHome.appendingPathComponent(".claude/skills"), "global-claude", "Global skill bridged to Codex")
        // The Skills page reads Claude Code's built-ins from a provider session.
        _ = try installSkillsClaudeFixture("claude-fixture-skills-codex")
        // Its own daemon, so restarting it below leaves the UI runner's shared one alone.
        let daemonEnvironment = ["PLAYHOUSE_BRIDGE_SERVICE_NAME": "\(serviceName!).skills-codex-\(UUID().uuidString.prefix(8))"]
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: daemonEnvironment)
        try createTaskFixture(title: "Other skills task", roots: [other.path])
        let otherBridge = try XCTUnwrap(try runCLI(["skills", "bridge", "--task", try taskID(named: "Other skills task")])["result"] as? [String: Any])
        let otherLink = try XCTUnwrap((otherBridge["codexLinks"] as? [[String: Any]])?.first?["link"] as? String)
        let otherWrapper = URL(fileURLWithPath: otherLink).deletingLastPathComponent()
        let task = try createSkillsTask("Codex skills", repositories: [repository])
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

        openTask(named: "Codex skills")
        openSkillsPage()
        XCTAssertTrue(element("skill-row-repo-off").waitToExist(timeout: 10))
        toggleSkill("repo-off")
        XCTAssertTrue(waitUntil({ self.isSkillOff("repo-off") }, timeout: 10))
        useSkill("repo-claude")
        let composer = element("message-composer")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "/repo-claude " }, timeout: 5), "Use puts /skill-name in the composer.")
        composer.typeText("Complete this task.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "/repo-claude Complete this task." }, timeout: 20))
        let sent = history()
        let skillInputs = try XCTUnwrap(sent["skillInputs"] as? [[String: String]])
        XCTAssertEqual(skillInputs.count, 1)
        XCTAssertEqual(skillInputs.first?["type"], "skill")
        XCTAssertEqual(skillInputs.first?["name"], "repo-claude")
        XCTAssertEqual(realPath(skillInputs.first?["path"] ?? ""), realPath(worktree.appendingPathComponent(".claude/skills/repo-claude/SKILL.md").path),
                       "Codex receives a structured skill input naming the skill's SKILL.md.")
        let bridge = try XCTUnwrap(try runCLI(["skills", "bridge", "--task", taskID])["result"] as? [String: Any])
        let ownWrapper = URL(fileURLWithPath: try XCTUnwrap((bridge["codexLinks"] as? [[String: Any]])?.first?["link"] as? String)).deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownWrapper.path).filter { !$0.hasPrefix(".") }.sorted(), ["global-claude", "repo-claude"],
                       "The cwd repository's .agents skills stay native to Codex.")
        XCTAssertEqual(Set((sent["skillExtraRoots"] as? [String] ?? []).map(realPath)), Set([ownWrapper.path, otherWrapper.path].map(realPath)),
                       "The shared app-server gets every task's wrapper as an extra root.")
        let config = (((sent["threadStartConfig"] as? [String: Any])?["skills"] as? [String: Any])?["config"] as? [[String: Any]]) ?? []
        let disabled = Set(config.filter { $0["enabled"] as? Bool == false }.compactMap { $0["path"] as? String }.map(realPath))
        XCTAssertTrue(disabled.contains(realPath(otherWrapper.appendingPathComponent("other-claude/SKILL.md").path)), "Another task's bridged skill is hidden.")
        XCTAssertTrue(disabled.contains(realPath(worktree.appendingPathComponent(".agents/skills/repo-off/SKILL.md").path)), "A disabled native skill is turned off.")
        XCTAssertFalse(disabled.contains { $0.hasPrefix(realPath(ownWrapper.path)) }, "The thread's own bridged skills stay on.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsCodexHome.appendingPathComponent("config.toml").path), "Codex's config.toml is not written.")
        attachScreenshot(named: "Codex turn started with a skill from the Skills page")
        answerQuestionIfAsked()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String).map { $0 != "In Progress" } == true }, timeout: 30),
                      "The first turn should settle before the next message.")

        // A restarted app-server loads the thread again, and must get the bridge again.
        let callsBefore = history()["skillExtraRootsCalls"] as? Int ?? 0
        // Stopping the bridge daemon also ends its app-server; the next send starts both again.
        let daemonPID = try XCTUnwrap((try runCLI(["status"], extraEnvironment: daemonEnvironment)["result"] as? [String: Any])?["processID"] as? Int)
        XCTAssertEqual(kill(pid_t(daemonPID), SIGKILL), 0, "The bridge daemon should stop so its Codex app-server restarts.")
        XCTAssertTrue(waitUntil({ kill(pid_t(daemonPID), 0) != 0 }, timeout: 10), "The stopped daemon should exit.")
        XCTAssertTrue(waitUntil({ composer.exists && composer.isHittable }, timeout: 20))
        composer.click()
        composer.typeText("Complete this task again.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ history()["userMessage"] as? String == "Complete this task again." }, timeout: 20))
        let resumed = history()
        XCTAssertEqual((resumed["skillInputs"] as? [[String: String]])?.count, 0, "A turn that names no skill sends none.")
        XCTAssertGreaterThan(resumed["skillExtraRootsCalls"] as? Int ?? 0, callsBefore, "The fresh app-server gets the extra skill roots again.")
        let resumedConfig = (((resumed["threadResumeConfig"] as? [String: Any])?["skills"] as? [String: Any])?["config"] as? [[String: Any]]) ?? []
        XCTAssertEqual(Set(resumedConfig.filter { $0["enabled"] as? Bool == false }.compactMap { $0["path"] as? String }.map(realPath)), disabled,
                       "The resumed thread gets the same per-thread skill config.")
        answerQuestionIfAsked()
    }
    // case-contract: test_skills_private_create_list_convert_and_delete | A repository skill created with Private on is written only to Playhouse's private skill store, in a folder keyed by the source repository and laid out as .claude/skills/<name>/SKILL.md, with nothing written to the repository or the task worktree, whose git status stays clean. It is listed under its repository with scope private and a Private badge, every task on that repository sees it from its own worktree, and a task on another repository does not. A private skill cannot take a name that the committed skills of any of the task's repositories, the global skills, or the built-in skills already use, and a committed skill of the same name that appears later in a worktree takes precedence there: the private one is shown as Shadowed and used by neither provider. Editing saves the store's SKILL.md, a private skill cannot be linked outside Playhouse, Convert to Repository Skill moves it into the worktree's .agents/skills as a repository skill ready to commit, Make Private moves a repository skill back into the store and out of the worktree, Make Private to a repository moves a global skill into that repository's store, and Delete removes only its store folder.
    func test_skills_private_create_list_convert_and_delete() throws {
        let repository = try makeSkillRepository("skills-private-repo", skills: [
            ".agents/skills/committed/SKILL.md": skillManifest("committed", "A committed repository skill"),
        ])
        let other = try makeSkillRepository("skills-private-other", skills: [:])
        try writeSkill(in: skillsHome.appendingPathComponent(".agents/skills"), "global-taken", "A global skill")
        // The Skills page reads Claude Code's built-ins from a provider session.
        _ = try installSkillsClaudeFixture("claude-fixture-skills-private")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Private skills", repositories: [repository])
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        let store = privateSkillStore(repository)
        let folder = store.appendingPathComponent(".claude/skills/deploy-notes")
        let privateID = "private:\(repository.path)#deploy-notes"
        func section(_ id: String = taskID) throws -> [[String: Any]] {
            try XCTUnwrap((try skillCatalog(taskID: id)["repositories"] as? [[String: Any]])?.first?["skills"] as? [[String: Any]])
        }
        func privateRecord(_ id: String = taskID) throws -> [String: Any]? { try section(id).first { $0["id"] as? String == privateID } }
        openTask(named: "Private skills")
        // Where the sidebar's Skills button sits, so a later step can click it while the
        // Skills page is still sliding out and covers it.
        let skillsButton = element("open-skills-button")
        XCTAssertTrue(waitUntil({ skillsButton.exists && skillsButton.isHittable }, timeout: 15))
        let window = app.windows.firstMatch
        let skillsButtonPoint = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: skillsButton.frame.midX - window.frame.minX, dy: skillsButton.frame.midY - window.frame.minY))
        openSkillsPage()

        func fillNewSkill(name: String, description: String, body: String?) {
            element("new-skill-button").click()
            XCTAssertTrue(element("new-skill-name").waitToExist(timeout: 5), "New Skill should open its panel.")
            typeIntoField(element("new-skill-name"), text: name)
            typeIntoField(element("new-skill-description"), text: description)
            if let body { typeIntoField(element("new-skill-body"), text: body) }
            XCTAssertFalse(element("new-skill-private").exists, "A global skill has no Private switch.")
            element("new-skill-scope").click()
            let option = app.menuItems["skills-private-repo"]
            XCTAssertTrue(option.waitToExist(timeout: 5), "Save to should offer the task's repository.")
            option.click()
            let privateSwitch = element("new-skill-private")
            XCTAssertTrue(privateSwitch.waitToExist(timeout: 5), "A repository skill offers the Private switch.")
            if !isOn(privateSwitch) { privateSwitch.click() }
            XCTAssertTrue(waitUntil({ self.isOn(self.element("new-skill-private")) }, timeout: 5))
        }

        fillNewSkill(name: "committed", description: "Taken", body: nil)
        element("new-skill-create").click()
        XCTAssertTrue(element("new-skill-error").waitToExist(timeout: 5), "A private skill cannot take a committed skill's name.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "A rejected private skill writes nothing.")
        element("new-skill-cancel").click()
        XCTAssertTrue(waitUntil({ !self.element("new-skill-name").exists }, timeout: 5))
        assertCLIError(try runCLI(["skills", "create", "--task", taskID, "--scope", "private", "--name", "global-taken", "--description", "Taken"], expectedStatus: 1), code: "already_exists")
        try writeSkill(in: skillsCodexHome.appendingPathComponent("skills/.system"), "codex-system-skill", "Bundled with Codex")
        assertCLIError(try runCLI(["skills", "create", "--task", taskID, "--scope", "private", "--name", "codex-system-skill", "--description", "Taken"], expectedStatus: 1), code: "already_exists")
        let bothID = try XCTUnwrap(try createSkillsTask("Private skills two repositories", repositories: [repository, other])["id"] as? String)
        assertCLIError(try runCLI(["skills", "create", "--task", bothID, "--scope", "private", "--root", other.path, "--name", "committed",
                                   "--description", "Taken in the other repository"], expectedStatus: 1), code: "already_exists")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "A rejected private skill writes nothing.")

        fillNewSkill(name: "deploy-notes", description: "Write deploy notes", body: "List the deploy steps.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("new-skill-destination-note")).hasPrefix("Private:"), "The panel explains that nothing is written to the repository.")
        attachScreenshot(named: "New Skill with Private on for a repository skill")
        element("new-skill-create").click()
        XCTAssertTrue(waitUntil({ !self.element("new-skill-name").exists }, timeout: 10), "Creating closes the panel.")
        XCTAssertTrue(element("skill-row-deploy-notes").waitToExist(timeout: 10), "The private skill shows in the Repo section.")
        XCTAssertTrue(isListed("skill-row-deploy-notes", inSection: "skills-group-repo"))
        XCTAssertTrue(element("skills-repo-section-skills-private-repo").exists)
        revealSkillHint("committed")
        XCTAssertFalse(element("skill-private-committed").exists, "A committed skill's hint has no Private badge.")
        revealSkillHint("deploy-notes")
        XCTAssertTrue(element("skill-private-deploy-notes").waitToExist(timeout: 5), "The private skill's hint has a Private badge.")
        XCTAssertTrue(rowBadge("skill-provider-deploy-notes-both").exists)
        XCTAssertTrue(accessibleLabelOrValue(of: element("skill-location-deploy-notes")).hasPrefix("Private to skills-private-repo"), "The hint names the repository it belongs to.")
        attachScreenshot(named: "A private skill's hint with its Private badge")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8),
                       "---\nname: deploy-notes\ndescription: \"Write deploy notes\"\n---\n\nList the deploy steps.\n")
        XCTAssertEqual(try String(contentsOf: store.appendingPathComponent("repository"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), repository.path)
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "Creating a private skill writes nothing into the worktree.")
        XCTAssertEqual(try runGitOutput(repository, "status", "--porcelain"), "", "Creating a private skill writes nothing into the repository.")
        let created = try XCTUnwrap(try privateRecord())
        XCTAssertEqual(created["scope"] as? String, "private")
        XCTAssertEqual(realPath(created["folderPath"] as? String ?? ""), realPath(folder.path))
        XCTAssertEqual(((created["locations"] as? [[String: Any]]) ?? []).map { $0["layout"] as? String }, ["playhousePrivate"])
        assertCLIError(try runCLI(["skills", "create", "--task", taskID, "--scope", "private", "--name", "deploy-notes", "--description", "Again"], expectedStatus: 1), code: "already_exists")

        let again = try createSkillsTask("Private skills again", repositories: [repository])
        let againID = try XCTUnwrap(again["id"] as? String)
        XCTAssertNotNil(try privateRecord(againID), "Every task on the repository sees its private skills.")
        let otherTask = try createSkillsTask("Private skills elsewhere", repositories: [other])
        XCTAssertEqual(try section(try XCTUnwrap(otherTask["id"] as? String)).count, 0, "A task on another repository does not.")

        XCTAssertTrue(openPanel("skill-editor-panel", with: element("skill-row-deploy-notes")), "Clicking the private skill opens its editor.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("skill-editor-location")).contains("private-skills"), "The editor shows the store's SKILL.md.")
        let edited = skillManifest("deploy-notes", "Write short deploy notes", body: "Name each deployed service.")
        let editor = element("skill-editor")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(edited)
        element("skill-editor-save").click()
        XCTAssertTrue(waitUntil({ !self.element("skill-editor-panel").exists }, timeout: 10), "Saving closes the editor.")
        XCTAssertTrue(waitUntil({ (try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) == edited }, timeout: 10), "Editing saves the store's SKILL.md.")
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "Editing a private skill writes nothing into the worktree.")
        element("skill-actions-deploy-notes").click()
        XCTAssertTrue(app.menuItems["Convert to Repository Skill"].waitToExist(timeout: 5), "A private skill offers Convert to Repository Skill.")
        XCTAssertFalse(app.menuItems["Make Available Outside Playhouse…"].exists, "A private skill cannot be linked outside Playhouse.")
        XCTAssertFalse(app.menuItems["Make Private"].exists, "A private skill is not offered a move into its own store.")
        attachScreenshot(named: "A private skill's actions menu offers Convert to Repository Skill")
        app.typeKey(.escape, modifierFlags: [])
        assertCLIError(try runCLI(["skills", "link", "--task", taskID, "--skill", privateID], expectedStatus: 2), code: "invalid_argument")

        // A committed skill of the same name takes precedence in the worktree it appears in.
        try writeSkill(in: worktree.appendingPathComponent(".claude/skills"), "deploy-notes", "A committed copy")
        element("skills-back-button").click()
        openSkillsPage()
        XCTAssertTrue(element("skill-shadowed-deploy-notes").waitToExist(timeout: 10), "A shadowed private skill is flagged on the page.")
        // Both copies are listed as deploy-notes; rest on the shadowed private one.
        let shadowedRow = app.descendants(matching: .any).matching(identifier: "skill-row-deploy-notes")
            .containing(.any, identifier: "skill-shadowed-deploy-notes").firstMatch
        XCTAssertTrue(waitUntil({
            shadowedRow.hover()
            return self.element("skill-issue-deploy-notes").waitToExist(timeout: 2)
        }, timeout: 10), "Resting on the shadowed private skill shows its hint.")
        XCTAssertTrue(accessibleLabelOrValue(of: element("skill-issue-deploy-notes")).contains("takes precedence"), "The hint explains which skill takes precedence.")
        attachScreenshot(named: "A private skill shadowed by a committed skill of the same name")
        let shadowed = try XCTUnwrap(try privateRecord())
        XCTAssertEqual(shadowed["providers"] as? [String], [], "A shadowed private skill is used by neither provider.")
        XCTAssertEqual(shadowed["shadowedBy"] as? String, "skills-private-repo's committed skills")
        XCTAssertEqual(try privateRecord(againID)?["providers"] as? [String], ["claude", "codex"], "Another worktree without the copy still uses the private skill.")
        try FileManager.default.removeItem(at: worktree.appendingPathComponent(".claude"))
        // Reopen straight away, through the Skills button's recorded position rather than a wait for
        // it to become hittable: when the VM is slow the click lands while the closing page is
        // still sliding out, and the page must then be a fresh one that reads the catalog again,
        // not the closing page revived with what it read before. XCUITest's idle wait after the
        // back click usually outlasts the slide-out, so this cannot force that timing every run.
        element("skills-back-button").click()
        skillsButtonPoint.click()
        XCTAssertTrue(element("skills-page").waitToExist(timeout: 10), "Clicking the Skills button right after closing the page should reopen it.")
        XCTAssertTrue(waitUntil({ !self.element("skill-shadowed-deploy-notes").exists && self.element("skill-row-deploy-notes").exists }, timeout: 10),
                      "A Skills page reopened right after closing should show the catalog read after the committed copy was removed.")
        revealSkillHint("deploy-notes")
        XCTAssertTrue(element("skill-private-deploy-notes").waitToExist(timeout: 5), "The no longer shadowed skill is still private.")
        attachScreenshot(named: "Reopened Skills page shows the private skill no longer shadowed")

        clickSkillMenuItem(skill: "deploy-notes", item: "skill-convert-repo-deploy-notes", title: "Convert to Repository Skill")
        let converted = worktree.appendingPathComponent(".agents/skills/deploy-notes/SKILL.md")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: converted.path) }, timeout: 10), "Converting moves the skill into the worktree's Agent Skills folder.")
        XCTAssertTrue(element("skill-row-deploy-notes").waitToExist(timeout: 10))
        revealSkillHint("deploy-notes")
        XCTAssertTrue(waitUntil({ !self.element("skill-private-deploy-notes").exists }, timeout: 10),
                      "The converted skill is a repository skill without the Private badge.")
        XCTAssertEqual(try String(contentsOf: converted, encoding: .utf8), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Converting removes the skill from the store.")
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain").trimmingCharacters(in: .whitespacesAndNewlines), "?? .agents/skills/deploy-notes/", "The converted skill is ready to commit.")
        XCTAssertEqual(try section(taskID).first { $0["name"] as? String == "deploy-notes" }?["scope"] as? String, "repo")
        XCTAssertNil(try privateRecord(againID), "A converted skill is no longer private to the repository's other tasks.")
        attachScreenshot(named: "A private skill converted to a repository skill")

        clickSkillMenuItem(skill: "deploy-notes", item: "skill-make-private-deploy-notes", title: "Make Private")
        XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: folder.appendingPathComponent("SKILL.md").path) }, timeout: 10))
        revealSkillHint("deploy-notes")
        XCTAssertTrue(waitUntil({ self.element("skill-private-deploy-notes").exists }, timeout: 10), "Make Private shows the Private badge again.")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8), edited, "Make Private moves the skill back into the store.")
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "Make Private takes the skill out of the worktree.")
        attachScreenshot(named: "A repository skill made private again")
        assertCLIError(try runCLI(["skills", "move", "--task", taskID, "--skill", privateID, "--scope", "private"], expectedStatus: 2), code: "invalid_argument")

        clickSkillMenuItem(skill: "deploy-notes", item: "skill-delete-deploy-notes", title: "Delete…")
        clickDialogButton("confirm-delete-skill", title: "Delete")
        XCTAssertTrue(waitUntil({ !self.element("skill-row-deploy-notes").exists }, timeout: 10), "A deleted private skill leaves the page.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Deleting removes the private skill's store folder.")
        XCTAssertTrue(element("skill-row-committed").exists, "Deleting a private skill leaves committed skills alone.")
        XCTAssertEqual(try section().compactMap { $0["name"] as? String }, ["committed"])
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "")

        // A global skill can be made private to one of the task's repositories.
        selectSkillsTab("Global")
        XCTAssertTrue(element("skill-row-global-taken").waitToExist(timeout: 10))
        clickSkillMenuItem(skill: "global-taken", item: "skill-make-private-global-taken-skills-private-repo", title: "Make Private to skills-private-repo")
        XCTAssertTrue(waitUntil({ !self.isListed("skill-row-global-taken", inSection: "skills-group-global") }, timeout: 10), "The skill leaves the Global section.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(".claude/skills/global-taken/SKILL.md").path),
                      "The global skill moves into the repository's store.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsHome.appendingPathComponent(".agents/skills/global-taken").path), "It leaves the global skills folder.")
        selectSkillsTab("Repo")
        XCTAssertTrue(waitUntil({ self.isListed("skill-row-global-taken", inSection: "skills-group-repo") }, timeout: 10), "It shows under its repository.")
        revealSkillHint("global-taken")
        XCTAssertTrue(element("skill-private-global-taken").waitToExist(timeout: 10), "It shows as private under its repository.")
        XCTAssertEqual(try section().compactMap { $0["name"] as? String }.sorted(), ["committed", "global-taken"])
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "Making a global skill private writes nothing into the worktree.")
        attachScreenshot(named: "A global skill made private to a repository")
    }
    // case-contract: test_skills_private_bridge_reaches_claude_and_codex_for_its_repository | A turn on a repository with private skills gets them as native skills, and a task on any other repository gets no extra folder, flag, or skill. Claude Code gets one more --add-dir, a Playhouse-owned wrapper named after the repository whose .claude/skills links to the store, so it lists the private skill and a /skill message reaches it unchanged; the link shows later edits, and a turned-off private skill is left out of the next turn without a skillOverrides entry and hidden from Codex threads. In a task with two repositories whose private skills share a name, each repository's wrapper is passed, and the later one is listed and invoked as /<repository>:<name>. Codex gets the repository's private wrapper among the shared app-server's extra skill roots, with other repositories' private skills disabled for its thread, and a /skill message, plain or namespaced, sends a structured skill input naming the private SKILL.md.
    func test_skills_private_bridge_reaches_claude_and_codex_for_its_repository() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let codexHistoryURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        let repository = try makeSkillRepository("skills-private-bridge", skills: [
            ".claude/skills/repo-claude/SKILL.md": skillManifest("repo-claude", "Claude reads this natively"),
        ])
        let second = try makeSkillRepository("skills-private-second", skills: [:])
        let plain = try makeSkillRepository("skills-private-plain", skills: [:])
        let executable = try installSkillsClaudeFixture("claude-fixture-private-bridge")
        let historyURL = URL(fileURLWithPath: executable.path + ".history")
        launchApp(defaultParent: fixture.parent.path)
        let task = try createSkillsTask("Private Claude skills", repositories: [repository], provider: "claude")
        let taskID = try XCTUnwrap(task["id"] as? String)
        let worktree = URL(fileURLWithPath: try XCTUnwrap((task["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String))
        func create(_ target: String, _ root: URL, _ name: String, _ description: String) throws -> [String: Any] {
            try XCTUnwrap(try runCLI(["skills", "create", "--task", target, "--scope", "private", "--root", root.path, "--name", name, "--description", description])["result"] as? [String: Any])
        }
        let release = try create(taskID, repository, "release-check", "Check a release")
        let shared = try create(taskID, repository, "shared-name", "The first repository's copy")
        func turns() -> [[String: Any]] {
            guard let data = try? Data(contentsOf: historyURL),
                  let history = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (history["turns"] as? [[String: Any]] ?? []).filter { ($0["userText"] as? String)?.isEmpty == false }
        }
        func turn(_ text: String) -> [String: Any]? { turns().last { $0["userText"] as? String == text } }
        func directories(_ entry: [String: Any]) -> [String] {
            let arguments = entry["arguments"] as? [String] ?? []
            return arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] }
        }
        let composer = element("message-composer")
        func send(_ text: String, typed: String? = nil) {
            // Use closes the Skills page and leaves the composer focused. Its hint popover is still
            // on screen for a moment after it leaves the accessibility tree, and hit-testing the
            // composer under it fails the test outright, so only a composer about to be clicked is
            // hit-tested; typing after Use proves the focus by the text that reaches the provider.
            XCTAssertTrue(waitUntil({ composer.exists && (typed != nil || composer.isHittable) }, timeout: 15))
            if typed == nil { composer.click() }
            composer.typeText(typed ?? text)
            element("send-message-button").click()
            XCTAssertTrue(waitUntil({ turn(text) != nil }, timeout: 20), "\(text) should reach Claude Code.")
        }
        func settle(_ id: String) {
            XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: id)?["status"] as? String).map { $0 != "In Progress" } == true }, timeout: 30))
        }

        let plainID = try XCTUnwrap(try createSkillsTask("Plain Claude skills", repositories: [plain], provider: "claude")["id"] as? String)
        openTask(named: "Plain Claude skills")
        send("Hello plain.")
        let plainTurn = try XCTUnwrap(turn("Hello plain."))
        XCTAssertEqual(directories(plainTurn), [], "A repository without private skills adds no folder.")
        XCTAssertFalse((plainTurn["arguments"] as? [String] ?? []).contains("--settings"))
        XCTAssertFalse((plainTurn["skills"] as? [String] ?? []).contains("release-check"), "A task on another repository does not see the private skill.")
        settle(plainID)

        openTask(named: "Private Claude skills")
        openSkillsPage()
        revealSkillHint("release-check")
        XCTAssertTrue(element("skill-private-release-check").waitToExist(timeout: 10))
        useSkill("release-check")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "/release-check " }, timeout: 5), "Use puts /skill-name at the start of the composer.")
        send("/release-check Run it.", typed: "Run it.")
        let first = try XCTUnwrap(turn("/release-check Run it."))
        let added = directories(first)
        XCTAssertEqual(added.count, 1, "One private wrapper should be added: \(first["arguments"] ?? [])")
        let wrapper = URL(fileURLWithPath: try XCTUnwrap(added.first))
        XCTAssertEqual(wrapper.lastPathComponent, "skills-private-bridge", "The wrapper is named after the repository.")
        XCTAssertEqual(realPath(wrapper.deletingLastPathComponent().deletingLastPathComponent().path), realPath(dataDirectory.appendingPathComponent("skill-bridge/claude").path))
        let links = wrapper.appendingPathComponent(".claude/skills")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: links.path).sorted(), ["release-check", "shared-name"])
        XCTAssertEqual(realPath(links.appendingPathComponent("release-check").path), realPath(release["folderPath"] as? String ?? ""))
        XCTAssertTrue((first["skills"] as? [String] ?? []).contains("release-check"), "Claude Code lists the private skill natively.")
        XCTAssertEqual(try runGitOutput(worktree, "status", "--porcelain"), "", "The worktree is not written to.")
        attachScreenshot(named: "Claude turn invoking a private skill from the Skills page")
        settle(taskID)

        let edited = skillManifest("release-check", "Check a release carefully", body: "Compare the changelog.")
        let editFile = dataDirectory.appendingPathComponent("private-skill-edit.md")
        try edited.write(to: editFile, atomically: true, encoding: .utf8)
        _ = try runCLI(["skills", "update", "--task", taskID, "--skill", try XCTUnwrap(release["id"] as? String), "--content-file", editFile.path])
        XCTAssertEqual(try String(contentsOf: links.appendingPathComponent("release-check/SKILL.md"), encoding: .utf8), edited, "The wrapper shows the edited skill.")
        let enabledBridge = try XCTUnwrap(try runCLI(["skills", "bridge", "--task", taskID])["result"] as? [String: Any])
        let oldCodexRelease = URL(fileURLWithPath: try XCTUnwrap((enabledBridge["codexLinks"] as? [[String: String]])?.first { $0["name"] == "release-check" }?["link"]))
        openSkillsPage()
        XCTAssertTrue(element("skill-row-release-check").waitToExist(timeout: 10))
        toggleSkill("release-check")
        XCTAssertTrue(waitUntil({ self.isSkillOff("release-check") }, timeout: 10))
        element("skills-back-button").click()
        send("Run it again.")
        let resumed = try XCTUnwrap(turn("Run it again."))
        XCTAssertEqual(resumed["resumed"] as? Bool, true)
        let resumedSkills = resumed["skills"] as? [String] ?? []
        XCTAssertFalse(resumedSkills.contains("release-check"), "A turned-off private skill is left out of the next turn.")
        XCTAssertTrue(resumedSkills.contains("shared-name") && resumedSkills.contains("repo-claude"), "Turning a private skill off leaves other skills alone.")
        XCTAssertFalse((resumed["arguments"] as? [String] ?? []).contains("--settings"), "A private skill is turned off without a skillOverrides entry.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: URL(fileURLWithPath: try XCTUnwrap(directories(resumed).first)).appendingPathComponent(".claude/skills").path), ["shared-name"])
        settle(taskID)

        let both = try createSkillsTask("Two private repositories", repositories: [repository, second], provider: "claude")
        let bothID = try XCTUnwrap(both["id"] as? String)
        let namespaced = try create(bothID, second, "shared-name", "The second repository's copy")
        openTask(named: "Two private repositories")
        openSkillsPage()
        let sharedRows = app.descendants(matching: .any).matching(identifier: "skill-row-shared-name")
        XCTAssertTrue(waitUntil({ sharedRows.count == 2 }, timeout: 10), "Each repository lists its own shared-name.")
        // The later repository's row is the second; resting on it shows its hint.
        XCTAssertTrue(waitUntil({
            sharedRows.element(boundBy: 1).hover()
            return self.element("skill-namespaced-shared-name").waitToExist(timeout: 2)
        }, timeout: 10), "The later repository's private skill's hint shows its namespaced name.")
        // The badge may be flattened into one static text or keep its label as a child.
        let namespacedBadge = element("skill-namespaced-shared-name")
        let namespacedText = namespacedBadge.staticTexts.firstMatch.exists ? namespacedBadge.staticTexts.firstMatch : namespacedBadge
        XCTAssertEqual(accessibleLabelOrValue(of: namespacedText), "/skills-private-second:shared-name",
                       "The badge shows the namespaced name to type.")
        XCTAssertLessThan(namespacedBadge.frame.height, 30, "The namespaced name sits on one line of its own instead of wrapping beside the chips.")
        attachScreenshot(named: "Two repositories' private skills with the same name, the later one namespaced")
        let sharedNameMenus = app.descendants(matching: .any).matching(identifier: "skill-actions-shared-name")
        XCTAssertEqual(sharedNameMenus.count, 2, "Each repository lists its own shared-name.")
        sharedNameMenus.element(boundBy: 1).click()
        let secondUse = app.menuItems.matching(identifier: "skill-use-shared-name").firstMatch
        XCTAssertTrue(secondUse.waitToExist(timeout: 5), "The later shared-name's menu offers Use.")
        secondUse.click()
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "/skills-private-second:shared-name " }, timeout: 5), "Use inserts the namespaced name.")
        send("/skills-private-second:shared-name Go.", typed: "Go.")
        let bothTurn = try XCTUnwrap(turn("/skills-private-second:shared-name Go."))
        XCTAssertEqual(directories(bothTurn).suffix(2).map { URL(fileURLWithPath: $0).lastPathComponent }, ["skills-private-bridge", "skills-private-second"],
                       "Each repository's private wrapper is passed.")
        XCTAssertTrue((bothTurn["skills"] as? [String] ?? []).contains("skills-private-second:shared-name"), "Claude Code namespaces the later repository's skill.")
        let bridged = try XCTUnwrap(try runCLI(["skills", "bridge", "--task", bothID, "--message", "/skills-private-second:shared-name Go."])["result"] as? [String: Any])
        let invocations = try XCTUnwrap(bridged["invocations"] as? [[String: String]])
        XCTAssertEqual(invocations.map { $0["name"] }, ["shared-name"])
        XCTAssertEqual(realPath(invocations.first?["path"] ?? ""), realPath((namespaced["folderPath"] as? String ?? "") + "/SKILL.md"))
        let secondLink = try XCTUnwrap((bridged["codexLinks"] as? [[String: String]])?.first { realPath($0["source"] ?? "") == realPath(namespaced["folderPath"] as? String ?? "") })
        let secondWrapper = URL(fileURLWithPath: try XCTUnwrap(secondLink["link"])).deletingLastPathComponent()
        settle(bothID)

        let codexTask = try createSkillsTask("Private Codex skills", repositories: [repository])
        let codexID = try XCTUnwrap(codexTask["id"] as? String)
        func codexHistory() -> [String: Any] {
            guard let data = try? Data(contentsOf: codexHistoryURL) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        openTask(named: "Private Codex skills")
        openSkillsPage()
        revealSkillHint("shared-name")
        XCTAssertTrue(element("skill-private-shared-name").waitToExist(timeout: 10))
        useSkill("shared-name")
        XCTAssertTrue(waitUntil({ (composer.value as? String) == "/shared-name " }, timeout: 5))
        composer.typeText("Complete this task.")
        element("send-message-button").click()
        XCTAssertTrue(waitUntil({ codexHistory()["userMessage"] as? String == "/shared-name Complete this task." }, timeout: 20))
        let sent = codexHistory()
        let skillInputs = try XCTUnwrap(sent["skillInputs"] as? [[String: String]])
        XCTAssertEqual(skillInputs.map { $0["name"] }, ["shared-name"])
        XCTAssertEqual(realPath(skillInputs.first?["path"] ?? ""), realPath((shared["folderPath"] as? String ?? "") + "/SKILL.md"),
                       "Codex receives a structured skill input naming the private SKILL.md.")
        let codexBridge = try XCTUnwrap(try runCLI(["skills", "bridge", "--task", codexID])["result"] as? [String: Any])
        let ownLink = try XCTUnwrap((codexBridge["codexLinks"] as? [[String: String]])?.first { $0["name"] == "shared-name" })
        let ownWrapper = URL(fileURLWithPath: try XCTUnwrap(ownLink["link"])).deletingLastPathComponent()
        XCTAssertTrue(Set((sent["skillExtraRoots"] as? [String] ?? []).map(realPath)).contains(realPath(ownWrapper.path)),
                      "The app-server gets the repository's private wrapper as an extra root.")
        let config = (((sent["threadStartConfig"] as? [String: Any])?["skills"] as? [String: Any])?["config"] as? [[String: Any]]) ?? []
        let disabled = Set(config.filter { $0["enabled"] as? Bool == false }.compactMap { $0["path"] as? String }.map(realPath))
        XCTAssertTrue(disabled.contains(realPath(secondWrapper.appendingPathComponent("shared-name/SKILL.md").path)), "Another repository's private skill is hidden from this thread.")
        XCTAssertTrue(disabled.contains(realPath(oldCodexRelease.appendingPathComponent("SKILL.md").path)), "A turned-off private skill is hidden from the Codex thread.")
        XCTAssertFalse(((codexBridge["codexLinks"] as? [[String: String]]) ?? []).contains { $0["name"] == "release-check" }, "A turned-off private skill is left out of the Codex wrapper.")
        XCTAssertFalse(disabled.contains { $0.hasPrefix(realPath(ownWrapper.path) + "/") }, "The thread's own private skills stay on.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: skillsCodexHome.appendingPathComponent("config.toml").path), "Codex's config.toml is not written.")
        attachScreenshot(named: "Codex turn invoking a private skill from the Skills page")
        if element("ai-question-form-title").waitToExist(timeout: 10) {
            selectQuestionOption("Blue")
            typeIntoField(element("ai-question-answer-token"), text: "fixture-secret")
            element("submit-ai-answers-button").click()
        }
        let plainBridge = try XCTUnwrap(try runCLI(["skills", "bridge", "--task", plainID, "--message", "/shared-name Go."])["result"] as? [String: Any])
        XCTAssertEqual((plainBridge["claudeAddDirectories"] as? [String])?.count, 0, "A repository without private skills adds no folder.")
        XCTAssertEqual((plainBridge["codexLinks"] as? [Any])?.count, 0)
        XCTAssertEqual((plainBridge["invocations"] as? [Any])?.count, 0, "Another repository's private skill cannot be invoked.")
    }
}

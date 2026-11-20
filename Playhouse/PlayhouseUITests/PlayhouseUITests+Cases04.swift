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
    // case-contract: test_task_auto_pr_toggle_creates_pull_request_on_review | A working-state task card (In Progress, Blocked, or Waiting Response) with no linked pull request shows the pull-request-mode plugin's compact mode pill, and no manual PR button yet, closed on its current mode and defaulting to Manual; clicking it slides out Manual, PR, Green, and Merge, and choosing one selects it and folds the pill back onto it. The pill stays beside linked pull requests so autopilot and merge remain switchable, and beside the manual PR button of a task in Review with no pull request. The mode is the plugin's own state keyed by task id, not a property of the task: a new task has no saved mode and is in Manual mode, choosing Manual clears the saved mode, every other choice (PR included) is saved and reflected across a fresh read, and a saved value no mode knows reads as Manual. When a turn completes in PR mode, the plugin creates the task's pull request on the way to Review with no user click, exactly once. Choosing Merge for that task in Review is a change the plugin acts on at once: it merges the green pull request with no other command, and the task stays in Review. In Manual mode, a new task's default, the task reaches Review with no pull request, and the existing manual PR button, shown beside the mode pill on Manual, still creates it afterward unchanged. Every new task starts in Manual mode, whatever mode another task was left in. Creating a pull request with --if-needed for an unknown task is rejected. A task saved before the mode was the plugin's keeps its old Manual, Green, or Merge choice: the bridge imports it once into the plugin's state at its next request (a mode already chosen in the plugin wins, and PR imports nothing), and its card's pill shows it. In the same request, once, each task saved while PR was the default that still has no mode of its own gets PR saved as its own, so existing tasks keep opening their pull request on Review and their pill shows PR; a task created afterward still starts in Manual.
    func test_task_auto_pr_toggle_creates_pull_request_on_review() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Auto PR toggle UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        XCTAssertTrue(element("task-card-\(taskID)").waitToExist(timeout: 5))
        XCTAssertFalse(element("task-pr-mode-\(taskID)").exists, "A Backlog task has no working-state PR controls yet.")
        // A worktree shares its source repository's git config, so the origin remotes this
        // case adds through its worktrees must not leak into later cases. A teardown block,
        // not `defer`: with continueAfterFailure off, a failed assertion stops the case
        // without running its defers.
        addTeardownBlock { [self] in
            for repository in [fixture.primary, fixture.secondary] {
                try? runGit(repository, "remote", "remove", "origin")
            }
        }

        openTask(named: "Auto PR toggle UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Auto PR toggle UI", whileTurnHeld: {
            self.element("back-to-board-button").click()
            let pill = self.element("task-pr-mode-\(taskID)")
            XCTAssertTrue(pill.waitToExist(timeout: 5), "An in-progress task with no linked PR should show the PR mode pill.")
            XCTAssertFalse(self.element("task-create-pr-\(taskID)").exists, "The mode pill replaces the manual PR button while the task is in progress.")
            XCTAssertGreaterThanOrEqual(pill.frame.height, 30, "The closed pill should keep a comfortable hit target.")
            let duration = self.element("task-working-duration-\(taskID)")
            XCTAssertGreaterThanOrEqual(pill.frame.minY, duration.frame.maxY, "The mode pill should sit below the working-duration time row.")
            // The time grows as it ticks ("9s" to "10s"); a stale layout kept the narrower width and truncated it to "…".
            let firstDuration = self.pluginText(duration)
            // Only under 10s does it grow within seconds; later the width check still applies to the current string.
            if firstDuration.count < 3 {
                XCTAssertTrue(self.waitUntil({ self.pluginText(duration).count > firstDuration.count }, timeout: 15),
                              "The working time should grow as it ticks, from \(firstDuration) to \(self.pluginText(duration)).")
            }
            XCTAssertTrue(self.waitUntil({
                let text = self.pluginText(duration)
                return duration.frame.width >= ceil(text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width) - 1
            }, timeout: 3), "The working time, grown from \(firstDuration), should keep its full width: \(self.pluginText(duration)) in \(duration.frame.width) pt")
            XCTAssertEqual(pill.value as? String, "manual", "The closed pill shows the current mode, defaulting to Manual.")
            XCTAssertFalse(self.element("task-pr-mode-merge-\(taskID)").exists, "A closed pill shows only the current mode.")
            XCTAssertNil(try self.taskRecord(id: taskID)?["pullRequestMode"], "The mode is the plugin's state, not a property of the task.")
            XCTAssertNil(try self.pullRequestMode(taskID: taskID), "A new task has no saved mode, so it is in Manual mode.")
            self.attachScreenshot(named: "Working task shows the closed mode pill on Manual")
            self.attachElementScreenshot(self.element("task-card-\(taskID)"), named: "Closed mode pill on Manual, the default (card)")

            pill.click()
            for mode in ["manual", "pr", "autopilot", "merge"] {
                let option = self.element("task-pr-mode-\(mode)-\(taskID)")
                XCTAssertTrue(option.waitToExist(timeout: 5), "The open pill should offer \(mode).")
                XCTAssertGreaterThanOrEqual(option.frame.height, 30, "Each mode should keep a comfortable hit target.")
            }
            XCTAssertEqual(self.element("task-pr-mode-manual-\(taskID)").value as? String, "selected")
            _ = self.settledPillOption("merge", taskID: taskID)
            self.attachScreenshot(named: "Clicking the pill slides out Manual, PR, Green, and Merge")
            self.attachElementScreenshot(self.element("task-card-\(taskID)"), named: "The open pill offers Manual, PR, Green, and Merge (card)")
            // Choosing the current mode again just folds the pill.
            self.settledPillOption("manual", taskID: taskID).click()
            XCTAssertTrue(self.waitUntil({ pill.exists && (pill.value as? String) == "manual" && !self.element("task-pr-mode-merge-\(taskID)").exists }, timeout: 5), "Choosing the current mode should fold the pill.")
            XCTAssertNil(try self.pullRequestMode(taskID: taskID), "Choosing the current mode saves nothing.")

            pill.click()
            self.settledPillOption("autopilot", taskID: taskID).click()
            XCTAssertTrue(self.waitUntil({
                (try? self.pullRequestMode(taskID: taskID)) == "autopilot"
            }, timeout: 5), "Choosing Green should persist immediately in the plugin's state.")
            XCTAssertTrue(self.waitUntil({ pill.exists && (pill.value as? String) == "autopilot" && !self.element("task-pr-mode-merge-\(taskID)").exists }, timeout: 5), "Choosing a mode should fold the pill back onto it.")
            self.attachScreenshot(named: "Choosing Green folds the pill back onto Green")
            try self.selectPullRequestMode("manual", taskID: taskID)
            // Manual is the default, so choosing it clears the saved mode.
            XCTAssertTrue(self.waitUntil({ (try? self.pullRequestMode(taskID: taskID) == nil) == true }, timeout: 5), "Choosing Manual should clear the saved mode immediately.")
            // PR is no longer the default, so choosing it is saved.
            try self.selectPullRequestMode("pr", taskID: taskID)
            XCTAssertTrue(self.waitUntil({ (try? self.pullRequestMode(taskID: taskID)) == "pr" }, timeout: 5), "Choosing PR should persist immediately in the plugin's state.")
            // A saved value no mode knows reads as the default: the pill moves from PR to Manual.
            try self.setPullRequestMode("sometimes", taskID: taskID)
            XCTAssertTrue(self.waitUntil({ (pill.value as? String) == "manual" }, timeout: 5), "An unknown saved mode reads as Manual.")
            try self.selectPullRequestMode("pr", taskID: taskID)
            XCTAssertTrue(self.waitUntil({ (try? self.pullRequestMode(taskID: taskID)) == "pr" }, timeout: 5), "Choosing PR again saves it over the unknown value.")
            self.attachScreenshot(named: "Choosing PR in the mode control persists")
            self.attachElementScreenshot(self.element("task-card-\(taskID)"), named: "Closed mode pill on PR, chosen (card)")

            let record = try XCTUnwrap((self.taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
            let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
            let remoteRoot = self.dataDirectory.appendingPathComponent("auto-pr-remotes", isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: remoteRoot.path), "Each UI case should start with an isolated bare remote fixture.")
            try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
            try WorkspaceFixture.ownerContents.write(to: remoteRoot.appendingPathComponent(WorkspaceFixture.ownerMarker), atomically: true, encoding: .utf8)
            let remote = remoteRoot.appendingPathComponent("repository-0.git", isDirectory: true)
            try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
            try self.runGit(remote, "init", "--bare")
            try self.runGit(worktree, "remote", "add", "origin", remote.path)
            try self.runGit(worktree, "push", "origin", "main")
            // GitHub rejects a pull request whose branch has no commits.
            try "Auto PR task change.\n".write(to: worktree.appendingPathComponent("task-change.txt"), atomically: true, encoding: .utf8)

            self.openTask(named: "Auto PR toggle UI")
        })
        XCTAssertTrue(waitUntil({
            (try? self.taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["pullRequestNumber"] != nil
        }, timeout: 15), "Auto PR should create the pull request itself once the task reaches Review.")
        element("back-to-board-button").click()
        let prLink = app.links["task-pr-link-\(taskID)-501"]
        XCTAssertTrue(prLink.waitToExist(timeout: 10), "The auto-created PR number should appear on the card without the user clicking the PR button.")
        XCTAssertTrue(element("task-pr-mode-\(taskID)").exists, "The mode pill stays beside the linked PR so autopilot and merge remain switchable.")
        XCTAssertEqual(element("task-pr-mode-\(taskID)").value as? String, "pr")
        attachScreenshot(named: "Auto PR created the pull request automatically once the task reached Review")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Auto PR created the pull request automatically once the task reached Review (card)")

        // Choosing Merge for a task in Review is a change the plugin acts on at once:
        // it follows the green pull request and merges it, with no other click.
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]))
        try "501=unmerged\n501.checks=success\n501.threads=0\n".write(to: stateURL, atomically: true, encoding: .utf8)
        try selectPullRequestMode("merge", taskID: taskID)
        XCTAssertTrue(element("task-complete-merged-pr-\(taskID)").waitToExist(timeout: 20), "Choosing Merge in Review merges the green pull request.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "Merging leaves the task in Review.")
        attachScreenshot(named: "Choosing Merge in Review merged the green pull request")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Choosing Merge in Review merged the green pull request (card)")

        let defaultPR = try XCTUnwrap(try runCLI(["task", "create", "--title", "Default PR mode UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any])
        let pullRequestTaskID = try XCTUnwrap(defaultPR["id"] as? String)
        XCTAssertNil(try pullRequestMode(taskID: pullRequestTaskID), "A new task should start in Manual mode.")
        try setPullRequestMode("pr", taskID: pullRequestTaskID)
        let afterOn = try XCTUnwrap(try runCLI(["task", "create", "--title", "Default PR mode after on UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path])["result"] as? [String: Any])
        XCTAssertNil(try pullRequestMode(taskID: try XCTUnwrap(afterOn["id"] as? String)), "A task created after switching another task to PR should still start in Manual mode.")
        XCTAssertEqual(try pullRequestMode(taskID: pullRequestTaskID), "pr")

        let manualCreated = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Manual PR toggle UI", "--prompt", "Fixture task description.", "--repo", fixture.secondary.path,
            "--merge-target", "\(fixture.secondary.path)=main",
        ])["result"] as? [String: Any])
        let manualTaskID = try XCTUnwrap(manualCreated["id"] as? String)
        // A new task, with no mode chosen, is in Manual mode.
        XCTAssertNil(try pullRequestMode(taskID: manualTaskID))
        let missing = try runCLI(["task", "pr", "create", "00000000-0000-0000-0000-000000000000", "--if-needed"], expectedStatus: 3)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "not_found")
        openTask(named: "Manual PR toggle UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Manual PR toggle UI")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: manualTaskID)?["status"] as? String, "Review")
        XCTAssertNil((try taskRecord(id: manualTaskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["pullRequestNumber"], "In Manual mode, the default, reaching Review must not create a pull request by itself.")
        XCTAssertTrue(waitUntil({
            ((try? self.diagnosticEvents()) ?? []).contains { $0["event"] as? String == "plugin.pull_request_mode.review" && $0["taskID"] as? String == manualTaskID && $0["mode"] as? String == "manual" }
        }, timeout: 15), "A new task reaches Review in Manual mode.")
        let manualButton = element("task-create-pr-\(manualTaskID)")
        XCTAssertTrue(manualButton.waitToExist(timeout: 5), "Auto PR off must leave the existing manual PR button in place.")
        let manualPill = element("task-pr-mode-\(manualTaskID)")
        XCTAssertTrue(manualPill.waitToExist(timeout: 5), "The mode pill stays beside the manual PR button in Review.")
        XCTAssertEqual(manualPill.value as? String, "manual", "The pill beside the PR button shows the task's Manual mode.")
        XCTAssertTrue(manualPill.frame.minY < manualButton.frame.maxY && manualButton.frame.minY < manualPill.frame.maxY,
                      "The pill and the PR button share the card's bottom row: \(manualPill.frame) vs \(manualButton.frame)")
        let manualRecord = try XCTUnwrap((try taskRecord(id: manualTaskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let manualWorktree = URL(fileURLWithPath: try XCTUnwrap(manualRecord["worktreePath"] as? String), isDirectory: true)
        let manualRemoteRoot = dataDirectory.appendingPathComponent("manual-pr-remotes", isDirectory: true)
        try FileManager.default.createDirectory(at: manualRemoteRoot, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(to: manualRemoteRoot.appendingPathComponent(WorkspaceFixture.ownerMarker), atomically: true, encoding: .utf8)
        let manualRemote = manualRemoteRoot.appendingPathComponent("repository-0.git", isDirectory: true)
        try FileManager.default.createDirectory(at: manualRemote, withIntermediateDirectories: true)
        try runGit(manualRemote, "init", "--bare")
        try runGit(manualWorktree, "remote", "add", "origin", manualRemote.path)
        try runGit(manualWorktree, "push", "origin", "main")
        try "Manual PR task change.\n".write(to: manualWorktree.appendingPathComponent("task-change.txt"), atomically: true, encoding: .utf8)
        revealOnBoard(manualButton)
        attachScreenshot(named: "Review card shows the manual PR button beside the mode pill")
        attachElementScreenshot(element("task-card-\(manualTaskID)"), named: "Manual PR button beside the mode pill (card)")
        manualButton.click()
        let manualPRLink = app.links["task-pr-link-\(manualTaskID)-502"]
        XCTAssertTrue(manualPRLink.waitToExist(timeout: 10), "The manual PR flow must still work unchanged when Auto PR stays off.")

        // A task saved before the mode was the plugin's kept Merge in its own columns: the bridge
        // imports it once into the plugin's state at its next request, and the card's pill shows it.
        let legacy = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Legacy PR mode UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
        ])["result"] as? [String: Any])
        let legacyID = try XCTUnwrap(legacy["id"] as? String)
        // A task saved while PR was the default, with no mode of its own, keeps PR.
        let pinned = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Pre-Manual default UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
        ])["result"] as? [String: Any])
        let pinnedID = try XCTUnwrap(pinned["id"] as? String)
        XCTAssertNil(try pullRequestMode(taskID: pinnedID))
        XCTAssertTrue(terminateAppAndWait(app))
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        seed.arguments = [dataDirectory.appendingPathComponent("Playhouse-v2.store").path,
                          "UPDATE ZBOARDTASK SET ZPULLREQUESTAUTOPILOT = 1, ZPULLREQUESTAUTOMERGE = 1, ZSTATUSRAWVALUE = 'In Progress' WHERE ZTITLE = 'Legacy PR mode UI'; SELECT changes(); UPDATE ZBOARDTASK SET ZSTATUSRAWVALUE = 'In Progress' WHERE ZTITLE = 'Pre-Manual default UI'; SELECT changes();"]
        let seedOutput = Pipe()
        seed.standardOutput = seedOutput
        seed.standardError = seedOutput
        try seed.run()
        seed.waitUntilExit()
        let seeded = String(data: seedOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(seed.terminationStatus, 0, seeded)
        XCTAssertEqual(seeded.split(whereSeparator: \.isNewline), ["1", "1"], "Seed the legacy Merge columns of the real SwiftData row, and start both tasks so their cards show the pill.")
        // Forget the import, and keeping PR for existing tasks, the way the CLI case does: an external
        // delete that the bridge, which already holds this case's path-named preferences suite, reads
        // at its next request. A first launch since Manual became the default runs both.
        for flag in ["legacyPullRequestModesImported", "existingTaskPullRequestModesPinned"] {
            let forget = Process()
            forget.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            forget.arguments = ["delete", preferencesSuiteName, flag]
            try forget.run()
            forget.waitUntilExit()
        }
        let imported = try runCLI(["plugin", "state", "--id", "pull-request-mode"])["result"] as? [String: Any]
        XCTAssertEqual((imported?["state"] as? [String: Any])?[legacyID] as? String, "merge", "The legacy Merge columns import as the plugin's state.")
        XCTAssertEqual((imported?["state"] as? [String: Any])?[pinnedID] as? String, "pr", "A task saved while PR was the default keeps PR as its own mode.")
        launchAppWithOpen(environmentOverrides: ghEnvironment)
        waitForBoardOrAbortSuite()
        XCTAssertEqual(try taskRecord(id: legacyID)?["status"] as? String, "In Progress")
        let legacyPill = element("task-pr-mode-\(legacyID)")
        XCTAssertTrue(legacyPill.waitToExist(timeout: 10), "The started legacy task shows the mode pill.")
        XCTAssertTrue(waitUntil({ (legacyPill.value as? String) == "merge" }, timeout: 5), "The pill shows the imported Merge mode.")
        revealOnBoard(legacyPill)
        attachElementScreenshot(element("task-card-\(legacyID)"), named: "Imported legacy Merge mode on the card")
        let pinnedPill = element("task-pr-mode-\(pinnedID)")
        XCTAssertTrue(pinnedPill.waitToExist(timeout: 10), "The started pre-Manual task shows the mode pill.")
        XCTAssertTrue(waitUntil({ (pinnedPill.value as? String) == "pr" }, timeout: 5), "The pill of a task saved while PR was the default shows PR.")
        revealOnBoard(pinnedPill)
        attachElementScreenshot(element("task-card-\(pinnedID)"), named: "A task saved while PR was the default keeps PR")
        let fresh = try XCTUnwrap(try runCLI(["task", "create", "--title", "Fresh after migration UI", "--prompt", "Fixture task description."])["result"] as? [String: Any])
        XCTAssertNil(try pullRequestMode(taskID: try XCTUnwrap(fresh["id"] as? String)), "A task created afterward still starts in Manual.")
    }
    // case-contract: test_pull_request_mode_chosen_in_review_opens_pull_request | A task that reached Review in Manual mode with no pull request gets one when another mode is chosen for it in Review, with no click: choosing a mode there does what reaching Review in it would. While its branch can't be published (no Git remote), choosing Green opens nothing and records the failure, and a Green pass that then finds no linked pull request (here on focus) records that and stops instead of polling. Once the branch is publishable, choosing PR opens the pull request exactly once and starts no autopilot pass, and choosing Merge afterward opens no second one and merges the green pull request; the task stays in Review.
    func test_pull_request_mode_chosen_in_review_opens_pull_request() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        var ghEnvironment = try makeGitHubStateFixture(expectedNumbers: []).merging(Self.prCheckCooldownEnvironment) { $1 }
        ghEnvironment["PLAYHOUSE_E2E_PR_AUTOPILOT_POLL_SECONDS"] = "2"
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "PR mode chosen in Review UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        addTeardownBlock { [self] in try? runGit(fixture.primary, "remote", "remove", "origin") }
        func events(_ name: String, _ fields: [String: String] = [:]) -> [[String: Any]] {
            ((try? self.diagnosticEvents()) ?? []).filter { event in
                event["event"] as? String == name && event["taskID"] as? String == taskID
                    && fields.allSatisfy { event[$0.key] as? String == $0.value }
            }
        }
        let createLogURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_LOG"]))
        let createdNumbers = {
            ((try? String(contentsOf: createLogURL, encoding: .utf8)) ?? "").split(separator: "\n")
                .filter { $0.hasPrefix("created\t") }.compactMap { $0.split(separator: "\t").last.map(String.init) }
        }

        openTask(named: "PR mode chosen in Review UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR mode chosen in Review UI")
        element("back-to-board-button").click()
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        XCTAssertTrue(waitUntil({ !events("plugin.pull_request_mode.review", ["mode": "manual"]).isEmpty }, timeout: 15), "The task reaches Review in Manual mode.")
        XCTAssertTrue(element("task-create-pr-\(taskID)").waitToExist(timeout: 5), "Manual mode leaves the task in Review with no pull request.")
        revealOnBoard(element("task-card-\(taskID)"))
        attachScreenshot(named: "Review task with no pull request, in Manual mode")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Review task with no pull request, in Manual mode (card)")

        // The branch has no remote to publish to: choosing Green tries to open the pull
        // request, records why it couldn't, and follows nothing.
        try selectPullRequestMode("autopilot", taskID: taskID)
        XCTAssertTrue(waitUntil({ !events("task.review.auto_pr.failed", ["trigger": "mode"]).isEmpty }, timeout: 15), "Choosing Green in Review tries to open the pull request.")
        XCTAssertFalse(events("plugin.pull_request_mode.chosen", ["mode": "autopilot"]).isEmpty)
        XCTAssertEqual(createdNumbers(), [])
        XCTAssertTrue(events("plugin.pull_request_mode.follow").isEmpty, "A pull request that couldn't be opened isn't followed.")
        // A Green pass with no linked pull request (here on focus) stops: nothing it can
        // poll for would link one.
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({ !events("plugin.pull_request_mode.no_pull_request", ["trigger": "focus"]).isEmpty }, timeout: 15), "A pass with no linked pull request says so.")
        XCTAssertEqual(events("plugin.pull_request_mode.followed", ["trigger": "focus"]).last?["action"] as? String, "inactive")
        XCTAssertFalse(waitUntil({ !events("plugin.pull_request_mode.follow", ["trigger": "poll"]).isEmpty }, timeout: 5), "A pass with no linked pull request isn't polled again.")
        XCTAssertTrue(element("task-create-pr-\(taskID)").exists, "The task still has no pull request.")
        revealOnBoard(element("task-card-\(taskID)"))
        attachScreenshot(named: "Green chosen while the branch can't be published: still no pull request")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Green chosen while the branch can't be published: still no pull request (card)")

        let record = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
        let remoteRoot = dataDirectory.appendingPathComponent("mode-in-review-remotes", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try WorkspaceFixture.ownerContents.write(to: remoteRoot.appendingPathComponent(WorkspaceFixture.ownerMarker), atomically: true, encoding: .utf8)
        let remote = remoteRoot.appendingPathComponent("repository-0.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try runGit(remote, "init", "--bare")
        try runGit(worktree, "remote", "add", "origin", remote.path)
        try runGit(worktree, "push", "origin", "main")
        // GitHub rejects a pull request whose branch has no commits.
        try "Mode chosen in Review change.\n".write(to: worktree.appendingPathComponent("task-change.txt"), atomically: true, encoding: .utf8)

        // Choosing PR in Review opens the pull request with no other click, and follows nothing.
        try selectPullRequestMode("pr", taskID: taskID)
        let prLink = app.links["task-pr-link-\(taskID)-501"]
        XCTAssertTrue(prLink.waitToExist(timeout: 60), "Choosing PR in Review opens the pull request.")
        XCTAssertEqual(createdNumbers(), ["501"])
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        XCTAssertTrue(events("plugin.pull_request_mode.follow", ["trigger": "mode"]).isEmpty, "PR mode opens the pull request but doesn't follow it.")
        revealOnBoard(element("task-card-\(taskID)"))
        attachScreenshot(named: "Choosing PR in Review opened the pull request")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Choosing PR in Review opened the pull request (card)")

        // Choosing Merge afterward opens no second pull request and merges the green one.
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]))
        try "501=unmerged\n501.checks=success\n501.threads=0\n".write(to: stateURL, atomically: true, encoding: .utf8)
        try selectPullRequestMode("merge", taskID: taskID)
        XCTAssertTrue(element("task-complete-merged-pr-\(taskID)").waitToExist(timeout: 30), "Choosing Merge in Review merges the green pull request.")
        XCTAssertEqual(events("plugin.pull_request_mode.follow", ["trigger": "mode"]).last?["mode"] as? String, "merge")
        XCTAssertEqual(createdNumbers(), ["501"], "The pull request is opened exactly once.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "Merging leaves the task in Review.")
        revealOnBoard(element("task-card-\(taskID)"))
        attachScreenshot(named: "Choosing Merge in Review merged the green pull request")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Choosing Merge in Review merged the green pull request (card)")
    }
    // case-contract: test_task_pr_autopilot_fixes_red_pull_request_until_green | `task pr status` reports each linked PR's check state, failing check names, and a green, red, or pending health, and reads unresolved review threads only when asked (`--review-threads`, as every autopilot pass does), so a PR-mode card's probe never reads them; the board colours each linked PR number green, red, or blue by that health and keeps the mode pill beside linked PRs. `task pr autopilot` is one pass of the pull-request-mode plugin's Green mode, which the plugin runs for its Green tasks when they reach Review, when Green is chosen for a task in Review, and on focus; a pass leaves a task inactive unless it sits in Review with a linked pull request. With checks still running it sends no turn, and the plugin re-probes only those Green PRs on a slow poll until they settle. When checks fail or review threads are unresolved it sends one visible Playhouse autopilot fix turn through the task's provider that names the failing checks and unresolved threads, asks the model to judge every comment critically and to reply to and resolve each thread whether or not it changes code, and allows waiting-response for blockers it cannot fix (such as a GitHub outage or a Jira ticket the user must add); the task is In Progress during that turn and returns to Review when it reports completed. Once the PR is green autopilot sends nothing, never merges it, and resets its loop guard, so the same red state returning later (picked up by the focus probe) is fixed again. A fix turn that reports waiting-response stops the loop until the user sends the task back to Review, after which autopilot may try the red PR once more; a red state unchanged since the last fix moves the task to Waiting Response with a reason instead of being sent again, and the CLI case also drives the five-attempt cap to its Waiting Response stop after a fresh set of attempts (`--reset-attempts`, as choosing the mode again passes). A check rerun counts only by its latest run, as on GitHub: a failure followed by a newer success reads green with no failing checks, a success followed by a newer failure reads red naming the check, and same-named checks from different workflows stay separate (one failing workflow still reads red, failing names listed once), as do commit status contexts by context and untimed entries by rollup order. The pull-request-mode plugin's service runs these passes itself and records each follow: when Green is chosen for a task in Review, when a Green task reaches Review, on the slow poll while checks run, and on focus through its throttle (the CLI case counts three focus events within the cooldown as one follow at once and one when it ends); each pass records its result, and a pass skipped because the turn that moved the task to Review still holds it is looked at again on the poll. A pass the plugin started (`--confirm-with pull-request-mode`) asks it again right before merging or sending a fix turn, so a Green task's `--merge` pass merges nothing and reports inactive, and `--confirm-with` with no plugin id is invalid_argument. A shared status probe (`task pr status --shared`, as the card's plugins probe) shares a probe already running, so two at once ask GitHub once, and reuses its answer for a few seconds, while an explicit read always asks GitHub and leaves the shared answer alone; creating a task's pull requests or running a pass forgets the shared answer, and a failed probe is not kept.
    func test_task_pr_autopilot_fixes_red_pull_request_until_green() throws {
        let executable = try makeCodexFixture(emptyQuestions: false)
        codexFixtureExecutable = executable.path
        var ghEnvironment = try makeGitHubStateFixture(expectedNumbers: []).merging(Self.prCheckCooldownEnvironment) { $1 }
        ghEnvironment["PLAYHOUSE_E2E_PR_AUTOPILOT_POLL_SECONDS"] = "2"
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]))
        let callLogURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CALL_LOG"]))
        func setPullRequest(_ checks: String, threads: Int = 0) throws {
            try "801=unmerged\n801.checks=\(checks)\n801.threads=\(threads)\n".write(to: stateURL, atomically: true, encoding: .utf8)
        }
        let holdRelease = URL(fileURLWithPath: executable.path + ".hold-release")
        let turnActive = URL(fileURLWithPath: executable.path + ".turn-active")
        let turnRelease = URL(fileURLWithPath: executable.path + ".turn-release")
        defer {
            try? "Release the fixture turn.\n".write(to: turnRelease, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: holdRelease)
        }
        try setPullRequest("pending")

        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "PR autopilot UI", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main", "--prompt", Self.fixtureTaskPrompt,
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        // A PR-mode task, PR chosen rather than the default.
        try setPullRequestMode("pr", taskID: taskID)
        /// Holds the next autopilot fix turn, checks the task while it runs, then reports `outcome`.
        func driveAutopilotFixTurn(outcome: String, whileHeld: () throws -> Void) throws {
            XCTAssertTrue(waitUntil({ FileManager.default.fileExists(atPath: turnActive.path) }, timeout: 20), "Autopilot should send a fix turn for the red pull request.")
            try whileHeld()
            let reported = try runCLI(["task", "outcome", taskID, outcome])
            XCTAssertEqual((reported["result"] as? [String: Any])?["outcome"] as? String, outcome)
            try "Release the fixture turn.\n".write(to: turnRelease, atomically: true, encoding: .utf8)
            XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: turnActive.path) }, timeout: 10))
        }
        func lastUserMessage() throws -> String {
            let history = try XCTUnwrap(try runCLI(["conversation", "history", taskID])["result"] as? [String: Any])
            let messages = try XCTUnwrap(history["messages"] as? [[String: Any]])
            return try XCTUnwrap(messages.last(where: { $0["role"] as? String == "user" })?["text"] as? String)
        }
        let missing = try runCLI(["task", "pr", "autopilot", "00000000-0000-0000-0000-000000000000"], expectedStatus: 3)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "not_found")
        openTask(named: "PR autopilot UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR autopilot UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ element("task-card-\(taskID)").exists }, timeout: 10))
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: taskID, number: 801, url: "https://github.com/playhouse-test/fixture/pull/801")

        // A shared probe (as the card's plugins make on focus and on moves) shares a running
        // probe and reuses its answer for a while; an explicit read always asks. The window
        // is closed here so only these reads reach GitHub.
        var cacheEnvironment = ghEnvironment
        cacheEnvironment["PLAYHOUSE_E2E_PR_STATUS_CACHE_SECONDS"] = "60"
        let probes = { (try? String(contentsOf: callLogURL, encoding: .utf8))?.components(separatedBy: "\n").filter { $0 == "801" }.count ?? 0 }
        func health(_ arguments: [String]) throws -> String? {
            (try runCLI(["task", "pr", "status", taskID] + arguments, extraEnvironment: cacheEnvironment)["result"] as? [[String: Any]])?.first?["health"] as? String
        }
        // Start from no shared answer: the card's probes before the window closed may have left one,
        // and this 60-second cache life would reuse it. With PR 801 linked, nothing is created.
        _ = try runCLI(["task", "pr", "create", taskID, "--if-needed"], extraEnvironment: cacheEnvironment)
        try Data().write(to: callLogURL, options: .atomic)
        try setPullRequest("failure")
        let together = DispatchGroup()
        let healths = NSMutableArray()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: together) {
                let read = (try? self.runCLI(["task", "pr", "status", taskID, "--shared"], extraEnvironment: cacheEnvironment)["result"] as? [[String: Any]])?.first?["health"] as? String
                objc_sync_enter(healths); healths.add(read ?? "none"); objc_sync_exit(healths)
            }
        }
        XCTAssertEqual(together.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(healths as? [String], ["red", "red"])
        XCTAssertEqual(probes(), 1, "Two shared probes at once ask GitHub once.")
        try setPullRequest("success")
        XCTAssertEqual(try health(["--shared"]), "red", "A shared probe within the cache's life reuses the answer.")
        XCTAssertEqual(probes(), 1)
        XCTAssertEqual(try health([]), "green", "An explicit read always asks GitHub.")
        XCTAssertEqual(probes(), 2)
        XCTAssertEqual(try health(["--shared"]), "red", "An explicit read leaves the shared answer alone.")
        _ = try runCLI(["task", "pr", "create", taskID, "--if-needed"], extraEnvironment: cacheEnvironment)
        XCTAssertEqual(try health(["--shared"]), "green", "Creating a task's pull requests forgets its shared answer.")
        XCTAssertEqual(probes(), 3)
        try setPullRequest("pending")
        XCTAssertEqual((try runCLI(["task", "pr", "autopilot", taskID], extraEnvironment: cacheEnvironment)["result"] as? [String: Any])?["action"] as? String, "pending")
        try FileManager.default.removeItem(at: stateURL)
        let failed = try runCLI(["task", "pr", "status", taskID, "--shared"], expectedStatus: 1, extraEnvironment: cacheEnvironment)
        XCTAssertEqual((failed["error"] as? [String: Any])?["code"] as? String, "operation_failed")
        try setPullRequest("pending")
        XCTAssertEqual(try health(["--shared"]), "pending", "A pass forgets the shared answer, and a failed probe isn't kept.")
        XCTAssertTrue(try diagnosticEvents().contains { $0["event"] as? String == "task.pr.status.shared" && $0["taskID"] as? String == taskID }, "The reused answers are recorded.")
        try Data().write(to: callLogURL, options: .atomic)

        // Pending checks: the PR number turns blue, and no fix turn is sent.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let prLink = app.links["task-pr-link-\(taskID)-801"]
        XCTAssertTrue(prLink.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ (prLink.value as? String) == "pending" }, timeout: 15), "Running checks should colour the PR number blue.")
        XCTAssertFalse((try? String(contentsOf: callLogURL, encoding: .utf8))?.contains("threads 801") ?? false, "A PR-mode card's probe leaves review threads alone.")
        let modePill = element("task-pr-mode-\(taskID)")
        XCTAssertTrue(modePill.waitToExist(timeout: 5), "A linked PR keeps the mode pill beside it.")
        XCTAssertEqual(modePill.value as? String, "pr", "The pill shows the task's own chosen mode.")
        XCTAssertGreaterThanOrEqual(modePill.frame.height, 30)
        attachScreenshot(named: "Pending checks colour the PR number blue")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Pending checks colour the PR number blue (card)")

        // A rerun counts only by its latest run, as on GitHub.
        for (checks, state, failing) in [("rerun-success", "success", [String]()), ("rerun-failure", "failure", ["fixture-ci"]), ("workflows", "failure", ["build"]), ("workflows-failing", "failure", ["build"]), ("statuses", "success", [String]()), ("untimed", "success", [String]())] {
            try setPullRequest(checks)
            let rerunStatus = try XCTUnwrap(try runCLI(["task", "pr", "status", taskID], extraEnvironment: ghEnvironment)["result"] as? [[String: Any]])
            XCTAssertEqual(rerunStatus.first?["checks"] as? String, state, checks)
            XCTAssertEqual(rerunStatus.first?["failingChecks"] as? [String], failing, checks)
        }
        try setPullRequest("failure", threads: 1)
        let withThreads = try XCTUnwrap(try runCLI(["task", "pr", "status", taskID, "--review-threads"], extraEnvironment: ghEnvironment)["result"] as? [[String: Any]])
        XCTAssertEqual(withThreads.first?["unresolvedReviewThreads"] as? Int, 1, "--review-threads reads them.")
        try Data().write(to: callLogURL, options: .atomic)
        try setPullRequest("pending")

        // Autopilot on while checks run: no fix turn, only the slow poll.
        try selectPullRequestMode("autopilot", taskID: taskID)
        XCTAssertTrue(waitUntil({ (try? self.pullRequestMode(taskID: taskID)) == "autopilot" }, timeout: 5), "Turning autopilot on should persist in the plugin's state.")
        XCTAssertTrue(waitUntil({ (try? String(contentsOf: callLogURL, encoding: .utf8))?.contains("threads 801") ?? false }, timeout: 15), "Autopilot reads the PR's review threads.")
        try Data().write(to: holdRelease, options: .atomic)
        XCTAssertFalse(waitUntil({ FileManager.default.fileExists(atPath: turnActive.path) }, timeout: 5), "Pending checks must not start a fix turn.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review")
        XCTAssertFalse(try lastUserMessage().hasPrefix("Playhouse autopilot:"))
        // The plugin's service did this itself, on the mode change and then on its slow poll.
        func follows(_ trigger: String) -> Int {
            ((try? diagnosticEvents()) ?? []).filter {
                $0["event"] as? String == "plugin.pull_request_mode.follow" && $0["taskID"] as? String == taskID && $0["trigger"] as? String == trigger
            }.count
        }
        XCTAssertGreaterThanOrEqual(follows("mode"), 1, "Choosing Green in Review makes the plugin follow the task.")
        XCTAssertTrue(waitUntil({ follows("poll") >= 1 }, timeout: 15), "Running checks are followed on the slow poll.")
        // Each pass records its result: with checks still running, the poll's pass is pending.
        XCTAssertTrue(waitUntil({
            ((try? self.diagnosticEvents()) ?? []).contains {
                $0["event"] as? String == "plugin.pull_request_mode.followed" && $0["taskID"] as? String == taskID
                    && $0["trigger"] as? String == "poll" && $0["action"] as? String == "pending"
            }
        }, timeout: 15), "The poll's pass records that the checks are still pending.")

        // Red: failing checks and unresolved threads, found by the poll, make autopilot send a fix turn.
        try setPullRequest("failure", threads: 2)
        try driveAutopilotFixTurn(outcome: "completed") {
            XCTAssertTrue(self.waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "In Progress" }, timeout: 10), "A fix turn brings the task back to In Progress.")
            XCTAssertTrue(self.waitUntil({ (prLink.value as? String) == "red" }, timeout: 10), "Failing checks should colour the PR number red.")
            let prompt = try lastUserMessage()
            XCTAssertTrue(prompt.hasPrefix("Playhouse autopilot:"), prompt)
            for expected in ["#801", "failing checks: fixture-ci", "2 unresolved review threads", "critically", "reply", "resolve", "waiting-response", "Jira"] {
                XCTAssertTrue(prompt.contains(expected), "The fix prompt should mention \(expected): \(prompt)")
            }
            self.attachScreenshot(named: "Autopilot moved the red PR's task back to In Progress with a fix turn")
            self.attachElementScreenshot(self.element("task-card-\(taskID)"), named: "Failing checks colour the PR number red (card)")
            // The fix is pushed: the threads are answered and resolved, and CI reruns.
            try setPullRequest("pending")
        }
        assertTaskVisible("PR autopilot UI", inColumn: "Review")
        XCTAssertTrue(waitUntil({ (prLink.value as? String) == "pending" }, timeout: 20), "Rerunning checks after the fix should show blue.")
        // CI passes; the plugin's slow poll, not a focus change, notices: its pass reads the
        // review threads, finds the PR green and resets the loop guard.
        let threadReads = { (try? String(contentsOf: callLogURL, encoding: .utf8))?.components(separatedBy: "\n").filter { $0 == "threads 801" }.count ?? 0 }
        let readsBeforeGreen = threadReads()
        try setPullRequest("success")
        XCTAssertTrue(waitUntil({ (prLink.value as? String) == "green" }, timeout: 20), "Passing checks should colour the PR number green.")
        let fixPromptCount = { () throws -> Int in
            try XCTUnwrap((try self.runCLI(["conversation", "history", taskID])["result"] as? [String: Any])?["messages"] as? [[String: Any]])
                .filter { ($0["text"] as? String)?.hasPrefix("Playhouse autopilot:") == true }.count
        }
        let fixPrompts = try fixPromptCount()
        attachScreenshot(named: "Autopilot fixed the PR and its number turned green")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "The PR number turned green (card)")

        // The same red state as the first fix returns after green; the focus probe picks it
        // up, green reset the loop guard so it is fixed again, and the model stops the loop.
        // The guard reset is that poll's pass, which reads review threads; let it finish first.
        XCTAssertTrue(waitUntil({ threadReads() >= readsBeforeGreen + 1 }, timeout: 15), "Green should run the plugin's pass that resets the loop guard.")
        try setPullRequest("failure", threads: 2)
        let focusFollows = follows("focus")
        activateOtherAppThenReturn()
        XCTAssertTrue(waitUntil({ follows("focus") > focusFollows }, timeout: 15), "Coming back to the app makes the plugin follow its Green task in Review.")
        try driveAutopilotFixTurn(outcome: "waiting-response") {
            XCTAssertEqual(try lastUserMessage().hasPrefix("Playhouse autopilot:"), true)
        }
        try FileManager.default.removeItem(at: holdRelease)
        assertTaskVisible("PR autopilot UI", inColumn: "Waiting Response")
        XCTAssertEqual(try fixPromptCount(), fixPrompts + 1, "A green PR needs no fix turn; only the red-again state sends one.")
        attachScreenshot(named: "A fix turn that reports waiting-response stops the autopilot loop")

        // The user sends the task back to Review: autopilot tries the still-red PR once
        // more, and when that fix changes nothing it stops with a reason.
        openTask(named: "PR autopilot UI")
        try assertAutomaticMessageBubble(taskID: taskID, containing: "Playhouse autopilot:")
        attachScreenshot(named: "Autopilot fix prompt shown as an automatic Playhouse message")
        // The task passes through Review only until the board runs autopilot again, so the
        // fix-turn wait below, not this status, proves autopilot picked it back up.
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR autopilot UI", expectedFinalStatus: "In Progress", whileTurnHeld: {
            try Data().write(to: holdRelease, options: .atomic)
        })
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ follows("review") >= 1 }, timeout: 15), "Reaching Review makes the plugin follow its Green task.")
        try driveAutopilotFixTurn(outcome: "completed") {}
        try FileManager.default.removeItem(at: holdRelease)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Waiting Response" }, timeout: 30), "An unchanged red state should stop autopilot in Waiting Response.")
        let reason = try taskRecord(id: taskID)?["statusMessage"] as? String
        XCTAssertTrue((reason ?? "").contains("nothing changed"), reason ?? "nil")
        XCTAssertEqual(try fixPromptCount(), fixPrompts + 2)
        assertTaskVisible("PR autopilot UI", inColumn: "Waiting Response")
        attachScreenshot(named: "Autopilot stops with a reason when nothing changed since its last fix")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "Autopilot stops with a reason (card)")

        // A pass the plugin started asks it again before it merges: with the mode no longer
        // Merge, it merges nothing.
        try setPullRequest("success")
        XCTAssertEqual((try runCLI(["task", "move", taskID, "Review"], extraEnvironment: ghEnvironment)["result"] as? [String: Any])?["status"] as? String, "Review")
        // The move to Review starts the plugin's own pass; until it lets go of the task, a
        // second pass skips it without asking the plugin, so ask again until one is declined.
        XCTAssertTrue(waitUntil({
            let declined = (try? self.runCLI(["task", "pr", "autopilot", taskID, "--merge", "--confirm-with", "pull-request-mode"], extraEnvironment: ghEnvironment))?["result"] as? [String: Any]
            XCTAssertEqual(declined?["action"] as? String, "inactive", "A Green task's merge pass merges nothing.")
            return ((try? self.diagnosticEvents()) ?? []).contains {
                $0["event"] as? String == "plugin.pull_request_mode.declined" && $0["taskID"] as? String == taskID && $0["action"] as? String == "merge"
            }
        }, timeout: 20), "The plugin declined the merge for a Green task.")
        let declinedLink = app.links["task-pr-link-\(taskID)-801"]
        XCTAssertTrue(declinedLink.waitToExist(timeout: 10), "The declined pass leaves the linked PR on the card.")
        XCTAssertFalse(waitUntil({ (declinedLink.value as? String) == "merged" }, timeout: 3), "The declined pass merged nothing.")
        let missingPlugin = try runCLI(["task", "pr", "autopilot", taskID, "--confirm-with"], expectedStatus: 2)
        XCTAssertEqual((missingPlugin["error"] as? [String: Any])?["code"] as? String, "invalid_argument")
        assertTaskVisible("PR autopilot UI", inColumn: "Review")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "A Green task's merge pass merges nothing (card)")
    }
    // case-contract: test_task_pr_merge_mode_merges_green_pull_request | Merge mode (a `task pr autopilot --merge` pass, which the pull-request-mode plugin runs for its Merge tasks) does everything autopilot does (it reads review threads, and red pull requests take the same autopilot fix path covered by the autopilot case) and also merges each linked pull request once it is green: with checks still running, or no checks reported yet on a freshly pushed head, it merges nothing and the task stays in Review; once checks pass (or the head has had no checks past the registration grace, as in a repository without CI) with no unresolved threads and GitHub reporting it mergeable, it merges the PR through GitHub CLI, pinned to the head commit it saw green, with the first merge method the repository allows (squash when allowed, otherwise a merge commit), exactly once; the PR reads as merged, the task stays in Review for the user to complete, and the card shows the merged completion action. A head that still has no checks after the registration grace is merged all the same. A merge GitHub refuses (for example a required review) moves the task to Waiting Response with GitHub's reason instead of retrying.
    func test_task_pr_merge_mode_merges_green_pull_request() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        var ghEnvironment = try makeGitHubStateFixture(expectedNumbers: []).merging(Self.prCheckCooldownEnvironment) { $1 }
        ghEnvironment["PLAYHOUSE_E2E_PR_AUTOPILOT_POLL_SECONDS"] = "2"
        let stateURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"]))
        let callLogURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CALL_LOG"]))
        let mergeLogURL = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_LOG"]))
        func merges() -> [String] {
            ((try? String(contentsOf: mergeLogURL, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("merge") }
        }
        try "811=unmerged\n811.checks=pending\n812=unmerged\n812.checks=none\n812.merge=Pull request is not mergeable: a review is required\n"
            .write(to: stateURL, atomically: true, encoding: .utf8)

        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        var taskIDs: [String] = []
        for (title, repository) in [("PR merge mode UI", fixture.primary), ("PR merge refused UI", fixture.secondary)] {
            let created = try XCTUnwrap(try runCLI([
                "task", "create", "--title", title, "--repo", repository.path, "--merge-target", "\(repository.path)=main",
                "--prompt", Self.fixtureTaskPrompt,
            ])["result"] as? [String: Any])
            taskIDs.append(try XCTUnwrap(created["id"] as? String))
            openTask(named: title)
            try completeCurrentTaskWithFixtureAnswers(taskTitle: title)
            element("back-to-board-button").click()
        }
        let (taskID, refusedID) = (taskIDs[0], taskIDs[1])
        /// The no-checks grace runs from the head's commit time; pin it either way.
        func commitHead(_ id: String, committedAt: String? = nil) throws {
            let record = try XCTUnwrap((try taskRecord(id: id)?["repositoryWorktrees"] as? [[String: Any]])?.first)
            let worktree = URL(fileURLWithPath: try XCTUnwrap(record["worktreePath"] as? String), isDirectory: true)
            let dates = committedAt.map { ["GIT_AUTHOR_DATE": $0, "GIT_COMMITTER_DATE": $0] } ?? [:]
            _ = try runGitOutput(worktree, ["commit", "--allow-empty", "-m", "Fixture head"], environment: dates)
        }
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: taskID, number: 811, url: "https://github.com/playhouse-test/fixture/pull/811")
        try seedTaskPullRequest(taskID: refusedID, number: 812, url: "https://github.com/playhouse-test/fixture/pull/812")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)

        let prLink = app.links["task-pr-link-\(taskID)-811"]
        XCTAssertTrue(prLink.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntil({ (prLink.value as? String) == "pending" }, timeout: 15))
        let pill = element("task-pr-mode-\(taskID)")
        XCTAssertTrue(pill.waitToExist(timeout: 5))
        pill.click()
        let mergeOption = settledPillOption("merge", taskID: taskID)
        attachScreenshot(named: "The open mode pill offers Merge beside the linked PR")
        attachElementScreenshot(element("task-card-\(taskID)"), named: "The open pill beside the linked PR (card)")
        mergeOption.click()
        XCTAssertTrue(waitUntil({ pill.exists && (pill.value as? String) == "merge" }, timeout: 5), "Choosing Merge should fold the pill onto Merge.")
        XCTAssertTrue(waitUntil({ (try? self.pullRequestMode(taskID: taskID)) == "merge" }, timeout: 5))
        XCTAssertTrue(waitUntil({ (try? String(contentsOf: callLogURL, encoding: .utf8))?.contains("threads 811") ?? false }, timeout: 15), "Merge mode reads review threads like autopilot.")
        XCTAssertFalse(waitUntil({ !merges().isEmpty }, timeout: 5), "Running checks must not be merged.")
        try commitHead(taskID)
        try (try String(contentsOf: stateURL, encoding: .utf8)).replacingOccurrences(of: "811.checks=pending", with: "811.checks=none")
            .write(to: stateURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(waitUntil({ !merges().isEmpty }, timeout: 5), "A head with no checks reported yet must not be merged.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "A freshly pushed head may not have registered its checks yet.")
        try (try String(contentsOf: stateURL, encoding: .utf8)).replacingOccurrences(of: "811.checks=none", with: "811.checks=pending")
            .write(to: stateURL, atomically: true, encoding: .utf8)
        attachScreenshot(named: "Merge mode waits while checks run")

        try (try String(contentsOf: stateURL, encoding: .utf8)).replacingOccurrences(of: "811.checks=pending", with: "811.checks=success")
            .write(to: stateURL, atomically: true, encoding: .utf8)
        let completeButton = element("task-complete-merged-pr-\(taskID)")
        XCTAssertTrue(completeButton.waitToExist(timeout: 20), "Once green, merge mode should merge the PR and the card should offer completion.")
        XCTAssertEqual(merges().filter { $0.contains("\t811\t") }, ["merged\t811\t--squash"], "The PR is merged once with the first allowed method.")
        XCTAssertEqual(try taskRecord(id: taskID)?["status"] as? String, "Review", "Merging leaves the task in Review for the user to complete.")
        attachScreenshot(named: "Merge mode merged the green PR and the card offers completion")

        // Long past the grace with still no checks (a repository without CI): merge mode
        // still attempts the merge; GitHub refuses it, so the task stops with GitHub's reason.
        try commitHead(refusedID, committedAt: "2020-01-01T00:00:00Z")
        try selectPullRequestMode("merge", taskID: refusedID)
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: refusedID)?["status"] as? String) == "Waiting Response" }, timeout: 20), "A refused merge of a PR with no checks should stop merge mode in Waiting Response.")
        let noCIReason = try taskRecord(id: refusedID)?["statusMessage"] as? String ?? ""
        XCTAssertTrue(noCIReason.contains("couldn't merge pull request #812") && !noCIReason.contains("no checks"), noCIReason)
        XCTAssertEqual(merges().filter { $0.contains("\t812\t") }, ["merge-failed\t812\t--squash"], "No checks past the grace is still merged, with the first allowed method.")
        assertTaskVisible("PR merge refused UI", inColumn: "Waiting Response")
        attachScreenshot(named: "Merge mode attempts the merge when GitHub reports no checks")

        // The user sends it back to Review; GitHub still refuses the merge. The
        // `repo.methods` line, written after #811 merged, disallows squash from here on.
        try (try String(contentsOf: stateURL, encoding: .utf8))
            .appending("repo.methods=merge,rebase\n").write(to: stateURL, atomically: true, encoding: .utf8)
        openTask(named: "PR merge refused UI")
        // Settling covers Review, the probe, the daemon's merge attempt, and its refusal.
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR merge refused UI", expectedFinalStatus: "Waiting Response", settleTimeout: 30)
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ ((try? self.taskRecord(id: refusedID)?["statusMessage"] as? String) ?? "").contains("couldn't merge pull request #812") }, timeout: 20), "A refused merge should stop in Waiting Response.")
        let reason = try taskRecord(id: refusedID)?["statusMessage"] as? String ?? ""
        XCTAssertTrue(reason.contains("couldn't merge pull request #812") && reason.contains("a review is required"), reason)
        assertTaskVisible("PR merge refused UI", inColumn: "Waiting Response")
        XCTAssertEqual(merges().filter { $0.contains("\t812\t") }, ["merge-failed\t812\t--squash", "merge-failed\t812\t--merge"], "A refused merge is not retried within a pass.")
        attachScreenshot(named: "A refused merge stops in Waiting Response with GitHub's reason")
    }
    // case-contract: test_task_pr_conflicts_detect_without_mutation | The real Git CLI detects merge conflicts without mutation, and PR creation still publishes the task branch and reaches the normal GitHub CLI path; conflicts do not block PR creation. CLI/XPC resolves staged conflicts locally without pushing and commits and pushes a staged resolution without changing the target. The paired UI confirms PR creation proceeds for a conflicted branch and the existing Fix Conflicts action still appears once the PR is linked.
    func test_task_pr_conflicts_detect_without_mutation() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        // The fixture gh fails the first create, so the click reaches the normal GitHub CLI
        // failure without depending on the gh installed in the VM or its sign-in.
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [])
        try "1".write(to: URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_FAILURE_PATH"])), atomically: true, encoding: .utf8)
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment.merging(Self.prCheckCooldownEnvironment) { $1 })
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "PR conflict choice UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        // Manual, the default, kept explicit: this case drives the manual PR path.
        try setPullRequestMode("manual", taskID: taskID)
        _ = try XCTUnwrap((created["repositoryWorktrees"] as? [[String: Any]])?.first)
        openTask(named: "PR conflict choice UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "PR conflict choice UI")
        let completedRecord = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktree = URL(fileURLWithPath: try XCTUnwrap(completedRecord["worktreePath"] as? String), isDirectory: true)

        let conflictPath = "playhouse-pr-conflict-fixture.txt"
        let originalTargetHead = try runGitOutput(fixture.primary, "rev-parse", "main")
        addTeardownBlock { [self] in
            try? runGit(fixture.primary, "remote", "remove", "origin")
            try? runGit(fixture.primary, "reset", "--hard", originalTargetHead)
        }
        try "target branch version\n".write(to: fixture.primary.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(fixture.primary, "add", conflictPath)
        try runGit(fixture.primary, "commit", "-m", "Update PR target fixture")
        try "task branch version\n".write(to: worktree.appendingPathComponent(conflictPath), atomically: true, encoding: .utf8)
        try runGit(worktree, "add", conflictPath)
        try runGit(worktree, "commit", "-m", "Update task branch fixture")
        let branchHead = try runGitOutput(worktree, "rev-parse", "HEAD")
        let targetHead = try runGitOutput(fixture.primary, "rev-parse", "main")
        let remote = runDirectory.appendingPathComponent("pr-conflict-origin.git", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path), "Each UI case should start with an isolated bare remote fixture.")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGitOutput(remote, "init", "--bare")
        try runGit(fixture.primary, "remote", "add", "origin", remote.path)
        try runGit(fixture.primary, "push", "--set-upstream", "origin", "main")
        let conflictResult = try runCLI(["task", "pr", "conflicts", taskID])["result"] as? [String: Any]
        XCTAssertEqual(conflictResult?["repositories"] as? [String], [fixture.primary.path])
        XCTAssertEqual(try runGitOutput(worktree, "rev-parse", "HEAD"), branchHead, "Conflict detection must leave the task branch unchanged.")
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetHead, "Conflict detection must leave the target branch unchanged.")
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent(conflictPath), encoding: .utf8), "task branch version\n")
        XCTAssertEqual(try String(contentsOf: fixture.primary.appendingPathComponent(conflictPath), encoding: .utf8), "target branch version\n")

        element("back-to-board-button").click()
        let prButton = element("task-create-pr-\(taskID)")
        XCTAssertTrue(prButton.waitToExist(timeout: 5))
        revealOnBoard(prButton)
        prButton.click()
        let failureAlert = app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
        XCTAssertTrue(failureAlert.waitToExist(timeout: 10), "PR creation should reach the fixture GitHub CLI failure after the task branch is published.")
        let conflictGuidance = failureAlert.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@", "Resolve conflicts")
        ).firstMatch
        XCTAssertFalse(conflictGuidance.exists, "Conflicts must no longer block PR creation.")
        let ghGuidance = failureAlert.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "GitHub CLI couldn't complete the request. fixture GitHub create failure")
        ).firstMatch
        XCTAssertTrue(ghGuidance.exists, "The failure should come from the normal GitHub CLI create call, not a conflict preflight.")
        failureAlert.buttons["OK"].click()
        let createCalls = try String(contentsOfFile: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_CREATE_LOG"]), encoding: .utf8)
        let failedCreateDirectories = createCalls.components(separatedBy: "\n").filter { $0.hasPrefix("failed\t") }
            .compactMap { $0.split(separator: "\t", maxSplits: 2).dropFirst().first.map(String.init) }
            .map { $0.replacingOccurrences(of: "/private/tmp/", with: "/tmp/") }
        XCTAssertEqual(
            failedCreateDirectories,
            [worktree.resolvingSymlinksInPath().path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")],
            "gh pr create should have run once in the task worktree: \(createCalls)"
        )
        XCTAssertEqual(try runGitOutput(worktree, "rev-parse", "HEAD"), branchHead)
        XCTAssertEqual(try runGitOutput(fixture.primary, "rev-parse", "main"), targetHead)
        XCTAssertEqual(
            try runGitOutput(fixture.primary, "ls-remote", "--heads", "origin", try XCTUnwrap(completedRecord["branch"] as? String))
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "\(branchHead)\trefs/heads/\(try XCTUnwrap(completedRecord["branch"] as? String))",
            "A conflicted task branch should still be published for PR creation."
        )
        XCTAssertTrue(waitUntil({ prButton.isEnabled }, timeout: 10))
        XCTAssertNil((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["pullRequestNumber"])

        // The fixture creates PR 501 on the retry and reports it conflicting, so the board's
        // review probe must bring back the Fix Conflicts action once the PR is linked.
        let resolveButton = element("task-resolve-pr-conflicts-\(taskID)")
        XCTAssertFalse(resolveButton.exists, "No conflict action can appear before a PR is linked.")
        try "501=conflicting\n".write(to: URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STATE_PATH"])), atomically: true, encoding: .utf8)
        prButton.click()
        XCTAssertTrue(element("task-pr-link-\(taskID)-501").waitToExist(timeout: 15), "The retried PR creation should link the fixture PR.")
        XCTAssertEqual((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["pullRequestNumber"] as? Int, 501)
        XCTAssertTrue(waitUntil({
            if resolveButton.exists { return true }
            activateOtherAppThenReturn()
            return resolveButton.waitToExist(timeout: Self.prCheckCooldown + 1)
        }, timeout: 20), "The linked conflicting PR should show the existing Fix Conflicts action.")
        attachScreenshot(named: "A linked conflicting PR shows the Fix Conflicts action")
    }
    // case-contract: test_review_probe_failure_alerts_only_while_in_review | A Review task whose linked pull request probe fails reports it: `task pr status` fails as operation_failed with the GitHub CLI's error, and the board raises its Pull request operation failed alert naming that error. Once the task moves to Done with --allow-unmerged, which removes its worktree, it is Done with no worktree left, a board probe that was already running when it moved raises no alert, and `task pr status` of the Done task lists only its recorded pull request, without probing, instead of the GitHub CLI's error.
    func test_review_probe_failure_alerts_only_while_in_review() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        // PR 999 is never probed, so every probe of 123 waits for it, then fails: a probe error
        // that holds for about two seconds before it is reported. The first launch gets it too:
        // a task in Review is checked for pull requests its agent opened, even in Manual mode.
        let ghEnvironment = try makeGitHubStateFixture(expectedNumbers: [123, 999])
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Review probe failure UI", "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
            "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        try setPullRequestMode("manual", taskID: taskID)
        openTask(named: "Review probe failure UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Review probe failure UI")
        element("back-to-board-button").click()
        XCTAssertTrue(waitUntil({ (try? self.taskRecord(id: taskID)?["status"] as? String) == "Review" }, timeout: 10))
        let worktreePath = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
        XCTAssertTrue(terminateAppAndWait(app))
        try seedTaskPullRequest(taskID: taskID, number: 123, url: "https://github.com/playhouse-test/fixture/pull/123")

        let startedDirectory = URL(fileURLWithPath: try XCTUnwrap(ghEnvironment["PLAYHOUSE_E2E_GH_STARTED_DIRECTORY"]))
        let started = startedDirectory.appendingPathComponent("123")
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: ghEnvironment.merging(Self.prCheckCooldownEnvironment) { $1 })
        let alert = app.sheets.matching(NSPredicate(format: "label == %@", "alert")).firstMatch
        XCTAssertTrue(alert.waitToExist(timeout: 15), "A failed probe of a task in Review raises the board's alert.")
        XCTAssertTrue(alert.staticTexts["Pull request operation failed"].exists)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "did not run in parallel")).firstMatch.exists,
                      "The alert names the probe's error.")
        attachScreenshot(named: "A failed probe of a Review task raises the alert")
        alert.buttons["OK"].click()
        XCTAssertTrue(waitForDisappearance(alert))
        // A trailing probe may still be held; let it report (the task is still in Review, so it
        // may alert again) before the probe this step times against the move.
        if waitUntil({ alert.exists }, timeout: 4) {
            alert.buttons["OK"].click()
            XCTAssertTrue(waitForDisappearance(alert))
        }

        // A probe already running when the task moves to Done fails after its worktree is gone.
        try? FileManager.default.removeItem(at: started)
        XCTAssertTrue(waitUntil({
            if FileManager.default.fileExists(atPath: started.path) { return true }
            self.activateOtherAppThenReturn()
            return self.waitUntil({ FileManager.default.fileExists(atPath: started.path) }, timeout: Self.prCheckCooldown + 1)
        }, timeout: 20), "A focus probe of the Review task should start.")
        XCTAssertEqual((try runCLI(["task", "move", taskID, "Done", "--allow-unmerged"])["result"] as? [String: Any])?["status"] as? String, "Done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath), "Moving to Done removes the worktree the running probe reads.")
        XCTAssertTrue(waitUntil({ !self.element("task-card-\(taskID)").exists }, timeout: 10), "The Done task leaves the board.")
        // The held probe fails about two seconds after it started; give its result time to land.
        XCTAssertFalse(waitUntil({ alert.exists }, timeout: 5), "A probe that failed after its task left Review raises no alert.")
        attachScreenshot(named: "No alert for a probe that failed after the task moved to Done")
        let doneStates = try runCLI(["task", "pr", "status", taskID], extraEnvironment: ghEnvironment)["result"] as? [[String: Any]]
        XCTAssertEqual(doneStates?.compactMap { $0["number"] as? Int }, [123], "A Done task whose worktree was removed lists only its recorded pull request, without probing GitHub.")
        XCTAssertNil(doneStates?.first?["past"])
    }
    // case-contract: test_done_task_accepts_follow_up_conversation | A Done task keeps its conversation open: the UI shows the composer with an archived hint saying a follow-up reopens the task in a fresh worktree from the merge target, instead of a read-only notice; its changes read reports no changes rather than a Git error for the removed worktree, and switching its provider is rejected. A follow-up sent from a Done task moves it back to In Progress before the turn starts, so it shows in the board's In Progress column while the agent works, with a fresh worktree renewed for the removed one. The real provider turn runs in that fresh worktree and is told it as an active task worktree rather than that the task is archived; its completed outcome moves the task to Review, the removed worktree stays removed, and the follow-up and its reply persist in the history across fresh reads. A Done task with no worktree to renew (one with only a context root) reopens to In Progress for its follow-up the same way, keeps that root, and its completed outcome moves it to Review.
    func test_done_task_accepts_follow_up_conversation() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Archived follow-up UI", "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path, "--merge-target", "\(fixture.primary.path)=main",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Archived follow-up UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Archived follow-up UI")
        let record = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktreePath = try XCTUnwrap(record["worktreePath"] as? String)
        let repositoryPath = try XCTUnwrap(record["repositoryPath"] as? String)
        element("back-to-board-button").click()
        moveTaskToDone(taskID: taskID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath), "Moving to Done removes the managed worktree before the follow-up.")
        element("done-archive-button").click()
        let archived = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archived.waitToExist(timeout: 10))
        archived.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let hint = element("archived-conversation-follow-up-hint")
        XCTAssertTrue(hint.waitToExist(timeout: 10), "A Done task shows the archived follow-up hint above its composer.")
        let hintText = accessibleLabelOrValue(of: hint)
        XCTAssertTrue(hintText.contains("a follow-up reopens this task in a fresh worktree from main"), "The hint names the merge target: \(hintText)")
        XCTAssertTrue(element("workspace-changes-empty").waitToExist(timeout: 10), "A Done task's changes load as no changes.")
        XCTAssertFalse(element("workspace-changes-error").exists, "A Done task shows no Git error for its removed worktree.")
        XCTAssertFalse(element("archived-conversation-read-only").exists, "A Done task's conversation is no longer read only.")
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 10), "A Done task keeps its composer for follow-up questions.")
        let providerMenu = element("conversation-provider-menu")
        XCTAssertTrue(providerMenu.waitToExist(timeout: 10))
        XCTAssertFalse(providerMenu.isEnabled, "A Done task still offers no provider switch.")
        let doneSwitch = try runCLI(["conversation", "provider", taskID, "set", "claude"], expectedStatus: 2)
        XCTAssertTrue(((doneSwitch["error"] as? [String: Any])?["message"] as? String ?? "").contains("Done tasks are closed"))
        attachScreenshot(named: "Done task keeps its composer with the archived follow-up hint")
        attachElementScreenshot(hint, named: "Archived hint says a follow-up reopens the task")

        let question = "Which files did this archived task change?"
        var freshWorktreePath: String?
        try completeCurrentTaskWithFixtureAnswers(
            taskTitle: "Archived follow-up UI",
            prompt: question,
            whileTurnHeld: { [self] in
                // While the agent works on the follow-up, the task is back on the board.
                let running = try XCTUnwrap(taskRecord(id: taskID))
                XCTAssertEqual(running["status"] as? String, "In Progress", "A follow-up moves the Done task back to In Progress.")
                let fresh = try XCTUnwrap((running["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String)
                XCTAssertNotEqual(fresh, worktreePath, "The reopened task works in a fresh worktree.")
                XCTAssertTrue(FileManager.default.fileExists(atPath: fresh), "The fresh worktree exists while the follow-up runs.")
                freshWorktreePath = fresh
                XCTAssertTrue(waitUntil({ !self.element("archived-conversation-follow-up-hint").exists }, timeout: 10), "The reopened task is no longer archived.")
                assertTaskVisible("Archived follow-up UI", inColumn: "In Progress")
                attachScreenshot(named: "Follow-up moves the Done task back to In Progress")
                attachElementScreenshot(element("task-card-\(taskID.uppercased())"), named: "Reopened task card in the In Progress column")
                openTask(named: "Archived follow-up UI")
            }
        )
        let sentQuestion = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", question)).firstMatch
        XCTAssertTrue(sentQuestion.waitToExist(timeout: 10), "The follow-up question stays in the task's conversation.")
        let replies = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "assistant-message-", "Answers received: Blue / fixture-secret."
        ))
        // The transcript renders lazily, so the first turn's reply may be scrolled out; the
        // follow-up's own reply is the one below the follow-up question.
        let followUpReplyBelowQuestion = {
            replies.allElementsBoundByIndex.contains { $0.frame.minY > sentQuestion.frame.maxY }
        }
        XCTAssertTrue(waitUntil(followUpReplyBelowQuestion, timeout: 10), "The follow-up's reply appears below the follow-up question.")
        let freshWorktree = try XCTUnwrap(freshWorktreePath)
        let history = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history"))) as? [String: Any]
        let followUp = try XCTUnwrap((history?["turns"] as? [[String: Any]])?.last)
        XCTAssertTrue((followUp["userMessage"] as? String ?? "").contains(question))
        XCTAssertEqual(followUp["cwd"] as? String, freshWorktree, "The follow-up runs in the fresh worktree.")
        let instructions = try XCTUnwrap((history?["threadResumeDeveloperInstructions"] as? [Any])?.last as? String)
        XCTAssertFalse(instructions.contains("This task is Done (archived)"), "The follow-up runs as an active task.")
        XCTAssertTrue(instructions.contains("Active task worktrees for edits: \(repositoryPath) -> \(freshWorktree)"))
        XCTAssertFalse(element("archived-conversation-follow-up-hint").exists)
        attachScreenshot(named: "Reopened task answers the follow-up in Review")
        assertTaskVisible("Archived follow-up UI", inColumn: "Review")
        let current = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(current["status"] as? String, "Review", "The follow-up's completed outcome moves the reopened task to Review.")
        XCTAssertEqual((current["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String, freshWorktree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath), "The removed worktree stays removed.")
        // A fresh history load keeps the follow-up and both replies.
        openTask(named: "Archived follow-up UI")
        XCTAssertTrue(sentQuestion.waitToExist(timeout: 10), "The follow-up persists in the reopened conversation.")
        XCTAssertTrue(waitUntil(followUpReplyBelowQuestion, timeout: 10), "The follow-up's reply persists below it in the reopened conversation.")
        attachScreenshot(named: "Reopened task keeps the follow-up and its reply")
        element("back-to-board-button").click()

        // A task with only a context root has no worktree to renew; its follow-up still reopens it.
        let rooted = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Archived rooted follow-up UI", "--prompt", "Fixture task description.", "--root", fixture.primary.path,
        ])["result"] as? [String: Any])
        let rootedID = try XCTUnwrap(rooted["id"] as? String)
        openTask(named: "Archived rooted follow-up UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Archived rooted follow-up UI")
        element("back-to-board-button").click()
        moveTaskToDone(taskID: rootedID)
        element("done-archive-button").click()
        let rootedArchived = element("done-archive-task-\(rootedID)")
        XCTAssertTrue(rootedArchived.waitToExist(timeout: 10))
        rootedArchived.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(element("archived-conversation-follow-up-hint").waitToExist(timeout: 10))
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Archived rooted follow-up UI", prompt: "One more question.", whileTurnHeld: { [self] in
            let running = try XCTUnwrap(taskRecord(id: rootedID))
            XCTAssertEqual(running["status"] as? String, "In Progress", "A follow-up reopens a Done task that has no worktree to renew.")
            XCTAssertEqual((running["repositoryWorktrees"] as? [Any])?.count, 0)
            XCTAssertEqual(running["workspaceRoots"] as? [String], [fixture.primary.path])
            assertTaskVisible("Archived rooted follow-up UI", inColumn: "In Progress")
        }, reloadConversationAfterTurn: true)
        assertTaskVisible("Archived rooted follow-up UI", inColumn: "Review")
        XCTAssertEqual(try taskRecord(id: rootedID)?["status"] as? String, "Review")
    }
    // case-contract: test_done_task_follow_up_reopen_failure_keeps_task_done | A follow-up to a Done task whose merge target no longer exists cannot renew its removed worktree: the send fails with the missing merge target error, the task stays Done with no new worktree and no provider turn, and the follow-up is not left pending as a submitted prompt, so the UI composer keeps its text.
    func test_done_task_follow_up_reopen_failure_keeps_task_done() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let target = "reopen-failure-target"
        try runGit(fixture.primary, "branch", target, "main")
        addTeardownBlock { [self] in
            if !((try? runGitOutput(fixture.primary, "branch", "--list", target)) ?? "").isEmpty {
                try? runGit(fixture.primary, "branch", "-D", target)
            }
        }
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Reopen failure UI", "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path, "--merge-target", "\(fixture.primary.path)=\(target)",
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Reopen failure UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Reopen failure UI")
        let record = try XCTUnwrap((try taskRecord(id: taskID)?["repositoryWorktrees"] as? [[String: Any]])?.first)
        let worktreePath = try XCTUnwrap(record["worktreePath"] as? String)
        element("back-to-board-button").click()
        moveTaskToDone(taskID: taskID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
        try runGit(fixture.primary, "branch", "-D", target)
        let historyURL = URL(fileURLWithPath: try XCTUnwrap(codexFixtureExecutable) + ".history")
        let turnsBefore = ((try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])?["turns"] as? [Any])?.count
        element("done-archive-button").click()
        let archived = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archived.waitToExist(timeout: 10))
        archived.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(element("archived-conversation-follow-up-hint").waitToExist(timeout: 10))
        let followUp = "Can you follow up on this?"
        element("message-composer").click()
        element("message-composer").typeText(followUp)
        element("send-message-button").click()
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitToExist(timeout: 15), "The failed reopen shows its error.")
        XCTAssertTrue(accessibleLabelOrValue(of: error).contains("The merge target '\(target)' doesn't exist"), accessibleLabelOrValue(of: error))
        XCTAssertTrue(waitUntil({ self.element("message-composer").value as? String == followUp }, timeout: 10), "The composer keeps the failed follow-up.")
        XCTAssertTrue(element("archived-conversation-follow-up-hint").exists, "The task stays archived.")
        attachScreenshot(named: "Failed reopen keeps the Done task and the follow-up")
        attachElementScreenshot(error, named: "Missing merge target error")
        let current = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(current["status"] as? String, "Done", "A follow-up that cannot reopen the task leaves it Done.")
        XCTAssertEqual((current["repositoryWorktrees"] as? [[String: Any]])?.first?["worktreePath"] as? String, worktreePath, "A failed reopen creates no worktree.")
        XCTAssertNil(current["pendingSubmittedPrompt"] as? String, "The failed follow-up is not left pending.")
        let turnsAfter = ((try JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: Any])?["turns"] as? [Any])?.count
        XCTAssertEqual(turnsAfter, turnsBefore, "No provider turn runs.")
        element("back-to-board-button").click()
    }
    // case-contract: test_done_task_follow_up_setup_failure_restores_draft | A Done task with only a context folder reopens without creating a worktree, but if that folder disappears and no default parent is configured, a bridge follow-up send fails before a provider turn starts; the task moves to Waiting Response, and the submitted prompt returns to its draft. The test then restores the folder so the UI can reopen the task and display the returned draft.
    func test_done_task_follow_up_setup_failure_restores_draft() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        let contextRoot = dataDirectory.appendingPathComponent("removed-follow-up-context", isDirectory: true)
        try FileManager.default.createDirectory(at: contextRoot, withIntermediateDirectories: true)
        launchApp(defaultParent: fixture.parent.path)
        let created = try XCTUnwrap(try runCLI([
            "task", "create", "--title", "Missing follow-up root UI", "--prompt", "Fixture task description.", "--root", contextRoot.path,
        ])["result"] as? [String: Any])
        let taskID = try XCTUnwrap(created["id"] as? String)
        openTask(named: "Missing follow-up root UI")
        try completeCurrentTaskWithFixtureAnswers(taskTitle: "Missing follow-up root UI")
        element("back-to-board-button").click()
        moveTaskToDone(taskID: taskID)
        element("done-archive-button").click()
        let archived = element("done-archive-task-\(taskID)")
        XCTAssertTrue(archived.waitToExist(timeout: 10))
        archived.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(element("message-composer").waitToExist(timeout: 10))
        try FileManager.default.removeItem(at: contextRoot)
        _ = try runCLI(["settings", "clear-parent"])
        let followUp = "Follow up after the context folder vanished."
        let failure = try runCLI(["conversation", "send", taskID, "--message", followUp], expectedStatus: 1)
        XCTAssertTrue(((failure["error"] as? [String: Any])?["message"] as? String ?? "").lowercased().contains("repository root folder"))
        let current = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(current["status"] as? String, "Waiting Response")
        XCTAssertNil(current["pendingSubmittedPrompt"] as? String)
        XCTAssertTrue(current["hasUnsentDraft"] as? Bool == true)
        XCTAssertEqual(current["savedPrompt"] as? String, followUp)
        XCTAssertEqual((current["repositoryWorktrees"] as? [Any])?.count, 0)
        try FileManager.default.createDirectory(at: contextRoot, withIntermediateDirectories: true)
        element("back-to-board-button").click()
        assertTaskVisible("Missing follow-up root UI", inColumn: "Waiting Response")
        attachScreenshot(named: "Failed archived follow-up moves to Waiting Response")
        attachElementScreenshot(element("task-card-\(taskID.uppercased())"), named: "Task card in Waiting Response after setup fails")
        openTask(named: "Missing follow-up root UI")
        XCTAssertTrue(waitUntil({ self.element("message-composer").value as? String == followUp }, timeout: 10), "The UI restores the submitted follow-up in the composer.")
        attachScreenshot(named: "Failed setup restores the follow-up in the composer")
        attachElementScreenshot(element("message-composer"), named: "Restored follow-up draft in the composer")
    }
}

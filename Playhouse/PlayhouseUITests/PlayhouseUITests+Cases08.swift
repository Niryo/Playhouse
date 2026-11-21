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
    // case-contract: test_task_repository_default_branch_from_uses_fresh_origin | With no branch-from given, adding a repository runs no Git: the pending record leaves its branch-from and merge target undecided until its chip's settings open (`task repository resolve`) or the task starts. Opening them saves and shows the defaults, and resolving again leaves them as saved, while resolving a repository the task lacks fails as not found. A repository without an origin remote keeps its local default branch, while a repository whose origin has the default branch resolves to origin's remote-tracking branch as the pending branch-from. Starting the task fetches origin first, so the worktree starts from origin's latest commit even when the local default branch and its remote-tracking ref are stale and the local branch holds unpushed commits, without making the remote branch the task branch's upstream. When origin can't be reached at start, the task still starts from the last fetched origin commit.
    func test_task_repository_default_branch_from_uses_fresh_origin() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)
        let badge = element("conversation-repository-badge-primary")
        let branchFromValue = element("conversation-repository-branch-from-value")
        func showBranchFrom(taskTitle: String, expected: String, screenshot: String) {
            openTask(named: taskTitle)
            XCTAssertTrue(badge.waitToExist(timeout: 5))
            badge.click()
            XCTAssertTrue(branchFromValue.waitToExist(timeout: 5), app.debugDescription)
            // Opening the chip's settings is what works the default out with Git.
            XCTAssertTrue(
                waitUntil({ accessibleLabelOrValue(of: branchFromValue) == expected }, timeout: 10),
                "The chip's settings should show the resolved default \(expected): \(app.debugDescription)"
            )
            attachScreenshot(named: screenshot)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitForDisappearance(branchFromValue), "Dismissing the editor should close it before the turn starts.")
        }

        let localTitle = "Default branch-from without origin"
        let localTask = try runCLI([
            "task", "create", "--title", localTitle, "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
        ])["result"] as? [String: Any]
        let localTaskID = try XCTUnwrap(localTask?["id"] as? String)
        // Adding the repository runs no Git: its defaults wait until the chip opens or the task starts.
        let undecided = try XCTUnwrap(repositoryRecord(taskID: localTaskID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(undecided["branchFrom"] as? String, "")
        XCTAssertNil(undecided["mergeTarget"] as? String)
        showBranchFrom(taskTitle: localTitle, expected: "main", screenshot: "Without an origin the default branch-from stays local")
        XCTAssertTrue(waitForRepositoryValue(taskID: localTaskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "main"))
        XCTAssertTrue(waitForRepositoryValue(taskID: localTaskID, repositoryPath: fixture.primary.path, key: "mergeTarget", expected: "main"))
        // Reopening shows the saved defaults; a repository the task lacks has none to resolve.
        showBranchFrom(taskTitle: localTitle, expected: "main", screenshot: "Reopened settings keep the resolved branch-from")
        let missing = try runCLI(["task", "repository", "resolve", localTaskID, "--repo", fixture.custom.path], expectedStatus: 3)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "not_found")

        let remote = runDirectory.appendingPathComponent("default-branch-from-origin.git", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path), "Each UI case should use a fresh owned bare remote.")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try runGit(remote, "init", "--bare")
        try runGit(fixture.primary, "remote", "add", "origin", remote.path)
        addTeardownBlock { [self] in try? runGit(fixture.primary, "remote", "remove", "origin") }
        try runGit(fixture.primary, "push", "--quiet", "origin", "main")
        let staleTracking = try runGitOutput(fixture.primary, "rev-parse", "refs/remotes/origin/main").trimmingCharacters(in: .whitespacesAndNewlines)

        let title = "Default branch-from from origin"
        let created = try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        // Publishing on Review would set the branch's upstream itself and hide a tracked base.
        try setPullRequestMode("manual", taskID: taskID)
        let pending = try XCTUnwrap(repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(pending["isPending"] as? Bool, true)
        XCTAssertEqual(pending["branchFrom"] as? String, "")
        showBranchFrom(taskTitle: title, expected: "origin/main", screenshot: "With an origin the default branch-from is origin's branch")
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "origin/main"))

        // Origin moves ahead without this repository fetching, and local main gains an unpushed commit.
        let clone = runDirectory.appendingPathComponent("default-branch-from-clone", isDirectory: true)
        _ = try runGitOutput(runDirectory, "clone", "--quiet", "--branch", "main", remote.path, clone.path)
        try "Landed on origin after the task was created.\n".write(to: clone.appendingPathComponent("origin-only.txt"), atomically: true, encoding: .utf8)
        try runGit(clone, "add", "origin-only.txt")
        try runGit(clone, "commit", "-m", "Origin-only commit")
        try runGit(clone, "push", "--quiet", "origin", "main")
        let originHead = try runGitOutput(clone, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try "Unpushed local commit.\n".write(to: fixture.primary.appendingPathComponent("local-only.txt"), atomically: true, encoding: .utf8)
        try runGit(fixture.primary, "add", "local-only.txt")
        try runGit(fixture.primary, "commit", "-m", "Local-only commit")
        let localHead = try runGitOutput(fixture.primary, "rev-parse", "main").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            try runGitOutput(fixture.primary, "rev-parse", "refs/remotes/origin/main").trimmingCharacters(in: .whitespacesAndNewlines),
            staleTracking
        )

        try completeCurrentTaskWithFixtureAnswers(taskTitle: title)
        let started = try XCTUnwrap(repositoryRecord(taskID: taskID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(started["isPending"] as? Bool, false)
        XCTAssertEqual(started["branchFrom"] as? String, "origin/main")
        let worktree = URL(fileURLWithPath: try XCTUnwrap(started["worktreePath"] as? String), isDirectory: true)
        let taskBranch = try XCTUnwrap(started["branch"] as? String)
        XCTAssertEqual(try runGitOutput(worktree, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), originHead)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("origin-only.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: worktree.appendingPathComponent("local-only.txt").path),
            "The local-only commit must not be the task's base."
        )
        XCTAssertEqual(
            try runGitOutput(fixture.primary, "rev-parse", "refs/remotes/origin/main").trimmingCharacters(in: .whitespacesAndNewlines),
            originHead
        )
        XCTAssertEqual(
            try runGitOutput(fixture.primary, "rev-parse", "main").trimmingCharacters(in: .whitespacesAndNewlines),
            localHead,
            "Starting must not move local main."
        )
        let upstream = try runGitOutput(worktree, "config", "--default", "", "--get", "branch.\(taskBranch).remote")
        XCTAssertEqual(upstream.trimmingCharacters(in: .whitespacesAndNewlines), "", "The origin base must not become the task branch's upstream.")
        attachScreenshot(named: "Task started from origin's latest commit")

        let offlineTitle = "Default branch-from while offline"
        let offline = try runCLI([
            "task", "create", "--title", offlineTitle, "--prompt", "Fixture task description.", "--repo", fixture.primary.path,
        ])["result"] as? [String: Any]
        let offlineID = try XCTUnwrap(offline?["id"] as? String)
        try setPullRequestMode("manual", taskID: offlineID)
        // Never opened, so the first send works the default out as the task starts.
        XCTAssertEqual(try repositoryRecord(taskID: offlineID, repositoryPath: fixture.primary.path)?["branchFrom"] as? String, "")
        try runGit(fixture.primary, "remote", "set-url", "origin", runDirectory.appendingPathComponent("unreachable-origin.git").path)
        openTask(named: offlineTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: offlineTitle)
        let offlineStarted = try XCTUnwrap(repositoryRecord(taskID: offlineID, repositoryPath: fixture.primary.path))
        XCTAssertEqual(offlineStarted["isPending"] as? Bool, false)
        XCTAssertEqual(offlineStarted["branchFrom"] as? String, "origin/main")
        let offlineWorktree = URL(fileURLWithPath: try XCTUnwrap(offlineStarted["worktreePath"] as? String), isDirectory: true)
        XCTAssertEqual(try runGitOutput(offlineWorktree, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines), originHead)
        attachScreenshot(named: "Offline start uses the last fetched origin commit")
    }
    // case-contract: test_task_repository_edit_rejects_stale_validation_after_removal | If a pending repository is removed while its settings are being validated, the stale edit is rejected and the newer repository removal and context root remain saved.
    func test_task_repository_edit_rejects_stale_validation_after_removal() throws {
        // The window validates the edit with real Git; the staged wrapper parks that call
        // for this repository so the CLI removal can land first.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: try makeGitHoldEnvironment())
        let title = "Concurrent repository edit"
        let created = try runCLI([
            "task", "create", "--title", title, "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path,
            "--root", fixture.custom.path,
        ])["result"] as? [String: Any]
        let taskID = try XCTUnwrap(created?["id"] as? String)
        openTask(named: title)
        let badge = element("conversation-repository-badge-primary")
        XCTAssertTrue(badge.waitToExist(timeout: 5))
        badge.click()
        // Opening the settings works the defaults out with Git; let that finish so the
        // barrier below holds the save's own Git call.
        XCTAssertTrue(waitForRepositoryValue(taskID: taskID, repositoryPath: fixture.primary.path, key: "branchFrom", expected: "main"))
        element("conversation-repository-branch-edit").click()
        replaceText(element("conversation-repository-branch"), with: "stale-ui-edit")

        let barrier = try GitHoldBarrier(repositoryURL: fixture.primary)
        element("conversation-repository-branch-save").click()
        var barrierReleased = false
        defer {
            if !barrierReleased { try? barrier.release() }
        }
        try barrier.waitForHeldCall()
        let removed = try runCLI(["task", "repository", "remove", taskID, "--repo", fixture.primary.path])
        let removedTask = try XCTUnwrap(removed["result"] as? [String: Any])
        XCTAssertEqual((removedTask["repositoryWorktrees"] as? [Any])?.count, 0)
        XCTAssertEqual(removedTask["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(removedTask["contextFolders"] as? [String], [fixture.custom.path])

        try barrier.release()
        barrierReleased = true
        let error = element("codex-chat-error")
        XCTAssertTrue(error.waitToExist(timeout: 10), "The stale repository edit should be reported in the conversation.")
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("settings changed"), error.label)
        let fresh = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual((fresh["repositoryWorktrees"] as? [Any])?.count, 0)
        XCTAssertEqual(fresh["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(fresh["contextFolders"] as? [String], [fixture.custom.path])
        attachScreenshot(named: "Concurrent repository removal rejects a stale settings save")
    }
    // case-contract: test_task_repository_removal_preserves_state_on_dirty_worktree | Removing one of two pending repositories leaves the remaining repository in task context and remembered settings, while preserving the removed source repository; the next task restores only the remaining remembered repository. Removing a pending repository preserves other context folders; removing a clean managed worktree through the GUI waits for an active turn, while the task repository API removes it from context immediately and defers clean worktree deletion until the turn releases; a bridge service restart preserves the cleanup intent and a fresh request completes removal; if the active turn writes files before release, deferred cleanup preserves that worktree and its changes; a dirty worktree rejects removal and preserves its task record and files.
    func test_task_repository_removal_preserves_state_on_dirty_worktree() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)

        let soleTitle = "Two repository removal through UI"
        let sole = try runCLI(["task", "create", "--title", soleTitle, "--prompt", "Fixture task description.", "--repo", fixture.primary.path, "--repo", fixture.secondary.path])["result"] as? [String: Any]
        let soleID = try XCTUnwrap(sole?["id"] as? String)
        openTask(named: soleTitle)
        element("remove-conversation-repository-primary").click()
        XCTAssertTrue(waitUntil({
            guard let result = try? self.taskRecord(id: soleID),
                  let records = result["repositoryWorktrees"] as? [[String: Any]] else { return false }
            return records.count == 1 && records[0]["repositoryPath"] as? String == self.fixture.secondary.path
        }, timeout: 10), "Removing one pending repository should preserve the other attachment.")
        XCTAssertEqual(try taskRecord(id: soleID)?["workspaceRoots"] as? [String], [fixture.secondary.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.primary.path))
        assertLastSelectedRepositories([fixture.secondary.path])

        element("back-to-board-button").click()
        element("new-task-button").click()
        let restoredTitle = element("empty-conversation-repository-title")
        XCTAssertTrue(restoredTitle.waitToExist(timeout: 5), "A new task should restore the remaining remembered repository.")
        // The remembered selection loads after the empty conversation first renders.
        XCTAssertTrue(waitUntil({ self.accessibleLabelOrValue(of: restoredTitle) == "secondary" }, timeout: 5),
                      "A new task should restore the remaining remembered repository, not \(accessibleLabelOrValue(of: restoredTitle)).")
        // The title names the saved repositories while they are still being attached, so the
        // header's chip, which shows once one is attached, can follow it a moment later.
        XCTAssertTrue(element("conversation-repository-badge-secondary").waitToExist(timeout: 5), "The new task attaches the remaining remembered repository.")
        XCTAssertFalse(element("conversation-repository-badge-primary").exists)
        attachScreenshot(named: "New task restores only the repository that remains selected")

        element("back-to-board-button").click()
        let pendingTitle = "Pending repository removal through UI"
        let pending = try runCLI([
            "task", "create", "--title", pendingTitle, "--prompt", "Fixture task description.",
            "--repo", fixture.primary.path,
            "--root", fixture.custom.path,
        ])["result"] as? [String: Any]
        let pendingID = try XCTUnwrap(pending?["id"] as? String)
        openTask(named: pendingTitle)
        element("remove-conversation-repository-primary").click()
        XCTAssertTrue(waitUntil({
            guard let result = try? self.taskRecord(id: pendingID),
                  let records = result["repositoryWorktrees"] as? [[String: Any]] else { return false }
            return records.isEmpty
        }, timeout: 10), "Removing a pending repository should update the persisted task.")
        let pendingAfterRemoval = try XCTUnwrap(taskRecord(id: pendingID))
        XCTAssertEqual(pendingAfterRemoval["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(pendingAfterRemoval["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.primary.path), "The source repository must remain on disk.")

        element("back-to-board-button").click()
        let cleanTitle = "Clean active repository removal through API"
        let cleanActive = try runCLI([
            "task", "create", "--title", cleanTitle, "--prompt", "Fixture task description.",
            "--repo", fixture.alternate.path,
            "--root", fixture.custom.path,
        ])["result"] as? [String: Any]
        let cleanActiveID = try XCTUnwrap(cleanActive?["id"] as? String)
        openTask(named: cleanTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: cleanTitle)
        let cleanRecord = try XCTUnwrap(repositoryRecord(taskID: cleanActiveID, repositoryPath: fixture.alternate.path))
        let cleanWorktreePath = try XCTUnwrap(cleanRecord["worktreePath"] as? String)
        let cleanReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: cleanActiveID)
        var cleanReservationReleased = false
        defer {
            if !cleanReservationReleased { try? cleanReservation.release() }
        }
        _ = try runCLI(["task", "repository", "remove", cleanActiveID, "--repo", fixture.alternate.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanWorktreePath))
        let cleanupScheduled = try XCTUnwrap(diagnosticEvents().first {
            $0["event"] as? String == "workspace.repository.deferred_removal_scheduled"
                && $0["taskID"] as? String == cleanActiveID
        })
        let bridgePIDText = try XCTUnwrap(cleanupScheduled["processID"] as? String)
        let bridgePID = pid_t(try XCTUnwrap(Int32(bridgePIDText)))
        if kill(bridgePID, SIGKILL) != 0 {
            XCTAssertEqual(errno, ESRCH, "The bridge service should either be killed here or already have exited.")
        }
        XCTAssertTrue(waitUntil({ kill(bridgePID, 0) != 0 && errno == ESRCH }, timeout: 5), "The isolated bridge service should exit before recovery is tested.")
        try cleanReservation.release()
        cleanReservationReleased = true
        _ = try taskRecord(id: cleanActiveID)
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: cleanWorktreePath) }, timeout: 10),
                      "Deferred cleanup should remove an unchanged managed worktree after the turn releases.")

        element("back-to-board-button").click()
        let activeTitle = "Started repository removal through UI"
        let active = try runCLI([
            "task", "create", "--title", activeTitle, "--prompt", "Fixture task description.",
            "--repo", fixture.secondary.path,
            "--root", fixture.custom.path,
        ])["result"] as? [String: Any]
        let activeID = try XCTUnwrap(active?["id"] as? String)
        openTask(named: activeTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: activeTitle)
        let activeRecord = try XCTUnwrap(repositoryRecord(taskID: activeID, repositoryPath: fixture.secondary.path))
        let worktreePath = try XCTUnwrap(activeRecord["worktreePath"] as? String)
        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let dirtyFile = worktreeURL.appendingPathComponent("repository-removal-dirty.txt")
        try Data("keep this worktree intact\n".utf8).write(to: dirtyFile)

        let removeButton = element("remove-conversation-repository-secondary")
        removeButton.click()
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 10), "Dirty worktree removal should report an error in the conversation.")
        XCTAssertTrue(element("codex-chat-error").label.contains("uncommitted changes"))
        XCTAssertEqual(try repositoryRecord(taskID: activeID, repositoryPath: fixture.secondary.path)?["worktreePath"] as? String, worktreePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyFile.path))

        try FileManager.default.removeItem(at: dirtyFile)
        XCTAssertTrue(removeButton.waitToExist(timeout: 5), "The repository can be removed after its worktree is clean.")
        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: activeID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        removeButton.click()
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertNil(
            try repositoryRecord(taskID: activeID, repositoryPath: fixture.secondary.path),
            "Active-conversation removal should detach the repository immediately while deferring worktree cleanup."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath))
        let inFlightURL = worktreeURL.appendingPathComponent("written-during-removal.txt")
        try Data("preserve edits made before the turn ended\n".utf8).write(to: inFlightURL)
        try conversationReservation.release()
        conversationReservationReleased = true
        XCTAssertTrue(waitUntil({
            guard let result = try? self.taskRecord(id: activeID),
                  let records = result["repositoryWorktrees"] as? [[String: Any]] else { return false }
            return records.isEmpty
        }, timeout: 10), "Repository removal should update the persisted task.")
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "workspace.repository.deferred_removal_kept_dirty"
                    && $0["taskID"] as? String == activeID
            }) ?? false
        }, timeout: 10), "Deferred cleanup should report that active-turn edits were preserved.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inFlightURL.path), "Deferred cleanup must preserve active-turn edits.")
        let activeAfterRemoval = try XCTUnwrap(taskRecord(id: activeID))
        XCTAssertEqual(activeAfterRemoval["workspaceRoots"] as? [String], [fixture.custom.path])
        XCTAssertEqual(activeAfterRemoval["contextFolders"] as? [String], [fixture.custom.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreePath), "Deferred cleanup must preserve the worktree containing active-turn edits.")

        element("back-to-board-button").click()
        let apiTitle = "Active API repository removal through UI"
        let apiTask = try runCLI(["task", "create", "--title", apiTitle, "--prompt", "Fixture task description.", "--repo", fixture.primary.path])["result"] as? [String: Any]
        let apiTaskID = try XCTUnwrap(apiTask?["id"] as? String)
        openTask(named: apiTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: apiTitle)
        let apiRecord = try XCTUnwrap(repositoryRecord(taskID: apiTaskID, repositoryPath: fixture.primary.path))
        let apiWorktreePath = try XCTUnwrap(apiRecord["worktreePath"] as? String)
        let apiReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: apiTaskID)
        var apiReservationReleased = false
        defer {
            if !apiReservationReleased { try? apiReservation.release() }
        }
        let removed = try runCLI(["task", "repository", "remove", apiTaskID, "--repo", fixture.primary.path])["result"] as? [String: Any]
        XCTAssertEqual((removed?["repositoryWorktrees"] as? [Any])?.count, 0)
        XCTAssertFalse(element("conversation-repository-badge-primary").exists, "API removal should immediately update the visible repository badges.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: apiWorktreePath), "The active turn worktree must remain until its reservation releases.")
        try apiReservation.release()
        apiReservationReleased = true
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: apiWorktreePath) }, timeout: 10), "API removal should clean up the worktree after the active reservation releases.")
    }
    // case-contract: test_task_delete_removes_task_and_later_lookup_is_not_found | The task context menu offers deletion. Pending repository tasks delete without confirmation and preserve the source repository; confirmed deletion removes the card from the board at once and waits briefly for a conversation-turn reservation another process holds; when that reservation stays held past the stop timeout the delete fails with a clear error and the task and its card come back, and with no turn to stop a task lock another process keeps holding fails the delete the same way after the lock timeout, recording the lock it waited for; clean started worktrees can be deleted; dirty started worktrees require confirmation, and canceling preserves the task and worktree. CLI delete-check derives and reports the confirmation requirement from saved task and worktree state without resuming the Codex thread; confirmed deletion removes the managed worktree. Deleting a task also removes its per-task preferences and any left by already-deleted tasks, while another task's preferences remain.
    func test_task_delete_removes_task_and_later_lookup_is_not_found() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        // Left by a task deleted before per-task preference cleanup existed.
        let orphanedPreference = "playhouse.codex.goal-generation.\(UUID().uuidString)"
        try PropertyListSerialization.data(fromPropertyList: [orphanedPreference: "plan"], format: .binary, options: 0)
            .write(to: isolatedPreferencesFile)
        // The started task's reads look up its branch's pull request; keep that on the gh fixture.
        launchApp(defaultParent: fixture.parent.path, environmentOverrides: try makeGitHubStateFixture(expectedNumbers: []))

        let pendingTitle = "Pending delete"
        _ = try runCLI(["task", "create", "--title", pendingTitle, "--prompt", "Pending delete description.", "--repo", fixture.secondary.path])
        let pendingTask = try XCTUnwrap(taskRecord(named: pendingTitle))
        let pendingID = try XCTUnwrap(pendingTask["id"] as? String)
        let pendingRecord = try XCTUnwrap((pendingTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        XCTAssertEqual(pendingRecord["isPending"] as? Bool, true)
        XCTAssertEqual(pendingRecord["worktreePath"] as? String, fixture.secondary.path)
        let promptedCheck = try runCLI(["task", "delete-check", pendingID])
        XCTAssertEqual((promptedCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, true, "A task with a saved prompt holds user content, so deleting it must confirm.")
        _ = try runCLI(["task", "prompt", pendingID, "--text", ""])
        let pendingCheck = try runCLI(["task", "delete-check", pendingID])
        XCTAssertEqual((pendingCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, false)
        let keptTitle = "Kept preferences"
        try createTaskFixture(title: keptTitle, roots: [fixture.custom.path])
        let keptID = try taskID(named: keptTitle)
        let pendingPreference = "conversationMode.\(pendingID.uppercased())"
        let keptPreference = "conversationMode.\(keptID.uppercased())"
        for title in [pendingTitle, keptTitle] {
            openTask(named: title)
            setPlanMode(true)
            element("back-to-board-button").click()
        }
        XCTAssertTrue(waitUntil({
            self.isolatedPreferenceKeys().isSuperset(of: [pendingPreference, keptPreference, orphanedPreference])
        }, timeout: 10), "Choosing a conversation mode should save it in the isolated preferences.")
        deleteTaskFromContextMenu(pendingTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitToExist(timeout: 5))
        let conversationReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: pendingID)
        var conversationReservationReleased = false
        defer {
            if !conversationReservationReleased { try? conversationReservation.release() }
        }
        element("confirm-delete-task-button").click()
        XCTAssertTrue(waitUntil({ !self.app.buttons[pendingTitle].exists }, timeout: 2), "The card should leave the board as soon as the delete is confirmed.")
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(try taskRecord(id: pendingID)?["id"] as? String, pendingID)
        attachAppWindowScreenshot(named: "Deleted card leaves the board while its delete waits")
        try conversationReservation.release()
        conversationReservationReleased = true
        var pendingDeleteEvent: [String: Any]?
        XCTAssertTrue(waitUntil({
            guard let events = try? self.diagnosticEvents() else { return false }
            pendingDeleteEvent = events.first {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == pendingID
            }
            return pendingDeleteEvent != nil
        }, timeout: 5), "Deleting a task through the visible menu should leave a persistent diagnostic event.")
        let pendingDeleteEventValue = try XCTUnwrap(pendingDeleteEvent)
        XCTAssertEqual(pendingDeleteEventValue["taskStatus"] as? String, "Backlog")
        XCTAssertNotNil(pendingDeleteEventValue["processID"] as? String)
        XCTAssertNotNil(pendingDeleteEventValue["storePath"] as? String)
        assertCLIError(try runCLI(["task", "get", pendingID], expectedStatus: 3), code: "not_found")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.secondary.path), "Deleting a pending task must preserve its source repository.")
        XCTAssertTrue(waitUntil({
            let keys = self.isolatedPreferenceKeys()
            return !keys.contains(pendingPreference) && !keys.contains(orphanedPreference)
        }, timeout: 10), "Deleting a task must remove its preferences and those left by already-deleted tasks.")
        XCTAssertTrue(isolatedPreferenceKeys().contains(keptPreference), "Another task's preferences must survive a delete.")
        // A reservation another process keeps holding fails the delete after the stop timeout
        // with a visible error, and the card comes back.
        let heldReservation = try ConversationTurnLockBarrier(dataDirectory: dataDirectory, taskID: keptID)
        var heldReservationReleased = false
        defer { if !heldReservationReleased { try? heldReservation.release() } }
        deleteTaskFromContextMenu(keptTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitToExist(timeout: 5))
        element("confirm-delete-task-button").click()
        XCTAssertTrue(waitUntil({ !self.app.buttons[keptTitle].exists }, timeout: 2), "The card should leave the board while its delete runs.")
        let deleteError = element("dismiss-delete-error-button")
        XCTAssertTrue(deleteError.waitToExist(timeout: 25), "A delete that can't stop the turn should fail visibly instead of hanging.")
        XCTAssertTrue(element(containingAccessibilityText: "wasn't deleted").exists, app.debugDescription)
        attachAppWindowScreenshot(named: "Delete that couldn't stop the turn reports an error")
        deleteError.click()
        XCTAssertTrue(app.buttons[keptTitle].waitToExist(timeout: 5), "The card comes back when its delete fails.")
        attachAppWindowScreenshot(named: "Card back on the board after its delete failed")
        XCTAssertEqual(try taskRecord(id: keptID)?["id"] as? String, keptID)
        try heldReservation.release()
        heldReservationReleased = true
        // With no turn to stop, a task lock another process keeps holding fails the delete after
        // the lock timeout, again with a visible error and the card back.
        let heldOperation = try TaskOperationLockBarrier(dataDirectory: dataDirectory, taskID: keptID)
        var heldOperationReleased = false
        defer { if !heldOperationReleased { try? heldOperation.release() } }
        deleteTaskFromContextMenu(keptTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitToExist(timeout: 5))
        element("confirm-delete-task-button").click()
        XCTAssertTrue(waitUntil({ !self.app.buttons[keptTitle].exists }, timeout: 2), "The card should leave the board while its delete runs.")
        let lockError = element("dismiss-delete-error-button")
        XCTAssertTrue(lockError.waitToExist(timeout: 25), "A delete that times out on a task lock should fail visibly instead of hanging.")
        XCTAssertTrue(element(containingAccessibilityText: "didn't finish within").exists, app.debugDescription)
        lockError.click()
        XCTAssertTrue(app.buttons[keptTitle].waitToExist(timeout: 5), "The card comes back when its delete times out.")
        XCTAssertTrue(try diagnosticEvents().contains {
            $0["event"] as? String == "task.delete.failed" && $0["taskID"] as? String == keptID
                && $0["phase"] as? String == "lock-wait" && $0["lock"] as? String == "task-operation"
        }, "A delete that timed out on a lock is recorded with the lock it waited for.")
        try heldOperation.release()
        heldOperationReleased = true
        XCTAssertEqual((try runCLI(["task", "delete", keptID])["result"] as? [String: Any])?["deleted"] as? Bool, true)
        XCTAssertTrue(waitUntil({ !self.isolatedPreferenceKeys().contains(keptPreference) }, timeout: 10))

        let cleanTitle = "Clean delete \(String(UUID().uuidString.prefix(8)).lowercased())"
        _ = try runCLI(["task", "create", "--title", cleanTitle, "--prompt", "Fixture task description.", "--repo", fixture.primary.path])
        openTask(named: cleanTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: cleanTitle)
        element("back-to-board-button").click()
        let cleanTask = try XCTUnwrap(taskRecord(named: cleanTitle))
        let cleanID = try XCTUnwrap(cleanTask["id"] as? String)
        let cleanRecord = try XCTUnwrap((cleanTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        let cleanPath = try XCTUnwrap(cleanRecord["worktreePath"] as? String)
        XCTAssertEqual(cleanRecord["isPending"] as? Bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleanPath))
        XCTAssertEqual(try runGitOutput(URL(fileURLWithPath: cleanPath), "status", "--porcelain").trimmingCharacters(in: .whitespacesAndNewlines), "")
        let cleanThreadID = try XCTUnwrap(cleanTask["codexThreadID"] as? String)
        let resumeEventsBeforeDeleteCheck = try diagnosticEvents().filter {
            $0["event"] as? String == "codex.thread.resume_started" && $0["threadID"] as? String == cleanThreadID
        }.count
        let cleanCheck = try runCLI(["task", "delete-check", cleanID])
        XCTAssertEqual((cleanCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, true)
        let resumeEventsAfterDeleteCheck = try diagnosticEvents().filter {
            $0["event"] as? String == "codex.thread.resume_started" && $0["threadID"] as? String == cleanThreadID
        }.count
        XCTAssertEqual(resumeEventsAfterDeleteCheck, resumeEventsBeforeDeleteCheck, "Delete-check must not resume a conversation thread already owned by the app.")
        deleteTaskFromContextMenu(cleanTitle)
        let cleanConfirmation = element("confirm-delete-task-button")
        XCTAssertTrue(cleanConfirmation.waitToExist(timeout: 5))
        cleanConfirmation.click()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == cleanID
            }) ?? false
        }, timeout: 20), "The app should finish the confirmed delete and record success before the worktree check.")
        assertCLIError(try runCLI(["task", "get", cleanID], expectedStatus: 3), code: "not_found")
        XCTAssertTrue(waitUntil({ !FileManager.default.fileExists(atPath: cleanPath) }, timeout: 10), "Deleting a clean started task must remove its managed worktree before the task record disappears.")

        let dirtyTitle = "Dirty delete \(String(UUID().uuidString.prefix(8)).lowercased())"
        _ = try runCLI(["task", "create", "--title", dirtyTitle, "--prompt", "Fixture task description.", "--repo", fixture.primary.path])
        let dirtyID = try taskID(named: dirtyTitle)
        openTask(named: dirtyTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: dirtyTitle, prompt: "Prepare a task for deletion.")
        XCTAssertEqual(try taskRecord(id: dirtyID)?["status"] as? String, "Review")
        element("back-to-board-button").click()
        let dirtyTask = try XCTUnwrap(taskRecord(id: dirtyID))
        let dirtyRecord = try XCTUnwrap((dirtyTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        let dirtyPath = try XCTUnwrap(dirtyRecord["worktreePath"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath))
        try "unsaved work\n".write(to: URL(fileURLWithPath: dirtyPath).appendingPathComponent("trash-test.txt"), atomically: true, encoding: .utf8)
        let dirtyCheck = try runCLI(["task", "delete-check", dirtyID])
        XCTAssertEqual((dirtyCheck["result"] as? [String: Any])?["requiresConfirmation"] as? Bool, true)

        deleteTaskFromContextMenu(dirtyTitle)
        let cancel = element("cancel-delete-task-button")
        XCTAssertTrue(cancel.waitToExist(timeout: 5), "Dirty work dropped on trash must require confirmation.")
        cancel.click()
        XCTAssertTrue(app.buttons[dirtyTitle].exists, "Canceling deletion must preserve the task.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirtyPath), "Canceling deletion must preserve the worktree.")

        deleteTaskFromContextMenu(dirtyTitle)
        let confirmation = element("confirm-delete-task-button")
        XCTAssertTrue(confirmation.waitToExist(timeout: 5))
        confirmation.click()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == dirtyID
            }) ?? false
        }, timeout: 20), "The app should finish the confirmed delete and record success before the worktree check.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirtyPath), "Confirmed deletion must remove the dirty managed worktree.")
        assertCLIError(try runCLI(["task", "get", dirtyID], expectedStatus: 3), code: "not_found")
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        attachScreenshot(named: "Deleted task removed from the board")
    }
    // case-contract: test_claude_delete_stops_live_turn_immediately | Deleting a task whose Claude turn waits on an AskUserQuestion, and one whose Claude turn is running and ignores its interrupt, removes the task within seconds instead of waiting for the agent: the delete declines the pending question, which ends that turn without force, asks Claude to interrupt a running turn, and force-stops the Claude Code process when the turn hasn't ended within the interrupt timeout, and records task.delete.stopping_turn, task.delete.turn_force_killed and task.delete.turn_stopped. Afterwards the Claude process is gone, the turn reservation is free, the task's worktree is removed, the daemon no longer reports the turn live, the stopped send ends, and no transcript rows come back. A follow-up queued behind the running turn is removed with the task and never runs, and a send waiting for that turn fails with task_deleting instead of starting a turn. A second delete sent while the first runs shares its result and a later one reports not found. In the window the card leaves the board as soon as the delete is confirmed, and no error appears.
    func test_claude_delete_stops_live_turn_immediately() throws {
        try exerciseDeleteDuringLiveTurns(provider: "claude")
    }
    // case-contract: test_codex_delete_stops_live_turn_immediately | Deleting a task whose Codex turn waits on a blocking question, and one whose Codex turn is running and ignores its turn/interrupt, removes the task within seconds instead of waiting for the agent: the delete declines the pending question, which ends that turn without force, asks Codex to interrupt a running turn, and, when the turn hasn't ended within the interrupt timeout, fails the turn in Playhouse without waiting for the shared app-server, and records task.delete.stopping_turn, task.delete.turn_force_killed and task.delete.turn_stopped. Afterwards the turn reservation is free, the task's worktree is removed, the daemon no longer reports the turn live, the stopped send ends, and no transcript rows come back, even after the app-server ends the stopped turn. A follow-up queued behind the running turn is removed with the task and never runs, and a send waiting for that turn fails with task_deleting instead of starting a turn. A second delete sent while the first runs shares its result and a later one reports not found. In the window the card leaves the board as soon as the delete is confirmed, and no error appears.
    func test_codex_delete_stops_live_turn_immediately() throws {
        try exerciseDeleteDuringLiveTurns(provider: "codex")
    }
    // case-contract: test_task_delete_reports_real_worktree_failure_and_allows_retry | A real worktree-removal failure records the task title and task, thread, process, phase, and underlying error details, including bounded NSError user-info keys and values, without recording conversation text; the failed task and worktree remain available and deletion succeeds after the repository is restored.
    func test_task_delete_reports_real_worktree_failure_and_allows_retry() throws {
        codexFixtureExecutable = try makeCodexFixture(emptyQuestions: false).path
        launchApp(defaultParent: fixture.parent.path)

        let brokenRepository = dataDirectory.appendingPathComponent("delete-failure-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenRepository, withIntermediateDirectories: true)
        try runGit(brokenRepository, "init", "--initial-branch=main")
        try runGit(brokenRepository, "config", "user.name", "Playhouse UI Test")
        try runGit(brokenRepository, "config", "user.email", "playhouse-ui-test@example.invalid")
        try "owned diagnostic fixture\n".write(
            to: brokenRepository.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try runGit(brokenRepository, "add", "README.md")
        try runGit(brokenRepository, "commit", "-m", "Baseline")
        let failureTitle = "PRIVATE_DELETE_TITLE_\(String(UUID().uuidString.prefix(8)))"
        let failurePrompt = "PRIVATE_CONVERSATION_TEXT_\(String(UUID().uuidString.prefix(8)))"
        _ = try runCLI(["task", "create", "--title", failureTitle, "--prompt", "Fixture task description.", "--repo", brokenRepository.path])
        openTask(named: failureTitle)
        try completeCurrentTaskWithFixtureAnswers(taskTitle: failureTitle, prompt: failurePrompt)
        element("back-to-board-button").click()
        let failureTask = try XCTUnwrap(taskRecord(named: failureTitle))
        let failureID = try XCTUnwrap(failureTask["id"] as? String)
        let failureRecord = try XCTUnwrap((failureTask["repositoryWorktrees"] as? [[String: Any]])?.first)
        let failureWorktree = try XCTUnwrap(failureRecord["worktreePath"] as? String)
        let movedRepository = dataDirectory.appendingPathComponent("delete-failure-repository-restored-after-error", isDirectory: true)
        try FileManager.default.moveItem(at: brokenRepository, to: movedRepository)
        deleteTaskFromContextMenu(failureTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitToExist(timeout: 5))
        element("confirm-delete-task-button").click()
        let saveErrorAlert = app.sheets.firstMatch
        XCTAssertTrue(saveErrorAlert.waitToExist(timeout: 10), "A worktree-removal failure should be visible to the user.")
        XCTAssertTrue(element(containingAccessibilityText: "Diagnostics.jsonl").waitToExist(timeout: 5), app.debugDescription)
        let failureLog = try String(contentsOf: dataDirectory.appendingPathComponent("Diagnostics.jsonl"), encoding: .utf8)
        let failureEvents = try failureLog.split(whereSeparator: \.isNewline).compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let failedDelete = try XCTUnwrap(failureEvents.first {
            $0["event"] as? String == "task.delete.failed" && $0["taskID"] as? String == failureID
        })
        XCTAssertEqual(failedDelete["phase"] as? String, "worktree-removal")
        XCTAssertEqual(failedDelete["taskStatus"] as? String, "Review")
        XCTAssertTrue((failedDelete["threadID"] as? String)?.isEmpty == false)
        XCTAssertNotNil(failedDelete["clientPID"] as? String)
        XCTAssertNotNil(failedDelete["codexPID"] as? String)
        XCTAssertNotNil(failedDelete["error0Domain"] as? String)
        XCTAssertNotNil(failedDelete["error0Code"] as? String)
        XCTAssertNotNil(failedDelete["error0UserInfoKeys"] as? String)
        XCTAssertNotNil(failedDelete["error0UserInfoKeyCount"] as? String)
        XCTAssertNotNil(failedDelete["error0UserInfo"] as? String)
        XCTAssertTrue(failureLog.contains(failureTitle), "Diagnostics should record the task title to help identify the affected task.")
        XCTAssertFalse(failureLog.contains(failurePrompt), "Diagnostics must not record conversation text.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: failureWorktree), "A failed deletion must preserve the worktree for retry.")
        XCTAssertEqual(try taskRecord(id: failureID)?["id"] as? String, failureID, "A failed deletion must preserve the task for retry.")
        saveErrorAlert.buttons["OK"].click()
        try FileManager.default.moveItem(at: movedRepository, to: brokenRepository)
        deleteTaskFromContextMenu(failureTitle)
        XCTAssertTrue(element("confirm-delete-task-button").waitToExist(timeout: 5))
        element("confirm-delete-task-button").click()
        XCTAssertTrue(waitUntil({
            (try? self.diagnosticEvents().contains {
                $0["event"] as? String == "task.delete.succeeded" && $0["taskID"] as? String == failureID
            }) ?? false
        }, timeout: 20), "Restoring the repository should allow the retry to complete and record success.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureWorktree), "Restoring the repository should allow deletion to be retried.")
        assertCLIError(try runCLI(["task", "get", failureID], expectedStatus: 3), code: "not_found")
        XCTAssertEqual(try tasksFromBoardList().count, 0)
        attachScreenshot(named: "Failed task deletion can be retried after repository recovery")
    }
    // case-contract: test_default_parent_settings_read_write_clear_and_validation | The default parent can be read, changed, cleared, and an unavailable path is rejected; a fresh CLI read and repository discovery use the persisted parent. Dark and Light appearance choices persist, the removed PR conflict preference is absent from CLI/XPC and Settings, and appearance changes update the open Settings picker. Clearing the default parent does not change roots already saved on a task. Before any root is set, opening the Add repository picker from the empty state's + still leaves Set root folder able to bring its folder panel to the front, every time it is clicked.
    func test_default_parent_settings_read_write_clear_and_validation() throws {
        launchApp(defaultParent: nil)
        let initialSettings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(initialSettings?["defaultParentFolder"] as? String)
        openNewTaskConversation()
        XCTAssertEqual(try tasksFromBoardList().count, 1, "New Task should create its pending conversation before folder discovery.")
        XCTAssertTrue(element("repository-root-required-notice").exists)
        XCTAssertFalse(element("send-message-button").isEnabled)
        // Opening the picker from the empty state's + first must not leave the root button unable
        // to show its folder panel.
        element("empty-conversation-add-repository-button").click()
        XCTAssertTrue(element("conversation-repository-search").waitToExist(timeout: 5))
        attachScreenshot(named: "Empty state + opens the picker before a root is set")
        element("set-conversation-repository-root-button").click()
        let firstRunPanel = openFolderPanel
        XCTAssertTrue(firstRunPanel.waitToExist(timeout: 10), "Set root folder should open its panel even after the empty state's + opened the picker.")
        attachScreenshot(named: "Set root folder opens its panel after the picker was open")
        XCTAssertTrue(firstRunPanel.buttons["Cancel"].isHittable, "The root folder panel should be in front, not hidden behind the conversation window.")
        // A click on the conversation window brings it over the panel, which must not leave the
        // root button doing nothing: clicking it again brings the same panel back to the front.
        element("message-composer").click()
        XCTAssertTrue(waitUntil({ !self.openFolderPanel.buttons["Cancel"].isHittable }, timeout: 5), "The conversation window should come in front of the panel.")
        element("set-conversation-repository-root-button").click()
        XCTAssertTrue(waitUntil({ self.openFolderPanel.buttons["Cancel"].isHittable }, timeout: 5), "Set root folder should bring its covered panel back to the front.")
        XCTAssertEqual(app.windows.matching(identifier: "open-panel").count, 1, "Clicking again should reuse the open panel, not stack another.")
        firstRunPanel.buttons["Cancel"].click()
        XCTAssertTrue(waitUntil({ !self.openFolderPanel.exists }, timeout: 5))
        XCTAssertFalse(element("conversation-repository-search").exists, "Canceling root setup should leave the direct-created task and picker closed.")
        XCTAssertEqual(try tasksFromBoardList().count, 1)

        element("set-conversation-repository-root-button").click()
        try chooseFolder(in: openFolderPanel, folder: fixture.parent, confirmationButton: "Use This Folder")
        XCTAssertFalse(element("repository-root-required-notice").exists)
        XCTAssertFalse(element("conversation-repository-search").exists, "Setting the root should leave the repo picker closed.")
        element("add-conversation-repository-button").click()
        XCTAssertTrue(element("conversation-repository-suggestion-primary").waitToExist(timeout: 10), "Choosing a suggestion folder should populate the conversation picker.")
        let parentVisibleToBridge = waitUntil({
            guard let response = try? self.runCLI(["settings", "get"]),
                  let settings = response["result"] as? [String: Any] else { return false }
            return (settings["defaultParentFolder"] as? String) == self.fixture.parent.path
        }, timeout: 5)
        XCTAssertTrue(parentVisibleToBridge, "The selected parent folder should be visible through a fresh CLI/XPC read.")
        let changeSuggestionParent = element("choose-repository-suggestion-parent-button")
        XCTAssertTrue(changeSuggestionParent.waitToExist(timeout: 5), "The picker should keep a Change parent action available after a valid parent has been selected.")
        XCTAssertTrue(changeSuggestionParent.label.localizedCaseInsensitiveContains("Change"))
        changeSuggestionParent.click()
        try chooseFolder(in: openFolderPanel, folder: fixture.alternateParent, confirmationButton: "Use This Folder")
        // The alternate parent sits inside the first parent, so `alternate` is already listed before
        // the change; the refresh is settled only once the first parent's `primary` is gone.
        XCTAssertTrue(waitUntil({ !self.element("conversation-repository-suggestion-primary").exists }, timeout: 10), "Suggestions from the previous parent should be replaced.")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").exists, "Changing the parent should refresh the repository suggestions.")
        XCTAssertTrue(waitUntil({
            guard let response = try? self.runCLI(["settings", "get"]),
                  let settings = response["result"] as? [String: Any] else { return false }
            return (settings["defaultParentFolder"] as? String) == self.fixture.alternateParent.path
        }, timeout: 5), "The changed parent folder should be visible through a fresh CLI/XPC read.")
        element("back-to-board-button").click()
        XCTAssertTrue(element("board-title").waitToExist(timeout: 10))
        XCTAssertEqual(try tasksFromBoardList().count, 0, "Backing out should discard the empty pending conversation.")

        app.typeKey(",", modifierFlags: .command)
        let preferencesWindow = settingsWindow
        XCTAssertTrue(preferencesWindow.waitToExist(timeout: 10), "Workspace Settings did not open.")
        let appearancePicker = preferencesWindow.descendants(matching: .any)
            .matching(identifier: "appearance-picker").firstMatch
        XCTAssertTrue(appearancePicker.waitToExist(timeout: 5), "Workspace Settings should expose the Dark and Light theme choices.")
        XCTAssertFalse(preferencesWindow.descendants(matching: .any).matching(identifier: "pr-conflict-action-picker").firstMatch.exists, "Workspace Settings should no longer expose automatic PR conflict behavior.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        appearancePicker.click()
        let lightChoice = preferencesWindow.menuItems["Light"]
        if lightChoice.waitToExist(timeout: 2) {
            lightChoice.click()
        } else {
            preferencesWindow.buttons["Light"].click()
        }
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "light")
        _ = try runCLI(["settings", "set-appearance", "dark"])
        // The pop-up button reports its visible title ("Dark") as its value.
        XCTAssertTrue(waitUntil({ (appearancePicker.value as? String)?.lowercased() == "dark" }, timeout: 5), "An external CLI write should update the open appearance picker.")
        XCTAssertEqual((try runCLI(["settings", "get"])["result"] as? [String: Any])?["appearance"] as? String, "dark")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !preferencesWindow.exists }, timeout: 5), "Settings should close before checking the workspace canvas.")
        let workspaceCanvas = element("board-columns-scroll-view")
        XCTAssertTrue(workspaceCanvas.waitToExist(timeout: 5), "The board workspace should be visible.")
        assertPixel(workspaceCanvas.screenshot().image, normalizedX: 0.02, normalizedY: 0.5, rgb: (30, 30, 30), accuracy: 20)
        app.typeKey(",", modifierFlags: .command)
        let reopenedPreferences = settingsWindow
        XCTAssertTrue(reopenedPreferences.waitToExist(timeout: 10), "Workspace Settings did not reopen.")
        let chooseParent = reopenedPreferences.descendants(matching: .any)
            .matching(identifier: "choose-default-parent-folder-button").firstMatch
        XCTAssertTrue(chooseParent.waitToExist(timeout: 10))
        chooseParent.click()
        try chooseFolder(in: openFolderPanel, folder: fixture.parent, confirmationButton: "Use This Folder")
        assertText("default-parent-folder-path", equals: fixture.parent.path)
        let saved = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(saved?["defaultParentFolder"] as? String, fixture.parent.path)

        assertCLIError(
            try runCLI(["settings", "set-parent", fixture.missing.path], expectedStatus: 2),
            code: "invalid_argument"
        )
        assertText("default-parent-folder-path", equals: fixture.parent.path)
        try createTaskFixture(title: "Roots survive settings", roots: [fixture.primary.path, fixture.secondary.path])
        reopenedPreferences.descendants(matching: .any)
            .matching(identifier: "clear-default-parent-folder-button").firstMatch.click()
        let cleared = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertNil(cleared?["defaultParentFolder"] as? String)
        assertText("default-parent-folder-path", equals: "No default parent folder selected")
        attachScreenshot(named: "Workspace settings can be changed and cleared")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitUntil({ !reopenedPreferences.exists }, timeout: 5), "Settings should close before the next UI case launches.")
        XCTAssertTrue(element("board-title").exists, "The main board should remain open when Settings closes.")
        // Roots already saved on a task survive clearing the default parent.
        openTask(named: "Roots survive settings")
        assertOrderedRoots([fixture.primary.path, fixture.secondary.path])
        let roots = try runCLI(["task", "roots", "get", try taskID(named: "Roots survive settings")])["result"] as? [String: Any]
        XCTAssertEqual(roots?["roots"] as? [String], [fixture.primary.path, fixture.secondary.path])
        element("back-to-board-button").click()
    }
    // case-contract: test_repository_suggestions_skip_nested_repositories_and_symlinks | The configured-root workspace repos list API returns top-level Git repositories while excluding nested repositories and symlink targets. The conversation picker shows those suggestions, filters by repository name or parent path, and reports no matches for non-repository folders.
    func test_repository_suggestions_skip_nested_repositories_and_symlinks() throws {
        launchApp(defaultParent: fixture.parent.path)
        let configuredRoot = fixture.parent
        _ = try runCLI(["settings", "set-parent", configuredRoot.path])
        let listed = try runCLI(["workspace", "repos", "list"])["result"] as? [String: Any]
        let expectedRepositories = [fixture.primary.path, fixture.secondary.path, fixture.alternate.path, fixture.changes.path].sorted()
        XCTAssertEqual(listed?["root"] as? String, configuredRoot.path)
        XCTAssertEqual(listed?["repositories"] as? [String], expectedRepositories)
        XCTAssertFalse((listed?["repositories"] as? [String] ?? []).contains(fixture.nested.path))
        XCTAssertFalse((listed?["repositories"] as? [String] ?? []).contains(fixture.linkedOutside.path))

        let result = try runCLI(["workspace", "suggest", "--parent", fixture.parent.path])["result"] as? [String: Any]
        XCTAssertEqual(result?["repositories"] as? [String], expectedRepositories)

        openNewTaskConversation()
        element("add-conversation-repository-button").click()
        let search = element("conversation-repository-search")
        XCTAssertTrue(element("conversation-repository-suggestion-primary").waitToExist(timeout: 10))
        XCTAssertFalse(element("conversation-repository-suggestion-nested").exists, "Nested Git folders should not be suggested.")
        XCTAssertFalse(element("conversation-repository-suggestion-linked-outside").exists, "Symlink targets should not be suggested.")
        replaceText(search, with: "primary")
        XCTAssertTrue(element("conversation-repository-suggestion-primary").waitToExist(timeout: 10))
        XCTAssertFalse(element("conversation-repository-suggestion-secondary").exists, "Search should filter suggestions by repository name.")
        replaceText(search, with: "linked-outside")
        XCTAssertTrue(app.staticTexts["No matching repositories."].waitToExist(timeout: 5))
        replaceText(search, with: "group")
        XCTAssertTrue(element("conversation-repository-suggestion-secondary").waitToExist(timeout: 5), "A path-only query should find a repository inside a matching parent folder.")
        XCTAssertFalse(element("conversation-repository-suggestion-primary").exists)
        replaceText(search, with: "changes")
        XCTAssertTrue(element("conversation-repository-suggestion-changes").exists)
        element("back-to-board-button").click()
        assertScreenshotIfVisible(named: "Repository suggestions exclude nested and symlinked folders")
    }
    // case-contract: test_new_task_remembers_last_selected_repositories | The CLI reads and writes ordered last-selected repositories across fresh XPC connections; repository batches prepare managed worktrees in order, use task-title-derived branches and main/main merge settings, and set the active task roots to those worktrees. The selected source repository list remains saved and applies to subsequent tasks. Invalid repository paths are rejected without changing the saved preference. In the UI, a new conversation automatically attaches saved repositories in order while the picker stays closed and the composer remains focused; while they are still attaching, its empty-state heading already names them and offers no add-repository prompt, and attaching them runs no Git, leaving their branch-from and merge target undecided. Opening the picker and choosing another suggestion adds it to the ordered context and saved selection for subsequent conversations. Each saved selection also feeds a newest-first recent repository history of up to twenty repositories that keeps repositories after they are removed from the selection; the task repository recent command lists those that still exist and are not attached to the task, and rejects an unknown task. In the UI, attached repositories appear as large chips carrying a remove badge and the header shows no suggestion chips; removing a repository through its badge makes the add-repository picker list it under Recent before anything is typed, clicking it adds it back to the task and saved selection, and typing a query replaces the recent list with the regular search suggestions.
    func test_new_task_remembers_last_selected_repositories() throws {
        launchApp(defaultParent: fixture.parent.path)
        _ = try runCLI(["settings", "set-last-repositories", "--repo", fixture.secondary.path, "--repo", fixture.primary.path])

        // Holding the repository's allocation lock keeps the saved repositories attaching, so the
        // heading is seen while they are still on their way rather than after they landed.
        let allocationLock = try RepositoryAllocationLockBarrier(dataDirectory: dataDirectory, repositoryURL: fixture.secondary)
        var allocationLockReleased = false
        defer {
            if !allocationLockReleased { try? allocationLock.release() }
        }
        openNewTaskConversation()
        XCTAssertFalse(element("conversation-repository-search").exists, "Saved repositories should apply without opening the picker.")
        let attachingTask = try XCTUnwrap(tasksFromBoardList().first)
        XCTAssertEqual((attachingTask["repositoryWorktrees"] as? [Any])?.count, 0, "The saved repositories should still be attaching.")
        let heading = element("empty-conversation-repository-title")
        XCTAssertTrue(heading.waitToExist(timeout: 5))
        XCTAssertEqual(accessibleLabelOrValue(of: heading), "secondary · primary",
                       "While the saved repositories attach, the heading names them instead of No repository selected.")
        XCTAssertFalse(element("empty-conversation-add-repository-button").exists, "No add-repository prompt while the saved repositories attach.")
        attachScreenshot(named: "A new task names its saved repositories while they attach")
        try allocationLock.release()
        allocationLockReleased = true
        XCTAssertTrue(element("conversation-repository-badge-secondary").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-repository-badge-primary").waitToExist(timeout: 10))
        XCTAssertEqual(accessibleLabelOrValue(of: heading), "secondary · primary")
        let firstTask = try XCTUnwrap(tasksFromBoardList().first)
        let firstTaskID = try XCTUnwrap(firstTask["id"] as? String)
        let firstRoots = try XCTUnwrap(firstTask["workspaceRoots"] as? [String])
        let firstRepositories = try XCTUnwrap(firstTask["repositoryWorktrees"] as? [[String: Any]])
        XCTAssertEqual(firstRoots, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(firstRepositories.map { $0["repositoryPath"] as? String }, [fixture.secondary.path, fixture.primary.path])
        XCTAssertEqual(firstRepositories.map { $0["branch"] as? String }, ["auto", "auto"])
        // Attaching ran no Git: the defaults wait until a chip opens or the task starts.
        XCTAssertEqual(firstRepositories.map { $0["branchFrom"] as? String }, ["", ""])
        XCTAssertEqual(firstRepositories.map { $0["mergeTarget"] as? String }, [nil, nil])
        assertLastSelectedRepositories([fixture.secondary.path, fixture.primary.path])
        element("back-to-board-button").click()
        assertCLIError(try runCLI(["task", "get", firstTaskID], expectedStatus: 3), code: "not_found")

        openNewTaskConversation()
        XCTAssertTrue(element("conversation-repository-badge-secondary").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-repository-badge-primary").exists)
        element("add-conversation-repository-button").click()
        let overrideSearch = element("conversation-repository-search")
        XCTAssertTrue(overrideSearch.waitToExist(timeout: 5))
        replaceText(overrideSearch, with: "alternate")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").waitToExist(timeout: 10))
        overrideSearch.typeKey(.downArrow, modifierFlags: [])
        overrideSearch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(element("conversation-repository-badge-alternate").waitToExist(timeout: 10))
        let expandedSelection = [fixture.secondary.path, fixture.primary.path, fixture.alternate.path]
        assertLastSelectedRepositories(expandedSelection)

        let quickAddTaskID = try XCTUnwrap(tasksFromBoardList().first?["id"] as? String)
        let alternateBadge = element("conversation-repository-badge-alternate")
        let primaryBadge = element("conversation-repository-badge-primary")
        let alternateRemove = element("remove-conversation-repository-alternate")
        XCTAssertFalse(element("conversation-recent-repositories").exists, "The header should not show recent suggestion chips.")
        XCTAssertTrue(alternateRemove.exists, "Each attached repository chip should carry its own remove badge.")
        XCTAssertGreaterThanOrEqual(alternateBadge.frame.height, 28, "Attached repository chips should be prominent.")
        // #173 enlarged the badge to a 20 pt target; it is still a corner badge, not a full button.
        XCTAssertGreaterThanOrEqual(alternateRemove.frame.width, 20, "The remove badge should be an easy target.")
        XCTAssertLessThanOrEqual(alternateRemove.frame.width, 22, "The remove badge should stay a small corner badge.")
        XCTAssertGreaterThan(alternateRemove.frame.midX, alternateBadge.frame.midX, "The remove badge should sit on the chip's trailing corner.")
        XCTAssertLessThan(alternateRemove.frame.midY, alternateBadge.frame.midY, "The remove badge should sit on the chip's top corner.")
        attachScreenshot(named: "Attached repositories as large chips with remove badges")
        alternateRemove.click()
        XCTAssertTrue(waitForDisappearance(alternateBadge, timeout: 10), "The remove badge should detach the repository.")
        element("remove-conversation-repository-primary").click()
        XCTAssertTrue(waitForDisappearance(primaryBadge, timeout: 10))
        XCTAssertFalse(element("conversation-recent-repositories").exists, "Removed repositories should not reappear as header chips.")
        assertLastSelectedRepositories([fixture.secondary.path])
        XCTAssertEqual(
            (try runCLI(["task", "repository", "recent", quickAddTaskID])["result"] as? [String: Any])?["repositories"] as? [String],
            [fixture.primary.path, fixture.alternate.path]
        )

        element("add-conversation-repository-button").click()
        let recentSearch = element("conversation-repository-search")
        XCTAssertTrue(recentSearch.waitToExist(timeout: 5))
        let recentHeader = element("conversation-repository-recent-header")
        let recentPrimary = element("conversation-repository-recent-primary")
        let recentAlternate = element("conversation-repository-recent-alternate")
        XCTAssertTrue(recentHeader.waitToExist(timeout: 5), "Before typing, the picker should list recent repositories.")
        XCTAssertTrue(recentPrimary.exists)
        XCTAssertTrue(recentAlternate.exists)
        XCTAssertLessThan(recentPrimary.frame.minY, recentAlternate.frame.minY, "Recent repositories should be ordered newest first.")
        XCTAssertFalse(element("conversation-repository-recent-secondary").exists, "An attached repository is not offered again.")
        XCTAssertFalse(element("conversation-repository-suggestion-changes").exists, "The search suggestions wait until something is typed.")
        attachScreenshot(named: "Add repository picker lists recent repositories before typing", fullScreen: true)
        replaceText(recentSearch, with: "alt")
        XCTAssertTrue(element("conversation-repository-suggestion-alternate").waitToExist(timeout: 5), "Typing should switch to the regular search suggestions.")
        XCTAssertFalse(recentHeader.exists, "Typing should replace the recent list.")
        XCTAssertFalse(recentAlternate.exists)
        attachScreenshot(named: "Typing switches the picker to search suggestions", fullScreen: true)
        recentSearch.typeKey("a", modifierFlags: .command)
        recentSearch.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(recentPrimary.waitToExist(timeout: 5), "Clearing the search should bring the recent list back.")
        recentPrimary.click()
        XCTAssertTrue(primaryBadge.waitToExist(timeout: 10), "Clicking a recent repository should add it immediately.")
        XCTAssertTrue(waitForDisappearance(recentSearch), "Adding a recent repository should close the picker.")
        element("add-conversation-repository-button").click()
        XCTAssertTrue(recentAlternate.waitToExist(timeout: 5))
        XCTAssertFalse(recentPrimary.exists, "A re-added repository leaves the recent list.")
        recentAlternate.click()
        XCTAssertTrue(alternateBadge.waitToExist(timeout: 10), "Clicking a recent repository should add it immediately.")
        attachScreenshot(named: "Recent repositories re-added as attached chips")
        // The badge appears before the saved selection is written, so wait for the write.
        XCTAssertTrue(waitUntil({
            ((try? self.runCLI(["settings", "get"]))?["result"] as? [String: Any])?["lastSelectedRepositories"] as? [String] == expandedSelection
        }, timeout: 10), "Re-adding recent repositories should restore the saved selection order.")
        XCTAssertEqual(try XCTUnwrap(tasksFromBoardList().first?["workspaceRoots"] as? [String]), expandedSelection)
        element("back-to-board-button").click()

        openNewTaskConversation()
        XCTAssertFalse(element("conversation-repository-search").exists)
        XCTAssertTrue(element("conversation-repository-badge-secondary").waitToExist(timeout: 10))
        XCTAssertTrue(element("conversation-repository-badge-primary").exists)
        XCTAssertTrue(element("conversation-repository-badge-alternate").waitToExist(timeout: 10))
        XCTAssertEqual(try XCTUnwrap(tasksFromBoardList().first?["workspaceRoots"] as? [String]), expandedSelection)
        element("back-to-board-button").click()
        assertScreenshotIfVisible(named: "New conversation restores and remembers repository choices")
    }
    // case-contract: test_new_task_repository_restore_is_atomic_on_invalid_default | Applying an ordered repository batch with a valid repository followed by an empty Git repository fails without mutation: the CLI reports invalid_argument and fresh reads show no repository attachments or workspace roots; New Task automatically applies saved repositories; an invalid batch shows an error, attaches neither repository, keeps roots empty, preserves the saved order, and leaves the picker closed by default.
    func test_new_task_repository_restore_is_atomic_on_invalid_default() throws {
        launchApp(defaultParent: fixture.parent.path)
        let savedDefaults = [fixture.primary.path, fixture.emptyGitRepository.path]
        let preferenceUpdate = try runCLI([
            "settings", "set-last-repositories",
            "--repo", savedDefaults[0],
            "--repo", savedDefaults[1],
        ])
        XCTAssertEqual(preferenceUpdate["ok"] as? Bool, true)

        openNewTaskConversation()
        let search = element("conversation-repository-search")
        XCTAssertTrue(element("codex-chat-error").waitToExist(timeout: 10), "The failed saved-repository batch should display an error.")
        XCTAssertFalse(search.exists, "A failed default restore should not open the repository picker.")
        XCTAssertFalse(element("conversation-repository-badge-primary").exists, "The first valid repository must not remain attached after the batch fails.")
        XCTAssertFalse(element("conversation-repository-badge-empty-git-repo").exists)

        let task = try XCTUnwrap(tasksFromBoardList().first, "New Task should create its empty conversation before restoring repositories.")
        let taskID = try XCTUnwrap(task["id"] as? String)
        let freshTask = try XCTUnwrap(taskRecord(id: taskID))
        XCTAssertEqual(freshTask["workspaceRoots"] as? [String], [], "The failed batch must leave the task without roots.")
        XCTAssertEqual((freshTask["repositoryWorktrees"] as? [[String: Any]])?.count, 0, "The failed batch must leave the task without repository attachments.")
        let settings = try runCLI(["settings", "get"])["result"] as? [String: Any]
        XCTAssertEqual(settings?["lastSelectedRepositories"] as? [String], savedDefaults, "A failed restore must preserve the user's ordered repository defaults.")

        element("back-to-board-button").click()
        assertScreenshotIfVisible(named: "Failed repository restore leaves the empty new conversation unchanged")
    }
}
